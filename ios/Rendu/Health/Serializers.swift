import Foundation
import HealthKit

struct SerializerContext: Sendable {
    /// Read at serialize time so long-running backfills track timezone changes.
    let defaultTimeZone: @Sendable () -> TimeZone
    let formatter: TimestampFormatter

    static let live = SerializerContext(defaultTimeZone: { .current }, formatter: TimestampFormatter())
}

/// HealthKit objects → wire JSON (docs/PROTOCOL.md, "Object format"). Field names
/// are HealthKit's own; nothing is merged, renamed, or rescaled.
enum Serializers {
    static func serialize(_ sample: HKSample, context: SerializerContext) -> JSON? {
        let zone = recordedTimeZone(sample) ?? context.defaultTimeZone()
        var object = base(sample, zone: zone, context: context)
        switch sample {
        case let quantitySample as HKQuantitySample:
            guard let quantity = quantity(quantitySample.quantity, of: quantitySample.quantityType) else { return nil }
            object["kind"] = .string(SampleKind.quantity.rawValue)
            object["quantity"] = quantity
            if quantitySample.count > 1 {
                object["count"] = .number(Double(quantitySample.count))
                // A discrete series' quantity is its average; the rest of
                // its statistics come with it. (Its values: SeriesData.)
                if let discrete = quantitySample as? HKDiscreteQuantitySample {
                    let type = quantitySample.quantityType
                    object["minimumQuantity"] = Self.quantity(discrete.minimumQuantity, of: type)
                    object["maximumQuantity"] = Self.quantity(discrete.maximumQuantity, of: type)
                    object["mostRecentQuantity"] = Self.quantity(discrete.mostRecentQuantity, of: type)
                    object["mostRecentQuantityDateInterval"] = [
                        "startDate": .string(context.formatter.string(discrete.mostRecentQuantityDateInterval.start, in: zone)),
                        "endDate": .string(context.formatter.string(discrete.mostRecentQuantityDateInterval.end, in: zone)),
                    ]
                }
            }
        case let categorySample as HKCategorySample:
            object["kind"] = .string(SampleKind.category.rawValue)
            object["value"] = .number(Double(categorySample.value))
            if let name = TypeCatalog.values(for: categorySample.categoryType.identifier)?.name(categorySample.value) {
                object["valueName"] = .string(name)
            }
        case let correlation as HKCorrelation:
            object["kind"] = .string(SampleKind.correlation.rawValue)
            object["objects"] = .array(correlation.objects.map(\.uuid.uuidString).sorted().map(JSON.string))
        case let workout as HKWorkout:
            object["kind"] = .string(SampleKind.workout.rawValue)
            object["workoutActivityType"] = .number(Double(workout.workoutActivityType.rawValue))
            object["workoutActivityTypeName"] = .string(WorkoutActivityName.name(for: workout.workoutActivityType))
            object["duration"] = .number(workout.duration)
            var statistics: [String: JSON] = [:]
            for (type, stats) in workout.allStatistics {
                if let entry = statisticsJSON(stats, of: type), !entry.isEmpty {
                    statistics[type.identifier] = .object(entry)
                }
            }
            if !statistics.isEmpty {
                object["statistics"] = .object(statistics)
            }
            if !workout.workoutActivities.isEmpty {
                object["workoutActivities"] = .array(
                    workout.workoutActivities.map { activityJSON($0, zone: zone, context: context) })
            }
            if let events = workout.workoutEvents, !events.isEmpty {
                object["workoutEvents"] = .array(events.map { eventJSON($0, zone: zone, context: context) })
            }
        case let stateOfMind as HKStateOfMind:
            object["kind"] = .string(SampleKind.stateOfMind.rawValue)
            object["stateOfMindKind"] = .number(Double(stateOfMind.kind.rawValue))
            object["valence"] = .number(stateOfMind.valence)
            object["valenceClassification"] = .number(Double(stateOfMind.valenceClassification.rawValue))
            object["labels"] = .array(stateOfMind.labels.map { .number(Double($0.rawValue)) })
            object["associations"] = .array(stateOfMind.associations.map { .number(Double($0.rawValue)) })
        case let ecg as HKElectrocardiogram:
            object["kind"] = .string(SampleKind.electrocardiogram.rawValue)
            object["classification"] = .number(Double(ecg.classification.rawValue))
            object["symptomsStatus"] = .number(Double(ecg.symptomsStatus.rawValue))
            object["numberOfVoltageMeasurements"] = .number(Double(ecg.numberOfVoltageMeasurements))
            if let heartRate = ecg.averageHeartRate {
                object["averageHeartRate"] = quantityJSON(heartRate, unit: HKUnit.count().unitDivided(by: .minute()))
            }
            if let frequency = ecg.samplingFrequency {
                object["samplingFrequency"] = quantityJSON(frequency, unit: .hertz())
            }
        case let audiogram as HKAudiogramSample:
            object["kind"] = .string(SampleKind.audiogram.rawValue)
            object["sensitivityPoints"] = .array(audiogram.sensitivityPoints.map(sensitivityPoint))
        case let assessment as HKScoredAssessment:
            object["kind"] = .string(SampleKind.scoredAssessment.rawValue)
            object["score"] = .number(Double(assessment.score))
            switch assessment {
            case let gad7 as HKGAD7Assessment:
                object["answers"] = .array(gad7.answers.map { .number(Double($0.rawValue)) })
                object["risk"] = .number(Double(gad7.risk.rawValue))
            case let phq9 as HKPHQ9Assessment:
                object["answers"] = .array(phq9.answers.map { .number(Double($0.rawValue)) })
                object["risk"] = .number(Double(phq9.risk.rawValue))
            default:
                break
            }
        // Their series data (locations, beats) is read separately and added
        // by SeriesData.
        case is HKWorkoutRoute:
            object["kind"] = .string(SampleKind.workoutRoute.rawValue)
        case is HKHeartbeatSeriesSample:
            object["kind"] = .string(SampleKind.heartbeatSeries.rawValue)
        case let dose as HKMedicationDoseEvent:
            object["kind"] = .string(SampleKind.medicationDoseEvent.rawValue)
            object["scheduleType"] = .number(Double(dose.scheduleType.rawValue))
            object["logStatus"] = .number(Double(dose.logStatus.rawValue))
            // Absent values are left out (docs/PROTOCOL.md).
            if let date = dose.scheduledDate {
                object["scheduledDate"] = .string(context.formatter.string(date, in: zone))
            }
            if let quantity = dose.scheduledDoseQuantity {
                object["scheduledDoseQuantity"] = .number(quantity)
            }
            if let quantity = dose.doseQuantity {
                object["doseQuantity"] = .number(quantity)
            }
            object["unit"] = .string(dose.unit.unitString)
        case let prescription as HKVisionPrescription:
            object["kind"] = .string(SampleKind.visionPrescription.rawValue)
            object.merge(Self.prescription(prescription, zone: zone, context: context)) { $1 }
        case is HKCDADocumentSample:
            // Its XML and the names HealthKit reads from it: SeriesData.
            object["kind"] = .string(SampleKind.cdaDocument.rawValue)
        default:
            return nil
        }
        return .object(object)
    }

