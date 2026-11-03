import BackgroundTasks
import Foundation
import UIKit

/// Keeps a large sync running after the user leaves the app: a continued
/// processing task (iOS 26), which iOS shows with its own progress on the
/// Lock Screen and in the Dynamic Island, and which the user can stop there.
/// Started while the app is open (iOS only accepts it then); it follows the
/// sync's progress and ends when the queue is empty or syncing pauses.
/// Without it an app gets about 30 seconds after it leaves the screen.
@MainActor
final class ContinuedUpload {
    /// Smaller syncs finish in the 30 seconds iOS gives anyway.
    static let threshold = 2000
    private static let identifierPrefix = (Bundle.main.bundleIdentifier ?? "rendu") + ".upload."

    private let status: AppStatus
    private let log: LogStore
    /// What to do when the user stops the task from the system UI.
    var onStop: () -> Void = {}

    private var task: BGContinuedProcessingTask?
    private var submitted = false
    private var monitor: Task<Void, Never>?

    init(status: AppStatus, log: LogStore) {
        self.status = status
        self.log = log
    }

    /// Call while a sync runs and when the app comes to the foreground: it
    /// starts once the sync has queued enough to outlast the app's ~30 s.
    func startIfNeeded() {
        guard !submitted, task == nil,
            UIApplication.shared.applicationState == .active,
            status.syncing || status.uploading,
            status.outbox.remainingUnits >= Self.threshold,
            !SyncPause.isActive
        else { return }
        let identifier = Self.identifierPrefix + UUID().uuidString.prefix(8)
        // Continued processing handlers are registered when they're needed.
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.run(task)
            }
        }
        guard registered else { return }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier, title: String(localized: "Syncing Apple Health Data"), subtitle: subtitle
        )
        request.strategy = .fail
        submitted = true
        let log = log
        Task { [weak self] in
            do {
                try await BGTaskScheduler.shared.submitTaskRequest(request)
            } catch {
                await log.info("background sync not available now: \(error.localizedDescription)")
            }
            // Submitted but never started: allow another try later.
            try? await Task.sleep(for: .seconds(15))
            if let self, self.task == nil { self.submitted = false }
        }
    }

    private func run(_ task: BGContinuedProcessingTask) {
        self.task = task
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                // Stopped by the user in the system UI, or by iOS.
                self?.finish(success: false)
                self?.onStop()
            }
        }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.update() { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Mirrors the sync into the task; false once the task is done.
    private func update() -> Bool {
        guard let task else { return false }
        let outbox = status.outbox
        if SyncPause.isActive || (!status.syncing && !status.uploading) {
            finish(success: !SyncPause.isActive)
            return false
        }
        // Preparing is the first part of the bar, uploading the rest.
        let prepareShare = 0.3
        let done: Double =
            if let preparing = status.preparing {
                prepareShare * preparing
            } else {
                prepareShare + (1 - prepareShare)
                    * (outbox.sessionTotal > 0
                        ? 1 - Double(status.remaining(at: .now)) / Double(outbox.sessionTotal) : 0)
            }
        task.progress.totalUnitCount = 1000
        task.progress.completedUnitCount = Int64(done * 1000)
        task.updateTitle(String(localized: "Syncing Apple Health Data"), subtitle: subtitle)
        return true
    }

    private var subtitle: String {
        if status.preparing != nil {
            String(localized: "Checking for new data…")
        } else {
            String(localized: "\(status.remaining(at: .now).formatted()) left")
        }
    }

    private func finish(success: Bool) {
        monitor?.cancel()
        monitor = nil
        task?.setTaskCompleted(success: success)
        task = nil
        submitted = false
    }
}
