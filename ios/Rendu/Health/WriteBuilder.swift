import CoreLocation
import Foundation
import HealthKit

/// Wire write objects → HealthKit objects (docs/PROTOCOL.md, POST /v1/writes).
/// Everything HealthKit would reject by raising — unknown types, malformed or
/// incompatible units, bad category values, end before start — is reported
/// as a WriteBuilder.Invalid so the write fails instead of the app crashing.
enum WriteBuilder {
    struct Invalid: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Sync identifier of correlation member `index`. Members need their own
    /// identifiers so a re-run after a crash dedupes them too.
    static func memberSyncIdentifier(_ syncIdentifier: String, _ index: Int) -> String {
        "\(syncIdentifier):\(index)"
    }

    /// A workout to build with HKWorkoutBuilder, which saves it itself
    /// (an HKWorkout can't be made and saved like other samples), with what
    /// goes with it: its activities and events, samples added to it, a
    /// route (HKWorkoutRouteBuilder), effort scores related to it.
    struct WorkoutPlan {
        let activityType: HKWorkoutActivityType
        let start: Date
        let end: Date
        /// Samples added to the workout (its energy, distance, …).
        let samples: [HKSample]
        let activities: [HKWorkoutActivity]
        let events: [HKWorkoutEvent]
        let route: [CLLocation]
        let routeMetadata: [String: Any]
        /// Effort scores, saved and then related to the workout.
        let effort: [HKSample]
        let metadata: [String: Any]

        var types: [HKSampleType] {
            [HKObjectType.workoutType()] + samples.map(\.sampleType) + effort.map(\.sampleType)
                + (route.isEmpty ? [] : [HKSeriesType.workoutRoute()])
        }
    }

    /// A quantity series (HKQuantitySeriesSampleBuilder): each value with
    /// its own time.
    struct QuantitySeriesPlan {
        let type: HKQuantityType
        let start: Date
        let end: Date
        let points: [(quantity: HKQuantity, interval: DateInterval)]
        let metadata: [String: Any]
    }

    /// Beat-to-beat times (HKHeartbeatSeriesBuilder); the series ends at the
    /// last beat.
    struct HeartbeatPlan {
        let start: Date
        let beats: [(time: TimeInterval, precededByGap: Bool)]
        let metadata: [String: Any]
    }

    enum Built {
        case sample(HKSample)
        case workout(WorkoutPlan)
        case quantitySeries(QuantitySeriesPlan)
        case heartbeatSeries(HeartbeatPlan)

        /// The types it writes, for the authorization check.
        var types: [HKSampleType] {
            switch self {
            case .sample(let sample): WriteBuilder.types(of: sample)
            case .workout(let plan): plan.types
            case .quantitySeries(let plan): [plan.type]
            case .heartbeatSeries: [HKSeriesType.heartbeat()]
            }
        }

        /// The type its sync identifier is looked up in.
        var mainType: HKSampleType {
            switch self {
            case .sample(let sample): sample.sampleType
            case .workout: HKObjectType.workoutType()
            case .quantitySeries(let plan): plan.type
            case .heartbeatSeries: HKSeriesType.heartbeat()
            }
        }
    }

    static func kind(of object: JSON) throws -> SampleKind {
        guard let kind = object["kind"]?.string.flatMap(SampleKind.init(rawValue:)) else {
            throw Invalid(message: "missing or unknown kind")
        }
        if !kind.writable {
            throw Invalid(message: "kind \(kind.rawValue) is read-only")
        }
        return kind
    }

    static func plan(_ object: JSON, syncIdentifier: String, version: Int) throws -> Built {
        switch try kind(of: object) {
        case .workout:
            return .workout(try workout(object, syncIdentifier: syncIdentifier, version: version))
        case .heartbeatSeries:
            return .heartbeatSeries(try heartbeats(object, syncIdentifier: syncIdentifier, version: version))
        case .quantity where object["series"] != nil:
            return .quantitySeries(try quantitySeries(object, syncIdentifier: syncIdentifier, version: version))
        default:
            return .sample(try build(object, syncIdentifier: syncIdentifier, version: version))
        }
    }

