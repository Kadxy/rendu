import HealthKit
import XCTest

@testable import Rendu

final class SerializerTests: XCTestCase {
    /// Fixed non-DST zone so the fallback path is deterministic.
    private let context = SerializerContext(
        defaultTimeZone: { TimeZone(identifier: "Asia/Dubai")! },
        formatter: TimestampFormatter()
    )

    private func serialize(_ sample: HKSample) throws -> JSON {
        try XCTUnwrap(Serializers.serialize(sample, context: context))
    }

    func testSleepSampleKeepsItsRecordedTimeZoneAndMetadata() throws {
        let start = TestSupport.date(2026, 7, 6, 1, 12, zone: "Europe/Lisbon")
        let end = TestSupport.date(2026, 7, 6, 2, 40, zone: "Europe/Lisbon")
        let sample = HKCategorySample(
            type: HKCategoryType(.sleepAnalysis),
            value: HKCategoryValueSleepAnalysis.asleepREM.rawValue,
            start: start,
            end: end,
            metadata: [HKMetadataKeyTimeZone: "Europe/Lisbon"]
        )

        let json = try serialize(sample)
        XCTAssertEqual(json["uuid"], .string(sample.uuid.uuidString))
        XCTAssertEqual(json["kind"], "category")
        XCTAssertEqual(json["type"], "HKCategoryTypeIdentifierSleepAnalysis")
        XCTAssertEqual(json["value"], 5)
        XCTAssertEqual(json["valueName"], "asleepREM")
        XCTAssertEqual(json["startDate"], "2026-07-06T01:12:00+01:00")
        XCTAssertEqual(json["endDate"], "2026-07-06T02:40:00+01:00")
        // Metadata passes through under HealthKit's own key.
        XCTAssertEqual(json["metadata"], ["HKTimeZone": "Europe/Lisbon"])
        XCTAssertNil(json["quantity"])
    }

    func testAudiogramKeepsEveryTest() throws {
        let start = TestSupport.date(2026, 7, 6, 9, 0, zone: "Asia/Dubai")
        let test = try HKAudiogramSensitivityTest(
            sensitivity: HKQuantity(unit: .decibelHearingLevel(), doubleValue: 15),
            type: .air, masked: false, side: .left, clampingRange: nil
        )
        let point = try HKAudiogramSensitivityPoint(frequency: HKQuantity(unit: .hertz(), doubleValue: 1000), tests: [test])
        let sample = HKAudiogramSample(sensitivityPoints: [point], start: start, end: start, metadata: nil)

        let json = try serialize(sample)
        XCTAssertEqual(json["kind"], "audiogram")
        XCTAssertEqual(json["type"], "HKDataTypeIdentifierAudiogram")
        let first = try XCTUnwrap(json["sensitivityPoints"]?.array?.first)
        XCTAssertEqual(first["frequency"], ["value": 1000, "unit": "Hz"])
        XCTAssertEqual(first["tests"]?.array?.first?["sensitivity"], ["value": 15, "unit": "dBHL"])
        XCTAssertEqual(first["tests"]?.array?.first?["side"], .number(Double(HKAudiogramSensitivityTestSide.left.rawValue)))
        XCTAssertEqual(first["tests"]?.array?.first?["masked"], false)
    }

    func testScoredAssessmentKeepsScoreAnswersAndRisk() throws {
        let date = TestSupport.date(2026, 7, 6, 9, 0, zone: "Asia/Dubai")
        let answers: [HKGAD7Assessment.Answer] = [
            .severalDays, .notAtAll, .notAtAll, .moreThanHalfTheDays, .notAtAll, .notAtAll, .severalDays,
        ]
        let sample = HKGAD7Assessment(date: date, answers: answers)

        let json = try serialize(sample)
        XCTAssertEqual(json["kind"], "scoredAssessment")
        XCTAssertEqual(json["type"], "HKScoredAssessmentTypeIdentifierGAD7")
        XCTAssertEqual(json["score"], .number(Double(sample.score)))
        XCTAssertEqual(json["answers"], .array(answers.map { .number(Double($0.rawValue)) }))
        XCTAssertEqual(json["risk"], .number(Double(sample.risk.rawValue)))
    }