    /// One activity of a multisport or interval workout.
    private static func activityJSON(_ activity: HKWorkoutActivity, zone: TimeZone, context: SerializerContext) -> JSON {
        let configuration = activity.workoutConfiguration
        var config: [String: JSON] = [
            "activityType": .number(Double(configuration.activityType.rawValue)),
            "activityTypeName": .string(WorkoutActivityName.name(for: configuration.activityType)),
            "locationType": .number(Double(configuration.locationType.rawValue)),
            "swimmingLocationType": .number(Double(configuration.swimmingLocationType.rawValue)),
        ]
        if let lap = configuration.lapLength {
            config["lapLength"] = quantityJSON(lap, unit: .meter())
        }
        var object: [String: JSON] = [
            "uuid": .string(activity.uuid.uuidString),
            "workoutConfiguration": .object(config),
            "startDate": .string(context.formatter.string(activity.startDate, in: zone)),
            "duration": .number(activity.duration),
        ]
        if let end = activity.endDate {
            object["endDate"] = .string(context.formatter.string(end, in: zone))
        }
        var statistics: [String: JSON] = [:]
        for (type, stats) in activity.allStatistics {
            if let entry = statisticsJSON(stats, of: type), !entry.isEmpty {
                statistics[type.identifier] = .object(entry)
            }
        }
        if !statistics.isEmpty {
            object["statistics"] = .object(statistics)
        }
        return .object(object)
    }

