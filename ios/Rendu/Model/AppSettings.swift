import Foundation
import Observation

enum SettingsKeys {
    static let endpoint = "server.endpoint"
    static let outboxSequence = "outbox.seq"
    static let outboxSecondsPerItem = "outbox.secondsPerItem"
}

/// The key this iPhone generated and paired with a server: its owner key.
/// Kept in one file in the app's container — not the Keychain, so deleting
/// the app deletes it — readable once the phone has been unlocked after a
/// restart (background syncs need it while locked), and excluded from
/// backups (restored onto another phone, two phones would hold it). Nothing
/// in the app shows it; it can only be forgotten.
enum OwnerKey {
    struct Pairing: Codable, Equatable {
        let server: URL
        let key: String
    }

    private nonisolated static var url: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Rendu", isDirectory: true).appendingPathComponent("owner.key")
    }

    /// nil when not paired, or before the first unlock after a restart.
    nonisolated static func read() -> Pairing? {
        if Demo.isOn { return Pairing(server: Demo.server, key: "demo") }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Pairing.self, from: data)
    }

    nonisolated static func write(_ pairing: Pairing) throws {
        guard !Demo.isOn else { return }
        var file = url
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(pairing).write(
            to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try file.setResourceValues(values)
    }

    nonisolated static func forget() {
        guard !Demo.isOn else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 32 random bytes, base64url without padding (43 characters).
    nonisolated static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            fatalError("no secure random bytes")
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// User configuration. The @Observable instance drives the UI; the static
/// accessors read the same storage (UserDefaults and the key file, both
/// thread-safe) so background actors never touch the UI object.
@Observable
@MainActor
final class AppSettings {
    /// The server this iPhone is paired with, or was last pointed at.
    private(set) var endpoint: String

    /// This iPhone's owner key, if it's paired with `endpoint`.
    private(set) var key: String

    init() {
        let stored = Demo.isOn ? Demo.server.absoluteString : UserDefaults.standard.string(forKey: SettingsKeys.endpoint)
        endpoint = stored ?? ""
        key = ""
        reload()
    }

    var baseURL: URL? { Self.baseURL(from: endpoint) }
    var isPaired: Bool { !key.isEmpty }

    /// Re-reads the key file (it can't be read before the first unlock).
    func reload() {
        if let pairing = OwnerKey.read(), pairing.server == baseURL {
            key = pairing.key
        } else {
            key = ""
        }
    }

    func paired(server: URL, key: String) throws {
        try OwnerKey.write(.init(server: server, key: key))
        endpoint = server.absoluteString
        UserDefaults.standard.set(endpoint, forKey: SettingsKeys.endpoint)
        self.key = key
    }

    func forget() {
        OwnerKey.forget()
        key = ""
    }

    // MARK: - Shared parsing / thread-safe accessors

    /// Bare hosts default to HTTPS; plain HTTP only works for local-network
    /// development servers (ATS NSAllowsLocalNetworking).
    nonisolated static func baseURL(from raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), url.host() != nil else { return nil }
        return url
    }

    /// The paired server and this iPhone's key, resolved at send time. nil
    /// until paired: nothing is read or queued before there is somewhere to
    /// send it. The key only ever goes to the server it was paired with.
    nonisolated static func currentTarget() -> (base: URL, token: String?)? {
        guard let pairing = OwnerKey.read() else { return nil }
        return (pairing.server, pairing.key)
    }
}