    func testQuantitySampleUsesCatalogUnitAndDeviceZoneFallback() throws {
        let start = TestSupport.date(2026, 7, 6, 8, 0, zone: "Asia/Dubai")
        let sample = HKQuantitySample(
            type: HKQuantityType(.heartRate),
            quantity: HKQuantity(unit: HKUnit.count().unitDivided(by: .second()), doubleValue: 1),
            start: start,
            end: start
        )

        let json = try serialize(sample)
        XCTAssertEqual(json["kind"], "quantity")
        XCTAssertEqual(json["type"], "HKQuantityTypeIdentifierHeartRate")
        // Recorded per second, delivered per minute.
        XCTAssertEqual(json["quantity"], ["value": 60, "unit": "count/min"])
        XCTAssertEqual(json["startDate"], "2026-07-06T08:00:00+04:00")
        XCTAssertNil(json["metadata"], "an assumed timezone must not masquerade as a recorded one")
        XCTAssertNil(json["count"])
    }

    func testPercentStaysAFractionAndMicronutrientsUseMicrograms() throws {
        let now = Date()
        let fat = HKQuantitySample(
            type: HKQuantityType(.bodyFatPercentage),
            quantity: HKQuantity(unit: .percent(), doubleValue: 0.18),
            start: now, end: now
        )
        XCTAssertEqual(try serialize(fat)["quantity"], ["value": 0.18, "unit": "%"])

        let vitaminD = HKQuantitySample(
            type: HKQuantityType(.dietaryVitaminD),
            quantity: HKQuantity(unit: .gramUnit(with: .milli), doubleValue: 0.025),
            start: now, end: now
        )
        let quantity = try XCTUnwrap(try serialize(vitaminD)["quantity"])
        XCTAssertEqual(quantity["unit"], "mcg")
        XCTAssertEqual(quantity["value"]?.number ?? 0, 25, accuracy: 1e-9)
    }

    func testFoodCorrelationListsMemberUUIDs() throws {
        let now = Date()
        let energy = HKQuantitySample(
            type: HKQuantityType(.dietaryEnergyConsumed),
            quantity: HKQuantity(unit: .kilocalorie(), doubleValue: 650),
            start: now, end: now
        )
        let protein = HKQuantitySample(
            type: HKQuantityType(.dietaryProtein),
            quantity: HKQuantity(unit: .gram(), doubleValue: 32),
            start: now, end: now
        )
        let food = HKCorrelation(
            type: HKCorrelationType(.food), start: now, end: now,
            objects: [energy, protein], metadata: [HKMetadataKeyFoodType: "牛肉面"]
        )

        let json = try serialize(food)
        XCTAssertEqual(json["kind"], "correlation")
        XCTAssertEqual(json["type"], "HKCorrelationTypeIdentifierFood")
        XCTAssertEqual(json["objects"], .array([energy, protein].map(\.uuid.uuidString).sorted().map(JSON.string)))
        XCTAssertEqual(json["metadata"]?["HKFoodType"], "牛肉面")
    }

    func testWorkoutSerialization() throws {
        let start = TestSupport.date(2026, 7, 5, 18, 30, zone: "Asia/Dubai")
        let workout = HKWorkout(activityType: .traditionalStrengthTraining, start: start, end: start.addingTimeInterval(3612))

        let json = try serialize(workout)
        XCTAssertEqual(json["kind"], "workout")
        XCTAssertEqual(json["type"], .string(HKObjectType.workoutType().identifier))
        XCTAssertEqual(json["workoutActivityType"], .number(Double(HKWorkoutActivityType.traditionalStrengthTraining.rawValue)))
        XCTAssertEqual(json["workoutActivityTypeName"], "traditionalStrengthTraining")
        XCTAssertEqual(json["duration"]?.number ?? 0, 3612, accuracy: 0.5)
        XCTAssertNil(json["statistics"], "a synthetic workout carries no statistics; the field stays absent")
    }

