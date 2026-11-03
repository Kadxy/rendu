import XCTest

@testable import Rendu

/// Summary's Recent: a sync each, added once it's over.
@MainActor
final class ActivityTests: XCTestCase {
    private var status: AppStatus!

    override func setUp() async throws {
        status = AppStatus(defaults: TestSupport.defaults())
    }

    private func upload(_ items: Int, type: String = "HKQuantityTypeIdentifierHeartRate", left: Int = 0) {
        var summary = OutboxSummary()
        summary.batches = left
        status.recordBatchDelivered(items: items, typeKey: type, secondsPerItem: 0.001, outbox: summary)
    }

    private func write(_ name: String, _ action: WriteRecord.Action = .create, outcome: WriteRecord.Outcome = .written) {
        status.recordWrites([
            WriteRecord(
                id: UUID().uuidString, date: Date(), action: action, syncIdentifier: name,
                type: "HKQuantityTypeIdentifierDietaryWater", title: name, items: [], outcome: outcome, error: nil)
        ])
    }

    private func sync(_ body: () -> Void) {
        status.beginPass(visible: false)
        body()
        status.endPass(nextVisible: false)
    }

    /// Each sync that did something is one, shown once it's over.
    func testASyncEach() {
        sync {
            upload(200, left: 1)
            upload(100)
            XCTAssertTrue(status.activities.isEmpty, "not before the sync is over")
        }
        sync {
            for n in 0 ..< 10 { write("w\(n)") }
            upload(10)
        }
        sync {}  // found nothing
        sync {
            write("x", outcome: .failed)
            write("y", .delete)
            write("z", .removedInHealth)
            upload(500, type: "HKQuantityTypeIdentifierStepCount")
        }

        let activities = status.activities
        XCTAssertEqual(activities.count, 3)
        XCTAssertEqual(activities.map(\.uploaded), [500, 10, 300])
        XCTAssertEqual(activities.map(\.saved), [0, 10, 0])
        XCTAssertEqual(activities[0].notSaved, 1)
        XCTAssertEqual(activities[0].deleted, 1)
        XCTAssertEqual(activities[0].removedInHealth, 1)
        XCTAssertEqual(activities[1].names.count, 10)
        XCTAssertEqual(activities[2].uploadedTypes, ["HKQuantityTypeIdentifierHeartRate": 300])
    }

    /// Uploads outside a sync (a retry) are one once the queue is empty.
    func testARetry() {
        upload(20_000, left: 2)
        upload(20_000, left: 1)
        XCTAssertTrue(status.activities.isEmpty)
        upload(5_000)
        XCTAssertEqual(status.activities.map(\.uploaded), [45_000])
    }

    /// The list outlives the app.
    func testKept() {
        let defaults = TestSupport.defaults()
        let first = AppStatus(defaults: defaults)
        first.beginPass(visible: false)
        first.recordWrites([
            WriteRecord(
                id: "w", date: Date(), action: .create, syncIdentifier: "s", type: nil, title: "Lunch", items: [],
                outcome: .failed, error: "refused")
        ])
        first.endPass(nextVisible: false)
        let second = AppStatus(defaults: defaults)
        second.load()
        XCTAssertEqual(second.activities.map(\.notSaved), [1])
        XCTAssertEqual(second.activities[0].names, ["Lunch"])
    }
}
