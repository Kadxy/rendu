import BackgroundTasks
import HealthKit
import UIKit

/// Registers every sanctioned wake mechanism and funnels them all into
/// SyncEngine.requestSync: HealthKit observer queries with background
/// delivery (primary), BGAppRefreshTask (opportunistic backstop),
/// BGProcessingTask (long runs while charging, for big catch-ups), and the
/// foreground and unlock hooks (wired in AppServices).
@MainActor
final class TriggerHub {
    static let refreshTaskID = (Bundle.main.bundleIdentifier ?? "rendu") + ".refresh"
    static let processingTaskID = (Bundle.main.bundleIdentifier ?? "rendu") + ".processing"

    private let healthStore: HKHealthStore
    private let engine: SyncEngine
    private let log: LogStore
    private var observerQueries: [HKObserverQuery] = []
    private var lastWakeLogged: Date?

    init(healthStore: HKHealthStore, engine: SyncEngine, log: LogStore) {
        self.healthStore = healthStore
        self.engine = engine
        self.log = log
    }

    // MARK: - Background tasks

    /// Must run before application(_:didFinishLaunchingWithOptions:) returns.
    func registerBackgroundTasks() {
        for (identifier, reason) in [
            (Self.refreshTaskID, SyncReason.backgroundRefresh), (Self.processingTaskID, .backgroundProcessing),
        ] {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] task in
                Task { @MainActor [weak self] in
                    guard let self else {
                        task.setTaskCompleted(success: false)
                        return
                    }
                    self.handle(task, reason: reason)
                }
            }
        }
    }

    private func handle(_ task: BGTask, reason: SyncReason) {
        scheduleBackgroundTasks()
        let work = Task {
            await log.record(.background, title: reason.backgroundTitle, message: "\(reason) task fired")
            await engine.requestSync(reason)
            if !Task.isCancelled {
                task.setTaskCompleted(success: true)
            }
        }
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    /// Refresh: short and opportunistic. Processing: runs for minutes, only
    /// while charging and on a network — iOS picks the moment (typically
    /// overnight), which is when a large backlog can drain.
    func scheduleBackgroundTasks() {
        let refresh = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 2 * 3600)
        BGTaskScheduler.shared.submitTaskRequest(refresh) { _ in }  // unsupported on simulator; fine

        let processing = BGProcessingTaskRequest(identifier: Self.processingTaskID)
        processing.requiresExternalPower = true
        processing.requiresNetworkConnectivity = true
        processing.earliestBeginDate = Date(timeIntervalSinceNow: 3600)
        BGTaskScheduler.shared.submitTaskRequest(processing) { _ in }
    }

    // MARK: - Observer queries

    /// (Re)registers observer queries and background delivery for every
    /// observable catalog type. Some types (step count, for one) HealthKit
    /// delivers at most hourly whatever is asked (HKHealthStore.h).
    func startObservers() async {
        stopObservers()
        for type in TypeCatalog.all where type.observable {
            do {
                try await healthStore.enableBackgroundDelivery(for: type.sampleType, frequency: .immediate)
            } catch {
                await log.warn("background delivery unavailable for \(type.key): \(error.localizedDescription)")
            }
            let key = type.key
            let query = HKObserverQuery(sampleType: type.sampleType, predicate: nil) { [weak self] _, completionHandler, error in
                if error != nil {
                    completionHandler()
                    return
                }
                Task { @MainActor [weak self] in
                    // HealthKit throttles future deliveries if the completion
                    // handler is called before the work is done — so it is
                    // called after the sync pass, from a background task with
                    // a watchdog in case the server hangs.
                    guard let self else {
                        completionHandler()
                        return
                    }
                    await self.observerFired(key)
                    completionHandler()
                }
            }
            healthStore.execute(query)
            observerQueries.append(query)
        }
    }

    func stopObservers() {
        observerQueries.forEach(healthStore.stop)
        observerQueries.removeAll()
    }

    private func observerFired(_ key: String) async {
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "rendu-observer-sync")
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }
        if UIApplication.shared.isProtectedDataAvailable {
            log.debug("observer wake: \(key)")
            // Whether HealthKit wakes the app in the background at all is
            // worth seeing in the log; once a minute is enough.
            if UIApplication.shared.applicationState == .background,
                lastWakeLogged.map({ Date().timeIntervalSince($0) > 60 }) ?? true
            {
                lastWakeLogged = Date()
                await log.record(
                    .background, title: String(localized: "Woken by Apple Health"),
                    detail: DisplayNames.name(forKey: key), message: "observer wake in the background: \(key)"
                )
            }
        } else {
            // F2: health data is unreadable while locked. The attempt is
            // still made — it fails cleanly without moving anchors — and the
            // next unlock-time trigger catches up.
            log.debug("observer wake (\(key)) while device locked — will catch up after unlock")
        }
        let engine = engine
        await withTimeout(seconds: 25) {
            await engine.requestSync(.observer(key))
        }
    }
}

/// Runs an operation but returns after `seconds` even if it hasn't finished,
/// cancelling it. Used to guarantee observer completion handlers are called
/// within the background execution window.
func withTimeout(seconds: TimeInterval, _ operation: @escaping @Sendable () async -> Void) async {
    await withTaskGroup(of: Void.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        await group.next()
        group.cancelAll()
    }
}
