import Foundation

/// Durable delivery queue. Every batch is written to disk *before* the first
/// upload attempt — already encoded and gzipped, exactly the bytes to send —
/// and deleted only on a server 2xx, at which point the batch's anchor (if
/// any, kept in a sidecar file) is persisted. Files drain strictly in enqueue
/// order and draining stops at the first failure, so anchors can never
/// advance past an undelivered batch. At-least-once delivery; the server
/// dedupes samples by uuid and replaces statistics, summaries, and
/// characteristics wholesale, so every batch is safe to resend.
/// What is waiting to be uploaded, derived from batch file names (no decoding).
/// Counted in items — samples, statistics rows, activity days — and keyed by
/// what they describe, so a type's statistics count toward that type
/// ("1,023 Heart Rate" may be 1,000 samples and 23 daily statistics).
struct OutboxSummary: Equatable, Sendable {
    var batches = 0
    /// Items per key: a catalog type, `activitySummary`, or `characteristics`.
    var itemsByKey: [String: Int] = [:]
    /// Keys in upload order: the first one is uploading now. A key whose
    /// statistics are queued behind other types shows up where they are.
    var keyOrder: [String] = []
    /// Items enqueued since the queue was last empty — the denominator of
    /// the progress bar.
    var sessionTotal = 0

    var remainingUnits: Int { itemsByKey.values.reduce(0, +) }

    /// A batch counts at least one item, so a queue of tombstones never
    /// reads as empty.
    static func items(_ count: Int) -> Int { max(count, 1) }

    var progress: Double {
        guard sessionTotal > 0 else { return 0 }
        return min(1, max(0, 1 - Double(remainingUnits) / Double(sessionTotal)))
    }
}

