import SwiftUI

/// What matters about a bridge: is data getting to the server (sync, with
/// its progress, or waiting for the server), and what came back (saved to
/// Health). The server itself is in Settings; what it holds is Browse.
struct SummaryView: View {
    let services: AppServices

    @State private var pairing = false
    /// Screenshots: `-rendu-demo -rendu-demo-open write` opens an update.
    @State private var demoWrite = false

    private var status: AppStatus { services.status }
    private var settings: AppSettings { services.settings }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if settings.isPaired {
                        VStack(spacing: 16) {
                            notices
                            SyncCard(services: services, pairing: $pairing)
                        }
                        if !status.activities.isEmpty {
                            SummarySection("Recent") {
                                ActivityListView(activities: status.activities)
                            } content: {
                                RecentCard(activities: status.activities)
                            }
                        }
                        // Only once something was submitted.
                        if !services.writes.records.isEmpty || (services.server.status?.pendingWrites ?? 0) > 0 {
                            SummarySection("Write History") {
                                WritesListView(services: services)
                            } content: {
                                SavedCard(services: services)
                            }
                        }
                    } else {
                        GetStarted(pairing: $pairing)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Summary")
            .task {
                await services.refreshServerStatus(maxAge: 30)
            }
            .task {
                guard Demo.isOn, UserDefaults.standard.string(forKey: "rendu-demo-open") == "write" else { return }
                try? await Task.sleep(for: .seconds(1))
                demoWrite = true
            }
            .navigationDestination(isPresented: $demoWrite) {
                if let record = services.writes.records.first(where: { $0.id == Demo.updateID }) {
                    WriteDetailView(services: services, record: record)
                }
            }
            .sheet(isPresented: $pairing) {
                PairView(services: services)
            }
        }
    }

    // MARK: - Needs attention

    /// Only what the user has to act on; each card's action spans its width.
    @ViewBuilder
    private var notices: some View {
        if status.authNeeded && status.accessAsked {
            NoticeCard(
                title: Text("Allow Access to More Data"),
                message: Text("Apple Health has kinds of data Rendu hasn't asked to access yet."),
                action: Text("Allow")
            ) {
                Task { await services.requestHealthAccess() }
            }
        }
        if UIApplication.shared.backgroundRefreshStatus == .denied {
            NoticeCard(
                title: Text("Background App Refresh Is Off"),
                message: Text("Rendu can sync only while it is open."),
                action: Text("Open Settings")
            ) {
                openAppSettings()
            }
        }
        if let expiry = Signing.expirationDate, expiry.timeIntervalSinceNow < 2 * 86400 {
            NoticeCard(
                title: Text("Signature Expires \(expiry.formatted(.relative(presentation: .named)))"),
                message: Text("Reinstall Rendu from Xcode to continue syncing. Your data will be kept."))
        }
    }
}

// MARK: - Sync

/// The state of syncing (Health to the server) as the card shows it: a pass
/// checks Health, then uploads what it found, and the count left only goes
/// down. Passes nobody asked for (new Health data arriving) show only when
/// they upload a lot.
enum SyncPhase: Equatable {
    case connecting, needsAccess, accessOff, saving, idle, checking, uploading, retrying, paused, waitingForServer, unpaired

    @MainActor
    init(_ services: AppServices) {
        let status = services.status
        let queued = status.uploading
        if let until = status.pausedUntil, until > .now {
            self = .paused
        } else if services.server.reachability == .unknown {
            // Opening the app starts with the server: where things stand
            // isn't known before it answers.
            self = .connecting
        } else if services.server.reachability == .keyRejected {
            self = .unpaired
        } else if !status.accessAsked {
            // Nothing is read before Apple Health access is given.
            self = .needsAccess
        } else if status.healthAccessOff {
            // Whatever a sync does then, nothing comes through.
            self = .accessOff
        } else if case .offline = services.server.reachability {
            self = .waitingForServer
        } else if queued && status.deliveryFailing {
            self = .retrying
        } else if status.saving != nil {
            // A pass starts by saving what the server holds for Apple
            // Health, so it reads those entries back right after.
            self = .saving
        } else {
            switch status.activity {
            case .uploading:
                self = queued ? .uploading : .idle
            case .checking(let visible):
                self = visible || status.outbox.remainingUnits >= SyncActivity.shownUpload ? .checking : .idle
            case .none:
                // Uploading outside a pass: a retry, or a queue left at launch.
                self = queued && status.outbox.sessionTotal >= SyncActivity.shownUpload ? .uploading : .idle
            }
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .connecting: "Connecting"
        case .needsAccess, .accessOff: "Not Syncing"
        case .saving: "Saving to Apple Health"
        case .idle: "Up to Date"
        case .checking: "Checking"
        case .uploading: "Uploading"
        case .retrying: "Waiting to Retry"
        case .paused: "Paused"
        case .waitingForServer: "Waiting for Server"
        case .unpaired: "No Longer Paired"
        }
    }

