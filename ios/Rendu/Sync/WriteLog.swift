import Foundation
import HealthKit

/// One thing that happened to an entry Rendu keeps in Apple Health: a write
/// from the server the app applied (or refused), or the user deleting it in
/// Apple Health. Entries are told apart by their sync identifier
/// (WriteEntry); each write has an id of its own.
struct WriteRecord: Codable, Identifiable, Equatable, Sendable {
    enum Action: String, Codable, Sendable {
        case create, update, delete
        /// Deleted by the user in Apple Health (seen by the next sync): all
        /// of the entry's samples, or some (`uuids`).
        case removedInHealth
    }
    enum Outcome: String, Codable, Sendable { case written, failed, conflict }

    /// One stored sample: its type identifier and a formatted value.
    struct Item: Codable, Equatable, Sendable {
        let type: String
        let value: String?
    }

    /// The server's write id.
    let id: String
    let date: Date
    let action: Action
    let syncIdentifier: String
    /// The object's own type (a correlation's, for meals).
    let type: String?
    /// HKFoodType for food correlations.
    let title: String?
    let items: [Item]
    let outcome: Outcome
    let error: String?
    /// A delete whose objects were already gone (removed in Health, or by an
    /// earlier run that couldn't report back) — nothing to show but the type.
    var alreadyGone: Bool? = nil
    /// The API key's name that submitted it (servers before 0.4 don't say).
    var submittedBy: String? = nil
    var submittedByID: String? = nil
    /// The HealthKit objects it saved (the entry's own first, then a meal's
    /// nutrients or a workout's samples); for removedInHealth, the ones
    /// removed.
    var uuids: [String]? = nil
    /// When the entry is in Apple Health (the sample's start), which may be
    /// long before it was written ("yesterday's lunch").
    var sampleDate: Date? = nil

    /// For ordering by time in Apple Health; records from before 0.4 have
    /// only the time written.
    var healthDate: Date { sampleDate ?? date }

    /// "DietaryWater 300 mL", or "Lunch · DietaryEnergyConsumed 650 kcal, …".
    var summary: String {
        let parts = items.map { [DisplayNames.shortName($0.type), $0.value].compactMap { $0 }.joined(separator: " ") }
        let body = parts.joined(separator: ", ")
        if let title { return body.isEmpty ? title : "\(title) · \(body)" }
        return body.isEmpty ? (type.map(DisplayNames.shortName) ?? syncIdentifier) : body
    }
}

extension WriteRecord {
    /// Items describing a HealthKit object: the sample itself, or a
    /// correlation's members.
    static func items(of sample: HKSample) -> [Item] {
        if let correlation = sample as? HKCorrelation {
            return correlation.objects
                .sorted { $0.sampleType.identifier < $1.sampleType.identifier }
                .flatMap { items(of: $0) }
        }
        return [Item(type: sample.sampleType.identifier, value: SampleFormat.value(sample))]
    }

    static func title(of sample: HKSample) -> String? {
        sample.metadata?[HKMetadataKeyFoodType] as? String
    }
}

/// The most recent write records, newest first, persisted as one JSON file.
actor WriteLog {
    static let capacity = 2000

    private let fileURL: URL
    private var records: [WriteRecord]
    private var sink: (@Sendable ([WriteRecord]) -> Void)?

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("writes.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = (try? Data(contentsOf: fileURL)).flatMap { try? decoder.decode([WriteRecord].self, from: $0) } ?? []
    }

    func all() -> [WriteRecord] { records }

    /// Receives the full list after every change (feeds the UI).
    func setSink(_ sink: @escaping @Sendable ([WriteRecord]) -> Void) {
        self.sink = sink
        sink(records)
    }

    /// The user deleted these objects in Apple Health: each entry still in
    /// Health that had any of them gets a removedInHealth record. (Rendu's
    /// own changes don't count: a change replaces the entry's objects, a
    /// delete leaves it deleted, before the same sync reads the deletions.)
    func recordRemovedInHealth(_ deleted: Set<String>) {
        guard !deleted.isEmpty else { return }
        var removed: [WriteRecord] = []
        for entry in WriteEntry.group(records) where entry.inHealth {
            guard let shown = entry.shown, let objects = shown.uuids else { continue }
            let hit = objects.filter(deleted.contains)
            guard !hit.isEmpty else { continue }
            removed.append(
                WriteRecord(
                    id: UUID().uuidString, date: Date(), action: .removedInHealth, syncIdentifier: entry.syncIdentifier,
                    type: shown.type, title: shown.title, items: shown.items, outcome: .written, error: nil, uuids: hit,
                    sampleDate: shown.sampleDate))
        }
        append(removed)
    }

    func append(_ new: [WriteRecord]) {
        guard !new.isEmpty else { return }
        records = Array((new.reversed() + records).prefix(Self.capacity))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(records) {
            try? data.write(to: fileURL, options: .atomic)
        }
        sink?(records)
    }
}