    static func build(_ object: JSON, syncIdentifier: String, version: Int) throws -> HKSample {
        let kind = try kind(of: object)
        let metadata = try healthMetadata(object, syncIdentifier: syncIdentifier, version: version)
        // Kinds that are a moment, or dated otherwise.
        switch kind {
        case .stateOfMind: return try stateOfMind(object, metadata: metadata)
        case .scoredAssessment: return try scoredAssessment(object, metadata: metadata)
        case .visionPrescription: return try visionPrescription(object, metadata: metadata)
        default: break
        }
        let (start, end) = try dates(object, defaults: nil)
        switch kind {
        case .quantity:
            return try quantitySample(object, start: start, end: end, metadata: metadata)
        case .category:
            return try categorySample(object, start: start, end: end, metadata: metadata)
        case .correlation:
            guard let typeName = object["type"]?.string,
                [HKCorrelationTypeIdentifier.food.rawValue, HKCorrelationTypeIdentifier.bloodPressure.rawValue].contains(typeName)
            else {
                throw Invalid(
                    message:
                        "correlation type must be HKCorrelationTypeIdentifierFood or HKCorrelationTypeIdentifierBloodPressure")
            }
            guard let members = object["objects"]?.array, !members.isEmpty else {
                throw Invalid(message: "correlation needs objects")
            }
            var samples: Set<HKSample> = []
            for (index, member) in members.enumerated() {
                guard member["kind"]?.string == SampleKind.quantity.rawValue else {
                    throw Invalid(message: "objects[\(index)]: correlation members must be quantity samples")
                }
                let (memberStart, memberEnd) = try dates(member, defaults: (start, end))
                var memberMetadata = try healthMetadata(
                    member, syncIdentifier: memberSyncIdentifier(syncIdentifier, index), version: version
                )
                // The meal's name on each of its nutrients too: Apple Health
                // lists the nutrients, not the meal.
                if memberMetadata[HKMetadataKeyFoodType] == nil, let food = metadata[HKMetadataKeyFoodType] {
                    memberMetadata[HKMetadataKeyFoodType] = food
                }
                samples.insert(try quantitySample(member, start: memberStart, end: memberEnd, metadata: memberMetadata))
            }
            let type = HKCorrelationType(HKCorrelationTypeIdentifier(rawValue: typeName))
            return try guarded("correlation") {
                HKCorrelation(type: type, start: start, end: end, objects: samples, metadata: metadata)
            }
        case .audiogram:
            return try audiogram(object, start: start, end: end, metadata: metadata)
        case .cdaDocument:
            guard let xml = object["documentData"]?.string, !xml.isEmpty else {
                throw Invalid(message: "documentData (the CDA XML) is required")
            }
            do {
                return try HKCDADocumentSample(data: Data(xml.utf8), start: start, end: end, metadata: metadata)
            } catch {
                throw Invalid(message: "documentData: \(error.localizedDescription)")
            }
        case .workout, .heartbeatSeries:
            throw Invalid(message: "\(kind.rawValue) is built with plan(_:)")
        case .stateOfMind, .scoredAssessment, .visionPrescription, .electrocardiogram, .workoutRoute, .medicationDoseEvent:
            preconditionFailure("handled above, or read-only")
        }
    }

