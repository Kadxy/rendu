import Foundation
import HealthKit

struct QuantityEntry: Sendable {
    let identifier: HKQuantityTypeIdentifier
    /// HKUnit string every sample of this type is read in.
    let unit: String
    let shareable: Bool

    init(_ identifier: HKQuantityTypeIdentifier, unit: String, shareable: Bool) {
        self.identifier = identifier
        self.unit = unit
        self.shareable = shareable
    }
}

struct CategoryEntry: Sendable {
    let identifier: HKCategoryTypeIdentifier
    let values: CategoryValues?
    let shareable: Bool

    init(_ identifier: HKCategoryTypeIdentifier, values: CategoryValues?, shareable: Bool) {
        self.identifier = identifier
        self.values = values
        self.shareable = shareable
    }
}

/// Category value enums whose case names go on the wire as `valueName`.
enum CategoryValues: Sendable {
    case sleepAnalysis, appleStandHour, severity, presence

    func name(_ rawValue: Int) -> String? {
        switch self {
        case .sleepAnalysis:
            switch HKCategoryValueSleepAnalysis(rawValue: rawValue) {
            case .inBed: "inBed"
            case .asleepUnspecified: "asleepUnspecified"
            case .awake: "awake"
            case .asleepCore: "asleepCore"
            case .asleepDeep: "asleepDeep"
            case .asleepREM: "asleepREM"
            default: nil
            }
        case .appleStandHour:
            switch HKCategoryValueAppleStandHour(rawValue: rawValue) {
            case .stood: "stood"
            case .idle: "idle"
            default: nil
            }
        case .severity:
            switch HKCategoryValueSeverity(rawValue: rawValue) {
            case .unspecified: "unspecified"
            case .notPresent: "notPresent"
            case .mild: "mild"
            case .moderate: "moderate"
            case .severe: "severe"
            default: nil
            }
        case .presence:
            switch HKCategoryValuePresence(rawValue: rawValue) {
            case .present: "present"
            case .notPresent: "notPresent"
            default: nil
            }
        }
    }
}

/// Every kind Rendu reads; `writable` the ones it also writes. Keep in step
/// with the capability table in docs/PROTOCOL.md.
enum SampleKind: String, CaseIterable, Sendable {
    case quantity, category, correlation, workout, stateOfMind, electrocardiogram, audiogram, scoredAssessment
    case workoutRoute, heartbeatSeries, medicationDoseEvent, visionPrescription, cdaDocument

    /// Every kind HealthKit lets apps create (checked against the SDK: the
    /// classes with a public initializer or builder). A route is written as
    /// part of its workout. ECGs and dose events only Apple makes.
    var writable: Bool {
        switch self {
        case .quantity, .category, .correlation, .workout, .stateOfMind, .audiogram, .scoredAssessment, .heartbeatSeries,
            .visionPrescription:
            true
        // Clinical documents: not supported (see docs/PROTOCOL.md).
        case .electrocardiogram, .workoutRoute, .medicationDoseEvent, .cdaDocument: false
        }
    }

    /// Read with data of their own besides the sample (SeriesData): a
    /// quantity series' values, workout effort, ECG voltages, route
    /// locations, beats, the medication of a dose, prescription
    /// attachments, a document's XML.
    var hasSeriesData: Bool {
        switch self {
        case .quantity, .workout, .electrocardiogram, .workoutRoute, .heartbeatSeries, .medicationDoseEvent, .visionPrescription,
            .cdaDocument:
            true
        case .category, .correlation, .stateOfMind, .audiogram, .scoredAssessment: false
        }
    }

    /// Samples per anchored query page. Some carry their series data (an
    /// ECG has 15,000 voltages, a route thousands of locations).
    var queryLimit: Int {
        switch self {
        case .electrocardiogram, .workoutRoute, .cdaDocument: 20
        case .heartbeatSeries: 1000
        default: SyncEngine.queryLimit
        }
    }
}

/// One type the sync engine reads with an anchored query.
struct SyncedType: Identifiable, @unchecked Sendable {
    /// `HKObjectType.identifier` — the wire `type` and the persistence key.
    let key: String
    let kind: SampleKind
    let sampleType: HKSampleType

    var id: String { key }

    /// Correlations can't be authorized or observed directly; they are read
    /// whenever a pass runs, which their member types' observers trigger.
    /// Dose events and prescriptions are shared one by one (PerObjectAccess),
    /// not with the other types.
    var observable: Bool { kind != .correlation && perObject == nil }

    /// The access the user gives object by object for this type, if so.
    var perObject: PerObjectAccess? {
        switch kind {
        case .medicationDoseEvent: .medications
        case .visionPrescription: .visionPrescriptions
        default: nil
        }
    }
}

enum TypeCatalog {
    /// Quantity types this OS accepts, with the unit they are read in. A type
    /// HealthKit refuses to construct, or whose catalog unit fails to parse or
    /// doesn't fit, is left out rather than crashing the app.
    private static let quantityTypes: [(type: HKQuantityType, unit: HKUnit, entry: QuantityEntry)] =
        TypeCatalogData.quantity.compactMap { entry in
            guard let type = construct({ HKQuantityType(entry.identifier) }),
                let unit = parseUnit(entry.unit), type.is(compatibleWith: unit)
            else { return nil }
            return (type, unit, entry)
        }