/// An entry Rendu keeps in Apple Health, as one sync identifier: what was
/// done to it, oldest first, and where it stands now.
struct WriteEntry: Identifiable, Sendable {
    let syncIdentifier: String
    /// Oldest first.
    let events: [WriteRecord]

    var id: String { syncIdentifier }
    var latest: WriteRecord { events[events.count - 1] }

    /// The newest values saved (or the newest attempt, if none was).
    var shown: WriteRecord? {
        events.last { $0.outcome == .written && ($0.action == .create || $0.action == .update) }
    }

    enum State: Equatable {
        case added, updated
        /// Deleted by a write from the server.
        case deleted
        /// Deleted by the user in Apple Health: all of it, or `removed` of
        /// `of` samples.
        case removedInHealth
        case partlyRemovedInHealth(removed: Int, of: Int)
        /// Never saved: refused, or a conflict.
        case notSaved
    }

    var state: State {
        guard let shown else { return events.contains { $0.action == .delete && $0.outcome == .written } ? .deleted : .notSaved }
        let after = events.drop { $0.id != shown.id }.dropFirst()
        if after.contains(where: { $0.action == .delete && $0.outcome == .written }) { return .deleted }
        let removed = Set(after.filter { $0.action == .removedInHealth }.flatMap { $0.uuids ?? [] })
        if !removed.isEmpty {
            // What Health lists: a meal's nutrients, a workout and its samples.
            let objects = shown.uuids ?? []
            let listed = objects.count > 1 && shown.items.count == objects.count - 1 ? Array(objects.dropFirst()) : objects
            let gone = listed.filter(removed.contains).count
            return gone >= listed.count || removed.contains(objects.first ?? "")
                ? .removedInHealth : .partlyRemovedInHealth(removed: gone, of: listed.count)
        }
        return shown.action == .update ? .updated : .added
    }

    /// Still (at least partly) in Apple Health.
    var inHealth: Bool {
        switch state {
        case .added, .updated, .partlyRemovedInHealth: true
        case .deleted, .removedInHealth, .notSaved: false
        }
    }

    /// The last thing tried failed or conflicted.
    var lastFailed: Bool { latest.outcome != .written }

    /// Records (newest first, as WriteLog keeps them) as entries, the
    /// most recently touched first.
    static func group(_ records: [WriteRecord]) -> [WriteEntry] {
        var order: [String] = []
        var bySync: [String: [WriteRecord]] = [:]
        for record in records {
            if bySync[record.syncIdentifier] == nil { order.append(record.syncIdentifier) }
            bySync[record.syncIdentifier, default: []].append(record)
        }
        // Oldest first, in the log's order (dates are whole seconds once saved).
        return order.map { WriteEntry(syncIdentifier: $0, events: Array(bySync[$0]!.reversed())) }
    }
}

/// What happened to a write's entry afterwards, as a bill marks a payment
/// refunded: its values replaced by a later change, the entry deleted (by
/// the server, or by the user in Apple Health, all of it or some samples).
enum WriteTag: Equatable, Sendable {
    case updated, deleted, removedInHealth
    case partlyRemovedInHealth(removed: Int, of: Int)
}