    /// Gray until the server answers, blue checking, indigo uploading;
    /// green done, orange waiting.
    var tint: Color {
        switch self {
        case .idle: .green
        case .connecting, .paused: .gray
        case .saving: .pink
        case .checking: .blue
        case .uploading: .indigo
        case .retrying, .waitingForServer, .unpaired, .needsAccess, .accessOff: .orange
        }
    }

    var running: Bool { self == .connecting || self == .saving || self == .checking || self == .uploading }
    var uploads: Bool { self == .uploading || self == .retrying }
}

/// The glass status icon: a symbol per phase, swapped in place while the
/// color fades to the next phase's over the same time; the checkmark draws
/// itself when a sync finishes.
private struct SyncIcon: View {
    let phase: SyncPhase
    let size: CGFloat

    private static let swap = AnyTransition.scale(scale: 0.6).combined(with: .opacity)

    var body: some View {
        ZStack {
            switch phase {
            case .idle:
                Image(systemName: "checkmark")
                    .transition(.symbolEffect(.drawOn))
            case .connecting:
                // Reaching the server: its racks light up in turn.
                Image(systemName: "server.rack")
                    .symbolEffect(.variableColor.iterative, options: .repeat(.continuous))
                    .transition(Self.swap)
            case .saving:
                Image(systemName: "heart.text.square.fill")
                    .symbolEffect(.pulse, options: .repeat(.continuous))
                    .transition(Self.swap)
            case .checking:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .symbolEffect(.rotate, options: .repeat(.continuous))
                    .transition(Self.swap)
            case .uploading:
                RisingArrow(size: size)
                    .transition(Self.swap)
            case .retrying, .waitingForServer:
                Image(systemName: "clock.arrow.circlepath")
                    .transition(Self.swap)
            case .paused:
                Image(systemName: "pause.fill")
                    .transition(Self.swap)
            case .unpaired:
                Image(systemName: "iphone.slash")
                    .transition(Self.swap)
            case .needsAccess, .accessOff:
                Image(systemName: "heart.slash.fill")
                    .transition(Self.swap)
            }
        }
        .font(.system(size: size * 0.4, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .clipShape(.circle)
        .tintedGlass(phase.tint)
        .animation(.smooth(duration: 0.35), value: phase)
    }
}

/// An up arrow that rises in from the bottom and leaves at the top, again
/// and again.
private struct RisingArrow: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "arrow.up")
            .keyframeAnimator(initialValue: 0.0, repeating: true) { content, travel in
                content
                    .offset(y: size * 0.5 * (1 - 2 * travel))
                    .opacity(1 - abs(2 * travel - 1))
            } keyframes: { _ in
                CubicKeyframe(0.5, duration: 0.9)
                LinearKeyframe(0.5, duration: 0.6)
                CubicKeyframe(1, duration: 0.9)
            }
    }
}

/// The large card: what sync is doing, how much is left and of what, and
/// the one action that fits. The queue appears when an upload starts and
/// goes when it's done; pausing, resuming and waiting keep it in place.
private struct SyncCard: View {
    let services: AppServices
    @Binding var pairing: Bool

    /// The queue is on the card (from the start of an upload to its end).
    @State private var queueShown = false
    /// The queue as it was when uploading stopped (paused, waiting, checking
    /// again on resume): what's read meanwhile doesn't make it grow.
    @State private var frozenQueue: OutboxSummary?
    /// Items uploaded before this sync, to tell what it uploaded.
    @State private var itemsBefore = 0
    /// Shown for a moment once a sync is done: "Uploaded 1,234".
    @State private var justUploaded: Int?
    /// The user tapped Sync Now, Resume or Try Again: the end is theirs to feel.
    @State private var requested = false
    @State private var haptic = HapticEvent()

    private static let queuePreview = 3