    private static let categoryTypes: [(type: HKCategoryType, entry: CategoryEntry)] =
        TypeCatalogData.category.compactMap { entry in
            construct({ HKCategoryType(entry.identifier) }).map { ($0, entry) }
        }

    static let units: [String: HKUnit] = Dictionary(
        uniqueKeysWithValues: quantityTypes.map { ($0.type.identifier, $0.unit) }
    )

    static let all: [SyncedType] = {
        var types: [SyncedType] = []
        for (type, _, _) in quantityTypes {
            types.append(SyncedType(key: type.identifier, kind: .quantity, sampleType: type))
        }
        for (type, _) in categoryTypes {
            types.append(SyncedType(key: type.identifier, kind: .category, sampleType: type))
        }
        for identifier in [HKCorrelationTypeIdentifier.food, .bloodPressure] {
            types.append(SyncedType(key: identifier.rawValue, kind: .correlation, sampleType: HKCorrelationType(identifier)))
        }
        let workout = HKObjectType.workoutType()
        let stateOfMind = HKObjectType.stateOfMindType()
        let electrocardiogram = HKObjectType.electrocardiogramType()
        types.append(SyncedType(key: workout.identifier, kind: .workout, sampleType: workout))
        types.append(SyncedType(key: stateOfMind.identifier, kind: .stateOfMind, sampleType: stateOfMind))
        types.append(SyncedType(key: electrocardiogram.identifier, kind: .electrocardiogram, sampleType: electrocardiogram))
        let audiogram = HKObjectType.audiogramSampleType()
        types.append(SyncedType(key: audiogram.identifier, kind: .audiogram, sampleType: audiogram))
        let route = HKSeriesType.workoutRoute()
        let heartbeat = HKSeriesType.heartbeat()
        let doseEvent = HKObjectType.medicationDoseEventType()
        types.append(SyncedType(key: route.identifier, kind: .workoutRoute, sampleType: route))
        types.append(SyncedType(key: heartbeat.identifier, kind: .heartbeatSeries, sampleType: heartbeat))
        types.append(SyncedType(key: doseEvent.identifier, kind: .medicationDoseEvent, sampleType: doseEvent))
        let prescription = HKObjectType.visionPrescriptionType()
        types.append(SyncedType(key: prescription.identifier, kind: .visionPrescription, sampleType: prescription))
        // Clinical documents (CDA) are written, not read: reading needs
        // per-object access, and querying them crashed on the device.
        for identifier in [HKScoredAssessmentTypeIdentifier.GAD7, .PHQ9] {
            let type = HKScoredAssessmentType(identifier)
            types.append(SyncedType(key: type.identifier, kind: .scoredAssessment, sampleType: type))
        }
        return types
    }()

    private static let byKey: [String: SyncedType] = Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })

    private static let categoryValues: [String: CategoryValues] = Dictionary(
        uniqueKeysWithValues: categoryTypes.compactMap { type, entry in entry.values.map { (type.identifier, $0) } }
    )

    static let characteristicTypes: Set<HKObjectType> = [
        HKCharacteristicType(.biologicalSex), HKCharacteristicType(.dateOfBirth), HKCharacteristicType(.bloodType),
        HKCharacteristicType(.fitzpatrickSkinType), HKCharacteristicType(.wheelchairUse), HKCharacteristicType(.activityMoveMode),
    ]

    static func type(for key: String) -> SyncedType? { byKey[key] }

    static func unit(for type: HKQuantityType) -> HKUnit? { units[type.identifier] }

    static func values(for categoryIdentifier: String) -> CategoryValues? { categoryValues[categoryIdentifier] }

    static var readTypes: Set<HKObjectType> {
        var types = Set(all.filter(\.observable).map { $0.sampleType as HKObjectType })
        types.insert(HKObjectType.activitySummaryType())
        types.formUnion(characteristicTypes)
        return types
    }

    /// Every sample type that could conceivably be saved. HealthKit itself
    /// decides which of these third-party apps may write (see
    /// HealthAuthorization).
    static var shareCandidates: Set<HKSampleType> {
        var types: Set<HKSampleType> = Set(quantityTypes.map(\.type))
        types.formUnion(categoryTypes.map(\.type))
        types.formUnion(otherShareTypes)
        return types
    }

    /// The writable kinds beyond quantities and categories.
    private static var otherShareTypes: [HKSampleType] {
        [
            HKObjectType.workoutType(), HKObjectType.stateOfMindType(), HKSeriesType.workoutRoute(), HKSeriesType.heartbeat(),
            HKObjectType.audiogramSampleType(), HKScoredAssessmentType(.GAD7), HKScoredAssessmentType(.PHQ9),
            HKObjectType.visionPrescriptionType(),
        ]
    }

    /// The candidates minus the generator's READ_ONLY guess — the fallback
    /// when HealthKit's refusal can't be parsed.
    static var presumedShareTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = []
        for (type, _, entry) in quantityTypes where entry.shareable {
            types.insert(type)
        }
        for (type, entry) in categoryTypes where entry.shareable {
            types.insert(type)
        }
        types.formUnion(otherShareTypes)
        return types
    }

    /// HKUnit(from:) raises on strings it can't parse.
    static func parseUnit(_ string: String) -> HKUnit? {
        construct { HKUnit(from: string) }
    }

    /// HealthKit initializers raise on identifiers this OS doesn't know.
    private static func construct<T>(_ make: () -> T) -> T? {
        var made: T?
        let failure = RDCatchException { made = make() }
        return failure == nil ? made : nil
    }
}
