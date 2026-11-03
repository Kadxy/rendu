import SwiftUI

/// Every write from the server (and every deletion the user made in Apple
/// Health), one row each, by day — like a bill list: an add or change is
/// marked (and dimmed) when it was later changed or deleted, as a payment is
/// marked refunded, and its details list the entry's related records and
/// delete what's in Apple Health. Writes still waiting for this iPhone come
/// first. Filter by where entries stand, sort by when they were written or
/// by when they are in Apple Health (a meal from last week written today),
/// search by name. What Apple Health holds now is Browse.
struct WritesListView: View {
    let services: AppServices

    @State private var filter: WriteFilter = .all
    @State private var order: WriteOrder = .written
    @State private var query = ""

    var body: some View {
        let records = services.writes.records
        let index = WriteIndex(records)
        let shown = records.filter { filter.includes($0, index: index) && (query.isEmpty || $0.matches(query)) }
        let days = Dictionary(grouping: shown) { Calendar.current.startOfDay(for: order.date(of: $0)) }
        let deleting = services.writes.deletesUnderway(services.server.pendingWrites)
        // Deletes this iPhone is running show on their entries instead.
        let running = services.writes.deleting
        let pending =
            filter == .all && query.isEmpty
            ? services.server.pendingWrites.filter { !($0.op == "delete" && running.contains($0.syncIdentifier)) } : []
        List {
            if !pending.isEmpty {
                Section("Waiting to Be Saved") {
                    ForEach(pending) { write in
                        QueuedWriteRow(write: write, records: records)
                    }
                }
            }
            ForEach(days.keys.sorted(by: >), id: \.self) { day in
                Section {
                    ForEach(days[day]!.sorted { order.date(of: $0) > order.date(of: $1) }) { record in
                        NavigationLink {
                            WriteDetailView(services: services, record: record)
                        } label: {
                            WriteRow(
                                record: record, tag: index.tag(for: record), changes: index.changes(of: record), order: order,
                                deleting: deleting.contains(record.syncIdentifier) && index.isCurrentInHealth(record))
                        }
                    }
                } header: {
                    Text(verbatim: day.dayTitle)
                }
            }
        }
        .overlay {
            if shown.isEmpty && pending.isEmpty {
                if query.isEmpty {
                    ContentUnavailableView("No Entries", systemImage: "line.3.horizontal.decrease")
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .searchable(text: $query)
        .navigationTitle("Write History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Like Messages' filter: the choices with their icons and a
                // check on the one in use, then how to sort (words only, as
                // Notes' and Files' are); the button turns blue while either
                // isn't the default.
                Menu {
                    Picker(selection: $filter) {
                        ForEach(WriteFilter.allCases) { filter in
                            Label(filter.title, systemImage: filter.symbol).tag(filter)
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.inline)
                    Section("Sort By") {
                        Picker(selection: $order) {
                            ForEach(WriteOrder.allCases) { order in
                                Text(order.title).tag(order)
                            }
                        } label: {
                            EmptyView()
                        }
                        .pickerStyle(.inline)
                    }
                } label: {
                    Label("Show", systemImage: "line.3.horizontal.decrease")
                        .foregroundStyle(filter == .all && order == .written ? Color.primary : Color.accentColor)
                }
            }
        }
        .task { await services.loadPendingWrites() }
    }
}

/// Which records the list shows: where entries stand.
enum WriteFilter: String, CaseIterable, Identifiable {
    case all, inHealth, deleted, problems
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all: "All"
        case .inHealth: "In Apple Health"
        case .deleted: "Deleted"
        case .problems: "Not Saved"
        }
    }

    var symbol: String {
        switch self {
        case .all: "list.bullet"
        case .inHealth: "heart"
        case .deleted: "trash"
        case .problems: "exclamationmark.circle"
        }
    }

    func includes(_ record: WriteRecord, index: WriteIndex) -> Bool {
        switch self {
        case .all: true
        // The values Apple Health holds now.
        case .inHealth: index.isCurrentInHealth(record)
        // Through the server or in Apple Health.
        case .deleted: record.isDeletion
        case .problems: record.outcome != .written
        }
    }
}

/// Days and order by when it was written, or by when it is in Apple Health.
enum WriteOrder: String, CaseIterable, Identifiable {
    case written, inHealth
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .written: "Date Written"
        case .inHealth: "Sample Date"
        }
    }

    func date(of record: WriteRecord) -> Date {
        self == .written ? record.date : record.healthDate
    }
}

