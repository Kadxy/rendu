import Foundation
import UserNotifications

/// Local notifications: writes applied to Health, deliveries that keep
/// failing, and the free-account signature running out. Remote push would
/// need a paid developer account; these are scheduled on the device.
final class Notifier: NSObject, Sendable, UNUserNotificationCenterDelegate {
    enum Kind: String {
        case writes = "rendu.writes"
        case deliveryFailing = "rendu.delivery-failing"
        case signingExpiry = "rendu.signing-expiry"
    }

    /// User preferences (Settings), all on by default.
    @UserDefault("notifications.writes") static var writesEnabled = true
    @UserDefault("notifications.failures") static var failuresEnabled = true
    @UserDefault("notifications.expiry") static var expiryEnabled = true

    private var center: UNUserNotificationCenter { .current() }

    func requestAuthorization() async {
        center.delegate = self
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// With Rendu open, what a notification would say is already on screen
    /// — the sync card saving, the new row in Write History, the server
    /// waiting — so none is shown, as Mail adds a message to the mailbox
    /// you're looking at (HIG, Notifications). The signature running out is
    /// shown nowhere else.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        notification.request.identifier == Kind.signingExpiry.rawValue ? [.banner, .list, .sound] : []
    }

    func writesApplied(_ records: [WriteRecord]) async {
        guard Self.writesEnabled, !records.isEmpty else { return }
        let written = records.filter { $0.outcome == .written }
        let rejected = records.count - written.count
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Saved to Apple Health")
        if records.count == 1, let record = records.first {
            if record.outcome != .written {
                content.title = String(localized: "Not Saved to Apple Health")
            }
            content.body = "\(record.action.label) · \(record.summary)"
        } else if rejected == 0 {
            // Inflection ("1 entry", "5 entries") needs an AttributedString;
            // String(localized:) shows the markup as is.
            content.body = String(AttributedString(localized: "^[\(written.count) entry](inflect: true) saved").characters)
        } else {
            content.body = String(localized: "\(written.count) saved, \(rejected) not saved")
        }
        content.threadIdentifier = Kind.writes.rawValue
        await post(Kind.writes.rawValue + "." + UUID().uuidString, content)
    }

    func deliveryFailing(_ reason: String) async {
        guard Self.failuresEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Sync Is Failing")
        content.body = String(localized: "Rendu is unable to connect to your server: \(reason)")
        await post(Kind.deliveryFailing.rawValue, content)
    }

    /// Reminds a day before the provisioning profile expires (free accounts
    /// sign for 7 days; after that the app won't launch and sync stops).
    func scheduleSigningReminder() async {
        center.removePendingNotificationRequests(withIdentifiers: [Kind.signingExpiry.rawValue])
        guard Self.expiryEnabled, let expiry = Signing.expirationDate else { return }
        let fireDate = expiry.addingTimeInterval(-24 * 3600)
        guard fireDate > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Rendu Expires Tomorrow")
        content.body = String(localized: "Reinstall Rendu from Xcode to continue syncing. Your data will be kept.")
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: Kind.signingExpiry.rawValue, content: content, trigger: trigger))
    }

    private func post(_ identifier: String, _ content: UNMutableNotificationContent) async {
        content.sound = .default
        try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}

extension WriteRecord.Action {
    var label: String {
        switch self {
        case .create: String(localized: "Added")
        case .update: String(localized: "Updated")
        case .delete: String(localized: "Deleted")
        case .removedInHealth: String(localized: "Deleted in Apple Health")
        }
    }
}

/// The app's provisioning profile, read from the bundle.
enum Signing {
    static let expirationDate: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
            let data = try? Data(contentsOf: url),
            let start = data.range(of: Data("<?xml".utf8)),
            let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound ..< data.endIndex),
            let plist = try? PropertyListSerialization.propertyList(
                from: data.subdata(in: start.lowerBound ..< end.upperBound), format: nil
            ) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }()
}