    var body: some View {
        let phase = SyncPhase(services)
        let status = services.status
        let live = frozenQueue == nil && phase.uploads
        VStack(alignment: .leading, spacing: 0) {
            TimelineView(.animation(minimumInterval: 0.1, paused: !live || status.inFlight == nil)) { context in
                let outbox = frozenQueue ?? status.outbox
                let remaining = live ? status.remaining(at: context.date) : outbox.remainingUnits
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        SyncIcon(phase: phase, size: Summary.iconSize)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(phase.title)
                                .font(.title3.weight(.semibold))
                            subtitle(phase, remaining: remaining, timeLeft: Double(remaining) * status.secondsPerItem)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    if queueShown {
                        VStack(alignment: .leading, spacing: 12) {
                            ProgressBar(
                                value: outbox.sessionTotal > 0 ? 1 - Double(remaining) / Double(outbox.sessionTotal) : 0,
                                tint: phase.running ? phase.tint : Color(.systemGray3)
                            )
                            queue(outbox, sent: outbox.remainingUnits - remaining)
                        }
                        .transition(.opacity)
                    }
                }
                .padding(16)
            }
            Divider().padding(.leading, 16)
            let action = action(phase)
            Button(action: action.perform) {
                HStack {
                    action.title
                    Spacer(minLength: 0)
                }
                .cardRow()
            }
            .buttonStyle(.pressable)
            .foregroundStyle(Color.accentColor)
        }
        .cardBackground()
        .onChange(of: phase, initial: true) { old, new in
            follow(from: old, to: new)
        }
        .haptic(haptic)
    }

    @ViewBuilder
    private func subtitle(_ phase: SyncPhase, remaining: Int, timeLeft: TimeInterval) -> some View {
        let status = services.status
        switch phase {
        case .connecting:
            Text(verbatim: services.settings.baseURL?.host() ?? services.settings.endpoint)
        case .saving:
            Text(
                verbatim: String(
                    AttributedString(localized: "^[\(status.saving ?? 0) entry](inflect: true) from the server").characters))
        case .idle:
            if let justUploaded {
                Text("Uploaded \(justUploaded.formatted())")
            } else if let last = status.lastSyncAt {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    if context.date.timeIntervalSince(last) < 60 {
                        Text("Synced just now")
                    } else {
                        Text("Synced \(last.formatted(.relative(presentation: .named)))")
                    }
                }
            } else {
                Text("Waiting for Apple Health data")
            }
        case .checking:
            Text("Checking Apple Health for new data")
        case .uploading:
            Text(verbatim: String(localized: "\(remaining.formatted()) left") + " · " + Self.timeLeft(timeLeft))
        case .retrying:
            if let retry = status.outboxNextRetry {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("Retrying \(retry.formatted(.relative(presentation: .named)))")
                }
            }
        case .paused:
            if let until = status.pausedUntil {
                Text("Resumes at \(until.formatted(date: .omitted, time: .shortened))")
            }
        case .waitingForServer:
            Text("New data is kept on this iPhone")
        case .unpaired:
            Text("Another iPhone was paired with the server")
        case .needsAccess:
            Text("Allow access to Apple Health to start")
        case .accessOff:
            Text("Access to Apple Health is off")
        }
    }

    private static func timeLeft(_ seconds: TimeInterval) -> String {
        seconds < 60
            ? String(localized: "Less than a minute")
            : String(localized: "About \(Int((seconds / 60).rounded(.up))) min")
    }

    /// What's still to upload, in upload order; the first is uploading now,
    /// `sent` of it on its way.
    private func queue(_ outbox: OutboxSummary, sent: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(outbox.keyOrder.prefix(Self.queuePreview).enumerated()), id: \.element) { index, key in
                HStack(spacing: 8) {
                    QueueKeyIcon(key: key)
                    Text(verbatim: QueueKeyIcon.name(key))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(verbatim: max(0, (outbox.itemsByKey[key] ?? 0) - (index == 0 ? sent : 0)).formatted())
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            let more = outbox.keyOrder.count - Self.queuePreview
            if more > 0 {
                Text("\(more) more types")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        // Rows come and go with the queue; no animation to catch the eye.
        .transaction { $0.animation = nil }
    }

    private func action(_ phase: SyncPhase) -> (title: Text, perform: () -> Void) {
        let sync = {
            requested = true
            Task { await services.syncNow(.manual) }
        }
        return switch phase {
        case .connecting, .saving, .checking, .uploading: (Text("Pause"), { Task { await services.pauseSync() } })
        case .retrying, .waitingForServer: (Text("Try Again"), sync)
        case .paused: (Text("Resume"), sync)
        case .idle: (Text("Sync Now"), sync)
        case .unpaired: (Text("Pair Again…"), { pairing = true })
        case .needsAccess: (Text("Allow Access…"), { Task { await services.requestHealthAccess() } })
        // iOS shows its sheet only for types it hasn't asked about; access
        // turned off is turned back on in Apple Health.
        case .accessOff: (Text("Open Apple Health"), openHealthApp)
        }
    }

    /// Keeps the queue in place and plays the feedback for a change.
    private func follow(from old: SyncPhase, to new: SyncPhase) {
        let status = services.status
        if (old == .idle || old == new) && new != .idle {
            itemsBefore = status.uploadedItems
            justUploaded = nil
        }
        switch new {
        case .uploading, .retrying:
            frozenQueue = nil
            if !queueShown { withAnimation(.smooth(duration: 0.35)) { queueShown = true } }
        case .idle:
            frozenQueue = nil
            if queueShown { withAnimation(.smooth(duration: 0.35)) { queueShown = false } }
        case .connecting, .needsAccess, .accessOff, .saving, .checking, .paused, .waitingForServer, .unpaired:
            if old == new, status.uploading, new != .checking {
                // The card appears paused or waiting with a queue.
                queueShown = true
            }
            if queueShown, frozenQueue == nil { frozenQueue = status.outbox }
        }
        guard old != new else { return }
        let feedback: SensoryFeedback?
        switch (old, new) {
        case (_, .paused):
            feedback = .impact(weight: .medium)
        case (.paused, _):
            feedback = .impact(weight: .light, intensity: 0.7)
        case (.checking, .idle), (.uploading, .idle):
            let uploaded = status.uploadedItems - itemsBefore
            if uploaded > 0 { showUploaded(uploaded) }
            feedback = requested || old == .uploading ? .success : nil
        case (.checking, .waitingForServer), (.uploading, .waitingForServer), (.checking, .retrying),
            (.uploading, .retrying), (.checking, .unpaired), (.uploading, .unpaired):
            // Only for a sync the user asked for: opening the app while the
            // server is down shouldn't buzz every time.
            feedback = requested ? .warning : nil
        default:
            feedback = nil
        }
        if new == .idle || !new.running { requested = false }
        if let feedback { haptic.play(feedback) }
    }

    private func showUploaded(_ items: Int) {
        justUploaded = items
        Task {
            try? await Task.sleep(for: .seconds(6))
            if justUploaded == items { justUploaded = nil }
        }
    }
}

/// iCloud's backup bar: a capsule track, filled in the tint.
private struct ProgressBar: View {
    let value: Double
    let tint: Color

    var body: some View {
        Capsule()
            .fill(Color(.tertiarySystemFill))
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule()
                        .fill(tint)
                        .frame(width: max(geometry.size.height, geometry.size.width * min(1, max(0, value))))
                }
            }
            .frame(height: 6)
    }
}