/// A write the server holds that hasn't run yet: what it is, who sent it.
private struct QueuedWriteRow: View {
    let write: QueuedWrite
    let records: [WriteRecord]

    var body: some View {
        // A delete names the entry it's for, as the history knows it.
        let known = records.first { $0.syncIdentifier == write.syncIdentifier }
        let type = write.type ?? known?.type ?? ""
        HStack(spacing: 12) {
            CategoryIcon(category: HealthCategory.of(type), size: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: write.foodName ?? known?.headline ?? DisplayNames.name(forKey: type))
                    .lineLimit(1)
                Text(
                    verbatim: [
                        write.op == "delete" ? WriteRecord.Action.delete.label : WriteRecord.Action.create.label,
                        write.submittedBy?.name,
                    ].compactMap { $0 }.joined(separator: " · ")
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let created = write.created {
                Text(verbatim: created.shortStamp)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The type's Health glyph, the entry's name, what was done, and when. Each
/// look means one thing, and none rests on color alone (HIG, Color):
/// - normal: where the entry stands, in Apple Health;
/// - name struck through: a deletion — where it stands is gone;
/// - dimmed, with an orange mark (✎ Updated, 🗑 Deleted…): not the latest,
///   it was changed or deleted later;
/// - a red ⓘ and the reason: not saved, as Messages marks a message it
///   couldn't send.
struct WriteRow: View {
    let record: WriteRecord
    var tag: WriteTag?
    /// An update's samples against what it replaced (WriteIndex.changes).
    var changes: [SampleChange]?
    var order: WriteOrder = .written
    /// A delete for its entry waits to run.
    var deleting = false

    /// The other date, when it's another day: "Oct 27" (in Apple Health)
    /// in a list by date written, "Written Nov 3" in one by date in Health.
    private var otherDay: String? {
        let calendar = Calendar.current
        guard let sampleDate = record.sampleDate, !calendar.isDate(sampleDate, inSameDayAs: record.date) else { return nil }
        switch order {
        case .written: return sampleDate.formatted(.dateTime.month().day())
        case .inHealth: return String(localized: "Written \(record.date.formatted(.dateTime.month().day()))")
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(category: HealthCategory.of(record.items.first?.type ?? record.type ?? ""), size: 18)
                .opacity(tag == nil ? 1 : 0.35)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: record.headline)
                    .foregroundStyle(tag == nil ? .primary : .secondary)
                    .strikethrough(record.isDeletion)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    let line = [record.detailLine(changes: changes), otherDay].compactMap { $0 }.joined(separator: " · ")
                    if record.outcome == .written {
                        Text(verbatim: line)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Mark(symbol: "exclamationmark.circle.fill", text: line)
                            .foregroundStyle(.red)
                    }
                    if let tag {
                        Mark(symbol: tag.symbol, text: tag.label)
                            .foregroundStyle(.orange)
                            .fixedSize()
                    } else if deleting {
                        Text("Deleting…")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .font(.subheadline)
            }
            Spacer(minLength: 8)
            Text(verbatim: order.date(of: record).formatted(date: .omitted, time: .shortened))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

/// A sample's type and value per row. For an update, against what it
/// replaced, as a price change reads: the old value struck through before
/// the new one, new values in full color, a dropped sample's value struck
/// through; the samples it left alone as before.
private struct SampleItems: View {
    let record: WriteRecord
    var struck = false
    var changes: [SampleChange]?

    var body: some View {
        let rows = changes ?? record.items.map { SampleChange(item: $0, kind: .same) }
        ForEach(Array(rows.enumerated()), id: \.offset) { _, change in
            HStack(alignment: .firstTextBaseline) {
                TypeName(identifier: change.item.type)
                Spacer(minLength: 8)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if case .changed(let from?) = change.kind {
                        Text(verbatim: from)
                            .foregroundStyle(.tertiary)
                            .strikethrough()
                    }
                    if let value = change.item.value {
                        Text(verbatim: value)
                            .foregroundStyle(change.kind == .same || change.kind == .removed ? Color.secondary : .primary)
                            .strikethrough(struck || change.kind == .removed)
                    }
                }
                .monospacedDigit()
            }
        }
    }
}

extension Date {
    /// "Today", "Yesterday", "Saturday, Nov 1" — section headers by day.
    var dayTitle: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return String(localized: "Today") }
        if calendar.isDateInYesterday(self) { return String(localized: "Yesterday") }
        return formatted(.dateTime.weekday(.wide).month().day())
    }
}

/// One write (or deletion in Apple Health): what it did and what became of
/// it, who submitted it (their API key a tap away), its values, the entry's
/// other records, and the ids: the sync identifier names the entry (every
/// write to it, and HealthKit, use it), the write id this one write.
struct WriteDetailView: View {
    let services: AppServices
    let record: WriteRecord

    @State private var confirming = false
    @State private var failure: String?

    var body: some View {
        let index = WriteIndex(services.writes.records)
        let tag = index.tag(for: record)
        let related = index.related(to: record)
        List {
            Section {
                DetailRow("Action", record.action.label)
                if record.action != .removedInHealth {
                    DetailRow("Result", record.outcome.label)
                }
                if let tag {
                    DetailRow("Since Then", tag.detail)
                }
                DetailRow("Date Written", record.date.formatted(.dateTime.year().month().day().hour().minute().second()))
                if let sampleDate = record.sampleDate {
                    DetailRow("Sample Date", sampleDate.formatted(.dateTime.year().month().day().hour().minute()))
                }
                if let title = record.title {
                    DetailRow("Name", title)
                }
                if let error = record.error {
                    DetailRow("Reason", error)
                }
                if record.alreadyGone == true {
                    DetailRow("Note", String(localized: "No longer in Apple Health"))
                }
            }
            if let name = record.submittedBy {
                Section {
                    SubmitterRow(services: services, name: name, id: record.submittedByID)
                }
            }
            if !record.items.isEmpty {
                Section("Samples") {
                    SampleItems(record: record, struck: record.isDeletion, changes: index.changes(of: record))
                }
            } else if let type = record.type {
                Section("Samples") {
                    TypeName(identifier: type)
                }
            }
            if !related.isEmpty {
                Section {
                    ForEach(related) { other in
                        NavigationLink {
                            WriteDetailView(services: services, record: other)
                        } label: {
                            RelatedRow(record: other)
                        }
                    }
                } header: {
                    Text("Related Records")
                }
            }
            Section {
                DetailRow("Sync Identifier", record.syncIdentifier, monospaced: true)
                if record.action != .removedInHealth {
                    DetailRow("Write ID", record.id, monospaced: true)
                }
            }
            // Like Health's Delete Data. The page stays: it shows the
            // deletion once the sync this starts has run it.
            if index.isCurrentInHealth(record) {
                Section {
                    if services.writes.deletesUnderway(services.server.pendingWrites).contains(record.syncIdentifier) {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Deleting…").foregroundStyle(.secondary)
                        }
                    } else {
                        Button("Delete from Apple Health", role: .destructive) { confirming = true }
                            // On the button, so it comes from it (HIG, Action sheets).
                            .confirmationDialog(
                                Text("Delete “\(record.headline)” from Apple Health?"), isPresented: $confirming,
                                titleVisibility: .visible
                            ) {
                                Button("Delete", role: .destructive) {
                                    Task {
                                        do {
                                            try await services.deleteFromHealth(syncIdentifier: record.syncIdentifier)
                                        } catch {
                                            failure = error.localizedDescription
                                        }
                                    }
                                }
                            } message: {
                                Text("Rendu deletes it from Apple Health and records the deletion.")
                            }
                    }
                }
            }
        }
        .alert("Unable to Delete", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: failure ?? "")
        }
        .navigationTitle(Text(verbatim: record.action.label))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A related record: what was done, by whom, when. (The name is the
/// entry's, the same as above.)
private struct RelatedRow: View {
    let record: WriteRecord

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if record.outcome == .written {
                    Text(verbatim: record.detailLine)
                        .lineLimit(1)
                } else {
                    Mark(symbol: "exclamationmark.circle.fill", text: record.detailLine)
                        .foregroundStyle(.red)
                }
                if let by = record.submittedBy {
                    Text(verbatim: by)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(verbatim: record.date.shortStamp)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

/// "Submitted By · My Personal AI 3F2A9C1B", opening the key while it still
/// exists.
private struct SubmitterRow: View {
    let services: AppServices
    let name: String
    let id: String?

    var body: some View {
        let key = id.flatMap { id in services.server.apiKeys?.first { $0.id == id } }
        let mine = id != nil && id == services.server.ownerKeyID
        Group {
            if mine {
                // Deleted from this iPhone (its own credential).
                VStack(alignment: .leading, spacing: 2) {
                    Text("Submitted By")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("This iPhone")
                }
            } else if let key {
                NavigationLink {
                    APIKeyDetailView(services: services, key: key) { removed in
                        services.server.apiKeys?.removeAll { $0.id == removed.id }
                    }
                } label: {
                    label(revoked: false)
                }
            } else {
                label(revoked: id != nil && services.server.apiKeys != nil)
            }
        }
        .task {
            if services.server.apiKeys == nil { try? await services.loadAPIKeys() }
        }
    }

    private func label(revoked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Submitted By")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(verbatim: name)
                if let id {
                    Text(verbatim: id).monospaced().foregroundStyle(.secondary)
                }
                if revoked {
                    Text("Revoked").foregroundStyle(.secondary)
                }
            }
        }
    }
}

extension WriteTag {
    /// For a row: "Updated", "Partly Deleted in Apple Health".
    var label: String {
        switch self {
        case .updated: String(localized: "Updated")
        case .deleted: String(localized: "Deleted")
        case .removedInHealth: String(localized: "Deleted in Apple Health")
        case .partlyRemovedInHealth: String(localized: "Partly Deleted in Apple Health")
        }
    }

    /// For the details: "2 of 4 samples deleted in Apple Health".
    var detail: String {
        switch self {
        case .partlyRemovedInHealth(let removed, let of):
            String(localized: "\(removed) of \(of) samples deleted in Apple Health")
        default: label
        }
    }

    var symbol: String {
        switch self {
        case .updated: "pencil"
        case .deleted, .removedInHealth, .partlyRemovedInHealth: "trash"
        }
    }
}

/// A small glyph before words, on their baseline: a row's marks.
struct Mark: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: symbol)
                .imageScale(.small)
            Text(verbatim: text)
                .lineLimit(1)
        }
    }
}

extension WriteRecord {
    /// It took the entry (or some of it) out of Apple Health.
    var isDeletion: Bool { outcome == .written && (action == .delete || action == .removedInHealth) }

