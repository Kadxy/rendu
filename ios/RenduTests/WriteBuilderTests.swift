import HealthKit
import XCTest

@testable import Rendu

final class WriteBuilderTests: XCTestCase {
    private func bodyMass(_ value: Double, unit: String = "kg") -> JSON {
        [
            "kind": "quantity", "type": "HKQuantityTypeIdentifierBodyMass",
            "startDate": "2026-11-01T08:00:00+08:00", "endDate": "2026-11-01T08:00:00+08:00",
            "quantity": ["value": .number(value), "unit": .string(unit)],
            "metadata": ["HKWasUserEntered": true],
        ]
    }

    private func assertInvalid(_ object: JSON, contains fragment: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try WriteBuilder.build(object, syncIdentifier: "s", version: 1), file: file, line: line) { error in
            XCTAssertTrue(error.localizedDescription.contains(fragment), "\(error.localizedDescription)", file: file, line: line)
        }
    }

    func testQuantityCarriesSyncMetadataAndConvertsUnits() throws {
        let sample = try XCTUnwrap(
            WriteBuilder.build(bodyMass(160, unit: "lb"), syncIdentifier: "abc", version: 3) as? HKQuantitySample)
        XCTAssertEqual(sample.quantityType, HKQuantityType(.bodyMass))
        XCTAssertEqual(sample.quantity.doubleValue(for: .gramUnit(with: .kilo)), 72.57, accuracy: 0.01)
        XCTAssertEqual(sample.metadata?[HKMetadataKeySyncIdentifier] as? String, "abc")
        XCTAssertEqual((sample.metadata?[HKMetadataKeySyncVersion] as? NSNumber)?.intValue, 3)
        XCTAssertEqual((sample.metadata?[HKMetadataKeyWasUserEntered] as? NSNumber)?.boolValue, true)
        XCTAssertEqual(sample.startDate, ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))
    }

    func testFoodCorrelationMembersGetTheirOwnSyncIdentifiers() throws {
        let meal: JSON = [
            "kind": "correlation", "type": "HKCorrelationTypeIdentifierFood",
            "startDate": "2026-11-01T12:30:00+08:00", "endDate": "2026-11-01T12:30:00+08:00",
            "metadata": ["HKFoodType": "牛肉面"],
            "objects": [
                [
                    "kind": "quantity", "type": "HKQuantityTypeIdentifierDietaryEnergyConsumed",
                    "quantity": ["value": 650, "unit": "kcal"],
                ],
                ["kind": "quantity", "type": "HKQuantityTypeIdentifierDietaryProtein", "quantity": ["value": 32, "unit": "g"]],
            ],
        ]
        let food = try XCTUnwrap(WriteBuilder.build(meal, syncIdentifier: "meal", version: 1) as? HKCorrelation)
        XCTAssertEqual(food.metadata?[HKMetadataKeyFoodType] as? String, "牛肉面")
        let memberIDs = Set(food.objects.compactMap { $0.metadata?[HKMetadataKeySyncIdentifier] as? String })
        XCTAssertEqual(memberIDs, ["meal:0", "meal:1"])
        XCTAssertTrue(food.objects.allSatisfy { $0.startDate == food.startDate }, "members default to the correlation's dates")
        XCTAssertEqual(
            Set(WriteBuilder.types(of: food).map(\.identifier)),
            [
                "HKQuantityTypeIdentifierDietaryEnergyConsumed", "HKQuantityTypeIdentifierDietaryProtein",
            ])
    }

    func testCategoryValueMustBeAnInteger() throws {
        func mindful(_ value: JSON) -> JSON {
            [
                "kind": "category", "type": "HKCategoryTypeIdentifierMindfulSession",
                "startDate": "2026-11-01T08:00:00+08:00", "endDate": "2026-11-01T08:10:00+08:00", "value": value,
            ]
        }
        XCTAssertTrue(try WriteBuilder.build(mindful(0), syncIdentifier: "m", version: 1) is HKCategorySample)
        assertInvalid(mindful(0.5), contains: "integer")
    }

    func testRejectionsAreErrorsNotCrashes() {
        assertInvalid(bodyMass(70, unit: "count"), contains: "not compatible")
        assertInvalid(bodyMass(70, unit: "furlongs"), contains: "not an HKUnit")
        assertInvalid(
            [
                "kind": "quantity", "type": "HKQuantityTypeIdentifierNope", "startDate": "2026-11-01T08:00:00+08:00",
                "endDate": "2026-11-01T08:00:00+08:00", "quantity": ["value": 1, "unit": "count"],
            ], contains: "unknown quantity type")
        assertInvalid(
            [
                "kind": "quantity", "type": "HKQuantityTypeIdentifierBodyMass", "startDate": "2026-11-01T09:00:00+08:00",
                "endDate": "2026-11-01T08:00:00+08:00", "quantity": ["value": 70, "unit": "kg"],
            ], contains: "before startDate")
        assertInvalid(["kind": "electrocardiogram", "type": "HKDataTypeIdentifierElectrocardiogram"], contains: "read-only")
    }

    /// Read and write support per kind, as docs/PROTOCOL.md's table states:
    /// everything HealthKit lets apps create.
    func testWritableKinds() {
        XCTAssertEqual(
            Set(SampleKind.allCases.filter { !$0.writable }),
            [.electrocardiogram, .workoutRoute, .medicationDoseEvent, .cdaDocument])
    }

    func testMealNameOnEveryNutrient() throws {
        let meal: JSON = [
            "kind": "correlation", "type": "HKCorrelationTypeIdentifierFood",
            "startDate": "2026-11-01T12:30:00+08:00", "endDate": "2026-11-01T12:30:00+08:00",
            "metadata": ["HKFoodType": "午餐"],
            "objects": [
                ["kind": "quantity", "type": "HKQuantityTypeIdentifierDietaryProtein", "quantity": ["value": 30, "unit": "g"]]
            ],
        ]
        let food = try XCTUnwrap(WriteBuilder.build(meal, syncIdentifier: "m", version: 1) as? HKCorrelation)
        XCTAssertEqual(food.objects.first?.metadata?[HKMetadataKeyFoodType] as? String, "午餐")
    }

    func testScoredAssessments() throws {
        let gad7: JSON = [
            "kind": "scoredAssessment", "type": "HKScoredAssessmentTypeIdentifierGAD7",
            "startDate": "2026-11-01T21:00:00+08:00", "answers": [1, 0, 2, 3, 0, 1, 1],
        ]
        let assessment = try XCTUnwrap(WriteBuilder.build(gad7, syncIdentifier: "a", version: 1) as? HKGAD7Assessment)
        XCTAssertEqual(assessment.score, 8)
        var bad = gad7.object!
        bad["answers"] = [1, 0, 2]
        assertInvalid(.object(bad), contains: "7 answers")
        let phq9: JSON = [
            "kind": "scoredAssessment", "type": "HKScoredAssessmentTypeIdentifierPHQ9",
            "startDate": "2026-11-01T21:00:00+08:00", "answers": [0, 1, 0, 0, 2, 0, 0, 1, 4],
        ]
        XCTAssertTrue(try WriteBuilder.build(phq9, syncIdentifier: "p", version: 1) is HKPHQ9Assessment)
    }

    func testAudiogram() throws {
        let object: JSON = [
            "kind": "audiogram", "type": "HKDataTypeIdentifierAudiogram",
            "startDate": "2026-11-01T10:00:00+08:00", "endDate": "2026-11-01T10:10:00+08:00",
            "sensitivityPoints": [
                [
                    "frequency": ["value": 1000, "unit": "Hz"],
                    "tests": [["sensitivity": ["value": 15, "unit": "dBHL"], "type": 0, "masked": false, "side": 0]],
                ]
            ],
        ]
        let audiogram = try XCTUnwrap(WriteBuilder.build(object, syncIdentifier: "h", version: 1) as? HKAudiogramSample)
        XCTAssertEqual(audiogram.sensitivityPoints.first?.tests.first?.sensitivity.doubleValue(for: .decibelHearingLevel()), 15)
    }

    func testGlassesPrescription() throws {
        let object: JSON = [
            "kind": "visionPrescription", "type": "HKVisionPrescriptionTypeIdentifier",
            "prescriptionType": 1, "dateIssued": "2026-10-01T10:00:00+08:00",
            "rightEye": [
                "sphere": ["value": -2.25, "unit": "D"], "cylinder": ["value": -0.5, "unit": "D"],
                "axis": ["value": 90, "unit": "deg"],
            ],
            "leftEye": ["sphere": ["value": -2.0, "unit": "D"], "farPupillaryDistance": ["value": 31, "unit": "mm"]],
        ]
        let glasses = try XCTUnwrap(WriteBuilder.build(object, syncIdentifier: "v", version: 1) as? HKGlassesPrescription)
        XCTAssertEqual(glasses.rightEye?.sphere.doubleValue(for: .diopter()), -2.25)
        XCTAssertEqual(glasses.leftEye?.farPupillaryDistance?.doubleValue(for: .meterUnit(with: .milli)), 31)
        var contacts = object.object!
        contacts["prescriptionType"] = 2
        assertInvalid(.object(contacts), contains: "brand")
    }

    func testSeriesPlans() throws {
        let series: JSON = [
            "kind": "quantity", "type": "HKQuantityTypeIdentifierHeartRate",
            "startDate": "2026-11-01T18:00:00+08:00", "endDate": "2026-11-01T18:02:00+08:00",
            "series": [
                [
                    "quantity": ["value": 92, "unit": "count/min"], "startDate": "2026-11-01T18:00:00+08:00",
                    "endDate": "2026-11-01T18:00:00+08:00",
                ],
                [
                    "quantity": ["value": 95, "unit": "count/min"], "startDate": "2026-11-01T18:01:00+08:00",
                    "endDate": "2026-11-01T18:01:00+08:00",
                ],
            ],
        ]
        guard case .quantitySeries(let plan) = try WriteBuilder.plan(series, syncIdentifier: "q", version: 1) else {
            return XCTFail("a quantity with series plans as a series")
        }
        XCTAssertEqual(plan.points.count, 2)
        let beats: JSON = [
            "kind": "heartbeatSeries", "type": "HKDataTypeIdentifierHeartbeatSeries", "startDate": "2026-11-01T08:00:00+08:00",
            "beats": [
                ["timeSinceSeriesStart": 0, "precededByGap": false], ["timeSinceSeriesStart": 0.8, "precededByGap": false],
            ],
        ]
        guard case .heartbeatSeries(let heartbeat) = try WriteBuilder.plan(beats, syncIdentifier: "b", version: 1) else {
            return XCTFail("beats plan as a heartbeat series")
        }
        XCTAssertEqual(heartbeat.beats.map(\.time), [0, 0.8])
    }

    func testWorkoutWithRouteEventsAndEffort() throws {
        let plan = try WriteBuilder.workout(
            workout([
                "workoutActivityTypeName": "running",
                "workoutEvents": [["type": 3, "startDate": "2026-11-01T18:10:00+08:00", "endDate": "2026-11-01T18:10:00+08:00"]],
                "route": [["timestamp": "2026-11-01T18:05:00+08:00", "latitude": 31.23, "longitude": 121.47]],
                "samples": [
                    [
                        "kind": "quantity", "type": "HKQuantityTypeIdentifierWorkoutEffortScore",
                        "startDate": "2026-11-01T18:00:00+08:00", "endDate": "2026-11-01T18:45:00+08:00",
                        "quantity": ["value": 6, "unit": "appleEffortScore"],
                    ]
                ],
            ]),
            syncIdentifier: "w", version: 1)
        XCTAssertEqual(plan.events.first?.type, .lap)
        XCTAssertEqual(plan.route.first?.coordinate.latitude, 31.23)
        XCTAssertEqual(plan.effort.count, 1, "effort scores are related to the workout, not added")
        XCTAssertTrue(plan.samples.isEmpty)
        XCTAssertTrue(plan.types.contains(HKSeriesType.workoutRoute()))
    }

    private func workout(_ fields: [String: JSON]) -> JSON {
        var object: [String: JSON] = [
            "kind": "workout", "type": "HKWorkoutTypeIdentifier",
            "startDate": "2026-11-01T18:00:00+08:00", "endDate": "2026-11-01T18:45:00+08:00",
        ]
        object.merge(fields) { $1 }
        return .object(object)
    }

    func testWorkoutPlanByNameWithSamples() throws {
        let energy: JSON = [
            "kind": "quantity", "type": "HKQuantityTypeIdentifierActiveEnergyBurned",
            "startDate": "2026-11-01T18:00:00+08:00", "endDate": "2026-11-01T18:45:00+08:00",
            "quantity": ["value": 210, "unit": "kcal"],
        ]
        let plan = try WriteBuilder.workout(
            workout(["workoutActivityTypeName": "traditionalStrengthTraining", "samples": [energy]]),
            syncIdentifier: "w", version: 2
        )
        XCTAssertEqual(plan.activityType, .traditionalStrengthTraining)
        XCTAssertEqual(plan.samples.count, 1)
        XCTAssertEqual(plan.samples[0].metadata?[HKMetadataKeySyncIdentifier] as? String, "w:0")
        XCTAssertEqual(plan.metadata[HKMetadataKeySyncVersion] as? NSNumber, 2)
        XCTAssertEqual(plan.types.map(\.identifier), ["HKWorkoutTypeIdentifier", "HKQuantityTypeIdentifierActiveEnergyBurned"])
        if case .workout = try WriteBuilder.plan(workout(["workoutActivityType": 37]), syncIdentifier: "w", version: 1) {
        } else {
            XCTFail("a workout plans as a workout")
        }
    }

    func testWorkoutRejections() {
        func invalid(_ object: JSON, _ fragment: String) {
            XCTAssertThrowsError(try WriteBuilder.workout(object, syncIdentifier: "w", version: 1)) { error in
                XCTAssertTrue(error.localizedDescription.contains(fragment), "\(error.localizedDescription)")
            }
        }
        invalid(workout([:]), "needs workoutActivityType")
        invalid(workout(["workoutActivityTypeName": "underwaterChess"]), "unknown activity type name")
        invalid(
            workout([
                "workoutActivityType": 37,
                "samples": [
                    [
                        "kind": "quantity", "type": "HKQuantityTypeIdentifierActiveEnergyBurned",
                        "startDate": "2026-11-01T17:00:00+08:00", "endDate": "2026-11-01T18:10:00+08:00",
                        "quantity": ["value": 10, "unit": "kcal"],
                    ]
                ],
            ]), "outside the workout")
    }

    func testStateOfMind() throws {
        let object: JSON = [
            "kind": "stateOfMind", "type": "HKDataTypeStateOfMind", "startDate": "2026-11-01T21:00:00+08:00",
            "stateOfMindKind": 1, "valence": -0.6,
            "labels": [.number(Double(HKStateOfMind.Label.stressed.rawValue))],
            "associations": [.number(Double(HKStateOfMind.Association.work.rawValue))],
        ]
        let mood = try XCTUnwrap(WriteBuilder.build(object, syncIdentifier: "m", version: 1) as? HKStateOfMind)
        XCTAssertEqual(mood.kind, .momentaryEmotion)
        XCTAssertEqual(mood.valence, -0.6)
        XCTAssertEqual(mood.labels, [.stressed])
        XCTAssertEqual(mood.associations, [.work])
        XCTAssertEqual(mood.metadata?[HKMetadataKeySyncIdentifier] as? String, "m")

        var bad = object.object!
        bad["valence"] = 2
        assertInvalid(.object(bad), contains: "valence")
        bad = object.object!
        // Any Int makes a Label in Swift; HealthKit itself refuses it, and
        // that refusal is an error, not a crash.
        bad["labels"] = [9999]
        assertInvalid(.object(bad), contains: "labels are not supported")
    }
}