/// The icon of a queue entry: the type's Health category, Activity for the
/// rings, a person for characteristics.
struct QueueKeyIcon: View {
    let key: String

    var body: some View {
        switch key {
        case "characteristics":
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.gray)
                .frame(width: 21, height: 18, alignment: .leading)
        default:
            CategoryIcon(category: HealthCategory.of(Self.identifier(key)), size: 15)
        }
    }

    private static func identifier(_ key: String) -> String {
        key == "activitySummary" ? "HKActivitySummaryTypeIdentifier" : key
    }

    static func name(_ key: String) -> String {
        DisplayNames.name(forKey: key)
    }
}

private enum Summary {
    static let iconSize: CGFloat = 52
}

/// The server at the top of Settings, large like the Apple Account row:
/// its host, and whether it's up — red when it isn't.
struct ServerRow: View {
    let services: AppServices

    var body: some View {
        HStack(spacing: 14) {
            SettingsIcon(symbol: "server.rack", tint: .blue, size: 58)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: services.settings.baseURL?.host() ?? services.settings.endpoint)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                ServerStatusLine(server: services.server)
                    .font(.subheadline)
            }
            Spacer(minLength: 8)
            LockMark(lock: services.lock)
            Chevron()
        }
        .padding(.vertical, 6)
    }
}

/// A small lock while the server settings are locked (ServerLock).
struct LockMark: View {
    let lock: ServerLock

    var body: some View {
        if lock.enabled && !lock.unlocked {
            Image(systemName: "lock.fill")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
    }
}

/// "Online", "Unreachable", "Token Rejected" — red only when something is
/// wrong.
struct ServerStatusLine: View {
    let server: ServerState