    private static func eventJSON(_ event: HKWorkoutEvent, zone: TimeZone, context: SerializerContext) -> JSON {
        var object: [String: JSON] = [
            "type": .number(Double(event.type.rawValue)),
            "startDate": .string(context.formatter.string(event.dateInterval.start, in: zone)),
            "endDate": .string(context.formatter.string(event.dateInterval.end, in: zone)),
        ]
        if let metadata = event.metadata, !metadata.isEmpty {
            object["metadata"] = .object(metadata.mapValues { jsonValue($0, zone: zone, context: context) })
        }
        return .object(object)
    }

    /// Glasses or contacts: the date issued, each eye's lens, the brand.
    private static func prescription(
        _ prescription: HKVisionPrescription, zone: TimeZone, context: SerializerContext
    )
        -> [String: JSON]
    {
        var object: [String: JSON] = [
            "prescriptionType": .number(Double(prescription.prescriptionType.rawValue)),
            "dateIssued": .string(context.formatter.string(prescription.dateIssued, in: zone)),
        ]
        if let expiration = prescription.expirationDate {
            object["expirationDate"] = .string(context.formatter.string(expiration, in: zone))
        }
        func lens(_ lens: HKLensSpecification) -> [String: JSON] {
            var eye: [String: JSON] = [:]
            eye["sphere"] = quantityJSON(lens.sphere, unit: .diopter())
            eye["cylinder"] = lens.cylinder.map { quantityJSON($0, unit: .diopter()) }
            eye["axis"] = lens.axis.map { quantityJSON($0, unit: .degreeAngle()) }
            eye["addPower"] = lens.addPower.map { quantityJSON($0, unit: .diopter()) }
            return eye
        }
        let millimeters = HKUnit.meterUnit(with: .milli)
        if let glasses = prescription as? HKGlassesPrescription {
            for (key, spec) in [("rightEye", glasses.rightEye), ("leftEye", glasses.leftEye)] {
                guard let spec else { continue }
                var eye = lens(spec)
                eye["vertexDistance"] = spec.vertexDistance.map { quantityJSON($0, unit: millimeters) }
                eye["farPupillaryDistance"] = spec.farPupillaryDistance.map { quantityJSON($0, unit: millimeters) }
                eye["nearPupillaryDistance"] = spec.nearPupillaryDistance.map { quantityJSON($0, unit: millimeters) }
                if let prism = spec.prism {
                    eye["prism"] = [
                        "amount": quantityJSON(prism.amount, unit: .prismDiopter()),
                        "angle": quantityJSON(prism.angle, unit: .degreeAngle()),
                        "verticalAmount": quantityJSON(prism.verticalAmount, unit: .prismDiopter()),
                        "verticalBase": .number(Double(prism.verticalBase.rawValue)),
                        "horizontalAmount": quantityJSON(prism.horizontalAmount, unit: .prismDiopter()),
                        "horizontalBase": .number(Double(prism.horizontalBase.rawValue)),
                        "eye": .number(Double(prism.eye.rawValue)),
                    ]
                }
                object[key] = .object(eye)
            }
        } else if let contacts = prescription as? HKContactsPrescription {
            object["brand"] = .string(contacts.brand)
            for (key, spec) in [("rightEye", contacts.rightEye), ("leftEye", contacts.leftEye)] {
                guard let spec else { continue }
                var eye = lens(spec)
                eye["baseCurve"] = spec.baseCurve.map { quantityJSON($0, unit: millimeters) }
                eye["diameter"] = spec.diameter.map { quantityJSON($0, unit: millimeters) }
                object[key] = .object(eye)
            }
        }
        return object
    }

    /// One frequency of a hearing test: its tests per ear and conduction
    /// type, in dBHL.
    private static func sensitivityPoint(_ point: HKAudiogramSensitivityPoint) -> JSON {
        let tests: [JSON] = point.tests.map { test in
            var entry: [String: JSON] = [
                "sensitivity": quantityJSON(test.sensitivity, unit: .decibelHearingLevel()),
                "type": .number(Double(test.type.rawValue)),
                "masked": .bool(test.masked),
                "side": .number(Double(test.side.rawValue)),
            ]
            if let range = test.clampingRange {
                var bounds: [String: JSON] = [:]
                if let lower = range.lowerBound { bounds["lowerBound"] = quantityJSON(lower, unit: .decibelHearingLevel()) }
                if let upper = range.upperBound { bounds["upperBound"] = quantityJSON(upper, unit: .decibelHearingLevel()) }
                entry["clampingRange"] = .object(bounds)
            }
            return .object(entry)
        }
        return [
            "frequency": quantityJSON(point.frequency, unit: .hertz()),
            "tests": .array(tests),
        ]
    }

