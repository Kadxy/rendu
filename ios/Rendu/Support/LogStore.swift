import Foundation
import os

struct LogEntry: Codable, Identifiable, Equatable, Sendable {
    enum Level: String, Codable, Sendable { case info, warn, error }

    /// What an entry is about, for its icon.
    enum Kind: String, Codable, Sendable {
        /// Reading Apple Health.
        case health
        case upload
        /// Entries from the server saved to Apple Health.
        case write
        case server
        /// iOS woke the app in the background.
        case background
        case pause
    }

    var id = UUID()
    let date: Date
    let level: Level
    /// The full message, in English, as exported.
    let message: String
    /// A readable line and details, in the app's language when written.
    /// Entries without them show their message.
    var kind: Kind?
    var title: String?
    var detail: String?
}

/// Append-only NDJSON activity log, persisted so background sync activity is
/// visible the next time the app is opened. Mirrors to os.Logger for Console;
/// routine detail (each type read, each wake) goes only there (`debug`).
/// Kept in full unless the user sets a size limit (LogRetention).
actor LogStore {
    nonisolated let fileURL: URL
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "rendu", category: "sync")
    private var sink: (@Sendable (LogEntry) -> Void)?

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("rendu-log.ndjson")
    }

    /// Receives every new entry (used to feed the UI on the main actor).
    func setSink(_ sink: @escaping @Sendable (LogEntry) -> Void) {
        self.sink = sink
    }

    func info(_ message: String) { append(LogEntry(date: Date(), level: .info, message: message)) }
    func warn(_ message: String) { append(LogEntry(date: Date(), level: .warn, message: message)) }
    func error(_ message: String) { append(LogEntry(date: Date(), level: .error, message: message)) }

    /// An entry with a readable title and details; `message` is what's
    /// exported.
    func record(_ kind: LogEntry.Kind, _ level: LogEntry.Level = .info, title: String, detail: String? = nil, message: String) {
        append(LogEntry(date: Date(), level: level, message: message, kind: kind, title: title, detail: detail))
    }

    /// Console only.
    nonisolated func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    private func append(_ entry: LogEntry) {
        switch entry.level {
        case .info: logger.info("\(entry.message, privacy: .public)")
        case .warn: logger.warning("\(entry.message, privacy: .public)")
        case .error: logger.error("\(entry.message, privacy: .public)")
        }
        persist(entry)
        sink?(entry)
    }

    private func persist(_ entry: LogEntry) {
        guard var line = try? Self.encoder().encode(entry) else { return }
        line.append(0x0A)
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            try? line.write(to: fileURL, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch { return }
        if let limit = LogRetention.limit, (try? handle.offset()).map({ $0 > UInt64(limit) }) == true {
            trim(to: limit)
        }
    }

    /// Keeps the newest three quarters of `limit`, cut at a line boundary.
    func trim(to limit: Int) {
        guard let data = try? Data(contentsOf: fileURL), data.count > limit else { return }
        let tail = data.suffix(limit * 3 / 4)
        guard let newline = tail.firstIndex(of: 0x0A) else { return }
        try? data[data.index(after: newline)...].write(to: fileURL, options: .atomic)
    }

    var size: Int {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
    }

    /// The newest `count` entries.
    func tail(_ count: Int) -> [LogEntry] {
        page(before: nil, count: count).entries
    }

    /// Up to `count` entries, newest first, that end before byte `offset`
    /// (nil: the end of the file), read backwards a chunk at a time; and the
    /// offset to continue from, nil at the start of the file.
    func page(
        before offset: UInt64?, count: Int, matching filter: (@Sendable (LogEntry) -> Bool)? = nil
    ) -> (entries: [LogEntry], next: UInt64?) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return ([], nil) }
        defer { try? handle.close() }
        let decoder = Self.decoder()
        var end = offset ?? ((try? handle.seekToEnd()) ?? 0)
        var entries: [LogEntry] = []
        var carry = Data()
        let chunk: UInt64 = 256 * 1024
        while end > 0 && entries.count < count {
            let start = end > chunk ? end - chunk : 0
            try? handle.seek(toOffset: start)
            var data = (try? handle.read(upToCount: Int(end - start))) ?? Data()
            data.append(carry)
            // The first line may be cut off (unless this is the file's start).
            var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            carry = start > 0 ? Data(lines.removeFirst()) : Data()
            // Each whole line's offset in the file, to continue from.
            var lineStart = start + UInt64(carry.count) + (start > 0 ? 1 : 0)
            var parsed: [(entry: LogEntry, start: UInt64)] = []
            for line in lines {
                if let entry = try? decoder.decode(LogEntry.self, from: line), filter?(entry) ?? true {
                    parsed.append((entry, lineStart))
                }
                lineStart += UInt64(line.count) + 1
            }
            for item in parsed.reversed() {
                entries.append(item.entry)
                if entries.count == count {
                    return (entries, item.start > 0 ? item.start : nil)
                }
            }
            end = start
            if start == 0 { carry = Data() }
        }
        return (entries, nil)
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// How much log to keep on this iPhone: all of it (the default), or up to
/// a size, oldest entries dropped first.
enum LogRetention {
    static let choices: [Int?] = [nil, 100_000_000, 20_000_000, 5_000_000]

    static var limit: Int? {
        get {
            let value = UserDefaults.standard.integer(forKey: "log.limit")
            return value > 0 ? value : nil
        }
        set { UserDefaults.standard.set(newValue ?? 0, forKey: "log.limit") }
    }
}

/// Pieces of log lines in the app's language.
enum LogText {
    /// "0.8 s", "12 s", "3 min".
    static func seconds(_ interval: TimeInterval) -> String {
        if interval < 10 {
            return Duration.seconds(interval).formatted(
                .units(allowed: [.seconds], width: .abbreviated, fractionalPart: .show(length: 1)))
        }
        if interval < 90 {
            return Duration.seconds(interval).formatted(.units(allowed: [.seconds], width: .abbreviated))
        }
        return Duration.seconds(interval).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}
