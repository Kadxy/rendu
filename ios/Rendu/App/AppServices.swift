import Foundation
import HealthKit
import SwiftUI

/// Writes applied by the app, for the Writes screen (fed by WriteLog).
@Observable
@MainActor
final class WriteHistory {
    var records: [WriteRecord] = []
    /// The log was read (WriteLog's sink).
    var loaded = false
    /// Entries this iPhone is deleting from Apple Health right now, by sync
    /// identifier.
    var deleting: Set<String> = []

    /// Entries with a delete on its way: this iPhone's, and the server's.
    func deletesUnderway(_ pending: [QueuedWrite]) -> Set<String> {
        deleting.union(pending.filter { $0.op == "delete" }.map(\.syncIdentifier))
    }
}

/// The server as last seen from this phone.
@Observable
@MainActor
final class ServerState {
    enum Reachability: Equatable {
        /// notPaired: no key; keyRejected: the server no longer accepts it.
        case unknown, notPaired, online, keyRejected
        case offline(String)
    }

    var reachability: Reachability = .unknown
    var status: ServerStatus?
    var checkedAt: Date?
    /// The server's API keys as last loaded; nil before the first load.
    var apiKeys: [APIKey]?
    /// This iPhone's own credential id (writes it submits name it).
    var ownerKeyID: String?
    /// Writes waiting for this iPhone, as last loaded.
    var pendingWrites: [QueuedWrite] = []
}

/// Composition root: owns the components and the lifecycle glue.
@MainActor
final class AppServices {
    let healthStore = HKHealthStore()
    let settings = AppSettings()
    let status = AppStatus(defaults: Demo.isOn ? Demo.defaults : .standard)
    let writes = WriteHistory()
    let server = ServerState()
    let serverData = ServerData()
    let log: LogStore
    let writeLog: WriteLog
    let notifier = Notifier()
    let anchors: AnchorStore
    let outbox: Outbox
    let engine: SyncEngine
    let hub: TriggerHub
    let uploader = HTTPUploader()
    let lock = ServerLock()
    let continued: ContinuedUpload
    private var unlockObserver: NSObjectProtocol?
    private var resumeTask: Task<Void, Never>?
    private var statusRefresh: Task<Void, Never>?
    private var writesWatch: Task<Void, Never>?
    /// The server's writes anchor as last seen (watchWrites).
    private var writesAnchor: String?
    private var wiping = false

    init() {
        let fm = FileManager.default
        let support =
            (try? fm.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )) ?? fm.temporaryDirectory
        var root = Demo.isOn ? Demo.prepare() : support.appendingPathComponent("Rendu", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        // Pending health data must not leak into device backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)

        log = LogStore(directory: root)
        writeLog = WriteLog(directory: root)
        anchors = AnchorStore(directory: root.appendingPathComponent("Anchors", isDirectory: true))
        let notifier = notifier
        outbox = Outbox(
            directory: root.appendingPathComponent("Outbox", isDirectory: true),
            anchors: anchors,
            uploader: uploader,
            target: { AppSettings.currentTarget() },
            log: log,
            status: status,
            onPersistentFailure: { reason in await notifier.deliveryFailing(reason) }
        )
        let uploader = uploader
        engine = SyncEngine(
            healthStore: healthStore, anchors: anchors, outbox: outbox,
            writes: WriteEngine(
                healthStore: healthStore, uploader: uploader, log: log, writeLog: writeLog, notifier: notifier, status: status),
            log: log, status: status,
            serverAnchors: {
                guard let target = AppSettings.currentTarget() else { return nil }
                return await uploader.serverAnchors(base: target.base, token: target.token)
            },
            replaceServerAnchors: { anchors in
                guard let target = AppSettings.currentTarget() else { return false }
                return await uploader.replaceServerAnchors(base: target.base, token: target.token, anchors)
            },
            put: { path, body in
                guard let target = AppSettings.currentTarget(),
                    let result = try? await uploader.send(
                        body, gzipped: false, method: "PUT",
                        to: target.base.appending(path: path), token: target.token, headers: [:])
                else { return false }
                return result.isSuccess
            }
        )
        hub = TriggerHub(healthStore: healthStore, engine: engine, log: log)
        continued = ContinuedUpload(status: status, log: log)
        serverData.directory = root
        serverData.loadCache()

        status.load()
        let status = status
        let log = log
        let writes = writes
        let writeLog = writeLog
        Task {
            let entries = await log.tail(200)
            status.seedLog(entries)
            await log.setSink { entry in
                Task { @MainActor in status.push(entry) }
            }
            await writeLog.setSink { records in
                Task { @MainActor in
                    // What's new since the last time, for Recent: none at
                    // the first, which is the log as stored.
                    if writes.loaded {
                        let known = Set(writes.records.map(\.id))
                        status.recordWrites(records.filter { !known.contains($0.id) })
                    }
                    writes.loaded = true
                    writes.records = records
                }
            }
        }
    }