actor Outbox {
    static let baseRetryInterval: TimeInterval = 60
    static let maxRetryInterval: TimeInterval = 3600

    private let directory: URL
    private let anchors: AnchorStore
    private let uploader: Uploading
    private let target: @Sendable () -> (base: URL, token: String?)?
    private let log: LogStore
    private let status: AppStatus
    private let maxBatchBytes: Int
    private let defaults: UserDefaults
    private var sequence: Int
    private var failureCount = 0
    private var nextAttempt = Date.distantPast
    private var chain: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var sessionTotal = 0
    /// Upload speed, measured on large batches and kept across launches.
    private var secondsPerItem: Double
    /// Called once when deliveries have been failing for a while.
    private let onPersistentFailure: @Sendable (String) async -> Void
    static let persistentFailureCount = 5
    /// Waits before the quick retries of a failed batch (sendRetrying).
    private let quickRetryDelays: [Duration]

    init(
        directory: URL,
        anchors: AnchorStore,
        uploader: Uploading,
        target: @escaping @Sendable () -> (base: URL, token: String?)?,
        log: LogStore,
        status: AppStatus,
        maxBatchBytes: Int = Wire.maxBatchBytes,
        defaults: UserDefaults = .standard,
        quickRetryDelays: [Duration] = [.seconds(1), .seconds(3)],
        onPersistentFailure: @escaping @Sendable (String) async -> Void = { _ in }
    ) {
        self.quickRetryDelays = quickRetryDelays
        self.directory = directory
        self.anchors = anchors
        self.uploader = uploader
        self.target = target
        self.log = log
        self.status = status
        self.maxBatchBytes = maxBatchBytes
        self.onPersistentFailure = onPersistentFailure
        self.defaults = defaults
        sequence = defaults.integer(forKey: SettingsKeys.outboxSequence)
        let speed = defaults.double(forKey: SettingsKeys.outboxSecondsPerItem)
        secondsPerItem = speed > 0 ? speed : InFlightBatch.defaultSecondsPerItem
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Enqueue

    /// Sample batches for /v1/ingest, split by size. Only the last slice
    /// carries the anchor — the one the samples were read up to, with the
    /// one they were read from (`base`, nil for none) — since it may only
    /// advance once *all* of the query result is delivered. The server moves
    /// its copy of the anchor in the same transaction, if it still has
    /// `base` (store/anchors.go).
    func enqueueSamples(typeKey: String, elements: [JSON], anchor: Data?, base: Data?) throws {
        guard !elements.isEmpty else { return }
        let slices = try BatchSlicer.encodedSlices(elements, maxBytes: maxBatchBytes)
        for (index, slice) in slices.enumerated() {
            let last = index == slices.count - 1
            try write(
                endpoint: .ingest, typeKey: typeKey,
                count: slice.elements.filter { !Wire.isTombstone($0) }.count,
                body: slice.body, anchor: last ? anchor : nil, base: last ? base : nil
            )
        }
        // Upload while the pass reads on; the UI counts down only once the
        // pass has queued everything (AppStatus.preparing).
        Task { await self.drain(force: false) }
    }

    /// A single payload for any other endpoint.
    func enqueue(_ endpoint: Endpoint, typeKey: String, count: Int, payload: JSON) throws {
        try write(endpoint: endpoint, typeKey: typeKey, count: count, body: Wire.encode(payload), anchor: nil, base: nil)
        Task { await self.drain(force: false) }
    }

    private func write(endpoint: Endpoint, typeKey: String, count: Int, body: Data, anchor: Data?, base: Data?) throws {
        sequence += 1
        defaults.set(sequence, forKey: SettingsKeys.outboxSequence)
        let name = BatchName(
            sequence: sequence, id: String(UUID().uuidString.prefix(8)),
            endpoint: endpoint, count: count, typeKey: typeKey, format: .gzip
        )
        // Sidecars first: a body file on disk always has its anchors. (An
        // empty base file: read from no anchor.)
        if let anchor {
            try (base ?? Data()).write(to: directory.appendingPathComponent(name.baseFileName), options: .atomic)
            try anchor.write(to: directory.appendingPathComponent(name.anchorFileName), options: .atomic)
        }
        try Gzip.compress(body).write(to: directory.appendingPathComponent(name.fileName), options: .atomic)
        if sessionTotal == 0 {
            sessionTotal = summarize(pendingFiles()).remainingUnits
        } else {
            sessionTotal += OutboxSummary.items(count)
        }
    }

    private typealias Loaded = (body: Data, anchor: Data?, base: Data?, endpoint: Endpoint, typeKey: String, count: Int)

    /// The gzipped body, anchors, and description of a queued file in either
    /// format. `base` is nil for batches queued before the server kept
    /// anchors; those don't move the server's.
    private func load(_ file: URL) throws -> Loaded {
        if let name = BatchName(fileName: file.lastPathComponent), name.format == .gzip {
            let anchor = try? Data(contentsOf: directory.appendingPathComponent(name.anchorFileName))
            let base = try? Data(contentsOf: directory.appendingPathComponent(name.baseFileName))
            return (try Data(contentsOf: file), anchor, base, name.endpoint, name.typeKey, name.count)
        }
        let batch = try Wire.fileDecoder().decode(Batch.self, from: Data(contentsOf: file))
        return (Gzip.compress(try Wire.encode(batch.payload)), batch.anchor, nil, batch.endpoint, batch.typeKey, batch.count)
    }

    private func remove(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
        if let name = BatchName(fileName: file.lastPathComponent), name.format == .gzip {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name.anchorFileName))
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name.baseFileName))
        }
    }

    // MARK: - Drain

    /// Serialized via task-chaining: concurrent calls queue up rather than
    /// interleave, and every caller returns only after its own pass finished.
    func drain(force: Bool) async {
        let previous = chain
        let task = Task {
            await previous?.value
            await self.performDrain(force: force)
        }
        chain = task
        await task.value
    }

    /// Stops the drain in flight; its batch stays queued.
    func cancel() {
        chain?.cancel()
        retryTask?.cancel()
        retryTask = nil
    }

    private func performDrain(force: Bool) async {
        defer { Task { await self.refreshPendingStatus() } }
        var files = pendingFiles()
        guard !files.isEmpty else { return }
        if !force && SyncPause.isActive { return }
        guard let target = target() else {
            log.debug("outbox: \(files.count) batch(es) waiting — not connected to a server")
            return
        }
        if !force && Date() < nextAttempt { return }

        // Pausing stops after the batch in flight.
        while let file = files.first, !Task.isCancelled, !SyncPause.isActive {
            files.removeFirst()
            let batch: Loaded
            do {
                batch = try load(file)
            } catch {
                // A batch file we can't read would poison the queue forever; set it aside.
                quarantine(file)
                await log.error("outbox: unreadable batch \(file.lastPathComponent) set aside (\(error.localizedDescription))")
                continue
            }
            do {
                let url = target.base.appending(path: batch.endpoint.rawValue)
                var headers: [String: String] = [:]
                if let anchor = batch.anchor, let base = batch.base {
                    headers["X-Rendu-Anchor-Type"] = batch.typeKey
                    headers["X-Rendu-Anchor"] = anchor.base64EncodedString()
                    if !base.isEmpty { headers["X-Rendu-Base-Anchor"] = base.base64EncodedString() }
                }
                let items = OutboxSummary.items(batch.count)
                await status.setInFlight(
                    InFlightBatch(
                        key: batch.typeKey, items: items, started: Date(), expected: secondsPerItem * Double(items)
                    ))
                let result = try await sendRetrying {
                    try await uploader.send(
                        batch.body, gzipped: true, method: batch.endpoint.method, to: url, token: target.token, headers: headers
                    )
                }
                guard result.isSuccess else {
                    await status.setInFlight(nil)
                    await recordFailure("HTTP \(result.status) \(result.bodySnippet.prefix(120))", status: result.status)
                    return
                }
                let reply = batch.endpoint == .ingest ? IngestReply(result.bodySnippet) : nil
                if let anchorData = batch.anchor {
                    if reply?.anchor == "stale" {
                        // The server's progress isn't where this batch began
                        // (its data was wiped or restored): the samples are
                        // stored, and the next pass continues from the
                        // server's anchor instead.
                        await log.warn("\(batch.typeKey): the server's sync progress moved — catching up from it next pass")
                    } else {
                        anchors.saveRaw(anchorData, for: batch.typeKey)
                    }
                }
                remove(file)
                if let rejected = reply?.rejected, rejected > 0 {
                    await log.warn("server skipped \(rejected) malformed \(batch.typeKey) element(s)")
                }
                failureCount = 0
                nextAttempt = .distantPast
                retryTask?.cancel()
                retryTask = nil
                let response = "HTTP \(result.status) · \(result.bodySnippet.prefix(80))"
                if batch.endpoint == .ingest {
                    await status.recordDelivery(typeKey: batch.typeKey, count: batch.count, response: response)
                } else {
                    await status.setLastResponse(response)
                }
                await log.record(
                    .upload, title: DisplayNames.name(forKey: batch.typeKey),
                    detail: batch.endpoint.uploaded(batch.count) + " · " + LogText.seconds(result.duration),
                    message:
                        "delivered \(batch.count) \(batch.typeKey) \(batch.endpoint.noun) — HTTP \(result.status) in \(Int(result.duration * 1000))ms"
                )
                // Small batches are mostly round trip; they'd skew the speed.
                if items >= 1000 {
                    secondsPerItem = 0.6 * secondsPerItem + 0.4 * result.duration / Double(items)
                    defaults.set(secondsPerItem, forKey: SettingsKeys.outboxSecondsPerItem)
                }
                await status.recordBatchDelivered(
                    items: items, typeKey: batch.typeKey, secondsPerItem: secondsPerItem, outbox: summary())
            } catch {
                await status.setInFlight(nil)
                // A cancelled sync leaves the batch queued; it isn't a failure.
                if Task.isCancelled { return }
                await recordFailure(error.localizedDescription, status: nil)
                return
            }
        }
    }

    /// A dropped connection or a server hiccup (5xx) gets two quick retries
    /// before it counts as a failure and the queue backs off.
    private func sendRetrying(_ send: () async throws -> UploadResult) async throws -> UploadResult {
        for delay in quickRetryDelays {
            do {
                let result = try await send()
                guard result.status >= 500 else { return result }
            } catch {
                if Task.isCancelled { throw error }
            }
            try await Task.sleep(for: delay)
        }
        return try await send()
    }

    /// The parts of an /ingest response the phone acts on.
    private struct IngestReply: Decodable {
        var rejected: Int?
        var anchor: String?

        init?(_ body: String) {
            guard let reply = try? JSONDecoder().decode(Self.self, from: Data(body.utf8)) else { return nil }
            self = reply
        }
    }

    private func recordFailure(_ reason: String, status statusCode: Int?) async {
        failureCount += 1
        let delay = min(
            Self.maxRetryInterval,
            Self.baseRetryInterval * pow(2, Double(failureCount - 1))
        )
        nextAttempt = Date(timeIntervalSinceNow: delay)
        var hint = ""
        if statusCode == 401 || statusCode == 403 {
            hint = " — the server no longer accepts this iPhone's key; pair again in Settings"
        }
        await status.setLastResponse(String(reason.prefix(160)))
        await log.record(
            .upload, .warn, title: String(localized: "Upload Failed"),
            detail: String(reason.prefix(160)) + " · " + String(localized: "Retrying in \(LogText.seconds(delay))"),
            message: "delivery failed: \(reason)\(hint) — retrying in \(Int(delay))s"
        )
        if failureCount == Self.persistentFailureCount {
            await onPersistentFailure(reason + hint)
        }
        // Retry on schedule for as long as the app keeps running; triggers
        // (foreground, unlock, new data) may still come sooner.
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.drain(force: false)
        }
    }

    private func quarantine(_ file: URL) {
        let destination = file.appendingPathExtension("corrupt")
        try? FileManager.default.moveItem(at: file, to: destination)
    }

    // MARK: - State

    private func pendingFiles() -> [URL] {
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )) ?? []
        return
            contents
            .filter { ["gz", "json"].contains($0.pathExtension) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The newest anchor queued per type: where reading got to, beyond what
    /// the server has. A relaunched app continues from here instead of
    /// reading the queued samples again.
    func queuedAnchors() -> [String: Data] {
        var out: [String: Data] = [:]
        for file in pendingFiles() {
            guard let name = BatchName(fileName: file.lastPathComponent), name.format == .gzip,
                let anchor = try? Data(contentsOf: directory.appendingPathComponent(name.anchorFileName))
            else { continue }
            out[name.typeKey] = anchor
        }
        return out
    }

    func pendingCount() -> Int {
        pendingFiles().count
    }

    func summary() -> OutboxSummary {
        summarize(pendingFiles())
    }

    private func summarize(_ files: [URL]) -> OutboxSummary {
        var summary = OutboxSummary(batches: files.count)
        for file in files {
            // A pre-0.2 file name tells nothing; count it as one item.
            let name = BatchName(fileName: file.lastPathComponent)
            let key = name?.typeKey ?? "unknown"
            if summary.itemsByKey[key] == nil {
                summary.keyOrder.append(key)
            }
            summary.itemsByKey[key, default: 0] += OutboxSummary.items(name?.count ?? 1)
        }
        // The progress bar measures against everything queued since the queue
        // was last empty; a backlog found at launch starts a new session.
        if summary.batches == 0 {
            sessionTotal = 0
        } else if sessionTotal == 0 {
            sessionTotal = summary.remainingUnits
        }
        summary.sessionTotal = max(sessionTotal, summary.remainingUnits)
        return summary
    }

    func refreshPendingStatus() async {
        let summary = summary()
        await status.setOutbox(summary, nextRetry: failureCount > 0 && summary.batches > 0 ? nextAttempt : nil)
    }

    func removeAll() async {
        await remove { _ in true }
    }

    /// Drops the queued sample batches (they're read again from the
    /// server's progress), keeping statistics, rings and characteristics:
    /// those carry no progress, and the state that made them (stale ranges,
    /// what was sent) is already spent.
    func removeSamples() async {
        await remove { $0 == .ingest }
    }

    private func remove(where matches: (Endpoint) -> Bool) async {
        for file in pendingFiles() {
            // An unnamed (pre-0.2) batch counts as samples.
            if matches(BatchName(fileName: file.lastPathComponent)?.endpoint ?? .ingest) {
                remove(file)
            }
        }
        failureCount = 0
        nextAttempt = .distantPast
        sessionTotal = 0
        await refreshPendingStatus()
    }
}