    /// Fields shared by every kind. Timestamps keep the sample's own timezone
    /// when it recorded one (metadata HKTimeZone, passed through untouched);
    /// otherwise the device timezone at sync time is used.
    private static func base(_ sample: HKSample, zone: TimeZone, context: SerializerContext) -> [String: JSON] {
        var object: [String: JSON] = [
            "uuid": .string(sample.uuid.uuidString),
            "type": .string(sample.sampleType.identifier),
            "startDate": .string(context.formatter.string(sample.startDate, in: zone)),
            "endDate": .string(context.formatter.string(sample.endDate, in: zone)),
            "sourceRevision": sourceRevision(sample.sourceRevision),
        ]
        if let device = sample.device.flatMap(device) {
            object["device"] = device
        }
        if let metadata = sample.metadata, !metadata.isEmpty {
            object["metadata"] = .object(metadata.mapValues { jsonValue($0, zone: zone, context: context) })
        }
        return object
    }

    static func recordedTimeZone(_ sample: HKSample) -> TimeZone? {
        (sample.metadata?[HKMetadataKeyTimeZone] as? String).flatMap {
            TimeZone(identifier: $0) ?? TimeZone(abbreviation: $0)
        }
    }

    /// `{value, unit}` in the catalog unit for this type; nil when the
    /// catalog has no unit for it.
    static func quantity(_ quantity: HKQuantity, of type: HKQuantityType) -> JSON? {
        guard let unit = TypeCatalog.unit(for: type), quantity.is(compatibleWith: unit) else { return nil }
        return quantityJSON(quantity, unit: unit)
    }

    private static func quantityJSON(_ quantity: HKQuantity, unit: HKUnit) -> JSON {
        ["value": .number(quantity.doubleValue(for: unit)), "unit": .string(unit.unitString)]
    }

    private static func statisticsJSON(_ statistics: HKStatistics, of type: HKQuantityType) -> [String: JSON]? {
        guard let unit = TypeCatalog.unit(for: type) else { return nil }
        var entry: [String: JSON] = [:]
        let fields: [(String, HKQuantity?)] = [
            ("sumQuantity", statistics.sumQuantity()),
            ("averageQuantity", statistics.averageQuantity()),
            ("minimumQuantity", statistics.minimumQuantity()),
            ("maximumQuantity", statistics.maximumQuantity()),
        ]
        for (name, quantity) in fields {
            if let quantity, quantity.is(compatibleWith: unit) {
                entry[name] = quantityJSON(quantity, unit: unit)
            }
        }
        return entry
    }

    private static func sourceRevision(_ revision: HKSourceRevision) -> JSON {
        var source: [String: JSON] = ["name": .string(revision.source.name)]
        source["bundleIdentifier"] = .string(revision.source.bundleIdentifier)
        var object: [String: JSON] = ["source": .object(source)]
        if let version = revision.version { object["version"] = .string(version) }
        if let productType = revision.productType { object["productType"] = .string(productType) }
        let os = revision.operatingSystemVersion
        if os.majorVersion > 0 {
            object["operatingSystemVersion"] = .string("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        }
        return .object(object)
    }

    private static func device(_ device: HKDevice) -> JSON? {
        let fields: [(String, String?)] = [
            ("name", device.name), ("manufacturer", device.manufacturer), ("model", device.model),
            ("hardwareVersion", device.hardwareVersion), ("firmwareVersion", device.firmwareVersion),
            ("softwareVersion", device.softwareVersion), ("localIdentifier", device.localIdentifier),
            ("UDIDeviceIdentifier", device.udiDeviceIdentifier),
        ]
        var object: [String: JSON] = [:]
        for case (let name, let value?) in fields {
            object[name] = .string(value)
        }
        return object.isEmpty ? nil : .object(object)
    }

    /// Strings, numbers, and booleans pass through natively; dates become
    /// timestamps and everything else (HKQuantity included) is stringified.
    static func jsonValue(_ value: Any, zone: TimeZone, context: SerializerContext) -> JSON {
        switch value {
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        case let date as Date:
            return .string(context.formatter.string(date, in: zone))
        default:
            return .string(String(describing: value))
        }
    }
}
