import HealthKit
import SwiftUI

/// What the server holds — exactly what API clients can read: search,
/// then every category, one row each.
struct BrowseView: View {
    let services: AppServices
    /// Bumped when the Browse tab is tapped while already selected, which
    /// focuses search (as in Health).
    var searchRequest = 0
    @State private var query = ""
    @FocusState private var focused: Bool
    @State private var path = NavigationPath()
    /// Also list categories and types the server has no data for.
    @AppStorage("browse.showEmpty") private var showEmpty = false
    /// How far the page has scrolled (0 at rest).
    @State private var scrolled: CGFloat = 0

    /// Health's layout: a large title, then the search field, which stops at
    /// the top once the title has scrolled away. The field floats above the
    /// page rather than scrolling inside it, so the blur at the top edge
    /// stays behind it. (A system navigation bar would keep a small title
    /// above the pinned field, which Health doesn't.)
    private static let titleTop: CGFloat = 56
    private static let titleHeight: CGFloat = 41
    private static let fieldHeight: CGFloat = 42
    private static let fieldGap: CGFloat = 8
    private static let margin: CGFloat = 20
    /// A navigation bar's height, and its buttons' distance from the edge.
    private static let barHeight: CGFloat = 44
    private static let barMargin: CGFloat = 16

    private var searching: Bool { focused || !query.isEmpty }
    /// Where the field rests before the page scrolls: under the title.
    private var fieldRest: CGFloat { searching ? Self.fieldGap : Self.titleTop + Self.titleHeight + Self.fieldGap }
    private var pinned: Bool { scrolled >= fieldRest - Self.fieldGap }

