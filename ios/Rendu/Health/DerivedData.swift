import Foundation
import HealthKit

/// Per quantity type, the time range whose statistics are stale because
/// samples were added or deleted there. Persisted so a pass killed between
/// reading samples and uploading statistics still recomputes them later.
struct StaleRanges: Sendable {
    struct Range: Codable, Sendable {
        var start: Date
        var end: Date
        /// A deletion: tombstones carry no dates, so the whole history is
        /// recomputed.
        var full: Bool
    }

    private static let key = "statistics.stale"

    func all() -> [String: Range] {
        guard let data = UserDefaults.standard.data(forKey: Self.key) else { return [:] }
        return (try? JSONDecoder().decode([String: Range].self, from: data)) ?? [:]
    }

    func markAdded(_ key: String, start: Date, end: Date) {
        update { ranges in
            if var range = ranges[key] {
                range.start = min(range.start, start)
                range.end = max(range.end, end)
                ranges[key] = range
            } else {
                ranges[key] = Range(start: start, end: end, full: false)
            }
        }
    }

    func markDeleted(_ key: String) {
        update { ranges in
            let now = Date()
            ranges[key] = Range(start: ranges[key]?.start ?? now, end: max(ranges[key]?.end ?? now, now), full: true)
        }
    }

    func clear(_ key: String) {
        update { $0[key] = nil }
    }

