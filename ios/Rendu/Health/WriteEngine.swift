import Foundation
import HealthKit
import UIKit

/// Executes the server's pending writes against HealthKit and reports the
/// outcomes (docs/PROTOCOL.md, "App write flow"). Every step is safe to re-run:
/// a write that reached HealthKit but whose result never reached the server
/// is recognized by its sync identifier and version on the next run.
actor WriteEngine {
    struct Pending: Decodable, Sendable {
        let id: String
        let op: String
        let syncIdentifier: String
        let syncVersion: Int?
        let object: JSON?
        let replaceUUIDs: [String]
        let replaceTypes: [String]
        /// The API key that submitted it.
        let submittedBy: Submitter?
    }

    struct Submitter: Decodable, Sendable {
        let id: String
        let name: String
    }

    private struct PendingResponse: Decodable {
        let writes: [Pending]
    }

    private enum Outcome {
        case written([String])
        case failed(String)
        case conflict(String)
        /// Device locked, or write access not asked for yet: leave the write
        /// pending.
        case retryLater
    }

    /// A type's name for the log, when the write had nothing better.
    private static func typeName(_ identifier: String?) -> String {
        identifier.map { DisplayNames.localized($0) ?? DisplayNames.shortName($0) } ?? String(localized: "Write History")
    }

    /// What the write touched, for the write log: the new object for saves,
    /// the removed one for deletes.
    private struct Described {
        var type: String?
        var title: String?
        var items: [WriteRecord.Item] = []
        var alreadyGone = false
        /// When the entry is in Apple Health (its start).
        var sampleDate: Date?
    }

    private let healthStore: HKHealthStore
    private let uploader: HTTPUploader
    private let log: LogStore
    private let writeLog: WriteLog
    private let notifier: Notifier

    /// Shows "Saving to Apple Health" while writes run.
    private let status: AppStatus?

    init(
        healthStore: HKHealthStore, uploader: HTTPUploader, log: LogStore, writeLog: WriteLog, notifier: Notifier,
        status: AppStatus? = nil
    ) {
        self.status = status
        self.healthStore = healthStore
        self.uploader = uploader
        self.log = log
        self.writeLog = writeLog
        self.notifier = notifier
    }

    /// The user deleted these objects in Apple Health (a sync read their
    /// deletion): the write history notes it on the entries they were.
    func removedInHealth(_ uuids: [String]) async {
        await writeLog.recordRemovedInHealth(Set(uuids))
    }

    /// Applies what's pending until nothing is: the server hands out one
    /// write per object at a time, in order, so "save, change, delete" on
    /// one entry takes a round each. Stops when a round settles nothing
    /// (all waiting, or the server didn't take the results).
    func runAll() async {
        for _ in 0 ..< 20 {
            guard await run() > 0 else { return }
        }
    }

    /// Returns how many writes reached a final state and were reported.
    @discardableResult
    func run() async -> Int {
        guard let target = AppSettings.currentTarget() else { return 0 }
        guard await MainActor.run(body: { UIApplication.shared.isProtectedDataAvailable }) else { return 0 }

        let pending: [Pending]
        do {
            let (status, data) = try await uploader.request("GET", "/v1/writes/pending", base: target.base, token: target.token)
            guard status == 200 else {
                await log.warn("writes: GET /v1/writes/pending → HTTP \(status)")
                return 0
            }
            pending = try JSONDecoder().decode(PendingResponse.self, from: data).writes
        } catch {
            await log.warn("writes: could not fetch pending writes (\(error.localizedDescription))")
            return 0
        }
        guard !pending.isEmpty else { return 0 }
        await status?.setSaving(pending.count)
        defer { Task { [status] in await status?.setSaving(nil) } }

        var results: [JSON] = []
        var records: [WriteRecord] = []
        for write in pending {
            var described = Described()
            let outcome = await execute(write, describe: &described)
            let record: (WriteRecord.Outcome, String?, [String]?)
            switch outcome {
            case .written(let uuids):
                results.append(["id": .string(write.id), "status": "written", "uuids": .array(uuids.map(JSON.string))])
                await log.record(
                    .write, title: described.title ?? Self.typeName(described.type ?? write.object?["type"]?.string),
                    detail: String(localized: "Saved to Apple Health"),
                    message: "write \(write.op) \(write.syncIdentifier) v\(write.syncVersion ?? 0): written"
                )
                record = (.written, nil, uuids.isEmpty ? nil : uuids)
            case .failed(let message):
                results.append(["id": .string(write.id), "status": "failed", "error": .string(message)])
                await log.record(
                    .write, .warn, title: described.title ?? Self.typeName(described.type ?? write.object?["type"]?.string),
                    detail: String(localized: "Failed") + " · " + message,
                    message: "write \(write.op) \(write.syncIdentifier): failed — \(message)"
                )
                record = (.failed, message, nil)
            case .conflict(let message):
                results.append(["id": .string(write.id), "status": "conflict", "error": .string(message)])
                await log.record(
                    .write, .warn, title: described.title ?? Self.typeName(described.type ?? write.object?["type"]?.string),
                    detail: String(localized: "Conflict") + " · " + message,
                    message: "write \(write.op) \(write.syncIdentifier): conflict — \(message)"
                )
                record = (.conflict, message, nil)
            case .retryLater:
                log.debug("write \(write.syncIdentifier): Health locked or access not asked for yet — will retry")
                continue
            }
            let action: WriteRecord.Action = write.op == "delete" ? .delete : (write.replaceUUIDs.isEmpty ? .create : .update)
            records.append(
                WriteRecord(
                    id: write.id, date: Date(), action: action, syncIdentifier: write.syncIdentifier,
                    type: described.type ?? write.object?["type"]?.string ?? write.replaceTypes.first,
                    title: described.title, items: described.items, outcome: record.0, error: record.1,
                    alreadyGone: described.alreadyGone ? true : nil,
                    submittedBy: write.submittedBy?.name, submittedByID: write.submittedBy?.id, uuids: record.2,
                    sampleDate: described.sampleDate
                ))
        }
        guard !results.isEmpty else { return 0 }
        await writeLog.append(records)
        await notifier.writesApplied(records)

        do {
            let (status, _) = try await uploader.request(
                "POST", "/v1/writes/results", base: target.base, token: target.token, body: Wire.encode(JSON.array(results))
            )
            if status != 200 {
                await log.warn("writes: reporting results → HTTP \(status); they will be re-derived next run")
                return 0
            }
        } catch {
            await log.warn("writes: could not report results (\(error.localizedDescription)); they will be re-derived next run")
            return 0
        }
        return results.count
    }

    private func execute(_ write: Pending, describe described: inout Described) async -> Outcome {
        do {
            let previous = try await objects(uuids: write.replaceUUIDs, types: write.replaceTypes)
            switch write.op {
            case "save":
                guard let object = write.object, let version = write.syncVersion else {
                    return .failed("save without object or syncVersion")
                }
                let built = try WriteBuilder.plan(object, syncIdentifier: write.syncIdentifier, version: version)
                let types = built.types
                let mainType = built.mainType
                described = Self.describe(built)
                // Only Rendu's own entries can be replaced (HealthKit would
                // refuse to delete another app's).
                if previous.contains(where: { !$0.isOwn }) {
                    return .failed("only entries saved by Rendu can be changed or deleted")
                }
                let statuses = types.map { ($0, healthStore.authorizationStatus(for: $0)) }
                // Turned off by the user: their choice, so the write fails.
                if let denied = statuses.first(where: { $0.1 == .sharingDenied }) {
                    return .failed("write access to \(denied.0.identifier) is turned off for Rendu in the Health settings")
                }
                // Never asked (a type new to this iOS version): the write
                // waits while Rendu asks for access, and is saved once given.
                if statuses.contains(where: { $0.1 == .notDetermined }) {
                    return .retryLater
                }
                if let existing = try await savedVersion(
                    type: mainType, memberTypes: types, syncIdentifier: write.syncIdentifier, version: version
                ) {
                    try await deleteRemaining(write, keeping: existing)
                    return .written(existing)
                }
                if !write.replaceUUIDs.isEmpty && previous.isEmpty {
                    return .conflict("previous objects no longer exist in Health")
                }
                let saved: [String]
                switch built {
                case .sample(let sample):
                    try await healthStore.save(sample)
                    saved = uuids(of: sample)
                case .workout(let plan):
                    saved = try await save(plan)
                case .quantitySeries(let plan):
                    saved = try await save(plan)
                case .heartbeatSeries(let plan):
                    saved = try await save(plan)
                }
                try await deleteRemaining(write, keeping: saved)
                return .written(saved)
            case "delete":
                // A correlation's members are fetched alongside it; describe
                // the top-level object only.
                let members = Set(previous.compactMap { $0 as? HKCorrelation }.flatMap { $0.objects.map(\.uuid) })
                if let top = previous.first(where: { $0 is HKWorkout }) ?? previous.first(where: { !members.contains($0.uuid) }) {
                    described = Described(
                        type: top.sampleType.identifier, title: WriteRecord.title(of: top), items: WriteRecord.items(of: top),
                        sampleDate: top.startDate)
                }
                if previous.contains(where: { !$0.isOwn }) {
                    return .failed("only entries saved by Rendu can be changed or deleted")
                }
                if previous.isEmpty {
                    described.alreadyGone = !write.replaceUUIDs.isEmpty
                } else {
                    try await healthStore.delete(previous)
                }
                return .written([])
            default:
                return .failed("unknown op \(write.op)")
            }
        } catch let error as HKError where error.code == .errorDatabaseInaccessible {
            return .retryLater
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Deletes the previous version's objects that still exist. Re-fetched
    /// after saving: for plain samples HealthKit already replaced the old
    /// version (same sync identifier, higher version).
    private func deleteRemaining(_ write: Pending, keeping kept: [String]) async throws {
        let stale = Set(write.replaceUUIDs).subtracting(kept)
        let remaining = try await objects(uuids: Array(stale), types: write.replaceTypes)
        if !remaining.isEmpty {
            try await healthStore.delete(remaining)
        }
    }

    /// Builds and saves a workout with the samples that go with it
    /// (HKWorkoutBuilder computes its totals from them).
    private func save(_ plan: WriteBuilder.WorkoutPlan) async throws -> [String] {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = plan.activityType
        let builder = HKWorkoutBuilder(healthStore: healthStore, configuration: configuration, device: .local())
        try await builder.beginCollection(at: plan.start)
        if !plan.samples.isEmpty {
            try await builder.addSamples(plan.samples)
        }
        for activity in plan.activities {
            try await builder.addWorkoutActivity(activity)
        }
        if !plan.events.isEmpty {
            try await builder.addWorkoutEvents(plan.events)
        }
        try await builder.addMetadata(plan.metadata)
        try await builder.endCollection(at: plan.end)
        guard let workout = try await builder.finishWorkout() else {
            throw WriteBuilder.Invalid(message: "HealthKit saved no workout")
        }
        var saved = [workout.uuid.uuidString] + plan.samples.map(\.uuid.uuidString)
        if !plan.route.isEmpty {
            let route = HKWorkoutRouteBuilder(healthStore: healthStore, device: .local())
            try await route.insertRouteData(plan.route)
            saved.append(try await route.finishRoute(with: workout, metadata: plan.routeMetadata).uuid.uuidString)
        }
        // Effort is related to the workout, not added to it.
        for sample in plan.effort {
            try await healthStore.save(sample)
            try await healthStore.relateWorkoutEffortSample(sample, with: workout, activity: nil)
            saved.append(sample.uuid.uuidString)
        }
        return saved
    }

    private func save(_ plan: WriteBuilder.QuantitySeriesPlan) async throws -> [String] {
        let builder = HKQuantitySeriesSampleBuilder(
            healthStore: healthStore, quantityType: plan.type, startDate: plan.start, device: .local())
        for point in plan.points {
            try builder.insert(point.quantity, for: point.interval)
        }
        return try await builder.finishSeries(metadata: plan.metadata, endDate: plan.end).map(\.uuid.uuidString)
    }

    private func save(_ plan: WriteBuilder.HeartbeatPlan) async throws -> [String] {
        let builder = HKHeartbeatSeriesBuilder(healthStore: healthStore, device: .local(), start: plan.start)
        for beat in plan.beats {
            try await builder.addHeartbeat(at: beat.time, precededByGap: beat.precededByGap)
        }
        try await builder.addMetadata(plan.metadata)
        return [try await builder.finishSeries().uuid.uuidString]
    }

    /// What the write log says about it.
    private static func describe(_ built: WriteBuilder.Built) -> Described {
        switch built {
        case .sample(let sample):
            return Described(
                type: sample.sampleType.identifier, title: WriteRecord.title(of: sample), items: WriteRecord.items(of: sample),
                sampleDate: sample.startDate)
        case .workout(let plan):
            let minutes = Int((plan.end.timeIntervalSince(plan.start) / 60).rounded())
            let workout = HKObjectType.workoutType().identifier
            let summary = WriteRecord.Item(
                type: workout, value: "\(WorkoutActivityName.name(for: plan.activityType)) · \(minutes) min")
            return Described(
                type: workout, title: nil, items: [summary] + (plan.samples + plan.effort).flatMap(WriteRecord.items(of:)),
                sampleDate: plan.start)
        case .quantitySeries(let plan):
            let item = WriteRecord.Item(type: plan.type.identifier, value: String(localized: "\(plan.points.count) values"))
            return Described(type: plan.type.identifier, title: nil, items: [item], sampleDate: plan.start)
        case .heartbeatSeries(let plan):
            let type = HKSeriesType.heartbeat().identifier
            return Described(
                type: type, title: nil,
                items: [WriteRecord.Item(type: type, value: String(localized: "\(plan.beats.count) beats"))],
                sampleDate: plan.start)
        }
    }

    /// The uuids already stored for this sync identifier at this version,
    /// if an earlier run saved it (with a workout's samples).
    private func savedVersion(
        type: HKSampleType, memberTypes: [HKSampleType], syncIdentifier: String, version: Int
    ) async throws -> [String]? {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [
                .sample(
                    type: type,
                    predicate: HKQuery.predicateForObjects(
                        withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: [syncIdentifier])
                )
            ],
            sortDescriptors: []
        )
        let matches = try await descriptor.result(for: healthStore).filter {
            ($0.metadata?[HKMetadataKeySyncVersion] as? NSNumber)?.intValue == version
        }
        guard let match = matches.first else { return nil }
        guard let workout = match as? HKWorkout else { return uuids(of: match) }
        var found = [workout.uuid.uuidString]
        for memberType in Set(memberTypes) where memberType != type {
            let members = HKSampleQueryDescriptor(
                predicates: [.sample(type: memberType, predicate: HKQuery.predicateForObjects(from: workout))],
                sortDescriptors: []
            )
            found += try await members.result(for: healthStore).map(\.uuid.uuidString)
        }
        return found
    }

    private func objects(uuids: [String], types: [String]) async throws -> [HKSample] {
        let ids = Set(uuids.compactMap(UUID.init(uuidString:)))
        guard !ids.isEmpty else { return [] }
        var found: [HKSample] = []
        for typeName in types {
            guard let type = sampleType(typeName) else { continue }
            let descriptor = HKSampleQueryDescriptor(
                predicates: [.sample(type: type, predicate: HKQuery.predicateForObjects(with: ids))],
                sortDescriptors: []
            )
            found += try await descriptor.result(for: healthStore)
        }
        return found
    }

    private func sampleType(_ identifier: String) -> HKSampleType? {
        TypeCatalog.type(for: identifier)?.sampleType
    }

    private func uuids(of sample: HKSample) -> [String] {
        var uuids = [sample.uuid.uuidString]
        if let correlation = sample as? HKCorrelation {
            uuids += correlation.objects.map(\.uuid.uuidString).sorted()
        }
        return uuids
    }
}

extension HKObject {
    /// Saved by this app.
    var isOwn: Bool { sourceRevision.source == HKSource.default() }
}