/// Batch file name: `batch-<seq>-<id>.<endpoint>.<count>.<typeKey>.gz` (the
/// gzipped request body; its anchor, if any, in `batch-<seq>-<id>.anchor`),
/// or `.json` for the pre-0.2 format. The sequence keeps lexical order equal
/// to enqueue order; the rest lets the UI summarize the queue without
/// reading files.
struct BatchName: Equatable {
    enum Format: String {
        case gzip = "gz"
        case legacy = "json"
    }

    let sequence: Int
    let id: String
    let endpoint: Endpoint
    let count: Int
    let typeKey: String
    let format: Format

    private static let codes: [Endpoint: String] = [
        .ingest: "i", .statistics: "s", .activitySummaries: "a", .characteristics: "c",
    ]

    init(sequence: Int, id: String, endpoint: Endpoint, count: Int, typeKey: String, format: Format = .gzip) {
        self.sequence = sequence
        self.id = id
        self.endpoint = endpoint
        self.count = count
        self.typeKey = typeKey
        self.format = format
    }

    init?(fileName: String) {
        let parts = fileName.split(separator: ".").map(String.init)
        guard parts.count == 5, let format = Format(rawValue: parts[4]),
            let endpoint = Self.codes.first(where: { $0.value == parts[1] })?.key,
            let count = Int(parts[2])
        else { return nil }
        let head = parts[0].split(separator: "-")
        guard head.count == 3, let sequence = Int(head[1]) else { return nil }
        self.init(sequence: sequence, id: String(head[2]), endpoint: endpoint, count: count, typeKey: parts[3], format: format)
    }

    private var stem: String { String(format: "batch-%012d-%@", sequence, id) }

    var fileName: String {
        "\(stem).\(Self.codes[endpoint]!).\(count).\(typeKey).\(format.rawValue)"
    }

    var anchorFileName: String { "\(stem).anchor" }
    var baseFileName: String { "\(stem).base" }
}

extension Endpoint {
    /// "Uploaded 20,000 samples", for the log.
    fileprivate func uploaded(_ count: Int) -> String {
        let text: AttributedString =
            switch self {
            case .ingest: AttributedString(localized: "Uploaded ^[\(count) sample](inflect: true)")
            case .statistics: AttributedString(localized: "Uploaded ^[\(count) statistic](inflect: true)")
            case .activitySummaries: AttributedString(localized: "Uploaded ^[\(count) day](inflect: true) of Activity rings")
            case .characteristics: AttributedString(localized: "Uploaded characteristics")
            }
        return String(text.characters)
    }

    fileprivate var noun: String {
        switch self {
        case .ingest: "sample(s)"
        case .statistics: "statistics row(s)"
        case .activitySummaries: "activity summary(ies)"
        case .characteristics: "characteristics"
        }
    }
}
