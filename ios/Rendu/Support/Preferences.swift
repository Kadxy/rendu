import Foundation
import SwiftUI

/// A Bool preference in UserDefaults.standard with a default.
@propertyWrapper
struct UserDefault {
    let key: String
    let defaultValue: Bool

    init(wrappedValue: Bool, _ key: String) {
        self.key = key
        defaultValue = wrappedValue
    }

    var wrappedValue: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// Haptics play with the change they confirm — `.haptic` on the view that
/// shows it, never after a network round trip — and each kind of outcome
/// has its own: success when a sync or pairing finishes, a warning when
/// syncing stops for the server, an error when something fails, a firm tap
/// for pausing and a soft one for resuming, a light one for copying.
@MainActor
enum Haptics {
    @UserDefault("haptics.enabled") static var enabled = true
}

extension View {
    /// Plays `feedback` when `trigger` changes, if haptics are on.
    func haptic<T: Equatable>(_ feedback: SensoryFeedback, trigger: T) -> some View {
        sensoryFeedback(trigger: trigger) { _, _ in Haptics.enabled ? feedback : nil }
    }

    /// Plays what the change from the old value to the new one calls for.
    func haptic<T: Equatable>(trigger: T, _ feedback: @escaping (T, T) -> SensoryFeedback?) -> some View {
        sensoryFeedback(trigger: trigger) { old, new in Haptics.enabled ? feedback(old, new) : nil }
    }

    /// Plays each event as it's set.
    func haptic(_ event: HapticEvent) -> some View {
        sensoryFeedback(trigger: event) { _, event in Haptics.enabled ? event.feedback : nil }
    }
}

/// A haptic for `.haptic(_:)` to play, set together with the change it
/// confirms; playing the same kind twice still plays twice.
struct HapticEvent: Equatable {
    private(set) var feedback: SensoryFeedback?
    private var id = 0

    mutating func play(_ feedback: SensoryFeedback) {
        self.feedback = feedback
        id += 1
    }
}
