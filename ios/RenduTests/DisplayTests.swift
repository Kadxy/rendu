import HealthKit
import XCTest

@testable import Rendu

final class DisplayTests: XCTestCase {
    func testEveryCatalogTypeHasAnAppleNameInBothLanguages() {
        // The types Apple's tables don't name; they show their identifier.
        let unnamedByApple: Set = [HKCorrelationTypeIdentifier.food.rawValue, HKSeriesType.heartbeat().identifier]
        let unnamed = TypeCatalog.all.map(\.key).filter { DisplayNames.en[$0] == nil && !unnamedByApple.contains($0) }
        XCTAssertEqual(unnamed, [])
        XCTAssertEqual(Set(DisplayNames.en.keys), Set(DisplayNames.zhHans.keys))
    }

    func testShortNamesDropOnlyTheHealthKitPrefix() {
        XCTAssertEqual(DisplayNames.shortName("HKQuantityTypeIdentifierWaistCircumference"), "WaistCircumference")
        XCTAssertEqual(DisplayNames.shortName("HKCategoryTypeIdentifierLowHeartRateEvent"), "LowHeartRateEvent")
        XCTAssertEqual(DisplayNames.shortName("HKCorrelationTypeIdentifierFood"), "Food")
        XCTAssertEqual(DisplayNames.shortName("HKDataTypeStateOfMind"), "StateOfMind")
        XCTAssertEqual(DisplayNames.shortName(HKObjectType.workoutType().identifier), "Workout")
        XCTAssertEqual(DisplayNames.shortName(HKObjectType.activitySummaryType().identifier), "ActivitySummary")
    }

    func testAppleNamesForSpotChecks() {
        XCTAssertEqual(DisplayNames.zhHans["HKQuantityTypeIdentifierWaistCircumference"], "腰围")
        XCTAssertEqual(DisplayNames.en["HKQuantityTypeIdentifierWaistCircumference"], "Waist Circumference")
        XCTAssertEqual(DisplayNames.zhHans["HKCategoryTypeIdentifierLowHeartRateEvent"], "低心率通知")
        XCTAssertEqual(DisplayNames.zhHans["HKQuantityTypeIdentifierStepCount"], "步数")
    }

    func testEveryCatalogTypeHasACategory() {
        let uncategorized = TypeCatalog.all.map(\.key).filter { HealthCategory.of($0) == .otherData }
        // Kept deliberately small; anything new here deserves a category.
        XCTAssertLessThanOrEqual(uncategorized.count, 12, "\(uncategorized)")
    }

    func testWriteRecordSummaryUsesShortNamesAndValues() throws {
        try XCTSkipUnless(SampleFormat.appLocale.identifier.hasPrefix("en"), "English formatting only")
        let now = Date()
        let water = HKQuantitySample(
            type: HKQuantityType(.dietaryWater), quantity: HKQuantity(unit: .literUnit(with: .milli), doubleValue: 300),
            start: now, end: now)
        XCTAssertEqual(WriteRecord.items(of: water), [.init(type: "HKQuantityTypeIdentifierDietaryWater", value: "300 mL")])

        let fat = HKQuantitySample(
            type: HKQuantityType(.bodyFatPercentage), quantity: HKQuantity(unit: .percent(), doubleValue: 0.185), start: now,
            end: now)
        XCTAssertEqual(WriteRecord.items(of: fat).first?.value, "18.5 %")

        let record = WriteRecord(
            id: "w", date: now, action: .create, syncIdentifier: "s", type: "HKCorrelationTypeIdentifierFood",
            title: "Lunch", items: [.init(type: "HKQuantityTypeIdentifierDietaryEnergyConsumed", value: "650 kcal")],
            outcome: .written, error: nil
        )
        XCTAssertEqual(record.summary, "Lunch · DietaryEnergyConsumed 650 kcal")
    }

    func testValuesReadLikeHealth() throws {
        try XCTSkipUnless(SampleFormat.appLocale.identifier.hasPrefix("en"), "English formatting only")
        XCTAssertEqual(SampleFormat.display(82, unit: "count/min"), "82 BPM")
        XCTAssertEqual(SampleFormat.display(6895, unit: "count"), "6,895")
        XCTAssertEqual(SampleFormat.display(0.185, unit: "%"), "18.5 %")
        XCTAssertEqual(SampleFormat.display(72.5, unit: "kg"), "72.5 kg")
        XCTAssertEqual(SampleFormat.display(650, unit: "kcal"), "650 kcal")
        XCTAssertEqual(SampleFormat.display(36.6, unit: "degC"), "36.6°C")
        XCTAssertEqual(SampleFormat.display(3, unit: "count/s"), "3 count/s")  // no Foundation unit: HKUnit string
    }

    func testRawJSONIsIndentedWithKeysInReadingOrder() {
        let json: JSON = [
            "type": "HKQuantityTypeIdentifierHeartRate", "uuid": "U", "quantity": ["value": 82, "unit": "count/min"],
            "metadata": [:],
        ]
        XCTAssertEqual(
            JSONText.text(json),
            """
            {
              "uuid": "U",
              "type": "HKQuantityTypeIdentifierHeartRate",
              "quantity": {
                "value": 82,
                "unit": "count/min"
              },
              "metadata": {}
            }
            """)
    }

    func testCompactCountsKeepADecimal() {
        XCTAssertEqual(SampleFormat.compactCount(342), "342")
        XCTAssertEqual(SampleFormat.compactCount(1_349), "1.3K")
        XCTAssertEqual(SampleFormat.compactCount(20_000), "20K")
        XCTAssertEqual(SampleFormat.compactCount(118_312), "118.3K")
        XCTAssertEqual(SampleFormat.compactCount(999_999), "999.9K")
        XCTAssertEqual(SampleFormat.compactCount(1_188_000), "1.1M")
    }
}