    private var results: [ServerType] {
        services.serverData.types
            .filter { item in
                DisplayNames.shortName(item.type).localizedCaseInsensitiveContains(query)
                    || (DisplayNames.localized(item.type)?.localizedCaseInsensitiveContains(query) ?? false)
            }
            .sorted { sortName($0.type) < sortName($1.type) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !searching {
                        VStack(alignment: .leading, spacing: 0) {
                            // Where a navigation bar's buttons are: above the
                            // large title, not beside it.
                            EmptyDataMenu(showEmpty: $showEmpty)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                                .padding(.trailing, Self.barMargin)
                                .frame(height: Self.barHeight)
                                .padding(.bottom, Self.titleTop - Self.barHeight)
                            Text(verbatim: HealthUIStrings.localized("BROWSE_TITLE") ?? "Browse")
                                .font(.largeTitle.bold())
                                .frame(height: Self.titleHeight)
                                .padding(.horizontal, Self.margin)
                        }
                        .transition(.opacity)
                    }
                    // Room for the floating search field.
                    Color.clear.frame(height: Self.fieldGap * 2 + Self.fieldHeight)
                    Group {
                        if !services.settings.isPaired {
                            ContentUnavailableView(
                                "Not Paired", systemImage: "link",
                                description: Text("After pairing, the data on your server appears here."))
                        } else if query.isEmpty {
                            categories
                        } else {
                            searchResults
                        }
                    }
                    // The standard 20 pt below the search field.
                    .padding(.top, 20 - Self.fieldGap)
                    .padding(.horizontal, Self.margin)
                    .padding(.bottom, 24)
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                scrolled = offset
            }
            .scrollEdgeEffectHidden(true, for: .top)
            .scrollDismissesKeyboard(.immediately)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .overlay(alignment: .top) {
                ZStack(alignment: .top) {
                    // Health's soft blur behind the pinned field.
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0), .init(color: .black, location: 0.55),
                                    .init(color: .clear, location: 1),
                                ], startPoint: .top, endPoint: .bottom)
                        )
                        .frame(height: Self.fieldGap * 2 + Self.fieldHeight)
                        .ignoresSafeArea(edges: .top)
                        .opacity(pinned ? 1 : 0)
                        .allowsHitTesting(false)
                    SearchField(text: $query, focused: $focused, active: searching, floating: pinned)
                        .padding(.horizontal, Self.margin)
                        .padding(.top, Self.fieldGap)
                        .offset(y: max(0, fieldRest - Self.fieldGap - scrolled))
                }
            }
            .animation(.smooth(duration: 0.3), value: searching)
            .animation(.smooth(duration: 0.2), value: pinned)
            .navigationTitle("Browse")
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: searchRequest) { focused = true }
            // Opening a result ends the search: coming back shows Browse.
            .onChange(of: path.count) { old, new in
                if new > old, searching {
                    query = ""
                    focused = false
                }
            }
            .task {
                await services.refreshServerData()
                // Screenshot tooling: open sleep's recorded data.
                if ProcessInfo.processInfo.arguments.contains("-rendu-open-sleep"),
                    let sleep = services.serverData.types.first(where: {
                        $0.type == HKCategoryTypeIdentifier.sleepAnalysis.rawValue
                    })
                {
                    path.append(sleep)
                }
            }
            .navigationDestination(for: HealthCategory.self) { category in
                CategoryView(services: services, category: category)
            }
            .navigationDestination(for: ServerType.self) { type in
                if type.type == HKCategoryTypeIdentifier.sleepAnalysis.rawValue {
                    SleepNightsView(services: services, type: type)
                } else {
                    SamplesView(services: services, type: type)
                }
            }
        }
    }

    private var categories: some View {
        let counts = Dictionary(grouping: services.serverData.types) { HealthCategory.of($0.type) }.mapValues(\.count)
        let shown = HealthCategory.allCases.filter { showEmpty || (counts[$0] ?? 0) > 0 }
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(shown) { category in
                NavigationLink(value: category) {
                    CategoryRow(category: category, types: counts[category] ?? 0)
                }
                .buttonStyle(.pressable)
                .cardBackground()
            }
            if shown.isEmpty {
                ContentUnavailableView(
                    "No Data", systemImage: "heart.text.square",
                    description: Text("Data appears here once this iPhone has uploaded it."))
            }
            if services.serverData.error != nil {
                Group {
                    if let loaded = services.serverData.loadedAt {
                        Text("Unable to connect to the server. Showing data as of \(loaded.listStamp).")
                    } else {
                        Text("Unable to connect to the server.")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if results.isEmpty {
            ContentUnavailableView.search(text: query)
                .padding(.top, 40)
        } else {
            // Rows at system list metrics: no extra card padding above the
            // first row or below the last.
            VStack(spacing: 0) {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.leading, 56) }
                    NavigationLink(value: item) {
                        HStack(spacing: 12) {
                            CategoryIcon(category: HealthCategory.of(item.type))
                            TypeRow(identifier: item.type, count: item.count)
                            Chevron()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                }
            }
            .cardBackground()
        }
    }
}

/// A category on a card of its own: its glyph, its name, and how many of
/// its types the server has.
private struct CategoryRow: View {
    let category: HealthCategory
    let types: Int

    var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(category: category, size: 22)
            Text(verbatim: category.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(types, format: .number)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Chevron()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Show what the server has data for (the default: Browse shows what the
/// API reads), or every category and type. The menu reads like Messages'
/// filter: the choices with their icons, a check on the one in use; the
/// button turns blue while it isn't the default.
private struct EmptyDataMenu: View {
    @Binding var showEmpty: Bool

    var body: some View {
        Menu {
            BrowseFilterChoices(showEmpty: $showEmpty)
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.body.weight(.semibold))
                .foregroundStyle(showEmpty ? Color.accentColor : .primary)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
    }
}

struct BrowseFilterChoices: View {
    @Binding var showEmpty: Bool

    var body: some View {
        Picker(selection: $showEmpty) {
            Text("Types with Data").tag(false)
            Text("All Types").tag(true)
        } label: {
            EmptyView()
        }
        .pickerStyle(.inline)
    }
}

/// The server's types in one category, and with "All Types"
/// the category's other types, which the server has no data for.
struct CategoryView: View {
    let services: AppServices
    let category: HealthCategory
    @AppStorage("browse.showEmpty") private var showEmpty = false

    /// The category's types this iPhone reads that the server has nothing of.
    private var emptyTypes: [String] {
        let present = Set(services.serverData.types.map(\.type))
        let order = category.order
        return TypeCatalog.all.map(\.key)
            .filter { HealthCategory.of($0) == category && !present.contains($0) }
            .sorted { a, b in
                switch (order[DisplayNames.shortName(a)], order[DisplayNames.shortName(b)]) {
                case (let ia?, let ib?): return ia < ib
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return sortName(a) < sortName(b)
                }
            }
    }

    private var types: [ServerType] {
        let order = category.order
        return services.serverData.types
            .filter { HealthCategory.of($0.type) == category }
            .sorted { a, b in
                let (ia, ib) = (order[DisplayNames.shortName(a.type)], order[DisplayNames.shortName(b.type)])
                switch (ia, ib) {
                case (let ia?, let ib?): return ia < ib
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return sortName(a.type) < sortName(b.type)
                }
            }
    }

    var body: some View {
        let empty = showEmpty ? emptyTypes : []
        List {
            if !types.isEmpty {
                Section {
                    ForEach(types) { item in
                        NavigationLink(value: item) {
                            TypeRow(identifier: item.type, count: item.count)
                        }
                    }
                }
            }
            if !empty.isEmpty {
                Section("No Data") {
                    ForEach(empty, id: \.self) { identifier in
                        TypeName(identifier: identifier)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    BrowseFilterChoices(showEmpty: $showEmpty)
                } label: {
                    Label("Show", systemImage: "line.3.horizontal.decrease")
                        .foregroundStyle(showEmpty ? Color.accentColor : .primary)
                }
            }
        }
        .overlay {
            if types.isEmpty && empty.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("No Data")
                    } icon: {
                        CategoryIcon(category: category, size: 44)
                    }
                } description: {
                    Text("There is no data in this category on your server.")
                }
            }
        }
        .navigationTitle(Text(verbatim: category.title))
    }
}

private func sortName(_ identifier: String) -> String {
    DisplayNames.localized(identifier) ?? DisplayNames.shortName(identifier)
}

/// The server's samples of one type, newest first — Health's "All Recorded
/// Data", but for what API clients read.
struct SamplesView: View {
    let services: AppServices
    let type: ServerType

    @State private var samples: [ServerSample] = []
    @State private var next: String?
    @State private var loading = false
    @State private var failure: String?

    private static let pageSize = 200

    var body: some View {
        List {
            Section {
                ForEach(samples) { sample in
                    NavigationLink {
                        SampleDetailView(sample: sample)
                    } label: {
                        HStack {
                            Text(verbatim: sample.value ?? "—")
                                .monospacedDigit()
                                .lineLimit(1)
                            Spacer(minLength: 12)
                            Text(verbatim: sample.start?.listStamp ?? "")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                if next != nil {
                    Button {
                        Task { await load() }
                    } label: {
                        HStack {
                            Text("Load More")
                            if loading {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(loading)
                }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    TypeName(identifier: type.type)
                    Text("\(type.count) samples on the server")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .textCase(nil)
                .padding(.bottom, 4)
            }
        }
        .overlay {
            if samples.isEmpty, loading {
                ProgressView()
            } else if samples.isEmpty, let failure {
                ContentUnavailableView {
                    Label("Unable to Connect to Server", systemImage: "exclamationmark.icloud")
                } description: {
                    Text(verbatim: failure)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            }
        }
        .navigationTitle(Text(verbatim: HealthUIStrings.localized("ALL_DATA_TITLE") ?? "All Recorded Data"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if samples.isEmpty { await load() }
        }
    }

    private func load() async {
        guard let base = services.settings.baseURL else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await services.uploader.serverSamples(
                base: base, token: services.settings.key, type: type.type, limit: Self.pageSize, cursor: next
            )
            samples += page.samples
            next = page.next
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// One sample as stored on the server, laid out like Health's Details,
/// followed by the raw JSON the API returns.
struct SampleDetailView: View {
    let sample: ServerSample
    @State private var toast = Toast()

    private var json: [String: JSON] { sample.json.object ?? [:] }

    var body: some View {
        let typeName = DisplayNames.localized(sample.type) ?? DisplayNames.shortName(sample.type)
        List {
            Section(header: Text(verbatim: Self.health("SAMPLE_DETAILS", "Sample Details"))) {
                DetailRow(verbatim: typeName, sample.value ?? "—")
                if let start = sample.start {
                    if let end = sample.end, end != start {
                        DetailRow(verbatim: Self.health("START_TIME", "Start Time"), Self.stamp(start))
                        DetailRow(verbatim: Self.health("END_TIME", "End Time"), Self.stamp(end))
                    } else {
                        DetailRow(verbatim: Self.health("DATE", "Date"), Self.stamp(start))
                    }
                }
                if let source = sample.sourceName {
                    DetailRow(verbatim: Self.health("SOURCE", "Source"), source)
                }
                if let zone = json["metadata"]?["HKTimeZone"]?.string.flatMap(TimeZone.init(identifier:)) {
                    DetailRow(
                        verbatim: Self.health("HKTimeZone", "Time Zone"),
                        zone.localizedName(for: .standard, locale: SampleFormat.appLocale) ?? zone.identifier)
                }
                if let metadata = json["metadata"]?.object {
                    ForEach(metadata.keys.filter { $0 != "HKTimeZone" }.sorted(), id: \.self) { key in
                        DetailRow(verbatim: DisplayNames.metadataName(key), metadata[key].map(describe) ?? "")
                    }
                }
            }
            if let device = json["device"]?.object, !device.isEmpty {
                Section(header: Text(verbatim: Self.health("DEVICE_DETAILS", "Device Details"))) {
                    ForEach(Self.deviceFields.filter { device[$0.key] != nil }, id: \.key) { field in
                        DetailRow(field.label, device[field.key].map(describe) ?? "")
                    }
                }
            }
            if let revision = json["sourceRevision"]?.object {
                Section(header: Text(verbatim: Self.health("CLINICAL_ACCOUNTS_SOURCE_DETAILS", "Source Details"))) {
                    if let bundle = revision["source"]?["bundleIdentifier"]?.string {
                        DetailRow("Bundle ID", bundle)
                    }
                    if let version = revision["version"]?.string {
                        DetailRow("Version", version)
                    }
                    if let product = revision["productType"]?.string {
                        DetailRow("Product Type", product)
                    }
                    if let os = revision["operatingSystemVersion"]?.string {
                        DetailRow("OS Version", os)
                    }
                }
            }
            Section {
                JSONText(json: sample.json)
            } header: {
                Text("Raw Data")
            }
        }
        .navigationTitle(Text(verbatim: Self.health("DETAILS", "Details")))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Button {
                    copy(JSONText.text(sample.json), "Copied JSON")
                } label: {
                    Label("Copy JSON", systemImage: "curlybraces")
                }
                Button {
                    copy(sample.id, "Copied UUID")
                } label: {
                    Label("Copy UUID", systemImage: "number")
                }
                Button {
                    copy(sample.type, "Copied Type Identifier")
                } label: {
                    Label("Copy Type Identifier", systemImage: "tag")
                }
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
        .toast($toast)
    }

    private func copy(_ string: String, _ message: LocalizedStringKey) {
        UIPasteboard.general.string = string
        toast.show(message)
    }

    /// Health's own label (HealthUIStrings).
    private static func health(_ key: String, _ fallback: String) -> String {
        HealthUIStrings.localized(key) ?? fallback
    }

    /// "Sep 18, 2026 at 05:21:35", as Health shows sample times.
    private static func stamp(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.abbreviated).day().hour().minute().second().locale(SampleFormat.appLocale))
    }

    private static let deviceFields: [(key: String, label: LocalizedStringKey)] = [
        ("name", "Name"), ("manufacturer", "Manufacturer"), ("model", "Model"),
        ("hardwareVersion", "Hardware"), ("firmwareVersion", "Firmware"),
        ("softwareVersion", "Software"), ("localIdentifier", "Local Identifier"),
        ("UDIDeviceIdentifier", "UDI Device Identifier"),
    ]

    private func describe(_ value: JSON) -> String {
        switch value {
        case .string(let string): string
        case .number(let number): number.formatted(.number.grouping(.never).precision(.fractionLength(0 ... 6)))
        case .bool(let bool): bool ? "true" : "false"
        default: JSONText.text(value)
        }
    }
}
