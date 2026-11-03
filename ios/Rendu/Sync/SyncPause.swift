import Foundation

/// After the user pauses syncing, automatic syncing (observer wakes,
/// background tasks, unlock, foreground) waits this long; resuming or a
/// manual sync ends the pause at once. Long enough not to restart under the
/// user's finger, short enough that syncing never silently stops for good.
enum SyncPause {
    static let duration: TimeInterval = 3600
    private static let key = "sync.pausedUntil"

    static var until: Date? {
        guard let date = UserDefaults.standard.object(forKey: key) as? Date, date > .now else { return nil }
        return date
    }

    static var isActive: Bool { until != nil }

    @discardableResult
    static func start() -> Date {
        let until = Date(timeIntervalSinceNow: duration)
        UserDefaults.standard.set(until, forKey: key)
        return until
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
