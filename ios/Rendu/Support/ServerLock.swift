import LocalAuthentication
import Observation
import SwiftUI

/// Optional Face ID (or the passcode) in front of the server settings and
/// pairing, which decide where Health data goes. Off by default; once
/// unlocked, they stay open until the app leaves the foreground.
@Observable
@MainActor
final class ServerLock {
    private static let key = "lock.server"

    private(set) var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.key) }
    }

    private(set) var unlocked = false

    init() {
        enabled = UserDefaults.standard.object(forKey: Self.key) as? Bool ?? false
    }

    /// True when the lock is off or already open, or when the iPhone has no
    /// passcode (there is nothing to check against).
    func unlock() async -> Bool {
        guard enabled, !unlocked else { return true }
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return true }
        unlocked =
            (try? await context.evaluatePolicy(
                .deviceOwnerAuthentication, localizedReason: String(localized: "Unlock the server settings.")
            )) ?? false
        return unlocked
    }

    func lock() {
        unlocked = false
    }

    /// Turning the lock on or off takes a successful check first: on, so it
    /// can't lock the user out; off, so nobody else can. Without a passcode
    /// there's nothing to check against, so it can't be turned on.
    func setEnabled(_ value: Bool) async {
        guard value != enabled else { return }
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            if !value { enabled = false }
            return
        }
        let reason =
            value
            ? String(localized: "Turn on the lock for the server settings.")
            : String(localized: "Turn off the lock for the server settings.")
        guard (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true else {
            return
        }
        enabled = value
        unlocked = true
    }

    /// "Face ID", "Touch ID", "Optic ID", or "Passcode".
    static var methodName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return String(localized: "Face ID")
        case .touchID: return String(localized: "Touch ID")
        case .opticID: return String(localized: "Optic ID")
        default: return String(localized: "Passcode")
        }
    }
}
