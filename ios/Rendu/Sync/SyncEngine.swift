import Foundation
import HealthKit

extension Error {
    /// HealthKit refuses reads while the iPhone is locked.
    var isHealthLocked: Bool {
        (self as? HKError)?.code == .errorDatabaseInaccessible
    }
}

enum SyncReason: CustomStringConvertible, Sendable {
    case manual
    case foreground
    case observer(String)
    case backgroundRefresh
    case backgroundProcessing
    case unlocked
    case settingsChanged
    case reimport
    case writesSubmitted

    var description: String {
        switch self {
        case .manual: "manual"
        case .foreground: "app opened"
        case .observer(let key): "new \(key) data"
        case .backgroundRefresh: "background refresh"
        case .backgroundProcessing: "background processing"
        case .unlocked: "device unlocked"
        case .settingsChanged: "settings changed"
        case .reimport: "full re-import"
        case .writesSubmitted: "writes submitted"
        }
    }

    /// For the log, when iOS starts a background task for it.
    var backgroundTitle: String {
        switch self {
        case .backgroundProcessing: String(localized: "Background Processing")
        default: String(localized: "Background App Refresh")
        }
    }

    /// Only an explicit request ends a pause the user started by cancelling.
    var overridesPause: Bool {
        switch self {
        case .manual, .reimport: true
        default: false
        }
    }

    /// Switching apps and unlocking come in bursts: a pass for them is
    /// skipped when one ran (or is running) within SyncEngine.throttle.
    /// New Health data (observers), the user, and background tasks always
    /// get one.
    var isThrottled: Bool {
        switch self {
        case .foreground, .unlocked: true
        default: false
        }
    }

    /// Passes the user can see retry auth-blocked types, force the outbox
    /// past its backoff, and refresh characteristics.
    var isUserVisible: Bool {
        switch self {
        case .manual, .foreground, .settingsChanged, .reimport: true
        case .observer, .backgroundRefresh, .backgroundProcessing, .unlocked, .writesSubmitted: false
        }
    }
}

