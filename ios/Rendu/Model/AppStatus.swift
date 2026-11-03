import Foundation
import Observation

enum SyncActivity: Equatable, Sendable {
    case none
    /// Reading Health. Only shown if someone asked (`visible`) or a large
    /// upload is going on meanwhile: passes for new Health data run unseen.
    case checking(visible: Bool)
    /// Uploading what the pass found, a large amount.
    case uploading

    /// Uploads smaller than this take a moment; they finish as part of
    /// checking (or unseen) instead of flashing their own progress.
    static let shownUpload = 1000
}

/// One sync, for Summary's Recent: what it saved to Apple Health (and
/// deleted, or found deleted there) and what it uploaded. Added once the
/// sync is over; a sync that did neither isn't one.
struct Activity: Codable, Identifiable, Equatable, Sendable {
    static let kept = 300

    var id = UUID()
    /// When the sync ended.
    var date: Date
    var saved = 0
    var deleted = 0
    var removedInHealth = 0
    var notSaved = 0
    /// The entries' names, the first few.
    var names: [String] = []
    var uploaded = 0
    /// Items uploaded by type key.
    var uploadedTypes: [String: Int] = [:]

    var hasWrites: Bool { saved + deleted + removedInHealth + notSaved > 0 }
    var isEmpty: Bool { !hasWrites && uploaded == 0 }
}

struct InFlightBatch: Equatable, Sendable {
    /// About 3 s for a batch of 20,000 samples.
    static let defaultSecondsPerItem = 3.0 / 20_000

    let key: String
    let items: Int
    let started: Date
    let expected: TimeInterval

    func sent(at date: Date) -> Int {
        guard expected > 0 else { return 0 }
        let fraction = min(0.97, max(0, date.timeIntervalSince(started) / expected))
        return Int(Double(items) * fraction)
    }
}

struct TypeStatus: Codable, Equatable, Sendable {
    var lastChecked: Date?
    var lastDelivered: Date?
    var totalDelivered: Int = 0
}

/// Observable UI state. All mutation happens on the main actor; background
/// actors call the methods below with await.
@Observable
@MainActor
final class AppStatus {
    var healthUnavailable = false
    var authNeeded = false
    /// iOS has asked for access to Apple Health on this install; nothing
    /// syncs before (HealthAuthorization.asked).
    var accessAsked = HealthAuthorization.asked
    /// Every type Rendu may write is turned off in Health's settings — the
    /// only sign of revoked access iOS gives (reads can't be checked).
    var healthAccessOff = false
    var syncing = false
    /// How far a pass has prepared its upload (reading Health, computing
    /// statistics), 0–1; nil when no pass is preparing. The count left
    /// isn't shown meanwhile: it would still grow.
    var preparing: Double?
    /// Entries from the server being saved to Apple Health right now (the
    /// start of a pass), or nil.
    var saving: Int?
    /// What the sync card shows of the running pass. Set by the engine at
    /// each step, so the card goes from one state to the next without
    /// passing through another for a frame.
    var activity = SyncActivity.none
    /// The batch being uploaded: its items, when it went out, and how long
    /// it should take, so the count left goes down smoothly instead of a
    /// batch at a time.
    var inFlight: InFlightBatch?
    /// Upload speed so far, for the time left.
    var secondsPerItem = InFlightBatch.defaultSecondsPerItem
    /// Items uploaded since launch; the difference over a sync is what it
    /// uploaded.
    var uploadedItems = 0
    /// What Rendu did lately, a sync each, newest first (Summary's Recent).
    private(set) var activities: [Activity] = []
    /// The running sync's, until it's over.
    private var current = Activity(date: .distantPast)
    var needsInitialImport = false
    var typeStatus: [String: TypeStatus] = [:]
    var outbox = OutboxSummary()
    var outboxNextRetry: Date?
    var lastResponse: String?
    /// End of the last pass that left nothing waiting to upload.
    var lastSyncAt: Date?
    /// Automatic syncing is paused until then (the user cancelled a sync).
    var pausedUntil: Date? = SyncPause.until
    var recentLog: [LogEntry] = []

    private static let statusKey = "status.types"
    private static let responseKey = "status.lastResponse"
    private static let lastSyncKey = "status.lastSyncAt"
    private static let activitiesKey = "status.activities"
    private let maxLogEntries = 200
    /// Injectable so tests running inside the app don't overwrite its state.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var uploading: Bool { outbox.batches > 0 }

    /// Items left to upload as of `date`, counting the batch in flight as
    /// partly sent. It never quite reaches the batch's end before the
    /// server confirms it.
    func remaining(at date: Date) -> Int {
        guard let inFlight else { return outbox.remainingUnits }
        return max(0, outbox.remainingUnits - inFlight.sent(at: date))
    }

    /// Roughly how long the rest of the queue takes.
    func timeLeft(at date: Date) -> TimeInterval {
        Double(remaining(at: date)) * secondsPerItem
    }
    var deliveryFailing: Bool { outboxNextRetry.map { $0 > Date() } ?? false }

