import SwiftUI

/// The app's log, newest first and grouped by day, a page at a time: what
/// happened (an icon for its kind, warnings orange, errors red), its
/// details, and the time. Filter by level, search the whole log, tap for
/// the full entry. How much is kept is set here too.
struct LogsView: View {
    let services: AppServices

    @State private var entries: [LogEntry] = []
    @State private var next: UInt64?
    @State private var level: LevelFilter = .all
    @State private var query = ""
    @State private var loading = true
    @State private var limit = LogRetention.limit
    @State private var size = 0

    private static let pageSize = 300

    enum LevelFilter: String, CaseIterable, Identifiable, Sendable {
        case all, warnings, errors
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .all: "All Levels"
            case .warnings: "Warnings and Errors"
            case .errors: "Errors"
            }
        }

        func includes(_ level: LogEntry.Level) -> Bool {
            switch self {
            case .all: true
            case .warnings: level != .info
            case .errors: level == .error
            }
        }
    }

    var body: some View {
        let days = Dictionary(grouping: entries) { Calendar.current.startOfDay(for: $0.date) }
        List {
            ForEach(days.keys.sorted(by: >), id: \.self) { day in
                Section {
                    ForEach(days[day]!) { entry in
                        NavigationLink {
                            LogEntryDetailView(entry: entry)
                        } label: {
                            LogRow(entry: entry)
                        }
                    }
                } header: {
                    Text(verbatim: day.dayTitle)
                }
            }
            if next != nil {
                Button {
                    Task { await load(more: true) }
                } label: {
                    HStack {
                        Text("Load Earlier Entries")
                        if loading {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(loading)
            }
        }
        .overlay {
            if loading && entries.isEmpty {
                ProgressView()
            } else if entries.isEmpty {
                if query.isEmpty {
                    ContentUnavailableView("No Entries", systemImage: "doc.text.magnifyingglass")
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .searchable(text: $query)
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Level", selection: $level) {
                        ForEach(LevelFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                } label: {
                    Label(
                        "Level",
                        systemImage: level == .all
                            ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ShareLink(item: services.log.fileURL) {
                        Label("Export Logs", systemImage: "square.and.arrow.up")
                    }
                    Section {
                        Picker("Keep Logs", selection: $limit) {
                            ForEach(LogRetention.choices, id: \.self) { choice in
                                if let choice {
                                    Text("Up to \(choice.formatted(.byteCount(style: .file)))").tag(choice as Int?)
                                } else {
                                    Text("All").tag(choice)
                                }
                            }
                        }
                        .pickerStyle(.menu)
                    } header: {
                        Text("Logs use \(size.formatted(.byteCount(style: .file)))")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
        .task(id: Filter(level: level, query: query)) {
            // Typing searches after a pause; the first load runs at once.
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            await load(more: false)
        }
        .task { size = await services.log.size }
        .onChange(of: limit) { _, value in
            LogRetention.limit = value
            Task {
                if let value { await services.log.trim(to: value) }
                size = await services.log.size
                await load(more: false)
            }
        }
    }

    private struct Filter: Equatable {
        let level: LevelFilter
        let query: String
    }

    /// The newest page, or the one before what's shown; filtering reads
    /// through the whole file.
    private func load(more: Bool) async {
        loading = true
        defer { loading = false }
        let level = level
        let query = query
        var filter: (@Sendable (LogEntry) -> Bool)?
        if level != .all || !query.isEmpty {
            filter = { entry in
                level.includes(entry.level) && (query.isEmpty || entry.matches(query))
            }
        }
        let page = await services.log.page(before: more ? next : nil, count: Self.pageSize, matching: filter)
        entries = more ? entries + page.entries : page.entries
        next = page.next
    }
}

extension LogEntry {
    func matches(_ query: String) -> Bool {
        [message, title ?? "", detail ?? ""].contains { $0.localizedCaseInsensitiveContains(query) }
    }

    /// The row's first line: the title, or for entries from before titles
    /// the message.
    var headline: String { title ?? message }

    var symbol: String {
        switch kind {
        case .health: "heart.fill"
        case .upload: "arrow.up"
        case .write: "square.and.arrow.down.fill"
        case .server: "server.rack"
        case .background: "moon.fill"
        case .pause: "pause.fill"
        case nil: level == .info ? "info" : "exclamationmark"
        }
    }

    var tint: Color {
        switch level {
        case .warn: .orange
        case .error: .red
        case .info:
            switch kind {
            case .health: .pink
            case .upload, .server: .blue
            case .write: .green
            case .background: .indigo
            case .pause, nil: .gray
            }
        }
    }
}

/// An icon for the kind of entry, one line of title with one of details
/// below, the time on the right; the rest is a tap away.
private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(spacing: 12) {
            SoftIcon(symbol: entry.symbol, tint: entry.tint, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: entry.headline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(entry.date, format: .dateTime.hour().minute())
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let detail = entry.detail {
                    Text(verbatim: detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

extension LogEntry.Level {
    var title: LocalizedStringResource {
        switch self {
        case .info: "Info"
        case .warn: "Warning"
        case .error: "Error"
        }
    }
}

/// Everything about an entry; long-press a row to copy it.
private struct LogEntryDetailView: View {
    let entry: LogEntry

    var body: some View {
        List {
            Section {
                if let title = entry.title {
                    DetailRow("Event", title)
                }
                if let detail = entry.detail {
                    DetailRow("Details", detail)
                }
                DetailRow("Time", entry.date.formatted(.dateTime.year().month().day().hour().minute().second()))
                DetailRow("Level", String(localized: entry.level.title))
            }
            Section {
                DetailRow("Message", entry.message, monospaced: true)
            }
        }
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
    }
}