    /// `{"kind": "workout", "workoutActivityType": 50 or
    /// "workoutActivityTypeName": "traditionalStrengthTraining", "samples":
    /// [quantity objects within the workout], "workoutActivities",
    /// "workoutEvents", "route": [locations], …}`.
    static func workout(_ object: JSON, syncIdentifier: String, version: Int) throws -> WorkoutPlan {
        let (start, end) = try dates(object, defaults: nil)
        let activity = try activityType(object, "workout")
        func within(_ from: Date, _ to: Date, _ what: String) throws {
            guard from >= start, to <= end else { throw Invalid(message: "\(what) lies outside the workout") }
        }
        var samples: [HKSample] = []
        var effort: [HKSample] = []
        let effortTypes: Set = [
            HKQuantityTypeIdentifier.workoutEffortScore.rawValue, HKQuantityTypeIdentifier.estimatedWorkoutEffortScore.rawValue,
        ]
        for (index, member) in (object["samples"]?.array ?? []).enumerated() {
            guard member["kind"]?.string == SampleKind.quantity.rawValue else {
                throw Invalid(message: "samples[\(index)]: workout samples must be quantity samples")
            }
            let (memberStart, memberEnd) = try dates(member, defaults: (start, end))
            try within(memberStart, memberEnd, "samples[\(index)]")
            let memberMetadata = try healthMetadata(
                member, syncIdentifier: memberSyncIdentifier(syncIdentifier, index), version: version)
            let sample = try quantitySample(member, start: memberStart, end: memberEnd, metadata: memberMetadata)
            if effortTypes.contains(sample.sampleType.identifier) {
                effort.append(sample)
            } else {
                samples.append(sample)
            }
        }
        var activities: [HKWorkoutActivity] = []
        for (index, item) in (object["workoutActivities"]?.array ?? []).enumerated() {
            let what = "workoutActivities[\(index)]"
            let configuration = try workoutConfiguration(item["workoutConfiguration"], what)
            guard let from = try item["startDate"].map(parseDate) else { throw Invalid(message: "\(what).startDate is required") }
            let to = try item["endDate"].map(parseDate)
            try within(from, to ?? from, what)
            let metadata = try plainMetadata(item, what)
            activities.append(
                try guarded(what) {
                    HKWorkoutActivity(workoutConfiguration: configuration, start: from, end: to, metadata: metadata)
                })
        }
        var events: [HKWorkoutEvent] = []
        for (index, item) in (object["workoutEvents"]?.array ?? []).enumerated() {
            let what = "workoutEvents[\(index)]"
            guard let raw = item["type"]?.number, let type = HKWorkoutEventType(rawValue: Int(raw)) else {
                throw Invalid(message: "\(what).type must be an HKWorkoutEventType")
            }
            let (from, to) = try dates(item, defaults: nil)
            try within(from, to, what)
            let metadata = try plainMetadata(item, what)
            events.append(
                try guarded(what) {
                    HKWorkoutEvent(type: type, dateInterval: DateInterval(start: from, end: to), metadata: metadata)
                })
        }
        var route: [CLLocation] = []
        for (index, item) in (object["route"]?.array ?? []).enumerated() {
            let location = try location(item, "route[\(index)]")
            try within(location.timestamp, location.timestamp, "route[\(index)]")
            route.append(location)
        }
        return WorkoutPlan(
            activityType: activity, start: start, end: end, samples: samples, activities: activities, events: events,
            route: route,
            routeMetadata: [
                HKMetadataKeySyncIdentifier: "\(syncIdentifier):route", HKMetadataKeySyncVersion: NSNumber(value: version),
            ],
            effort: effort, metadata: try healthMetadata(object, syncIdentifier: syncIdentifier, version: version)
        )
    }

    /// `workoutActivityType` (raw) or `workoutActivityTypeName`.
    private static func activityType(_ object: JSON, _ what: String) throws -> HKWorkoutActivityType {
        if let raw = object["workoutActivityType"]?.number ?? object["activityType"]?.number {
            guard raw == raw.rounded(), raw > 0, let type = HKWorkoutActivityType(rawValue: UInt(raw)) else {
                throw Invalid(message: "\(what): \(raw) is not an HKWorkoutActivityType")
            }
            return type
        }
        if let name = object["workoutActivityTypeName"]?.string ?? object["activityTypeName"]?.string {
            guard let type = WorkoutActivityName.type(named: name) else {
                throw Invalid(message: "\(what): unknown activity type name \(name)")
            }
            return type
        }
        throw Invalid(message: "\(what) needs workoutActivityType or workoutActivityTypeName")
    }

