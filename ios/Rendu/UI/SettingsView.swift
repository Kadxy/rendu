import SwiftUI

/// iOS Settings style: the server and sync at the top, preferences below,
/// details one level down.
struct SettingsView: View {
    let services: AppServices

    @Environment(\.scenePhase) private var scenePhase
    @State private var pairing = false
    @State private var showServer = false
    @State private var showKeys = false
    @State private var haptics = Haptics.enabled
    /// How many objects are shared, per kind; nil before the sheet was shown.
    @State private var shared: [PerObjectAccess: Int] = [:]
    @State private var backgroundRefresh = UIApplication.shared.backgroundRefreshStatus
    /// Types writing is off for (iOS says) or reading looks off for.
    @State private var accessOff = 0

    var body: some View {
        let settings = services.settings
        NavigationStack {
            Form {
                Section {
                    if settings.isPaired {
                        Button {
                            Task { if await services.lock.unlock() { showServer = true } }
                        } label: {
                            ServerRow(services: services)
                        }
                        .tint(.primary)
                        // The server's keys for other programs, right under it.
                        Button {
                            Task { if await services.lock.unlock() { showKeys = true } }
                        } label: {
                            row("key.fill", .gray, Text("API Keys")) {
                                LockMark(lock: services.lock)
                                Chevron()
                            }
                        }
                        .tint(.primary)
                        .disabled(services.server.reachability == .keyRejected)
                    } else {
                        Button {
                            pairing = true
                        } label: {
                            row("server.rack", .blue, Text("Pair with Server…")) { EmptyView() }
                        }
                    }
                }

                // Access to Apple Health; below, what's shared one by one.
                Section {
                    NavigationLink {
                        HealthAccessView(services: services)
                            .onDisappear { Task { await refreshAccess() } }
                    } label: {
                        row("heart.fill", .pink, Text("Apple Health")) {
                            if accessOff > 0 {
                                Text("Partly Off")
                            }
                        }
                    }
                    ForEach(PerObjectAccess.allCases, id: \.self) { access in
                        NavigationLink {
                            SharedObjectsView(services: services, access: access)
                                .onDisappear { Task { await refreshShared() } }
                        } label: {
                            row(access.symbol, access.tint, access.title) {
                                if let count = shared[access] {
                                    Text("\(count) Shared")
                                }
                            }
                        }
                    }
                }

                Section {
                    // Mirrors the iOS setting; flipping it opens iOS Settings,
                    // the only place it can change.
                    Toggle(isOn: Binding(get: { backgroundRefresh == .available }, set: { _ in openAppSettings() })) {
                        row("arrow.clockwise", .teal, Text("Background App Refresh")) { EmptyView() }
                    }
                    .disabled(backgroundRefresh == .restricted)
                }

                Section {
                    NavigationLink {
                        NotificationSettingsView(services: services)
                    } label: {
                        row("bell.badge.fill", .red, Text("Notifications")) { EmptyView() }
                    }
                    Toggle(isOn: $haptics) {
                        row("hand.tap.fill", .purple, Text("Haptics")) { EmptyView() }
                    }
                    .onChange(of: haptics) { _, value in Haptics.enabled = value }
                }

                Section {
                    NavigationLink {
                        LogsView(services: services)
                    } label: {
                        row("doc.text.magnifyingglass", .indigo, Text("Logs")) { EmptyView() }
                    }
                }

                Section {
                    LabeledContent("Version", value: appVersion)
                    if let expiry = Signing.expirationDate {
                        LabeledContent("Signature Expires") {
                            Text(expiry, format: .dateTime.month().day().hour().minute())
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .task {
                await refreshAccess()
                await refreshShared()
                await services.refreshServerStatus(maxAge: 30)
                // So API Keys opens with its list.
                try? await services.loadAPIKeys()
                // Screenshot tooling; the lock still applies.
                if ProcessInfo.processInfo.arguments.contains("-rendu-open-server"), await services.lock.unlock() {
                    showServer = true
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    backgroundRefresh = UIApplication.shared.backgroundRefreshStatus
                    Task { await refreshAccess() }
                }
            }
            .sheet(isPresented: $pairing) {
                PairView(services: services)
            }
            .navigationDestination(isPresented: $showServer) {
                ServerView(services: services)
            }
            .navigationDestination(isPresented: $showKeys) {
                APIKeysView(services: services)
            }

        }
    }

    private func refreshAccess() async {
        guard !Demo.isOn else { return }
        let store = services.healthStore
        accessOff = HealthAuthorization.writeAccess(store).off.count + (await HealthAuthorization.readingLooksOff(store)).count
    }

    private func refreshShared() async {
        guard !Demo.isOn else { return }
        for access in PerObjectAccess.allCases {
            shared[access] = await access.sharedCount(services.healthStore)
        }
    }

    private func row<Trailing: View>(
        _ symbol: String, _ tint: Color, _ title: Text,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: symbol, tint: tint)
            title.foregroundStyle(.primary)
            Spacer(minLength: 8)
            trailing()
                .foregroundStyle(.secondary)
        }
    }

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }
}

private struct NotificationSettingsView: View {
    let services: AppServices

    @State private var writes = Notifier.writesEnabled
    @State private var failures = Notifier.failuresEnabled
    @State private var expiry = Notifier.expiryEnabled