    func clearAll() {
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    private func update(_ mutate: (inout [String: Range]) -> Void) {
        var ranges = all()
        mutate(&ranges)
        if let data = try? JSONEncoder().encode(ranges) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

/// Uploads what HealthKit itself derives from the samples — statistics,
/// activity summaries, characteristics — so the server never has to merge
/// overlapping sources the way the Health app does.
struct DerivedData: Sendable {
    /// Hourly statistics cover only this recent window; daily ones cover all
    /// history.
    static let hourlyWindow: TimeInterval = 30 * 86400
    /// Activity summaries re-sent on every pass (late Watch syncs).
    static let activityWindowDays = 7

    private static let activityBaselineKey = "activity.baselineDone"
    private static let characteristicsKey = "characteristics.lastSent"
    private static let activityRecentKey = "activity.recentSent"

    let healthStore: HKHealthStore
    let outbox: Outbox
    let log: LogStore
    let stale = StaleRanges()
    let context = SerializerContext.live

    // MARK: - Statistics

    func uploadStaleStatistics(progress: @Sendable (Double) async -> Void = { _ in }) async {
        let ranges = stale.all()
        for (index, (key, range)) in ranges.enumerated() {
            await progress(Double(index) / Double(max(ranges.count, 1)))
            guard let type = TypeCatalog.type(for: key)?.sampleType as? HKQuantityType,
                let unit = TypeCatalog.unit(for: type)
            else {
                stale.clear(key)
                continue
            }
            do {
                try await uploadStatistics(type, unit: unit, range: range)
                stale.clear(key)
            } catch  where error.isHealthLocked {
                return
            } catch {
                await log.error("\(key) statistics: \(error.localizedDescription)")
            }
        }
    }

    private func uploadStatistics(_ type: HKQuantityType, unit: HKUnit, range: StaleRanges.Range) async throws {
        let calendar = Calendar.current
        let now = Date()
        let end = max(range.end, now)
        var start = range.start
        if range.full {
            // Nothing left after a deletion: still upload, so the server's
            // replace-in-range clears what it holds.
            start = try await earliestSampleDate(type) ?? now
        }
        // A full recompute replaces everything the server holds, including
        // rows bucketed in another timezone before a trip.
        let epoch = Date(timeIntervalSince1970: 0)

        let dayStart = calendar.startOfDay(for: start)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end))!
        try await upload(
            type, unit: unit, interval: "day", components: DateComponents(day: 1),
            query: dayStart ..< dayEnd, replace: (range.full ? epoch : dayStart) ..< dayEnd
        )

        let windowStart = calendar.dateInterval(of: .hour, for: now.addingTimeInterval(-Self.hourlyWindow))!.start
        let hourStart = max(calendar.dateInterval(of: .hour, for: start)!.start, windowStart)
        let hourEnd = calendar.dateInterval(of: .hour, for: end)!.end
        if hourStart < hourEnd {
            try await upload(
                type, unit: unit, interval: "hour", components: DateComponents(hour: 1),
                query: hourStart ..< hourEnd, replace: (range.full ? epoch : hourStart) ..< hourEnd
            )
        }
    }

    private func upload(
        _ type: HKQuantityType, unit: HKUnit, interval: String, components: DateComponents,
        query: Swift.Range<Date>, replace: Swift.Range<Date>
    ) async throws {
        let cumulative = type.aggregationStyle == .cumulative
        var options: HKStatisticsOptions =
            cumulative
            ? .cumulativeSum
            : [.discreteAverage, .discreteMin, .discreteMax, .mostRecent]
        // How long the samples lasted too (an exposure's duration), where
        // HealthKit computes it for the type.
        let withDuration = Self.durationSupported(type, options)
        if withDuration { options.insert(.duration) }
        func run(_ options: HKStatisticsOptions) async throws -> HKStatisticsCollection {
            try await HKStatisticsCollectionQueryDescriptor(
                predicate: .quantitySample(
                    type: type,
                    predicate: HKQuery.predicateForSamples(withStart: query.lowerBound, end: query.upperBound)
                ),
                options: options,
                anchorDate: query.lowerBound,
                intervalComponents: components
            ).result(for: healthStore)
        }
        let collection: HKStatisticsCollection
        do {
            collection = try await run(options)
        } catch  where withDuration {
            // Refused with duration: remember, and go without it.
            Self.durationRefused.insert(type.identifier)
            collection = try await run(options.subtracting(.duration))
        }
        let zone = TimeZone.current
        let rows: [JSON] = collection.statistics().compactMap { statistics in
            var row: [String: JSON] = [
                "startDate": .string(context.formatter.string(statistics.startDate, in: zone)),
                "endDate": .string(context.formatter.string(statistics.endDate, in: zone)),
            ]
            let values: [(String, HKQuantity?)] =
                cumulative
                ? [("sumQuantity", statistics.sumQuantity())]
                : [
                    ("averageQuantity", statistics.averageQuantity()),
                    ("minimumQuantity", statistics.minimumQuantity()),
                    ("maximumQuantity", statistics.maximumQuantity()),
                    ("mostRecentQuantity", statistics.mostRecentQuantity()),
                ]
            for case (let name, let quantity?) in values where quantity.is(compatibleWith: unit) {
                row[name] = .number(quantity.doubleValue(for: unit))
            }
            guard row.count > 2 else { return nil }
            if let duration = statistics.duration(), duration.is(compatibleWith: .second()) {
                row["duration"] = .number(duration.doubleValue(for: .second()))
            }
            if !cumulative, let interval = statistics.mostRecentQuantityDateInterval() {
                row["mostRecentQuantityDateInterval"] = [
                    "startDate": .string(context.formatter.string(interval.start, in: zone)),
                    "endDate": .string(context.formatter.string(interval.end, in: zone)),
                ]
            }
            return .object(row)
        }
        let payload: JSON = [
            "type": .string(type.identifier),
            "interval": .string(interval),
            "unit": .string(unit.unitString),
            "timeZone": .string(zone.identifier),
            "rangeStart": .string(context.formatter.string(replace.lowerBound, in: zone)),
            "rangeEnd": .string(context.formatter.string(replace.upperBound, in: zone)),
            "statistics": .array(rows),
        ]
        try await outbox.enqueue(.statistics, typeKey: type.identifier, count: rows.count, payload: payload)
    }

    /// Types whose statistics HealthKit refused with `.duration`, this launch.
    nonisolated(unsafe) private static var durationRefused: Set<String> = []

    /// Whether HealthKit accepts `.duration` with these options for the type
    /// (an unsupported combination raises when the query is made).
    private static func durationSupported(_ type: HKQuantityType, _ options: HKStatisticsOptions) -> Bool {
        guard !durationRefused.contains(type.identifier) else { return false }
        let raised = RDCatchException {
            _ = HKStatisticsCollectionQuery(
                quantityType: type, quantitySamplePredicate: nil, options: options.union(.duration), anchorDate: Date(),
                intervalComponents: DateComponents(day: 1))
        }
        if raised != nil { durationRefused.insert(type.identifier) }
        return raised == nil
    }

    private func earliestSampleDate(_ type: HKQuantityType) async throws -> Date? {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)],
            limit: 1
        )
        return try await descriptor.result(for: healthStore).first?.startDate
    }

    // MARK: - Activity summaries

    /// Full history once, then a rolling recent window.
    func uploadActivitySummaries() async {
        let calendar = Calendar.current
        let baselineDone = UserDefaults.standard.bool(forKey: Self.activityBaselineKey)
        let now = Date()
        let start =
            baselineDone
            ? calendar.date(byAdding: .day, value: -Self.activityWindowDays, to: now)!
            : calendar.date(from: DateComponents(year: 2014, month: 1, day: 1))!
        var startComponents = calendar.dateComponents([.era, .year, .month, .day], from: start)
        var endComponents = calendar.dateComponents([.era, .year, .month, .day], from: now)
        startComponents.calendar = calendar
        endComponents.calendar = calendar

        do {
            let descriptor = HKActivitySummaryQueryDescriptor(
                predicate: HKQuery.predicate(forActivitySummariesBetweenStart: startComponents, end: endComponents)
            )
            let summaries = try await descriptor.result(for: healthStore).map { summaryJSON($0, calendar: calendar) }
            // The recent window is re-read on every pass; queue it only when
            // it changed, or passes while the server is down pile up copies.
            let encoded = try Wire.encode(JSON.array(summaries))
            if baselineDone, encoded == UserDefaults.standard.data(forKey: Self.activityRecentKey) { return }
            for chunk in stride(from: 0, to: summaries.count, by: 1000) {
                let slice = Array(summaries[chunk ..< min(chunk + 1000, summaries.count)])
                try await outbox.enqueue(
                    .activitySummaries, typeKey: "activitySummary", count: slice.count, payload: .array(slice))
            }
            // Nothing yet may only mean no read access yet: try the whole
            // history again next time.
            if !summaries.isEmpty {
                UserDefaults.standard.set(true, forKey: Self.activityBaselineKey)
            }
            UserDefaults.standard.set(baselineDone ? encoded : nil, forKey: Self.activityRecentKey)
        } catch {
            await log.error("activity summaries: \(error.localizedDescription)")
        }
    }

    private func summaryJSON(_ summary: HKActivitySummary, calendar: Calendar) -> JSON {
        let day = summary.dateComponents(for: calendar)
        var object: [String: JSON] = [
            "dateComponents": .string(String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)),
            "activityMoveMode": .number(Double(summary.activityMoveMode.rawValue)),
            "paused": .bool(summary.isPaused),
        ]
        let fields: [(String, HKQuantity?, HKUnit)] = [
            ("activeEnergyBurned", summary.activeEnergyBurned, .kilocalorie()),
            ("activeEnergyBurnedGoal", summary.activeEnergyBurnedGoal, .kilocalorie()),
            ("appleMoveTime", summary.appleMoveTime, .minute()),
            ("appleMoveTimeGoal", summary.appleMoveTimeGoal, .minute()),
            ("appleExerciseTime", summary.appleExerciseTime, .minute()),
            ("exerciseTimeGoal", summary.exerciseTimeGoal, .minute()),
            ("appleStandHours", summary.appleStandHours, .count()),
            ("standHoursGoal", summary.standHoursGoal, .count()),
        ]
        for case (let name, let quantity?, let unit) in fields where quantity.is(compatibleWith: unit) {
            object[name] = .number(quantity.doubleValue(for: unit))
        }
        return .object(object)
    }

    // MARK: - Characteristics

    /// Sent only when something changed since the last upload.
    func uploadCharacteristics() async {
        // The server replaces its copy with each upload, so a read that
        // failed (Health is unreadable while the phone is locked) must not
        // pass for "not set" and wipe it.
        var locked = false
        func read<T>(_ body: () throws -> T) -> T? {
            do {
                return try body()
            } catch let error as HKError where error.code == .errorDatabaseInaccessible {
                locked = true
            } catch {}
            return nil
        }
        var object: [String: JSON] = [:]
        if let sex = read({ try healthStore.biologicalSex().biologicalSex }), sex != .notSet {
            object["biologicalSex"] = .number(Double(sex.rawValue))
        }
        if let birth = read({ try healthStore.dateOfBirthComponents() }),
            let year = birth.year, let month = birth.month, let day = birth.day
        {
            object["dateOfBirth"] = .string(String(format: "%04d-%02d-%02d", year, month, day))
        }
        if let blood = read({ try healthStore.bloodType().bloodType }), blood != .notSet {
            object["bloodType"] = .number(Double(blood.rawValue))
        }
        if let skin = read({ try healthStore.fitzpatrickSkinType().skinType }), skin != .notSet {
            object["fitzpatrickSkinType"] = .number(Double(skin.rawValue))
        }
        if let wheelchair = read({ try healthStore.wheelchairUse().wheelchairUse }), wheelchair != .notSet {
            object["wheelchairUse"] = .number(Double(wheelchair.rawValue))
        }
        if let moveMode = read({ try healthStore.activityMoveMode().activityMoveMode }) {
            object["activityMoveMode"] = .number(Double(moveMode.rawValue))
        }
        guard !locked else { return }
        guard let encoded = try? Wire.encode(JSON.object(object)),
            encoded != UserDefaults.standard.data(forKey: Self.characteristicsKey)
        else { return }
        do {
            try await outbox.enqueue(.characteristics, typeKey: "characteristics", count: object.count, payload: .object(object))
            UserDefaults.standard.set(encoded, forKey: Self.characteristicsKey)
        } catch {
            await log.error("characteristics: \(error.localizedDescription)")
        }
    }

    /// Forget what was sent so a re-import resends everything.
    static func resetSentState() {
        UserDefaults.standard.removeObject(forKey: activityBaselineKey)
        UserDefaults.standard.removeObject(forKey: characteristicsKey)
        UserDefaults.standard.removeObject(forKey: activityRecentKey)
        // Sent by SyncEngine; a new or emptied server needs them again.
        UserDefaults.standard.removeObject(forKey: "snapshot.authorization")
        UserDefaults.standard.removeObject(forKey: "snapshot.catalog")
        UserDefaults.standard.removeObject(forKey: "snapshot.medications")
    }
}