    func load() {
        if let data = defaults.data(forKey: Self.statusKey),
            let decoded = try? JSONDecoder().decode([String: TypeStatus].self, from: data)
        {
            typeStatus = decoded
        }
        lastResponse = defaults.string(forKey: Self.responseKey)
        lastSyncAt = defaults.object(forKey: Self.lastSyncKey) as? Date
        if let data = defaults.data(forKey: Self.activitiesKey) {
            activities = (try? JSONDecoder().decode([Activity].self, from: data)) ?? []
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(typeStatus) {
            defaults.set(data, forKey: Self.statusKey)
        }
        defaults.set(lastResponse, forKey: Self.responseKey)
    }

    func setSyncing(_ value: Bool) {
        syncing = value
    }

    func setSaving(_ count: Int?) {
        saving = count
    }

    func setPreparing(_ progress: Double?) {
        preparing = progress
    }

    /// The user asked for a sync (or opened the app): show it from now on,
    /// even before its pass starts.
    func showChecking() {
        switch activity {
        case .none, .checking: activity = .checking(visible: true)
        case .uploading: break
        }
    }

    /// A pass starts: checking Health, visibly if anyone asked for it.
    func beginPass(visible: Bool) {
        syncing = true
        preparing = 0
        if case .checking(true) = activity { return }
        activity = .checking(visible: visible)
    }

    /// Reading is done and `pending` items are queued: large uploads show
    /// their own progress; small ones finish as part of checking.
    func beginUpload(pending: Int) {
        preparing = nil
        if pending >= SyncActivity.shownUpload { activity = .uploading }
    }

    /// A pass ends; `nextVisible`: a pass someone asked for runs next, so
    /// the card stays on checking.
    func endPass(nextVisible: Bool) {
        syncing = false
        preparing = nil
        finishActivity()
        activity = nextVisible ? .checking(visible: true) : .none
    }

    /// A requested sync didn't start (the server refused this iPhone).
    func cancelChecking() {
        if !syncing, case .checking = activity { activity = .none }
    }

    func setInFlight(_ batch: InFlightBatch?) {
        inFlight = batch
    }

    /// A batch was delivered: the queue without it, in one update with the
    /// end of its interpolation so the count doesn't step back.
    func recordBatchDelivered(
        items: Int, typeKey: String, secondsPerItem: Double, outbox summary: OutboxSummary, at date: Date = Date()
    ) {
        inFlight = nil
        uploadedItems += items
        current.uploaded += items
        current.uploadedTypes[typeKey, default: 0] += items
        // A retry, or a queue left at launch, delivered outside a sync.
        if !syncing && summary.batches == 0 { finishActivity(at: date) }
        self.secondsPerItem = secondsPerItem
        outbox = summary
        outboxNextRetry = nil
    }

    /// Write records just added to the log (by a sync's writes, or
    /// deletions it found made in Apple Health).
    func recordWrites(_ records: [WriteRecord]) {
        for record in records.reversed() {
            switch (record.action, record.outcome) {
            case (.removedInHealth, _): current.removedInHealth += 1
            case (_, .failed), (_, .conflict): current.notSaved += 1
            case (.delete, _): current.deleted += 1
            default: current.saved += 1
            }
            if !current.names.contains(record.headline), current.names.count < 10 {
                current.names.append(record.headline)
            }
        }
        if !syncing { finishActivity(at: records.first?.date ?? Date()) }
    }

    /// The sync is over: what it did becomes the newest activity.
    func finishActivity(at date: Date = Date()) {
        guard !current.isEmpty else { return }
        current.date = date
        activities.insert(current, at: 0)
        current = Activity(date: .distantPast)
        if activities.count > Activity.kept { activities.removeLast(activities.count - Activity.kept) }
        if let data = try? JSONEncoder().encode(activities) {
            defaults.set(data, forKey: Self.activitiesKey)
        }
    }

    func setPausedUntil(_ date: Date?) {
        pausedUntil = date
    }

    func recordSynced() {
        lastSyncAt = Date()
        defaults.set(lastSyncAt, forKey: Self.lastSyncKey)
    }

    func recordChecked(_ key: String) {
        update(key) { $0.lastChecked = Date() }
    }

    func recordDelivery(typeKey: String, count: Int, response: String) {
        update(typeKey) {
            $0.lastDelivered = Date()
            $0.totalDelivered += count
        }
        lastResponse = response
        save()
    }

    func setLastResponse(_ response: String) {
        lastResponse = response
        save()
    }

    func setOutbox(_ summary: OutboxSummary, nextRetry: Date?) {
        outbox = summary
        outboxNextRetry = nextRetry
    }

    func resetCounters() {
        typeStatus = [:]
        lastResponse = nil
        save()
    }

    func push(_ entry: LogEntry) {
        recentLog.insert(entry, at: 0)
        if recentLog.count > maxLogEntries {
            recentLog.removeLast(recentLog.count - maxLogEntries)
        }
    }

    func seedLog(_ entries: [LogEntry]) {
        recentLog = entries.sorted { $0.date > $1.date }
    }

    private func update(_ key: String, _ mutate: (inout TypeStatus) -> Void) {
        var status = typeStatus[key] ?? TypeStatus()
        mutate(&status)
        typeStatus[key] = status
        save()
    }
}