    /// Development only: `devicectl … process launch <bundle ID> --
    /// -rendu-dev <action>` drives what is otherwise a tap, for measuring on
    /// a real device. Normal launches pass no arguments.
    private func runDevAction() async {
        guard let action = UserDefaults.standard.string(forKey: "rendu-dev") else { return }
        try? await Task.sleep(for: .seconds(2))
        log.debug("dev action: \(action)")
        switch action {
        case "reimport":
            await reimportAll()
        case "reimport-pause":
            Task { await reimportAll() }
            try? await Task.sleep(for: .seconds(30))
            await pauseSync()
        case "sync":
            await syncNow(.manual)
        default:
            break
        }
    }

    private var isTestRun: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Called from application(_:didFinishLaunchingWithOptions:). Also runs
    /// when HealthKit relaunches the app in the background for delivery.
    func launch() {
        guard HKHealthStore.isHealthDataAvailable() else {
            status.healthUnavailable = true
            return
        }
        guard !isTestRun else { return }
        if Demo.isOn {
            // Made-up data only: no Apple Health, no syncing.
            status.accessAsked = true
            Task {
                await refreshServerStatus()
                await refreshServerData()
                try? await loadAPIKeys()
            }
            return
        }
        hub.registerBackgroundTasks()
        hub.scheduleBackgroundTasks()
        continued.onStop = { [weak self] in Task { await self?.pauseSync() } }
        // Health data becomes readable again on unlock: resume right away
        // instead of waiting for the next observer wake.
        unlockObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.engine.requestSync(.unlocked) }
        }
        let notifier = notifier
        Task {
            await runDevAction()
        }
        Task {
            await notifier.requestAuthorization()
            await notifier.scheduleSigningReminder()
            await hub.startObservers()
            await refreshAuthStatus()
            await HealthAuthorization.learnReadFromOthers(healthStore)
            await refreshDerived()
        }
    }

    func scenePhase(_ phase: ScenePhase) {
        guard !isTestRun, !status.healthUnavailable, !Demo.isOn else { return }
        switch phase {
        case .active:
            settings.reload()
            continued.startIfNeeded()
            watchWrites()
            Task {
                await refreshAuthStatus()
                await syncNow(.foreground)
            }
        case .background:
            writesWatch?.cancel()
            hub.scheduleBackgroundTasks()
            lock.lock()
        default:
            break
        }
    }

    func syncNow(_ reason: SyncReason = .manual) async {
        if Demo.isOn {
            await refreshServerStatus()
            return
        }
        // Backfill can take a while; don't let the screen lock kill it (F2),
        // and ask for time to finish the batch in flight if the user leaves.
        UIApplication.shared.isIdleTimerDisabled = true
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "rendu-sync")
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }
        if reason.overridesPause {
            resumeTask?.cancel()
            status.pausedUntil = nil
        }
        // Shown from the tap (or the app opening) to the end of its pass;
        // a pass the throttle skips isn't shown at all.
        if reason.isUserVisible {
            let runs = if reason.isThrottled { await engine.wouldRun(reason) } else { true }
            if runs { status.showChecking() }
        }
        // Where things stand with the server first: a pass against a server
        // that refuses this iPhone's key would only fail.
        await refreshServerStatus()
        if server.reachability == .keyRejected {
            status.cancelChecking()
            return
        }
        let watch = Task { [weak self] in
            // A pass that turns out large keeps running in the background.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.continued.startIfNeeded()
            }
        }
        await engine.requestSync(reason)
        watch.cancel()
        await refreshDerived()
        await refreshServerStatus()
        if !server.pendingWrites.isEmpty || (server.status?.pendingWrites ?? 0) > 0 {
            await loadPendingWrites()
        }
    }

    /// While the app is open, waits on the server for writes to be
    /// submitted and runs a pass when one is, so it's saved at once — there
    /// is no push. In the background, the passes that run anyway (Health's
    /// wakes, background refresh) pick writes up.
    private func watchWrites() {
        writesWatch?.cancel()
        writesWatch = Task { [weak self] in
            while !Task.isCancelled, let self, let target = AppSettings.currentTarget() {
                do {
                    let anchor = try await uploader.awaitWrites(
                        base: target.base, token: target.token, anchor: writesAnchor, wait: 25)
                    // A server that can't wait would answer at once, every time.
                    guard let anchor else { return }
                    let submitted = writesAnchor.map { $0 != anchor } ?? false
                    writesAnchor = anchor
                    if submitted { await syncNow(.writesSubmitted) }
                } catch {
                    if Task.isCancelled { return }
                    try? await Task.sleep(for: .seconds(30))
                }
            }
        }
    }

    /// Pauses syncing (SyncPause) — at once on screen, and the running pass
    /// and uploads at their next step. While the app stays alive, syncing
    /// resumes by itself when the pause ends; otherwise the next wake after
    /// it does. Resuming or a manual sync ends it sooner.
    func pauseSync() async {
        status.pausedUntil = SyncPause.start()
        await engine.pause()
        await refreshDerived()
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(SyncPause.duration + 5))
            guard !Task.isCancelled else { return }
            await self?.engine.requestSync(.backgroundRefresh)
        }
    }

    /// Asks the server for its status, once more after a moment if that
    /// fails (a single dropped request shouldn't read as an outage). Calls
    /// while one is out share it, and it runs on its own: a screen that
    /// asked and went away (switching tabs) doesn't cancel it — a cancelled
    /// request once read as the server being down. `maxAge`: an answer that
    /// recent is good enough.
    func refreshServerStatus(maxAge: TimeInterval = 0) async {
        if maxAge > 0, server.reachability == .online,
            let checked = server.checkedAt, Date().timeIntervalSince(checked) < maxAge
        {
            return
        }
        if let statusRefresh {
            await statusRefresh.value
            return
        }
        let task = Task { await checkServer() }
        statusRefresh = task
        await task.value
        statusRefresh = nil
    }

    private func checkServer() async {
        guard let base = settings.baseURL else {
            server.reachability = .unknown
            return
        }
        guard settings.isPaired else {
            server.reachability = .notPaired
            server.status = nil
            return
        }
        for attempt in 1 ... 2 {
            do {
                server.status = try await uploader.serverStatus(base: base, token: settings.key)
                server.reachability = .online
                break
            } catch is KeyRejected {
                server.reachability = .keyRejected
                break
            } catch {
                if (error as? URLError)?.code == .cancelled { return }
                if attempt == 2 {
                    server.reachability = .offline(error.localizedDescription)
                } else {
                    try? await Task.sleep(for: .seconds(1.5))
                }
            }
        }
        server.checkedAt = Date()
    }

    /// Loads the server's API keys (not this iPhone's own) into
    /// server.apiKeys; throws when the server can't be reached.
    func loadAPIKeys() async throws {
        guard let base = settings.baseURL, settings.isPaired else { return }
        let keys = try await uploader.apiKeys(base: base, token: settings.key)
        server.ownerKeyID = keys.first { $0.scope == .owner }?.id
        server.apiKeys = keys.filter { $0.scope != .owner }
    }

    func loadPendingWrites() async {
        guard let base = settings.baseURL, settings.isPaired else { return }
        if let writes = try? await uploader.pendingWrites(base: base, token: settings.key) {
            server.pendingWrites = writes
        }
    }

    /// Deletes an entry Rendu saved from Apple Health, the way the server's
    /// other writes go — submitted to the server, so it keeps every entry's
    /// one history — and run at once by the sync this starts. A delete
    /// Apple Health refuses is recorded as failed, like any write.
    func deleteFromHealth(syncIdentifier: String) async throws {
        guard let base = settings.baseURL else { return }
        writes.deleting.insert(syncIdentifier)
        do {
            try await uploader.submitDelete(base: base, token: settings.key, syncIdentifier: syncIdentifier)
        } catch {
            writes.deleting.remove(syncIdentifier)
            throw error
        }
        await log.record(.write, title: String(localized: "Delete Requested"), message: "delete requested for \(syncIdentifier)")
        Task {
            await syncNow(.manual)
            // Still pending (say, access to the type was never asked for),
            // it shows as waiting.
            await loadPendingWrites()
            writes.deleting.remove(syncIdentifier)
        }
    }

    /// The types the server holds (Browse).
    func refreshServerData() async {
        guard let base = settings.baseURL, settings.isPaired else {
            serverData.types = []
            return
        }
        do {
            serverData.store(try await uploader.serverTypes(base: base, token: settings.key))
        } catch {
            // The last copy stays on screen, marked with its age.
            serverData.error = error.localizedDescription
        }
    }

    /// Empties the server's health data. The next pass finds the server
    /// without this iPhone's sync progress and uploads everything again. A
    /// second call while one runs is ignored.
    func wipeServer() async throws {
        guard let base = settings.baseURL, !wiping else { return }
        wiping = true
        defer { wiping = false }
        try await uploader.wipeServerData(base: base, token: settings.key)
        await log.record(
            .server, .warn, title: String(localized: "Server Data Cleared"), message: "server data wiped from this iPhone")
        serverData.store([])
        await syncNow(.manual)
    }

    /// Keeps the key this iPhone just paired with `url`, and syncs.
    func paired(server url: URL, key: String) async {
        if settings.endpoint != url.absoluteString {
            serverData.store([])
        }
        do {
            try settings.paired(server: url, key: key)
        } catch {
            await log.error("could not save the key: \(error.localizedDescription)")
            return
        }
        await log.record(
            .server, title: String(localized: "Paired"), detail: url.host() ?? url.absoluteString,
            message: "paired with \(url.host() ?? url.absoluteString)")
        await refreshServerStatus()
        writesAnchor = nil
        watchWrites()
        // The first sync can take a while; the caller doesn't wait for it.
        Task {
            await syncNow(.manual)
            await refreshServerData()
        }
    }

    /// Deletes this iPhone's key. The server keeps the key's hash until
    /// another iPhone pairs, but nobody holds the key anymore.
    func forgetServer() async {
        await pauseSync()
        writesWatch?.cancel()
        settings.forget()
        server.reachability = .notPaired
        server.status = nil
        server.apiKeys = nil
        await log.record(
            .server, .warn, title: String(localized: "Server Forgotten"), detail: settings.baseURL?.host() ?? settings.endpoint,
            message: "forgot the key for \(settings.baseURL?.host() ?? settings.endpoint)")
    }

    func requestHealthAccess() async {
        do {
            try await HealthAuthorization.request(healthStore, log: log)
        } catch {
            await log.error("authorization request failed: \(error.localizedDescription)")
        }
        await refreshAuthStatus()
        await syncNow(.manual)
    }

    /// Shows iOS's sheet for choosing which objects (medications,
    /// prescriptions) Rendu may read, then syncs them. Returns why the sheet
    /// couldn't be shown, if it couldn't.
    func chooseShared(_ access: PerObjectAccess) async -> String? {
        do {
            try await access.request(healthStore)
        } catch {
            await log.error("\(access.rawValue) access request failed: \(error.localizedDescription)")
            return error.localizedDescription
        }
        Task { await syncNow(.manual) }
        return nil
    }

    func refreshAuthStatus() async {
        guard !status.healthUnavailable else { return }
        do {
            status.authNeeded = try await HealthAuthorization.needsRequest(healthStore, log: log)
            if !status.authNeeded { HealthAuthorization.asked = true }
            status.accessAsked = HealthAuthorization.asked
            status.healthAccessOff = !status.authNeeded && HealthAuthorization.accessTurnedOff(healthStore)
        } catch {
            // Typically a signing problem (missing HealthKit entitlement) —
            // surface it, and keep the last known authNeeded rather than
            // clearing it: hiding the Grant button on a transient error
            // would strand newly added types with no way to authorize them.
            await log.warn("could not determine Health authorization status: \(error.localizedDescription)")
        }
    }

    func refreshDerived() async {
        status.needsInitialImport = TypeCatalog.all.contains { !anchors.hasAnchor($0.key) }
        await outbox.refreshPendingStatus()
    }

    /// Clears this iPhone's sync progress, here and on the server, and sends
    /// everything again. Safe (the server dedupes by uuid) but slow, so
    /// it's behind a confirmation. Interrupted, it continues from wherever
    /// the server got to.
    func reimportAll() async {
        await log.record(.server, .warn, title: String(localized: "Re-import All History"), message: "full re-import requested")
        await syncNow(.reimport)
    }

}