/// The write history by entry, to look up a record's related records and
/// what became of it.
struct WriteIndex: Sendable {
    /// Each entry's records, oldest first.
    private let bySync: [String: [WriteRecord]]

    init(_ records: [WriteRecord]) {
        // In the order they happened: the log keeps it (newest first);
        // saved dates are whole seconds, often the same for a save and a
        // delete in one sync.
        bySync = Dictionary(grouping: records, by: \.syncIdentifier).mapValues { Array($0.reversed()) }
    }

    /// The values Apple Health holds now for its entry: a saved add or
    /// change not replaced or deleted since (some samples deleted in Apple
    /// Health still counts).
    func isCurrentInHealth(_ record: WriteRecord) -> Bool {
        guard record.outcome == .written, record.action == .create || record.action == .update else { return false }
        switch tag(for: record) {
        case nil, .partlyRemovedInHealth: return true
        case .updated, .deleted, .removedInHealth: return false
        }
    }

    /// The other records of the same entry, oldest first.
    func related(to record: WriteRecord) -> [WriteRecord] {
        (bySync[record.syncIdentifier] ?? []).filter { $0.id != record.id }
    }

    /// What became of the values an add or change saved; nil while they're
    /// still what Apple Health holds (or for other records).
    func tag(for record: WriteRecord) -> WriteTag? {
        guard record.outcome == .written, record.action == .create || record.action == .update,
            let events = bySync[record.syncIdentifier], let index = events.firstIndex(where: { $0.id == record.id })
        else { return nil }
        var removed: Set<String> = []
        for event in events[(index + 1)...] where event.outcome == .written {
            switch event.action {
            case .update: return .updated
            case .delete: return .deleted
            case .removedInHealth: removed.formUnion(event.uuids ?? [])
            case .create: continue
            }
        }
        guard !removed.isEmpty else { return nil }
        // What Health lists: a meal's nutrients, a workout and its samples.
        let objects = record.uuids ?? []
        let listed = objects.count > 1 && record.items.count == objects.count - 1 ? Array(objects.dropFirst()) : objects
        let gone = listed.filter(removed.contains).count
        if gone >= listed.count || removed.contains(objects.first ?? "") { return .removedInHealth }
        return .partlyRemovedInHealth(removed: gone, of: listed.count)
    }

    /// An update's samples against the values it replaced (the entry's last
    /// saved add or change before it): which stayed, which changed and
    /// from what, which are new, which it dropped. nil for anything else.
    func changes(of record: WriteRecord) -> [SampleChange]? {
        guard record.action == .update, record.outcome == .written,
            let events = bySync[record.syncIdentifier], let index = events.firstIndex(where: { $0.id == record.id })
        else { return nil }
        var replaced: WriteRecord?
        for event in events[..<index].reversed() where event.outcome == .written {
            if event.action == .create || event.action == .update {
                replaced = event
                break
            }
            if event.action == .delete { return nil }
        }
        guard let replaced else { return nil }
        return SampleChange.compare(replaced.items, record.items)
    }
}

/// A sample of an update, against the one it replaced.
struct SampleChange: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case same, added, removed
        case changed(from: String?)
    }

    let item: WriteRecord.Item
    let kind: Kind

    /// Pairs the samples by type, in order (a workout may have several of
    /// one type); what `old` has left over was dropped, listed last.
    static func compare(_ old: [WriteRecord.Item], _ new: [WriteRecord.Item]) -> [SampleChange] {
        var left = old
        var out: [SampleChange] = []
        for item in new {
            if let i = left.firstIndex(where: { $0.type == item.type }) {
                let before = left.remove(at: i)
                out.append(SampleChange(item: item, kind: before.value == item.value ? .same : .changed(from: before.value)))
            } else {
                out.append(SampleChange(item: item, kind: .added))
            }
        }
        return out + left.map { SampleChange(item: $0, kind: .removed) }
    }
}