    /// For search: its name, its types' names, who submitted it.
    func matches(_ query: String) -> Bool {
        let names = [headline, submittedBy ?? ""] + items.map { DisplayNames.name(forKey: $0.type) }
        return names.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    var headline: String {
        if let title { return title }
        // The entry's own type (a correlation's, a workout's), else its sample's.
        let type = self.type ?? items.first?.type
        return type.map { DisplayNames.localized($0) ?? DisplayNames.shortName($0) } ?? syncIdentifier
    }

    /// "300 mL", "4 samples".
    var valueSummary: String? {
        if items.count == 1, let value = items[0].value { return value }
        if items.count > 1 { return String(localized: "\(items.count) samples") }
        return nil
    }

    /// "Added · 300 mL", "Deleted · 4 samples", "Failed · unit 'kg' is not …";
    /// an update says what it changed: "Updated · Caffeine 236 mg",
    /// "Updated · 2 samples changed".
    var detailLine: String { detailLine(changes: nil) }

    func detailLine(changes: [SampleChange]?) -> String {
        switch outcome {
        case .failed, .conflict: return "\(outcome.label) · \(error ?? "")"
        case .written:
            let count = action == .removedInHealth ? uuids.map { String(localized: "\($0.count) samples") } : valueSummary
            return [action.label, changes.flatMap(Self.summary) ?? count].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// What an update changed, in a few words; nil when it changed no value
    /// (a new time, say).
    private static func summary(_ changes: [SampleChange]) -> String? {
        let changed = changes.filter { $0.kind != .same }
        guard let only = changed.first else { return nil }
        guard changed.count == 1 else {
            return String(AttributedString(localized: "^[\(changed.count) sample](inflect: true) changed").characters)
        }
        let name = DisplayNames.name(forKey: only.item.type)
        if only.kind == .removed { return String(localized: "\(name) removed") }
        return [name, only.item.value].compactMap { $0 }.joined(separator: " ")
    }
}

extension WriteRecord.Outcome {
    var label: String {
        switch self {
        case .written: String(localized: "Written")
        case .failed: String(localized: "Failed")
        case .conflict: String(localized: "Conflict")
        }
    }
}