    var body: some View {
        Group {
            switch server.reachability {
            case .online: Text("Online")
            case .offline: Text("Unreachable")
            case .keyRejected: Text("No Longer Paired")
            case .notPaired: Text("Not Paired")
            case .unknown: Text("Checking…")
            }
        }
        .foregroundStyle(server.failing ? Color.red : .secondary)
        .lineLimit(1)
    }
}

extension ServerState {
    var failing: Bool {
        switch reachability {
        case .offline, .keyRejected: true
        default: false
        }
    }
}

// MARK: - Saved to Health

/// A part of Summary as Health lays its own out: the title above the card,
/// with Show All beside it.
private struct SummarySection<Destination: View, Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let destination: () -> Destination
    @ViewBuilder let content: () -> Content

    init(
        _ title: LocalizedStringKey, @ViewBuilder destination: @escaping () -> Destination,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.destination = destination
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.title3.bold())
                Spacer(minLength: 8)
                NavigationLink("Show All", destination: destination)
                    .font(.body)
            }
            .padding(.horizontal, 4)
            content()
        }
    }
}

/// What Rendu did lately, a sync each, newest first (AppStatus.activities)
/// — here rather than as banners while the app is open (HIG,
/// Notifications). A sync shows up once it's over; times say what's new,
/// nothing is marked unread.
private struct RecentCard: View {
    let activities: [Activity]
    private static let shown = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(activities.prefix(Self.shown).enumerated()), id: \.element.id) { position, activity in
                if position > 0 { Divider().padding(.leading, 16) }
                ActivityRow(activity: activity)
                    .cardRow()
            }
        }
        .cardBackground()
        .animation(.smooth(duration: 0.35), value: activities.first?.id)
    }
}

/// Every sync kept, by day.
private struct ActivityListView: View {
    let activities: [Activity]

