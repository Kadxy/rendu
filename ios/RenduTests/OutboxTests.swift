import XCTest

@testable import Rendu

/// Scriptable uploader. Unscripted calls succeed with HTTP 200.
final class MockUploader: Uploading, @unchecked Sendable {
    struct Call {
        let body: Data
        let method: String
        let url: URL
        let token: String?
        let headers: [String: String]
    }

    static let ok = UploadResult(status: 200, bodySnippet: #"{"received":1}"#, duration: 0.01)

    private let lock = NSLock()
    private var script: [Result<UploadResult, Error>] = []
    private var calls: [Call] = []

    func enqueueResult(_ result: Result<UploadResult, Error>) {
        lock.lock()
        script.append(result)
        lock.unlock()
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls.count
    }

    func call(_ index: Int) -> Call {
        lock.lock()
        defer { lock.unlock() }
        return calls[index]
    }

    func send(
        _ body: Data, gzipped: Bool, method: String, to url: URL, token: String?,
        headers: [String: String]
    ) async throws -> UploadResult {
        switch record(Call(body: body, method: method, url: url, token: token, headers: headers)) {
        case .none:
            return Self.ok
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        }
    }

    private func record(_ call: Call) -> Result<UploadResult, Error>? {
        lock.lock()
        defer { lock.unlock() }
        calls.append(call)
        return script.isEmpty ? nil : script.removeFirst()
    }
}

@MainActor
final class OutboxTests: XCTestCase {
    private var base: URL!
    private var outboxDir: URL!
    private var anchors: AnchorStore!
    private var uploader: MockUploader!
    private var status: AppStatus!
    private var defaults: UserDefaults!
    private var log: LogStore!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("outbox-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        outboxDir = base.appendingPathComponent("Outbox")
        anchors = AnchorStore(directory: base.appendingPathComponent("Anchors"))
        uploader = MockUploader()
        defaults = TestSupport.defaults()
        status = AppStatus(defaults: defaults)
        log = LogStore(directory: base)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func makeOutbox(maxBatchBytes: Int = Wire.maxBatchBytes, hasTarget: Bool = true) -> Outbox {
        let target: @Sendable () -> (base: URL, token: String?)?
        if hasTarget {
            let base = URL(string: "http://127.0.0.1:1")!
            target = { (base: base, token: "tok") }
        } else {
            target = { nil }
        }
        return Outbox(
            directory: outboxDir,
            anchors: anchors,
            uploader: uploader,
            target: target,
            log: log,
            status: status,
            maxBatchBytes: maxBatchBytes,
            defaults: defaults,
            quickRetryDelays: [.zero, .zero]
        )
    }

    private func element(_ id: String, pad: Int = 0) -> JSON {
        [
            "uuid": .string(id + String(repeating: "x", count: pad)),
            "kind": "category",
            "type": "HKCategoryTypeIdentifierSleepAnalysis",
            "startDate": "2026-07-06T01:12:00+01:00",
            "endDate": "2026-07-06T02:40:00+01:00",
            "value": 0,
            "valueName": "inBed",
        ]
    }

    private func anchorData(_ key: String) -> Data? {
        try? Data(contentsOf: base.appendingPathComponent("Anchors/\(key).anchor"))
    }

    // MARK: - Tests

    func testDrainDeliversFIFOPersistsAnchorsAndClearsFiles() async throws {
        let outbox = makeOutbox()
        let anchorA1 = Data("anchor-a1".utf8)
        let anchorA2 = Data("anchor-a2".utf8)
        let anchorB1 = Data("anchor-b1".utf8)

        try await outbox.enqueueSamples(typeKey: "a", elements: [element("first")], anchor: anchorA1, base: nil)
        try await outbox.enqueueSamples(typeKey: "a", elements: [element("second")], anchor: anchorA2, base: nil)
        try await outbox.enqueueSamples(typeKey: "b", elements: [element("third")], anchor: anchorB1, base: nil)
        await outbox.drain(force: true)

        XCTAssertEqual(uploader.callCount, 3)
        let pending = await outbox.pendingCount()
        XCTAssertEqual(pending, 0)

        // The anchor moves only when the server says yes — and in order.
        XCTAssertEqual(anchorData("a"), anchorA2)
        XCTAssertEqual(anchorData("b"), anchorB1)

        // FIFO: bodies arrive in enqueue order.
        let firstBody = TestSupport.gunzip(uploader.call(0).body, expectedSize: 1 << 20)
        let decoded = try JSONDecoder().decode([JSON].self, from: firstBody)
        XCTAssertTrue(decoded[0]["uuid"]?.string?.hasPrefix("first") == true)
        XCTAssertEqual(uploader.call(0).token, "tok")
        XCTAssertEqual(uploader.call(0).method, "POST")
        XCTAssertEqual(uploader.call(0).url.path, "/v1/ingest")
    }

    func testBatchCarriesItsAnchorsAndAStaleReplyKeepsTheLocalOne() async throws {
        let outbox = makeOutbox()
        uploader.enqueueResult(
            .success(UploadResult(status: 200, bodySnippet: #"{"received":1,"anchor":"saved"}"#, duration: 0.01)))
        uploader.enqueueResult(
            .success(UploadResult(status: 200, bodySnippet: #"{"received":1,"anchor":"stale"}"#, duration: 0.01)))
        try await outbox.enqueueSamples(typeKey: "a", elements: [element("one")], anchor: Data("a1".utf8), base: nil)
        try await outbox.enqueueSamples(typeKey: "a", elements: [element("two")], anchor: Data("a2".utf8), base: Data("a1".utf8))
        await outbox.drain(force: true)

        XCTAssertEqual(uploader.callCount, 2)
        let first = uploader.call(0).headers
        XCTAssertEqual(first["X-Rendu-Anchor-Type"], "a")
        XCTAssertEqual(first["X-Rendu-Anchor"], Data("a1".utf8).base64EncodedString())
        XCTAssertNil(first["X-Rendu-Base-Anchor"], "read from no anchor")
        XCTAssertEqual(uploader.call(1).headers["X-Rendu-Base-Anchor"], Data("a1".utf8).base64EncodedString())
        // The server didn't move its anchor for the second batch: neither
        // does the phone.
        XCTAssertEqual(anchorData("a"), Data("a1".utf8))
        let pending = await outbox.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    func testQueuedAnchorsAreTheNewestPerType() async throws {
        let outbox = makeOutbox(hasTarget: false)
        try await outbox.enqueueSamples(typeKey: "a", elements: [element("one")], anchor: Data("a1".utf8), base: nil)
        try await outbox.enqueueSamples(typeKey: "b", elements: [element("two")], anchor: Data("b1".utf8), base: nil)
        try await outbox.enqueueSamples(
            typeKey: "a", elements: [element("three")], anchor: Data("a2".utf8), base: Data("a1".utf8))
        let queued = await outbox.queuedAnchors()
        XCTAssertEqual(queued, ["a": Data("a2".utf8), "b": Data("b1".utf8)])
    }

    func testFailureStopsDrainKeepsFilesAndBacksOff() async throws {
        // Fails its two quick retries too.
        for _ in 0 ..< 3 { uploader.enqueueResult(.failure(URLError(.cannotConnectToHost))) }
        let outbox = makeOutbox()

        try await outbox.enqueueSamples(typeKey: "a", elements: [element("one")], anchor: Data("a1".utf8), base: nil)
        try await outbox.enqueueSamples(typeKey: "a", elements: [element("two")], anchor: Data("a2".utf8), base: Data("a1".utf8))
        await outbox.drain(force: false)  // barrier for the enqueue-spawned drains

        // The attempt and its two quick retries failed; backoff must
        // swallow non-forced retries.
        XCTAssertEqual(uploader.callCount, 3)
        var pending = await outbox.pendingCount()
        XCTAssertEqual(pending, 2)
        XCTAssertNil(anchorData("a"), "no ACK, no anchor")

        await outbox.drain(force: false)
        XCTAssertEqual(uploader.callCount, 3, "backoff window must suppress retries")

        // Manual sync bypasses the backoff.
        await outbox.drain(force: true)
        XCTAssertEqual(uploader.callCount, 5)
        pending = await outbox.pendingCount()
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(anchorData("a"), Data("a2".utf8))
    }

    func testNon2xxResponseIsAFailure() async throws {
        for _ in 0 ..< 3 { uploader.enqueueResult(.success(UploadResult(status: 500, bodySnippet: "boom", duration: 0.01))) }
        let outbox = makeOutbox()

        try await outbox.enqueueSamples(typeKey: "a", elements: [element("one")], anchor: Data("a1".utf8), base: nil)
        await outbox.drain(force: false)

        let pending = await outbox.pendingCount()
        XCTAssertEqual(pending, 1)
        XCTAssertNil(anchorData("a"))
    }

    func testAServerHiccupIsRetriedQuicklyAndAClientErrorIsNot() async throws {
        uploader.enqueueResult(.success(UploadResult(status: 502, bodySnippet: "bad gateway", duration: 0.01)))
        let outbox = makeOutbox()
        try await outbox.enqueueSamples(typeKey: "a", elements: [element("one")], anchor: Data("a1".utf8), base: nil)
        await outbox.drain(force: true)
        XCTAssertEqual(uploader.callCount, 2, "one 502, then delivered")
        var pending = await outbox.pendingCount()
        XCTAssertEqual(pending, 0)

        uploader.enqueueResult(.success(UploadResult(status: 400, bodySnippet: "bad", duration: 0.01)))
        try await outbox.enqueueSamples(typeKey: "a", elements: [element("two")], anchor: Data("a2".utf8), base: Data("a1".utf8))
        await outbox.drain(force: false)
        XCTAssertEqual(uploader.callCount, 3, "a 4xx isn't retried")
        pending = await outbox.pendingCount()
        XCTAssertEqual(pending, 1)
    }

    func testCorruptBatchFileIsQuarantinedNotRetriedForever() async throws {
        let outbox = makeOutbox()
        try FileManager.default.createDirectory(at: outboxDir, withIntermediateDirectories: true)
        try Data("this is not json".utf8)
            .write(to: outboxDir.appendingPathComponent("batch-000000000001-dead.json"))

        await outbox.drain(force: true)

        XCTAssertEqual(uploader.callCount, 0)
        let pending = await outbox.pendingCount()
        XCTAssertEqual(pending, 0)
        let names = try FileManager.default.contentsOfDirectory(atPath: outboxDir.path)
        XCTAssertEqual(names, ["batch-000000000001-dead.json.corrupt"])
    }

    func testOversizedEnqueueSplitsAndOnlyLastSliceCarriesAnchor() async throws {
        // No server configured: files stay on disk for inspection.
        let outbox = makeOutbox(maxBatchBytes: 700, hasTarget: false)
        let anchor = Data("final-anchor".utf8)

        try await outbox.enqueueSamples(
            typeKey: "a",
            elements: (0 ..< 8).map { element("id-\($0)", pad: 150) },
            anchor: anchor, base: nil
        )
        await outbox.drain(force: true)  // no-op without a target; barrier only

        let files = try FileManager.default.contentsOfDirectory(at: outboxDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "gz" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertGreaterThan(files.count, 1, "batch should have been split")

        var totalSamples = 0
        for (index, file) in files.enumerated() {
            let name = try XCTUnwrap(BatchName(fileName: file.lastPathComponent))
            totalSamples += name.count
            let sidecar = try? Data(contentsOf: outboxDir.appendingPathComponent(name.anchorFileName))
            if index == files.count - 1 {
                XCTAssertEqual(sidecar, anchor, "only the last slice may advance the anchor")
            } else {
                XCTAssertNil(sidecar)
            }
        }
        XCTAssertEqual(totalSamples, 8)
        XCTAssertEqual(uploader.callCount, 0)
    }

    func testRemoveAllClearsQueue() async throws {
        let outbox = makeOutbox(hasTarget: false)
        try await outbox.enqueueSamples(typeKey: "a", elements: [element("one")], anchor: nil, base: nil)
        var pending = await outbox.pendingCount()
        XCTAssertEqual(pending, 1)

        await outbox.removeAll()
        pending = await outbox.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    /// Starting over from the server's progress drops the queued samples
    /// (read again) but keeps statistics and the rest: what made them is
    /// spent.
    func testRemoveSamplesKeepsDerivedData() async throws {
        let outbox = makeOutbox(hasTarget: false)
        try await outbox.enqueueSamples(typeKey: "a", elements: [element("one")], anchor: nil, base: nil)
        try await outbox.enqueue(.statistics, typeKey: "a", count: 3, payload: ["statistics": []])
        try await outbox.enqueue(.activitySummaries, typeKey: "activitySummary", count: 2, payload: [])
        await outbox.removeSamples()
        let summary = await outbox.summary()
        XCTAssertEqual(summary.batches, 2)
        XCTAssertEqual(Set(summary.keyOrder), ["a", "activitySummary"])
    }

    func testUploadBodyIsGzippedWireFormat() async throws {
        let outbox = makeOutbox()
        let elements: [JSON] = [element("one"), Wire.tombstone(["gone-1", "gone-2"])]
        try await outbox.enqueueSamples(typeKey: "a", elements: elements, anchor: nil, base: nil)
        await outbox.drain(force: true)

        XCTAssertEqual(uploader.callCount, 1)
        let body = uploader.call(0).body
        XCTAssertEqual(Array(body.prefix(2)), [0x1f, 0x8b], "body must be gzipped")
        let decoded = try JSONDecoder().decode(
            [JSON].self,
            from: TestSupport.gunzip(body, expectedSize: 1 << 20)
        )
        XCTAssertEqual(decoded, elements)
        let pending = await outbox.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    func testTombstonesDoNotCountAsSamples() async throws {
        let outbox = makeOutbox(hasTarget: false)
        try await outbox.enqueueSamples(
            typeKey: "a", elements: [element("one"), Wire.tombstone(["gone"])], anchor: nil, base: nil)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: outboxDir, includingPropertiesForKeys: nil).first)
        XCTAssertEqual(BatchName(fileName: file.lastPathComponent)?.count, 1)
    }

    func testAnchorSidecarIsRemovedWithItsBatch() async throws {
        let outbox = makeOutbox()
        try await outbox.enqueueSamples(typeKey: "a", elements: [element("one")], anchor: Data("a1".utf8), base: nil)
        await outbox.drain(force: true)
        XCTAssertEqual(anchorData("a"), Data("a1".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outboxDir.path), [])
    }

    func testLegacyBatchFilesStillDeliver() async throws {
        let legacy = Batch(
            id: UUID(), endpoint: .ingest, typeKey: "a", createdAt: Date(),
            anchor: Data("old".utf8), count: 1, payload: [element("legacy")]
        )
        try FileManager.default.createDirectory(at: outboxDir, withIntermediateDirectories: true)
        try Wire.fileEncoder().encode(legacy)
            .write(to: outboxDir.appendingPathComponent("batch-000000000001-0ld.i.1.a.json"))
        let outbox = makeOutbox()
        await outbox.drain(force: true)

        XCTAssertEqual(uploader.callCount, 1)
        let decoded = try JSONDecoder().decode(
            [JSON].self, from: TestSupport.gunzip(uploader.call(0).body, expectedSize: 1 << 20))
        XCTAssertEqual(decoded, [element("legacy")])
        XCTAssertEqual(anchorData("a"), Data("old".utf8))
    }

    func testNonSampleBatchesGoToTheirOwnEndpoints() async throws {
        let outbox = makeOutbox()
        try await outbox.enqueue(.statistics, typeKey: "HKQuantityTypeIdentifierStepCount", count: 1, payload: ["statistics": []])
        try await outbox.enqueue(.characteristics, typeKey: "characteristics", count: 1, payload: ["biologicalSex": 2])
        await outbox.drain(force: true)

        XCTAssertEqual(uploader.callCount, 2)
        XCTAssertEqual(uploader.call(0).url.path, "/v1/statistics")
        XCTAssertEqual(uploader.call(0).method, "POST")
        XCTAssertEqual(uploader.call(1).url.path, "/v1/characteristics")
        XCTAssertEqual(uploader.call(1).method, "PUT")
        XCTAssertNil(anchorData("characteristics"), "non-sample batches never move anchors")
    }
}

final class BatchNameTests: XCTestCase {
    func testRoundTripsThroughTheFileName() {
        let name = BatchName(
            sequence: 42, id: "ABCD1234", endpoint: .ingest, count: 20000, typeKey: "HKQuantityTypeIdentifierHeartRate")
        XCTAssertEqual(name.fileName, "batch-000000000042-ABCD1234.i.20000.HKQuantityTypeIdentifierHeartRate.gz")
        XCTAssertEqual(name.anchorFileName, "batch-000000000042-ABCD1234.anchor")
        XCTAssertEqual(BatchName(fileName: name.fileName), name)
    }

    func testLexicalOrderIsEnqueueOrder() {
        let early = BatchName(sequence: 9, id: "B", endpoint: .statistics, count: 1, typeKey: "z").fileName
        let late = BatchName(sequence: 10, id: "A", endpoint: .ingest, count: 1, typeKey: "a").fileName
        XCTAssertLessThan(early, late)
    }

    func testOldStyleNamesAreNotParsed() {
        XCTAssertNil(BatchName(fileName: "batch-000000000001-dead.json"))
        XCTAssertEqual(BatchName(fileName: "batch-000000000002-beef.s.3.x.json")?.format, .legacy)
    }
}

@MainActor
final class OutboxSummaryTests: XCTestCase {
    func testSummaryCountsItemsPerTypeInUploadOrder() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("summary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let uploader = MockUploader()
        let defaults = TestSupport.defaults()
        let outbox = Outbox(
            directory: base.appendingPathComponent("Outbox"),
            anchors: AnchorStore(directory: base.appendingPathComponent("Anchors")),
            uploader: uploader, target: { nil }, log: LogStore(directory: base),
            status: AppStatus(defaults: defaults), defaults: defaults
        )
        func sample(_ id: Int) -> JSON { ["uuid": .string("u\(id)"), "type": "t"] }
        try await outbox.enqueueSamples(typeKey: "HR", elements: (0 ..< 3).map(sample), anchor: nil, base: nil)
        try await outbox.enqueueSamples(typeKey: "Steps", elements: [sample(9), Wire.tombstone(["x"])], anchor: nil, base: nil)
        try await outbox.enqueue(.statistics, typeKey: "HR", count: 5, payload: [:])

        let summary = await outbox.summary()
        XCTAssertEqual(summary.batches, 3)
        // Statistics count toward their type; order is upload order.
        XCTAssertEqual(summary.itemsByKey, ["HR": 8, "Steps": 1])
        XCTAssertEqual(summary.keyOrder, ["HR", "Steps"])
        XCTAssertEqual(summary.remainingUnits, 9)
        XCTAssertEqual(summary.sessionTotal, 9)
        XCTAssertEqual(summary.progress, 0)
    }
}