/// Per catalog type: run an anchored query from the last anchor, hand the
/// results to the outbox, and let the outbox persist the new anchor once the
/// server has stored them. The server keeps the same anchors, moved in the
/// same transaction as the samples (store/anchors.go); each pass starts by
/// comparing them, so the phone always continues from what the server
/// really has — after a wipe, a restore, or a crash. An in-memory anchor
/// cache leads the persisted one so overlapping triggers don't re-read
/// samples that are already queued. Each pass first executes pending server
/// writes (so the same pass reads them back), and after the samples uploads
/// what HealthKit derives from them (see DerivedData).
actor SyncEngine {
    static let queryLimit = 20000
    static let throttle: TimeInterval = 60

    private let healthStore: HKHealthStore
    private let anchors: AnchorStore
    private let outbox: Outbox
    private let derived: DerivedData
    private let writes: WriteEngine
    private let log: LogStore
    private let status: AppStatus
    /// This iPhone's anchors on the server (GET /v1/anchors); nil when the
    /// server can't say. And setting them (PUT /v1/anchors).
    private let serverAnchors: @Sendable () async -> [String: Data]?
    private let replaceServerAnchors: @Sendable ([String: Data]) async -> Bool
    /// PUT a JSON body to a server path; false if it didn't take it.
    private let put: @Sendable (String, Data) async -> Bool
    private var anchorCache: [String: HKQueryAnchor] = [:]
    /// The shared medications by concept, for naming dose events.
    private var medicationEntries: [HKHealthConceptIdentifier: Medications.Entry] = [:]
    private var chain: Task<Void, Never>?
    /// A pass waiting behind the running one, and the reason it will run with.
    private var queued: Task<Void, Never>?
    private var queuedReason: SyncReason?
    private var passRunning = false
    private var lastPassEnded: Date?

    init(
        healthStore: HKHealthStore, anchors: AnchorStore, outbox: Outbox, writes: WriteEngine,
        log: LogStore, status: AppStatus,
        serverAnchors: @escaping @Sendable () async -> [String: Data]? = { nil },
        replaceServerAnchors: @escaping @Sendable ([String: Data]) async -> Bool = { _ in false },
        put: @escaping @Sendable (String, Data) async -> Bool = { _, _ in false }
    ) {
        self.healthStore = healthStore
        self.anchors = anchors
        self.outbox = outbox
        self.derived = DerivedData(healthStore: healthStore, outbox: outbox, log: log)
        self.writes = writes
        self.log = log
        self.status = status
        self.serverAnchors = serverAnchors
        self.replaceServerAnchors = replaceServerAnchors
        self.put = put
    }

    /// Every trigger funnels here. Passes are serialized, and triggers that
    /// arrive while a pass is already waiting join it instead of queueing
    /// another: a pass reads every type, so one waiting pass covers them all.
    /// (Registering ~190 observers fires each once — without coalescing that
    /// was ~190 back-to-back full passes.) Each caller returns after the pass
    /// that covers it completes.
    func requestSync(_ reason: SyncReason) async {
        guard wouldRun(reason) else { return }
        if let queued {
            if reason.isUserVisible { queuedReason = reason }
            await queued.value
            return
        }
        queuedReason = reason
        let previous = chain
        let task = Task {
            await previous?.value
            await self.performSync(self.dequeue())
        }
        queued = task
        chain = task
        await task.value
    }

    private func dequeue() -> SyncReason {
        let reason = queuedReason ?? .manual
        queued = nil
        queuedReason = nil
        return reason
    }

    /// Pauses syncing (SyncPause, set by the caller): the running pass stops
    /// at its next check, uploads after the batch in flight. Nothing is lost:
    /// unsent batches stay queued and anchors only ever advance on delivery.
    func pause() async {
        queued?.cancel()
        chain?.cancel()
        await outbox.cancel()
        await log.record(
            .pause, title: String(localized: "Sync Paused"),
            detail: String(
                localized:
                    "Resumes at \(Date(timeIntervalSinceNow: SyncPause.duration).formatted(date: .omitted, time: .shortened))"),
            message: "sync paused for \(Int(SyncPause.duration / 60)) min"
        )
    }

    /// Whether requestSync(reason) would run a pass rather than skip it
    /// (isThrottled).
    func wouldRun(_ reason: SyncReason) -> Bool {
        !(reason.isThrottled && queued == nil
            && (passRunning || lastPassEnded.map({ Date().timeIntervalSince($0) < Self.throttle }) == true))
    }

    /// A pass stops when its task is cancelled or the user pauses midway
    /// (a pass that overrides the pause clears it before it starts).
    private var stopped: Bool { Task.isCancelled || SyncPause.isActive }

    /// One pass, and what the card shows after it: checking still, when
    /// the pass waiting next is one someone asked for.
    private func performSync(_ reason: SyncReason) async {
        await runPass(reason)
        await status.endPass(nextVisible: queued != nil && queuedReason?.isUserVisible == true)
    }

    private func runPass(_ reason: SyncReason) async {
        guard !Task.isCancelled else { return }
        guard HealthAuthorization.asked else {
            log.debug("sync skipped (\(reason)): Apple Health access not asked for yet")
            return
        }
        guard AppSettings.currentTarget() != nil else {  // no server, or not connected
            log.debug("sync skipped (\(reason)): not connected to a server")
            return
        }
        if reason.overridesPause {
            SyncPause.clear()
        } else if SyncPause.isActive {
            log.debug("sync skipped (\(reason)): paused by the user")
            return
        }
        await status.setPausedUntil(nil)
        await status.beginPass(visible: reason.isUserVisible)
        passRunning = true
        defer {
            passRunning = false
            lastPassEnded = Date()
        }
        if case .reimport = reason {
            // Start over on both sides, inside the serialized chain (done by
            // the caller, a pass already running would write its anchors
            // back afterwards).
            guard await replaceServerAnchors([:]) else {
                await log.warn("full re-import needs the server — not started")
                return
            }
            await startOver(anchors: [:])
            log.debug("full re-import: sync state cleared")
        } else {
            await reconcileAnchors()
            if anchorCache.isEmpty {
                // A new process: what's still queued was read already.
                for (key, data) in await outbox.queuedAnchors() {
                    anchorCache[key] = try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
                }
            }
        }
        // Dose events only once the user has chosen medications to share.
        // Types shared object by object, once the user has chosen some.
        let enabled = TypeCatalog.all.filter { $0.perObject?.requested ?? true }
        let userVisible = reason.isUserVisible
        let medications = (try? await Medications.shared(healthStore)) ?? []
        medicationEntries = Medications.entries(medications)

        await writes.runAll()

        var resolvedAnchors: [String: HKQueryAnchor] = [:]
        for type in enabled {
            if let anchor = anchorCache[type.key] ?? anchors.load(type.key) {
                resolvedAnchors[type.key] = anchor
            }
        }

        // Reading is most of preparing; statistics are the rest.
        let readingShare = 0.85
        var queued = 0
        var anyFailed = false
        for (index, type) in enabled.enumerated() {
            if stopped { break }
            await status.setPreparing(readingShare * Double(index) / Double(enabled.count))
            do {
                queued += try await sync(type, anchor: resolvedAnchors[type.key])
            } catch is CancellationError {
                break
            } catch  where error.isHealthLocked {
                // Every type would fail the same way; unlocking syncs again.
                log.debug("Apple Health is locked — stopping until unlock")
                return
            } catch {
                anyFailed = true
                await log.error("\(type.key): \(error.localizedDescription)")
            }
        }
        if stopped { return }

        let status = status
        await derived.uploadStaleStatistics { done in
            await status.setPreparing(readingShare + (1 - readingShare) * done)
        }
        if stopped { return }
        if userVisible || queued > 0 {
            await derived.uploadActivitySummaries()
        }
        if userVisible {
            await derived.uploadCharacteristics()
            await uploadAuthorization()
            await uploadSnapshot("/v1/catalog", key: "snapshot.catalog", await HealthCatalog.json(healthStore))
            if PerObjectAccess.medications.requested {
                await uploadSnapshot(
                    "/v1/medications", key: "snapshot.medications", ["medications": .array(medications.map(Medications.json))])
            }
        }
        // Everything this pass found is queued: now upload it, in one go.
        await outbox.refreshPendingStatus()
        await status.beginUpload(pending: await outbox.summary().remainingUnits)
        await outbox.drain(force: userVisible)
        if !anyFailed, await outbox.pendingCount() == 0 {
            await status.recordSynced()
        }
        if queued > 0 {
            await log.record(
                .health, title: String(localized: "Apple Health"),
                detail: String(AttributedString(localized: "Found ^[\(queued) new sample](inflect: true)").characters),
                message: "sync (\(reason)): queued \(queued) sample(s)"
            )
        }
    }

    /// Makes this iPhone continue from what the server holds: the server's
    /// anchors are the truth. Different ones mean it lost data (wiped,
    /// restored) or this iPhone was just paired (pairing clears them).
    /// Offline, the phone carries on from its own.
    private func reconcileAnchors() async {
        guard let server = await serverAnchors() else { return }
        let local = anchors.allRaw()
        guard server != local else { return }
        if server.isEmpty {
            await log.record(
                .server, .warn, title: String(localized: "Uploading All Data"),
                detail: String(localized: "The server has none of this iPhone's data."),
                message: "the server has none of this iPhone's data — uploading all of it"
            )
        } else {
            let differing = Set(server.keys).union(local.keys).filter { server[$0] != local[$0] }.count
            await log.record(
                .server, .warn, title: String(localized: "Continuing from the Server's Progress"),
                detail: String(
                    AttributedString(localized: "The server's progress differs for ^[\(differing) type](inflect: true).")
                        .characters),
                message: "the server's sync progress differs for \(differing) type(s) — continuing from the server's"
            )
        }
        await startOver(anchors: server)
    }

    /// Drops everything queued and continues from these anchors; with none,
    /// what HealthKit derives (statistics, rings, characteristics) is sent
    /// again too.
    private func startOver(anchors server: [String: Data]) async {
        await outbox.removeSamples()
        anchorCache = [:]
        anchors.replaceAll(server)
        if server.isEmpty {
            DerivedData.resetSentState()
        }
        await status.resetCounters()
    }

    private func sync(_ type: SyncedType, anchor resolvedAnchor: HKQueryAnchor?) async throws -> Int {
        var anchor = resolvedAnchor
        var queued = 0
        while true {
            // A large type reads in many pages; pausing must not wait for all.
            if stopped { throw CancellationError() }
            let descriptor = HKAnchoredObjectQueryDescriptor(
                predicates: [.sample(type: type.sampleType)],
                anchor: anchor,
                limit: type.kind.queryLimit
            )
            let result = try await descriptor.result(for: healthStore)
            let added = result.addedSamples
            let deleted = result.deletedObjects.map { $0.uuid.uuidString }
            if added.contains(where: { $0.sourceRevision.source.bundleIdentifier != Bundle.main.bundleIdentifier }) {
                HealthAuthorization.noteReadFromOthers(type.key)
            }
            let newAnchor = normalize(result.newAnchor)

            if added.isEmpty && deleted.isEmpty {
                // Nothing new. The anchor stays where it is, so it stays the
                // same as the server's (asking again from it costs nothing).
                await status.recordChecked(type.key)
                return queued
            }

            var page: [(sample: HKSample, json: JSON)] = []
            for sample in added {
                if let json = Serializers.serialize(sample, context: .live) { page.append((sample, json)) }
            }
            var elements =
                type.kind.hasSeriesData
                ? try await SeriesData(store: healthStore, medications: medicationEntries).attach(page, kind: type.kind)
                : page.map(\.json)
            let serialized = elements.count
            if serialized < added.count {
                await log.warn("\(type.key): \(added.count - serialized) sample(s) not serializable — skipped")
            }
            if !deleted.isEmpty {
                elements.append(Wire.tombstone(deleted))
                await writes.removedInHealth(deleted)
            }
            let anchorData = newAnchor.flatMap { anchors.archive($0) }
            let baseData = anchor.flatMap { anchors.archive($0) }
            try await outbox.enqueueSamples(typeKey: type.key, elements: elements, anchor: anchorData, base: baseData)
            if type.kind == .quantity {
                if let start = added.map(\.startDate).min(), let end = added.map(\.endDate).max() {
                    derived.stale.markAdded(type.key, start: start, end: end)
                }
                if !deleted.isEmpty {
                    derived.stale.markDeleted(type.key)
                }
            }
            if let newAnchor {
                anchorCache[type.key] = newAnchor
                anchor = newAnchor
            }
            queued += serialized
            await status.recordChecked(type.key)
            log.debug("\(type.key): queued \(serialized) sample(s) + \(deleted.count) deletion(s)")
            if added.count < type.kind.queryLimit && deleted.count < type.kind.queryLimit {
                return queued
            }
        }
    }

    /// Which types Rendu may write, as HealthKit says now (PUT
    /// /v1/authorization): the server turns away writes Health would
    /// refuse before the phone ever sees them. Types missing from the map
    /// are ones HealthKit doesn't let apps write.
    private func uploadAuthorization() async {
        var share: [String: JSON] = [:]
        for type in HealthAuthorization.shareTypes {
            let status: String =
                switch healthStore.authorizationStatus(for: type) {
                case .sharingAuthorized: "sharingAuthorized"
                case .sharingDenied: "sharingDenied"
                default: "notDetermined"
                }
            share[type.identifier] = .string(status)
        }
        await uploadSnapshot("/v1/authorization", key: "snapshot.authorization", ["share": .object(share)])
    }

    /// Sends a document the server replaces wholesale, when it differs from
    /// what the server last took (DerivedData.resetSentState forgets that).
    private func uploadSnapshot(_ path: String, key: String, _ payload: JSON) async {
        guard let body = try? Wire.encode(payload), body != UserDefaults.standard.data(forKey: key) else { return }
        if await put(path, body) {
            UserDefaults.standard.set(body, forKey: key)
        }
    }

    /// The SDK has flip-flopped on the optionality of `newAnchor`; funneling
    /// it through an optional parameter compiles either way.
    private func normalize(_ anchor: HKQueryAnchor?) -> HKQueryAnchor? {
        anchor
    }

    func resetAllAnchors() {
        anchorCache = [:]
    }
}