    func testMetadataValuesKeepTheirJSONTypes() {
        let zone = TimeZone(identifier: "Asia/Shanghai")!
        XCTAssertEqual(Serializers.jsonValue(true as NSNumber, zone: zone, context: context), .bool(true))
        XCTAssertEqual(Serializers.jsonValue(2 as NSNumber, zone: zone, context: context), .number(2))
        XCTAssertEqual(Serializers.jsonValue("x", zone: zone, context: context), .string("x"))
        let date = TestSupport.date(2026, 11, 1, 8, 0, zone: "Asia/Shanghai")
        XCTAssertEqual(Serializers.jsonValue(date, zone: zone, context: context), .string("2026-11-01T08:00:00+08:00"))
    }

    func testWholeNumbersEncodeWithoutAFraction() throws {
        let data = try Wire.encode(["a": 5, "b": 72.5] as JSON)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"a":5,"b":72.5}"#)
    }
}

final class TypeCatalogTests: XCTestCase {
    func testEveryQuantityTypeHasACompatibleUnit() {
        let missing = TypeCatalogData.quantity.map(\.identifier.rawValue).filter { TypeCatalog.units[$0] == nil }
        XCTAssertEqual(missing, [], "catalog units HealthKit rejects")
    }

    func testCatalogKeysAreUniqueAndCoverEveryKind() {
        let keys = TypeCatalog.all.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count)
        let kinds = Set(TypeCatalog.all.map(\.kind))
        // Everything is read but clinical documents (written only).
        XCTAssertEqual(kinds, Set(SampleKind.allCases).subtracting([.cdaDocument]))
    }

    func testReadAndShareSetsExcludeWhatHealthKitForbids() {
        let read = TypeCatalog.readTypes.map(\.identifier)
        XCTAssertFalse(read.contains(HKCorrelationTypeIdentifier.food.rawValue), "correlations can't be authorized")
        XCTAssertFalse(
            read.contains(HKObjectType.medicationDoseEventType().identifier), "dose events are authorized per medication")
        XCTAssertFalse(
            read.contains(HKObjectType.visionPrescriptionType().identifier), "prescriptions are shared one by one")
        XCTAssertFalse(read.contains(HKDocumentType(.CDA).identifier), "clinical documents aren't read")
        XCTAssertTrue(read.contains(HKSeriesType.workoutRoute().identifier))
        XCTAssertTrue(read.contains(HKSeriesType.heartbeat().identifier))
        XCTAssertTrue(read.contains(HKObjectType.activitySummaryType().identifier))

        let candidates = Set(TypeCatalog.shareCandidates.map(\.identifier))
        XCTAssertFalse(candidates.contains(HKObjectType.electrocardiogramType().identifier), "ECG is never writable")
        XCTAssertTrue(
            candidates.contains(HKQuantityTypeIdentifier.appleExerciseTime.rawValue), "HealthKit decides, not the catalog")

        let presumed = Set(TypeCatalog.presumedShareTypes.map(\.identifier))
        XCTAssertFalse(presumed.contains(HKQuantityTypeIdentifier.appleExerciseTime.rawValue))
        XCTAssertTrue(presumed.contains(HKQuantityTypeIdentifier.bodyMass.rawValue))
        XCTAssertTrue(presumed.contains(HKQuantityTypeIdentifier.dietaryProtein.rawValue))
    }

    func testInvalidUnitStringsDoNotCrash() {
        XCTAssertNil(TypeCatalog.parseUnit("not a unit"))
        XCTAssertEqual(TypeCatalog.parseUnit("mcg")?.unitString, "mcg")
    }
}
