import XCTest

@testable import Rendu

final class LogStoreTests: XCTestCase {
    private var base: URL!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("log-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    /// Pages read backwards across chunk boundaries return every entry once,
    /// newest first.
    func testPagesCoverTheWholeLog() async {
        let log = LogStore(directory: base)
        // Long messages, so the log spans several 256 KB chunks.
        let padding = String(repeating: "x", count: 900)
        for index in 0 ..< 1500 {
            await log.info("entry \(index) \(padding)")
        }
        var seen: [Int] = []
        var next: UInt64?
        repeat {
            let page = await log.page(before: next, count: 200)
            seen += page.entries.map { Int($0.message.split(separator: " ")[1])! }
            next = page.next
        } while next != nil
        XCTAssertEqual(seen, Array((0 ..< 1500).reversed()))
    }

    func testFilteredPages() async {
        let log = LogStore(directory: base)
        for index in 0 ..< 600 {
            if index % 3 == 0 {
                await log.warn("warning \(index)")
            } else {
                await log.info("info \(index)")
            }
        }
        var warnings: [String] = []
        var next: UInt64?
        repeat {
            let page = await log.page(before: next, count: 50) { $0.level == .warn }
            warnings += page.entries.map(\.message)
            next = page.next
        } while next != nil
        XCTAssertEqual(warnings.count, 200)
        XCTAssertEqual(warnings.first, "warning 597")
        XCTAssertEqual(warnings.last, "warning 0")
    }

    func testTrimKeepsTheNewestEntries() async {
        let log = LogStore(directory: base)
        for index in 0 ..< 2000 {
            await log.info("entry \(index)")
        }
        let before = await log.size
        await log.trim(to: before / 2)
        let after = await log.size
        XCTAssertLessThanOrEqual(after, before / 2)
        let newest = await log.tail(1)
        XCTAssertEqual(newest.first?.message, "entry 1999")
    }

    func testEntriesWithTitlesRoundTrip() async {
        let log = LogStore(directory: base)
        await log.record(.upload, title: "Heart Rate", detail: "Uploaded 20,000 samples", message: "delivered 20000 HeartRate")
        await log.info("plain")
        let entries = await log.tail(10)
        XCTAssertEqual(entries.map(\.title), [nil, "Heart Rate"])
        XCTAssertEqual(entries.last?.kind, .upload)
    }
}

final class InFlightBatchTests: XCTestCase {
    /// The count goes down while a batch is out, but never reaches the end
    /// of the batch before the server confirms it.
    func testInterpolation() {
        let start = Date()
        let batch = InFlightBatch(key: "HKQuantityTypeIdentifierHeartRate", items: 20_000, started: start, expected: 4)
        XCTAssertEqual(batch.sent(at: start), 0)
        XCTAssertEqual(batch.sent(at: start.addingTimeInterval(2)), 10_000)
        XCTAssertEqual(batch.sent(at: start.addingTimeInterval(60)), 19_400)
    }
}