    private static func workoutConfiguration(_ object: JSON?, _ what: String) throws -> HKWorkoutConfiguration {
        guard let object else { throw Invalid(message: "\(what).workoutConfiguration is required") }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = try activityType(object, what)
        if let raw = object["locationType"]?.number {
            guard let type = HKWorkoutSessionLocationType(rawValue: Int(raw)) else {
                throw Invalid(message: "\(what): locationType \(raw) is not an HKWorkoutSessionLocationType")
            }
            configuration.locationType = type
        }
        if let raw = object["swimmingLocationType"]?.number {
            guard let type = HKWorkoutSwimmingLocationType(rawValue: Int(raw)) else {
                throw Invalid(message: "\(what): swimmingLocationType \(raw) is not an HKWorkoutSwimmingLocationType")
            }
            configuration.swimmingLocationType = type
        }
        if let lap = object["lapLength"] {
            configuration.lapLength = try quantity(lap, compatibleWith: .meter(), "\(what).lapLength")
        }
        return configuration
    }

    /// A route point: latitude and longitude, and what's known besides
    /// (missing accuracy, speed or course read as unknown).
    private static func location(_ object: JSON, _ what: String) throws -> CLLocation {
        guard let latitude = object["latitude"]?.number, (-90 ... 90).contains(latitude),
            let longitude = object["longitude"]?.number, (-180 ... 180).contains(longitude)
        else { throw Invalid(message: "\(what) needs latitude (−90…90) and longitude (−180…180)") }
        guard let time = object["timestamp"] else { throw Invalid(message: "\(what).timestamp is required") }
        let altitude = object["altitude"]?.number
        return CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: altitude ?? 0,
            horizontalAccuracy: object["horizontalAccuracy"]?.number ?? 5,
            verticalAccuracy: object["verticalAccuracy"]?.number ?? (altitude == nil ? -1 : 5),
            course: object["course"]?.number ?? -1,
            speed: object["speed"]?.number ?? -1,
            timestamp: try parseDate(time)
        )
    }

    /// `{"kind": "quantity", "startDate", "endDate", "series": [{"quantity",
    /// "startDate", "endDate"}]}`, instead of one `quantity`.
    private static func quantitySeries(_ object: JSON, syncIdentifier: String, version: Int) throws -> QuantitySeriesPlan {
        guard object["quantity"] == nil else { throw Invalid(message: "give either quantity or series, not both") }
        guard let typeName = object["type"]?.string, let type = TypeCatalog.type(for: typeName)?.sampleType as? HKQuantityType
        else { throw Invalid(message: "unknown quantity type \(object["type"]?.string ?? "(missing)")") }
        let (start, end) = try dates(object, defaults: nil)
        guard let items = object["series"]?.array, !items.isEmpty else { throw Invalid(message: "series is empty") }
        let points = try items.enumerated().map { index, item in
            let what = "series[\(index)]"
            let (from, to) = try dates(item, defaults: nil)
            guard from >= start, to <= end else { throw Invalid(message: "\(what) lies outside startDate…endDate") }
            let unit = TypeCatalog.unit(for: type) ?? .count()
            return (
                quantity: try quantity(item["quantity"], compatibleWith: unit, "\(what).quantity"),
                interval: DateInterval(start: from, end: to)
            )
        }
        return QuantitySeriesPlan(
            type: type, start: start, end: end, points: points,
            metadata: try healthMetadata(object, syncIdentifier: syncIdentifier, version: version))
    }

    /// `{"kind": "heartbeatSeries", "startDate", "beats":
    /// [{"timeSinceSeriesStart", "precededByGap"}]}`.
    private static func heartbeats(_ object: JSON, syncIdentifier: String, version: Int) throws -> HeartbeatPlan {
        guard let startValue = object["startDate"] else { throw Invalid(message: "startDate is required") }
        guard object["endDate"] == nil else {
            throw Invalid(message: "a heartbeat series ends at its last beat: omit endDate")
        }
        guard let items = object["beats"]?.array, !items.isEmpty else { throw Invalid(message: "beats is empty") }
        var last = -1.0
        let beats = try items.enumerated().map { index, item in
            guard let time = item["timeSinceSeriesStart"]?.number, time >= 0, time > last else {
                throw Invalid(message: "beats[\(index)].timeSinceSeriesStart must be ≥ 0 and increasing")
            }
            last = time
            return (time: time, precededByGap: item["precededByGap"]?.boolean ?? false)
        }
        return HeartbeatPlan(
            start: try parseDate(startValue), beats: beats,
            metadata: try healthMetadata(object, syncIdentifier: syncIdentifier, version: version))
    }

    /// `{"kind": "audiogram", "sensitivityPoints": [{"frequency", "tests":
    /// [{"sensitivity", "type", "masked", "side", "clampingRange"}]}]}`, as
    /// read.
    private static func audiogram(_ object: JSON, start: Date, end: Date, metadata: [String: Any]) throws -> HKAudiogramSample {
        guard let items = object["sensitivityPoints"]?.array, !items.isEmpty else {
            throw Invalid(message: "sensitivityPoints is empty")
        }
        let points = try items.enumerated().map { index, item in
            let what = "sensitivityPoints[\(index)]"
            let frequency = try quantity(item["frequency"], compatibleWith: .hertz(), "\(what).frequency")
            guard let testItems = item["tests"]?.array, !testItems.isEmpty else {
                throw Invalid(message: "\(what).tests is empty")
            }
            let tests = try testItems.enumerated().map { testIndex, test in
                let testPath = "\(what).tests[\(testIndex)]"
                let sensitivity = try quantity(
                    test["sensitivity"], compatibleWith: .decibelHearingLevel(), "\(testPath).sensitivity")
                guard let rawType = test["type"]?.number, let type = HKAudiogramConductionType(rawValue: Int(rawType)),
                    let rawSide = test["side"]?.number, let side = HKAudiogramSensitivityTestSide(rawValue: Int(rawSide))
                else { throw Invalid(message: "\(testPath) needs type (conduction) and side") }
                var range: HKAudiogramSensitivityPointClampingRange?
                if let clamping = test["clampingRange"] {
                    let bound = { (key: String) throws -> NSNumber? in
                        try clamping[key].map {
                            NSNumber(
                                value: try quantity(
                                    $0, compatibleWith: .decibelHearingLevel(), "\(testPath).clampingRange.\(key)"
                                )
                                .doubleValue(for: .decibelHearingLevel()))
                        }
                    }
                    range = try HKAudiogramSensitivityPointClampingRange(
                        lowerBound: try bound("lowerBound"), upperBound: try bound("upperBound"))
                }
                return try HKAudiogramSensitivityTest(
                    sensitivity: sensitivity, type: type, masked: test["masked"]?.boolean ?? false, side: side,
                    clampingRange: range)
            }
            return try HKAudiogramSensitivityPoint(frequency: frequency, tests: tests)
        }
        return try guarded("audiogram") {
            HKAudiogramSample(sensitivityPoints: points, start: start, end: end, device: nil, metadata: metadata)
        }
    }

    /// `{"kind": "scoredAssessment", "type": GAD-7 or PHQ-9, "startDate",
    /// "answers": [Int]}`; HealthKit computes the score and risk.
    private static func scoredAssessment(_ object: JSON, metadata: [String: Any]) throws -> HKScoredAssessment {
        let date = try moment(object, "an assessment")
        let raw = try (object["answers"]?.array ?? []).map { value in
            guard let number = value.number, number == number.rounded() else {
                throw Invalid(message: "answers must be integers")
            }
            return Int(number)
        }
        switch object["type"]?.string {
        case HKScoredAssessmentTypeIdentifier.GAD7.rawValue:
            let answers = raw.compactMap(HKGAD7Assessment.Answer.init(rawValue:))
            guard answers.count == 7, raw.count == 7, raw.allSatisfy({ (0 ... 3).contains($0) }) else {
                throw Invalid(message: "GAD-7 needs 7 answers, each 0–3")
            }
            return try guarded("GAD-7") { HKGAD7Assessment(date: date, answers: answers, metadata: metadata) }
        case HKScoredAssessmentTypeIdentifier.PHQ9.rawValue:
            let answers = raw.compactMap(HKPHQ9Assessment.Answer.init(rawValue:))
            guard answers.count == 9, raw.count == 9, raw.prefix(8).allSatisfy({ (0 ... 3).contains($0) }),
                (0 ... 4).contains(raw[8])
            else { throw Invalid(message: "PHQ-9 needs 9 answers, each 0–3 (the 9th may be 4, prefer not to answer)") }
            return try guarded("PHQ-9") { HKPHQ9Assessment(date: date, answers: answers, metadata: metadata) }
        default:
            throw Invalid(message: "type must be HKScoredAssessmentTypeIdentifierGAD7 or HKScoredAssessmentTypeIdentifierPHQ9")
        }
    }

    /// Glasses or contacts (`prescriptionType` 1 or 2), each eye's lens.
    private static func visionPrescription(_ object: JSON, metadata: [String: Any]) throws -> HKVisionPrescription {
        guard object["startDate"] == nil, object["endDate"] == nil else {
            throw Invalid(message: "a prescription is dated by dateIssued: omit startDate and endDate")
        }
        guard let issuedValue = object["dateIssued"] else { throw Invalid(message: "dateIssued is required") }
        let issued = try parseDate(issuedValue)
        let expiration = try object["expirationDate"].map(parseDate)
        let diopters = HKUnit.diopter()
        let millimeters = HKUnit.meterUnit(with: .milli)
        func optional(_ eye: JSON, _ key: String, _ unit: HKUnit, _ what: String) throws -> HKQuantity? {
            try eye[key].map { try quantity($0, compatibleWith: unit, "\(what).\(key)") }
        }
        let glasses = object["prescriptionType"]?.number == Double(HKVisionPrescriptionType.glasses.rawValue)
        let contacts = object["prescriptionType"]?.number == Double(HKVisionPrescriptionType.contacts.rawValue)
        guard glasses || contacts else { throw Invalid(message: "prescriptionType must be 1 (glasses) or 2 (contacts)") }
        guard object["rightEye"] != nil || object["leftEye"] != nil else { throw Invalid(message: "give rightEye or leftEye") }
        if glasses {
            func lens(_ key: String) throws -> HKGlassesLensSpecification? {
                guard let eye = object[key] else { return nil }
                var prism: HKVisionPrism?
                if let item = eye["prism"] {
                    let what = "\(key).prism"
                    guard let rawEye = item["eye"]?.number, let side = HKVisionEye(rawValue: Int(rawEye)) else {
                        throw Invalid(message: "\(what).eye must be 1 (left) or 2 (right)")
                    }
                    if item["amount"] != nil {
                        prism = HKVisionPrism(
                            amount: try quantity(item["amount"], compatibleWith: .prismDiopter(), "\(what).amount"),
                            angle: try quantity(item["angle"], compatibleWith: .degreeAngle(), "\(what).angle"), eye: side)
                    } else {
                        func base(_ key: String) throws -> HKPrismBase {
                            guard let raw = item[key]?.number, let base = HKPrismBase(rawValue: Int(raw)) else {
                                throw Invalid(message: "\(what).\(key) must be 0–4")
                            }
                            return base
                        }
                        prism = HKVisionPrism(
                            verticalAmount: try quantity(
                                item["verticalAmount"], compatibleWith: .prismDiopter(), "\(what).verticalAmount"),
                            verticalBase: try base("verticalBase"),
                            horizontalAmount: try quantity(
                                item["horizontalAmount"], compatibleWith: .prismDiopter(), "\(what).horizontalAmount"),
                            horizontalBase: try base("horizontalBase"), eye: side)
                    }
                }
                return HKGlassesLensSpecification(
                    sphere: try quantity(eye["sphere"], compatibleWith: diopters, "\(key).sphere"),
                    cylinder: try optional(eye, "cylinder", diopters, key),
                    axis: try optional(eye, "axis", .degreeAngle(), key),
                    addPower: try optional(eye, "addPower", diopters, key),
                    vertexDistance: try optional(eye, "vertexDistance", millimeters, key),
                    prism: prism,
                    farPupillaryDistance: try optional(eye, "farPupillaryDistance", millimeters, key),
                    nearPupillaryDistance: try optional(eye, "nearPupillaryDistance", millimeters, key))
            }
            let right = try lens("rightEye")
            let left = try lens("leftEye")
            return try guarded("glasses prescription") {
                HKGlassesPrescription(
                    rightEyeSpecification: right, leftEyeSpecification: left, dateIssued: issued, expirationDate: expiration,
                    device: nil, metadata: metadata)
            }
        }
        guard let brand = object["brand"]?.string, !brand.isEmpty else { throw Invalid(message: "contacts need a brand") }
        func lens(_ key: String) throws -> HKContactsLensSpecification? {
            guard let eye = object[key] else { return nil }
            return HKContactsLensSpecification(
                sphere: try quantity(eye["sphere"], compatibleWith: diopters, "\(key).sphere"),
                cylinder: try optional(eye, "cylinder", diopters, key),
                axis: try optional(eye, "axis", .degreeAngle(), key),
                addPower: try optional(eye, "addPower", diopters, key),
                baseCurve: try optional(eye, "baseCurve", millimeters, key),
                diameter: try optional(eye, "diameter", millimeters, key))
        }
        let right = try lens("rightEye")
        let left = try lens("leftEye")
        return try guarded("contacts prescription") {
            HKContactsPrescription(
                rightEyeSpecification: right, leftEyeSpecification: left, brand: brand, dateIssued: issued,
                expirationDate: expiration, device: nil, metadata: metadata)
        }
    }

    /// `{"value", "unit"}` as an HKQuantity of a unit compatible with `unit`.
    private static func quantity(_ json: JSON?, compatibleWith unit: HKUnit, _ what: String) throws -> HKQuantity {
        guard let value = json?["value"]?.number, let unitString = json?["unit"]?.string else {
            throw Invalid(message: "\(what) needs a numeric value and a unit")
        }
        guard let parsed = TypeCatalog.parseUnit(unitString), HKQuantity(unit: unit, doubleValue: 0).is(compatibleWith: parsed)
        else {
            throw Invalid(message: "\(what): '\(unitString)' is not a unit of \(unit.unitString)")
        }
        return HKQuantity(unit: parsed, doubleValue: value)
    }

    /// The date of something that is a moment: `startDate`, and `endDate`
    /// only if the same.
    private static func moment(_ object: JSON, _ what: String) throws -> Date {
        guard let startValue = object["startDate"] else { throw Invalid(message: "startDate is required") }
        let date = try parseDate(startValue)
        if let endValue = object["endDate"], try parseDate(endValue) != date {
            throw Invalid(message: "\(what) is a moment: endDate must equal startDate")
        }
        return date
    }

    /// `{"kind": "stateOfMind", "startDate", "stateOfMindKind": 1 or 2,
    /// "valence": -1…1, "labels": [Int], "associations": [Int]}`, HealthKit's
    /// raw values.
    private static func stateOfMind(_ object: JSON, metadata: [String: Any]) throws -> HKStateOfMind {
        let date = try moment(object, "a state of mind")
        guard let rawKind = object["stateOfMindKind"]?.number, let kind = HKStateOfMind.Kind(rawValue: Int(rawKind)) else {
            throw Invalid(message: "stateOfMindKind must be 1 (momentaryEmotion) or 2 (dailyMood)")
        }
        guard let valence = object["valence"]?.number, (-1 ... 1).contains(valence) else {
            throw Invalid(message: "valence must be a number from -1 to 1")
        }
        func values<T: RawRepresentable>(_ key: String, _ make: (Int) -> T?) throws -> [T] where T.RawValue == Int {
            try (object[key]?.array ?? []).map { value in
                guard let number = value.number, let made = make(Int(number)) else {
                    throw Invalid(message: "\(key): \(value) is not a HealthKit value")
                }
                return made
            }
        }
        let labels = try values("labels", HKStateOfMind.Label.init(rawValue:))
        let associations = try values("associations", HKStateOfMind.Association.init(rawValue:))
        return try guarded("stateOfMind") {
            HKStateOfMind(
                date: date, kind: kind, valence: valence, labels: labels, associations: associations, metadata: metadata)
        }
    }

    /// The sample types a built object touches, for authorization checks.
    static func types(of sample: HKSample) -> [HKSampleType] {
        if let correlation = sample as? HKCorrelation {
            return correlation.objects.map(\.sampleType)
        }
        return [sample.sampleType]
    }

    private static func quantitySample(_ object: JSON, start: Date, end: Date, metadata: [String: Any]) throws -> HKQuantitySample
    {
        guard let typeName = object["type"]?.string,
            let type = TypeCatalog.type(for: typeName)?.sampleType as? HKQuantityType
        else {
            throw Invalid(message: "unknown quantity type \(object["type"]?.string ?? "(missing)")")
        }
        guard let value = object["quantity"]?["value"]?.number, let unitString = object["quantity"]?["unit"]?.string else {
            throw Invalid(message: "\(typeName): quantity needs a numeric value and a unit")
        }
        guard let unit = TypeCatalog.parseUnit(unitString) else {
            throw Invalid(message: "'\(unitString)' is not an HKUnit string")
        }
        guard type.is(compatibleWith: unit) else {
            throw Invalid(message: "unit '\(unitString)' is not compatible with \(typeName)")
        }
        return try guarded(typeName) {
            HKQuantitySample(
                type: type, quantity: HKQuantity(unit: unit, doubleValue: value), start: start, end: end, metadata: metadata)
        }
    }

    private static func categorySample(_ object: JSON, start: Date, end: Date, metadata: [String: Any]) throws -> HKCategorySample
    {
        guard let typeName = object["type"]?.string,
            let type = TypeCatalog.type(for: typeName)?.sampleType as? HKCategoryType
        else {
            throw Invalid(message: "unknown category type \(object["type"]?.string ?? "(missing)")")
        }
        guard let value = object["value"]?.number, value == value.rounded() else {
            throw Invalid(message: "\(typeName): value must be an integer")
        }
        return try guarded(typeName) {
            HKCategorySample(type: type, value: Int(value), start: start, end: end, metadata: metadata)
        }
    }

    private static func dates(_ object: JSON, defaults: (Date, Date)?) throws -> (Date, Date) {
        let start = try object["startDate"].map(parseDate) ?? defaults?.0
        let end = try object["endDate"].map(parseDate) ?? defaults?.1
        guard let start, let end else { throw Invalid(message: "startDate and endDate are required") }
        guard end >= start else { throw Invalid(message: "endDate is before startDate") }
        return (start, end)
    }

    private static func parseDate(_ value: JSON) throws -> Date {
        let strict = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let string = value.string, let date = strict.date(from: string) ?? fractional.date(from: string) else {
            throw Invalid(message: "unparseable timestamp \(value)")
        }
        return date
    }

    /// Wire metadata plus the sync keys. HealthKit metadata values may only be
    /// strings, numbers, and dates; booleans travel as NSNumber.
    private static func healthMetadata(_ object: JSON, syncIdentifier: String, version: Int) throws -> [String: Any] {
        var metadata: [String: Any] = [:]
        for (key, value) in object["metadata"]?.object ?? [:] {
            switch value {
            case .string(let string): metadata[key] = string
            case .number(let number): metadata[key] = NSNumber(value: number)
            case .bool(let bool): metadata[key] = NSNumber(value: bool)
            default: throw Invalid(message: "metadata \(key): values must be strings, numbers, or booleans")
            }
        }
        metadata[HKMetadataKeySyncIdentifier] = syncIdentifier
        metadata[HKMetadataKeySyncVersion] = NSNumber(value: version)
        return metadata
    }

    /// Metadata of a workout's activity or event (no sync keys: HealthKit
    /// keeps them with the workout).
    private static func plainMetadata(_ object: JSON, _ what: String) throws -> [String: Any]? {
        guard object["metadata"] != nil else { return nil }
        var metadata = try healthMetadata(object, syncIdentifier: "", version: 0)
        metadata[HKMetadataKeySyncIdentifier] = nil
        metadata[HKMetadataKeySyncVersion] = nil
        return metadata
    }

    private static func guarded<T>(_ what: String, _ make: () -> T) throws -> T {
        var made: T?
        if let reason = RDCatchException({ made = make() }) {
            throw Invalid(message: "\(what): \(reason)")
        }
        return made!
    }
}