    var body: some View {
        Form {
            Section {
                Toggle("Saved to Apple Health", isOn: $writes)
                    .onChange(of: writes) { _, value in Notifier.writesEnabled = value }
                Toggle("Sync Failures", isOn: $failures)
                    .onChange(of: failures) { _, value in Notifier.failuresEnabled = value }
                Toggle("Signature Expiring", isOn: $expiry)
                    .onChange(of: expiry) { _, value in
                        Notifier.expiryEnabled = value
                        Task { await services.notifier.scheduleSigningReminder() }
                    }
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension PerObjectAccess {
    var title: Text {
        switch self {
        case .medications: Text("Medications")
        case .visionPrescriptions: Text("Vision Prescriptions")
        }
    }

    var changeTitle: LocalizedStringKey {
        switch self {
        case .medications: "Change Shared Medications…"
        case .visionPrescriptions: "Change Shared Prescriptions…"
        }
    }

    var noneShared: LocalizedStringKey {
        switch self {
        case .medications: "No medications are shared."
        case .visionPrescriptions: "No prescriptions are shared."
        }
    }

    var symbol: String {
        switch self {
        case .medications: "pills.fill"
        case .visionPrescriptions: "eyeglasses"
        }
    }

    var tint: Color {
        switch self {
        case .medications: .cyan
        case .visionPrescriptions: .blue
        }
    }
}

/// What Rendu may read of a kind shared one by one (medications, vision
/// prescriptions), as HealthKit reports it now, and the button that brings
/// up iOS's sheet to change it.
/// What Rendu may do in Apple Health: writing, type by type, as iOS says;
/// reading, as far as it can be told (readingLooksOff); and where to change
/// it, which is Apple Health — iOS's sheet only asks about types it hasn't
/// asked about before.
private struct HealthAccessView: View {
    let services: AppServices

    @Environment(\.scenePhase) private var scenePhase
    @State private var access: (allowed: [String], off: [String], notAsked: [String]) = ([], [], [])
    @State private var readingOff: [String]?

    var body: some View {
        List {
            Section {
                LabeledContent("Writing Allowed", value: access.allowed.count.formatted())
                LabeledContent("Writing Off", value: access.off.count.formatted())
                if !access.notAsked.isEmpty {
                    LabeledContent("Not Asked Yet", value: access.notAsked.count.formatted())
                }
            } footer: {
                Text("Entries of a type Rendu may not write aren't saved, and the server refuses them.")
            }
            Section {
                LabeledContent("Reading Looks Off") {
                    if let readingOff {
                        Text(verbatim: readingOff.count.formatted())
                    } else {
                        ProgressView()
                    }
                }
            } footer: {
                Text(
                    "iOS doesn't tell apps what they may read: with reading off, an app sees only what it saved itself. These are types Rendu read from Apple Watch or other apps before and now gets none of — reading was most likely turned off, or that data was deleted."
                )
            }
            Section {
                if !access.notAsked.isEmpty {
                    Button("Allow Access…") {
                        Task {
                            await services.requestHealthAccess()
                            await refresh()
                        }
                    }
                }
                Button("Open Apple Health") { openHealthApp() }
            } footer: {
                Text("Change what Rendu may read and write in Apple Health, under the apps that access your data.")
            }
            if let readingOff, !readingOff.isEmpty {
                Section("Reading Looks Off") {
                    ForEach(readingOff.sorted { DisplayNames.name(forKey: $0) < DisplayNames.name(forKey: $1) }, id: \.self) {
                        TypeName(identifier: $0)
                    }
                }
            }
            if !access.off.isEmpty {
                Section("Writing Off") {
                    ForEach(access.off.sorted { DisplayNames.name(forKey: $0) < DisplayNames.name(forKey: $1) }, id: \.self) {
                        TypeName(identifier: $0)
                    }
                }
            }
        }
        .navigationTitle("Apple Health")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    private func refresh() async {
        access = HealthAuthorization.writeAccess(services.healthStore)
        readingOff = await HealthAuthorization.readingLooksOff(services.healthStore)
    }
}

private struct SharedObjectsView: View {
    let services: AppServices
    let access: PerObjectAccess

    @State private var items: [PerObjectAccess.Item]?
    @State private var failure: String?
    /// The request came back at once, without iOS's sheet (seen with
    /// medications; why, iOS doesn't say).
    @State private var notAsked = false

    var body: some View {
        List {
            Section {
                if let items {
                    if items.isEmpty {
                        Text(access.noneShared)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: item.title)
                            if let detail = item.detail {
                                Text(verbatim: detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            } header: {
                Text("Shared with Rendu")
            }
            Section {
                Button(access.changeTitle) {
                    Task {
                        let asked = Date()
                        failure = await services.chooseShared(access)
                        notAsked = failure == nil && Date().timeIntervalSince(asked) < 1.5
                        await load()
                    }
                }
                if notAsked {
                    Button("Open Health") { openHealthApp() }
                }
            } footer: {
                if let failure {
                    Text(verbatim: failure).foregroundStyle(.red)
                } else if notAsked {
                    Text(
                        "iOS didn't show its sheet. What Rendu may read can also be changed in the Health app, under the apps that access your data."
                    )
                }
            }
        }
        .navigationTitle(access.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        items = await access.items(services.healthStore)
    }
}
