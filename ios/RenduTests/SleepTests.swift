import XCTest

@testable import Rendu

final class SleepTests: XCTestCase {
    private func sample(_ uuid: String, _ value: String, _ start: String, _ end: String, source: String = "Watch") -> ServerSample
    {
        ServerSample(json: [
            "uuid": .string(uuid), "kind": "category", "type": "HKCategoryTypeIdentifierSleepAnalysis",
            "valueName": .string(value), "startDate": .string(start), "endDate": .string(end),
            "sourceRevision": ["source": ["name": .string(source)]],
        ])
    }

    func testSamplesGroupByNightStageAndSourceInHealthOrder() {
        let zone = TimeZone.current
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> String {
            var components = DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute)
            components.timeZone = zone
            return ISO8601DateFormatter().string(from: Calendar.current.date(from: components)!)
        }
        let nights = SleepNight.group([
            sample("a", "asleepDeep", at(18, 4, 22), at(18, 4, 50)),
            sample("b", "asleepREM", at(18, 5, 21), at(18, 5, 38)),
            sample("c", "asleepREM", at(17, 23, 30), at(17, 23, 50)),
            sample("d", "awake", at(18, 6, 39), at(18, 6, 41)),
            sample("e", "asleepCore", at(16, 23), at(17, 1)),
        ])
        XCTAssertEqual(nights.count, 2)
        XCTAssertEqual(nights[0].rows.map(\.stage), [.awake, .asleepREM, .asleepDeep])
        XCTAssertEqual(nights[0].rows[1].samples.count, 2)
        XCTAssertEqual(nights[0].rows[1].duration, 37 * 60)
        XCTAssertEqual(nights[1].rows.map(\.stage), [.asleepCore])
    }

    func testHealthNamesExistInBothLanguages() {
        XCTAssertEqual(Set(HealthUIStrings.en.keys), Set(HealthUIStrings.zhHans.keys))
        XCTAssertEqual(HealthUIStrings.zhHans["ASLEEP_REM"], "快速动眼睡眠")
        XCTAssertEqual(HealthUIStrings.en["ASLEEP_REM_INTERVALS"], "REM Intervals: %@")
    }
}
