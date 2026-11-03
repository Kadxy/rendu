import XCTest

@testable import Rendu

final class WriteEntryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_793_000_000)

    private func record(
        _ id: String, _ sync: String, _ action: WriteRecord.Action, at minute: Double, outcome: WriteRecord.Outcome = .written,
        uuids: [String]? = nil
    ) -> WriteRecord {
        WriteRecord(
            id: id, date: start.addingTimeInterval(minute * 60), action: action, syncIdentifier: sync,
            type: "HKCorrelationTypeIdentifierFood", title: "加餐",
            items: [
                .init(type: "HKQuantityTypeIdentifierDietaryEnergyConsumed", value: "93 kcal"),
                .init(type: "HKQuantityTypeIdentifierDietaryProtein", value: "7.8 g"),
            ],
            outcome: outcome, error: outcome == .written ? nil : "refused", uuids: uuids)
    }

    /// The same snack added twice (two entries), then one of them deleted.
    func testDuplicatesAndADelete() {
        let records = [
            record("w3", "B", .delete, at: 2),
            record("w2", "B", .create, at: 1, uuids: ["b", "b0", "b1"]),
            record("w1", "A", .create, at: 0, uuids: ["a", "a0", "a1"]),
        ]
        let entries = WriteEntry.group(records)
        XCTAssertEqual(entries.map(\.syncIdentifier), ["B", "A"])
        XCTAssertEqual(entries[0].state, .deleted)
        XCTAssertEqual(entries[0].events.map(\.id), ["w2", "w3"])
        XCTAssertEqual(entries[1].state, .added)
        XCTAssertTrue(entries[1].inHealth)
    }

    func testUpdatesAndFailures() {
        let entries = WriteEntry.group([
            record("w3", "A", .update, at: 2, outcome: .failed),
            record("w2", "A", .update, at: 1, uuids: ["a2", "a20", "a21"]),
            record("w1", "A", .create, at: 0, uuids: ["a", "a0", "a1"]),
        ])
        XCTAssertEqual(entries[0].state, .updated)
        XCTAssertTrue(entries[0].lastFailed)
        XCTAssertEqual(entries[0].shown?.id, "w2")
    }

    func testDeletedInHealth() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("writes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = WriteLog(directory: directory)
        await log.append([record("w1", "A", .create, at: 0, uuids: ["a", "a0", "a1"])])

        // One of the meal's two nutrients deleted in Apple Health; and
        // objects that aren't the entry's change nothing.
        await log.recordRemovedInHealth(["a0", "other"])
        var all = await log.all()
        var entry = try XCTUnwrap(WriteEntry.group(all).first)
        XCTAssertEqual(entry.state, .partlyRemovedInHealth(removed: 1, of: 2))
        XCTAssertTrue(entry.inHealth)

        await log.recordRemovedInHealth(["a1"])
        all = await log.all()
        entry = try XCTUnwrap(WriteEntry.group(all).first)
        XCTAssertEqual(entry.state, .removedInHealth)
        XCTAssertFalse(entry.inHealth)

        // Gone: later deletions aren't recorded again.
        await log.recordRemovedInHealth(["a"])
        all = await log.all()
        XCTAssertEqual(all.count, 3)
    }

    /// The snack added twice, one deleted later: that add is marked, the
    /// other isn't; the delete lists the add as related.
    func testTagsAndRelatedRecords() {
        let records = [
            record("w4", "C", .removedInHealth, at: 4, uuids: ["c0"]),
            record("w3", "B", .delete, at: 3),
            record("w2", "B", .create, at: 2, uuids: ["b", "b0", "b1"]),
            record("w1", "A", .create, at: 1, uuids: ["a", "a0", "a1"]),
            record("w0", "C", .create, at: 0, uuids: ["c", "c0", "c1"]),
        ]
        let index = WriteIndex(records)
        XCTAssertEqual(index.tag(for: records[2]), .deleted)
        XCTAssertNil(index.tag(for: records[3]))
        XCTAssertEqual(index.tag(for: records[4]), .partlyRemovedInHealth(removed: 1, of: 2))
        XCTAssertNil(index.tag(for: records[1]), "deletes aren't marked")
        XCTAssertEqual(index.related(to: records[1]).map(\.id), ["w2"])
    }

    /// A save and a delete in the same second (dates are saved in whole
    /// seconds): the log's order decides.
    func testSameSecond() {
        let records = [record("w2", "B", .delete, at: 1), record("w1", "B", .create, at: 1, uuids: ["b", "b0", "b1"])]
        XCTAssertEqual(WriteIndex(records).tag(for: records[1]), .deleted)
        XCTAssertEqual(WriteEntry.group(records).first?.state, .deleted)
    }

    /// The filter for what Apple Health holds: current adds and changes
    /// only, also when some samples were deleted in Apple Health.
    func testCurrentInHealth() {
        let records = [
            record("w5", "C", .removedInHealth, at: 5, uuids: ["c0"]),
            record("w4", "B", .delete, at: 4),
            record("w3", "A", .update, at: 3, uuids: ["a2", "a20", "a21"]),
            record("w2", "B", .create, at: 2, uuids: ["b", "b0", "b1"]),
            record("w1", "A", .create, at: 1, uuids: ["a", "a0", "a1"]),
            record("w0", "C", .create, at: 0, uuids: ["c", "c0", "c1"]),
        ]
        let index = WriteIndex(records)
        XCTAssertEqual(records.filter(index.isCurrentInHealth).map(\.id), ["w3", "w0"])
    }
}

/// An update's samples against what it replaced.
final class SampleChangeTests: XCTestCase {
    private func item(_ type: String, _ value: String) -> WriteRecord.Item { .init(type: type, value: value) }

    func testComparesByTypeInOrder() {
        let old = [item("Caffeine", "150 mg"), item("Energy", "94 kcal"), item("Protein", "3 g")]
        let new = [item("Caffeine", "236 mg"), item("Energy", "94 kcal"), item("Sugar", "10 g")]
        XCTAssertEqual(
            SampleChange.compare(old, new).map(\.kind), [.changed(from: "150 mg"), .same, .added, .removed])
        XCTAssertEqual(SampleChange.compare(old, new).last?.item.type, "Protein")
        // Several of one type pair up in order.
        XCTAssertEqual(
            SampleChange.compare([item("E", "1"), item("E", "2")], [item("E", "1"), item("E", "3")]).map(\.kind),
            [.same, .changed(from: "2")])
    }

    func testAgainstTheLastSavedValues() {
        func record(
            _ id: String, _ action: WriteRecord.Action, _ caffeine: String, outcome: WriteRecord.Outcome = .written
        )
            -> WriteRecord
        {
            WriteRecord(
                id: id, date: Date(), action: action, syncIdentifier: "S", type: nil, title: "Latte",
                items: [.init(type: "HKQuantityTypeIdentifierDietaryCaffeine", value: caffeine)], outcome: outcome,
                error: nil)
        }
        // Newest first, as the log keeps them.
        let records = [
            record("u2", .update, "236 mg"),
            record("u1", .update, "999 mg", outcome: .failed),
            record("a", .create, "150 mg"),
        ]
        let index = WriteIndex(records)
        XCTAssertEqual(index.changes(of: records[0])?.map(\.kind), [.changed(from: "150 mg")])
        XCTAssertNil(index.changes(of: records[2]))
        XCTAssertEqual(records[0].detailLine(changes: index.changes(of: records[0])).hasSuffix("236 mg"), true)
    }
}