    var body: some View {
        let days = Dictionary(grouping: activities) { Calendar.current.startOfDay(for: $0.date) }
        List {
            ForEach(days.keys.sorted(by: >), id: \.self) { day in
                Section {
                    ForEach(days[day]!) { activity in
                        ActivityRow(activity: activity, time: activity.date.formatted(date: .omitted, time: .shortened))
                    }
                } header: {
                    Text(verbatim: day.dayTitle)
                }
            }
        }
        .navigationTitle("Recent")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A sync as Health shows a reading: what it was, in its color, and when;
/// the number, large; what it was about. Pink saving to Apple Health and
/// indigo uploading, as on the sync card; red only for what wasn't saved.
private struct ActivityRow: View {
    let activity: Activity
    var time: String?

    var body: some View {
        let kind = activity.kind
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(kind.title)
                } icon: {
                    Image(systemName: kind.symbol)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(kind.tint)
                Spacer(minLength: 8)
                Text(verbatim: time ?? activity.date.shortStamp)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: kind.count.formatted())
                    .font(.title2.weight(.semibold))
                    .fontDesign(.rounded)
                Text(kind.unit(kind.count))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if activity.notSaved > 0 && kind != .notSaved(activity.notSaved) {
                Mark(
                    symbol: "exclamationmark.circle.fill",
                    text: String(AttributedString(localized: "^[\(activity.notSaved) entry](inflect: true) not saved").characters)
                )
                .font(.subheadline)
                .foregroundStyle(.red)
            }
            if !activity.about.isEmpty {
                Text(verbatim: activity.about)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

extension Activity {
    /// What a sync is shown as: what changed Apple Health first.
    enum Shown: Equatable {
        case saved(Int)
        case deleted(Int)
        case removedInHealth(Int)
        case notSaved(Int)
        case uploaded(Int)

        var count: Int {
            switch self {
            case .saved(let n), .deleted(let n), .removedInHealth(let n), .notSaved(let n), .uploaded(let n): n
            }
        }

        var title: LocalizedStringKey {
            switch self {
            case .saved: "Saved to Apple Health"
            case .deleted: "Deleted from Apple Health"
            case .removedInHealth: "Deleted in Apple Health"
            case .notSaved: "Not Saved"
            case .uploaded: "Uploaded"
            }
        }

        var symbol: String {
            switch self {
            case .saved: "heart.fill"
            case .deleted, .removedInHealth: "trash.fill"
            case .notSaved: "exclamationmark.circle.fill"
            case .uploaded: "arrow.up.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .saved: .pink
            case .deleted, .removedInHealth: .gray
            case .notSaved: .red
            case .uploaded: .indigo
            }
        }

        /// "entries" for what was written, "items" for what was uploaded.
        func unit(_ count: Int) -> LocalizedStringKey {
            switch self {
            case .uploaded: count == 1 ? "item" : "items"
            default: count == 1 ? "entry" : "entries"
            }
        }
    }

    var kind: Shown {
        if saved > 0 { return .saved(saved) }
        if deleted > 0 { return .deleted(deleted) }
        if removedInHealth > 0 { return .removedInHealth(removedInHealth) }
        if notSaved > 0 { return .notSaved(notSaved) }
        return .uploaded(uploaded)
    }

    /// The entries written, or else the kinds of data uploaded, most first.
    var about: String {
        if !names.isEmpty { return names.formatted(.list(type: .and, width: .narrow)) }
        let kinds = uploadedTypes.sorted { $0.value > $1.value }.map { DisplayNames.name(forKey: $0.key) }
        return kinds.count > 3
            ? String(localized: "\(kinds.prefix(2).formatted(.list(type: .and, width: .narrow))) and \(kinds.count - 2) more")
            : kinds.formatted(.list(type: .and, width: .narrow))
    }
}

private struct SavedCard: View {
    let services: AppServices
    private static let recent = 5
    /// An entry's two lines.
    static let rowHeight: CGFloat = 42

    var body: some View {
        let records = services.writes.records
        let index = WriteIndex(records)
        // As of the last status check, less what was saved since.
        let checked = services.server.checkedAt ?? .distantFuture
        let pending = max(
            0,
            (services.server.status?.pendingWrites ?? 0)
                - records.filter { $0.date > checked && $0.action != .removedInHealth }.count)
        VStack(alignment: .leading, spacing: 0) {
            if pending > 0 {
                Label("\(pending) waiting to be saved", systemImage: "clock")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .cardRow()
                if !records.isEmpty { Divider().padding(.leading, 16) }
            }
            ForEach(Array(records.prefix(Self.recent).enumerated()), id: \.element.id) { position, record in
                if position > 0 { Divider().padding(.leading, 49) }
                NavigationLink {
                    WriteDetailView(services: services, record: record)
                } label: {
                    WriteRow(record: record, tag: index.tag(for: record), changes: index.changes(of: record))
                        .frame(minHeight: SavedCard.rowHeight)
                        .cardRow()
                }
                .buttonStyle(.pressable)
            }
        }
        .cardBackground()
    }
}

// MARK: - Not paired

private struct GetStarted: View {
    @Binding var pairing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    GlassIcon(symbol: "server.rack", tint: .blue, size: Summary.iconSize)
                    Text("Pair with Your Server")
                        .font(.title3.weight(.semibold))
                }
                Text(
                    "Rendu uploads your Apple Health data to your own server. Other programs read it through the API, and entries they submit are saved to Apple Health."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                Divider()
                step(1, Text("Enter the address of your server."))
                step(2, Text("Run the pairing command shown in Rendu on the server."))
            }
            .cardRow()
            Divider().padding(.leading, 16)
            Button {
                pairing = true
            } label: {
                HStack {
                    Text("Pair…")
                    Spacer(minLength: 0)
                }
                .cardRow()
            }
            .buttonStyle(.pressable)
            .foregroundStyle(Color.accentColor)
        }
        .cardBackground()
        Text("Apple Health data is sent only to the server you pair with.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
    }

    private func step(_ number: Int, _ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "\(number).")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            text
                .font(.subheadline)
        }
    }
}

// MARK: - Pieces

/// iCloud's suggestion card: title and message, and an action row under a
/// divider that responds across the card's full width.
private struct NoticeCard: View {
    let title: Text
    let message: Text
    var action: Text?
    var perform: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                title.font(.headline)
                message
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .cardRow()
            if let action {
                Divider().padding(.leading, 16)
                Button(action: perform) {
                    HStack {
                        action
                        Spacer(minLength: 0)
                    }
                    .cardRow()
                }
                .buttonStyle(.pressable)
                .foregroundStyle(Color.accentColor)
            }
        }
        .cardBackground()
    }
}

extension Date {
    /// "13:05" today, "Yesterday", "Nov 1" — for tight spaces.
    var shortStamp: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(self) { return String(localized: "Yesterday") }
        return formatted(.dateTime.month().day())
    }
}

/// The Health app, where the data an app may read is changed.
@MainActor
func openHealthApp() {
    if let url = URL(string: "x-apple-health://") {
        UIApplication.shared.open(url)
    }
}

@MainActor
func openAppSettings() {
    if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
    }
}
