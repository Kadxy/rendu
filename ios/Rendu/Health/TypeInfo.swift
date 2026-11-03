import Foundation
import SwiftUI

extension DisplayNames {
    /// Apple's own name for an object type in the app's language — the
    /// localization the system picked from the ones the app ships (English,
    /// Simplified Chinese), so English unless the device prefers Chinese.
    static func localized(_ identifier: String) -> String? {
        let chinese = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true
        return (chinese ? zhHans : en)[identifier]
    }

    /// The identifier without its HealthKit prefix, which the UI leads with
    /// (WaistCircumference, SleepAnalysis, StateOfMind; Workout for
    /// HKWorkoutTypeIdentifier).
    static func shortName(_ identifier: String) -> String {
        if identifier.hasPrefix("HK"), identifier.hasSuffix("TypeIdentifier"), identifier.count > 16 {
            return String(identifier.dropFirst(2).dropLast("TypeIdentifier".count))
        }
        for prefix in [
            "HKQuantityTypeIdentifier", "HKCategoryTypeIdentifier", "HKCorrelationTypeIdentifier",
            "HKScoredAssessmentTypeIdentifier", "HKMedicationDoseEventTypeIdentifier", "HKDocumentTypeIdentifier",
            "HKDataTypeIdentifier", "HKDataType", "HK",
        ] where identifier.hasPrefix(prefix) {
            return String(identifier.dropFirst(prefix.count))
        }
        return identifier
    }

    /// What an upload queue key is called: a type by Apple's name, the
    /// rings as Activity, or Characteristics.
    static func name(forKey key: String) -> String {
        if key == "characteristics" { return String(localized: "Characteristics") }
        let identifier = key == "activitySummary" ? "HKActivitySummaryTypeIdentifier" : key
        return localized(identifier) ?? shortName(identifier)
    }

    /// A metadata key without its HealthKit prefix (HeartRateMotionContext).
    /// Apple's tables carry no display names for metadata keys.
    static func metadataName(_ key: String) -> String {
        key.hasPrefix("HKMetadataKey") && key.count > 13 ? String(key.dropFirst(13)) : key
    }
}

/// The Health app's browse categories, used to group types, with Health's
/// own names (HealthUIStrings).
enum HealthCategory: Int, CaseIterable, Identifiable {
    case activity, bodyMeasurements, cycleTracking, hearing, heart, medications, mentalWellbeing,
        mobility, nutrition, respiratory, sleep, symptoms, vitals, otherData

    var id: Int { rawValue }

    /// HealthUI's key for the category name.
    private var key: String {
        switch self {
        case .activity: "FITNESS"
        case .bodyMeasurements: "BODY_MEASUREMENTS"
        case .cycleTracking: "REPRODUCTIVE_HEALTH"
        case .hearing: "HEARING_HEALTH"
        case .heart: "HEART"
        case .medications: "MEDICATION_TRACKING"
        case .mentalWellbeing: "MENTAL_WELLBEING"
        case .mobility: "MOBILITY"
        case .nutrition: "NUTRITION"
        case .respiratory: "RESPIRATORY"
        case .sleep: "SLEEP"
        case .symptoms: "SYMPTOMS"
        case .vitals: "VITAL_SIGNS"
        case .otherData: "OTHER"
        }
    }

    var title: String { HealthUIStrings.localized(key) ?? key }

    /// The Health app's own glyph for the category, exactly as HealthUI
    /// names it (HKDisplayCategory.systemImageName, read on the device by
    /// HealthUIProbe); CategoryIcon draws it filled and in multicolor, as
    /// Health does. Some are private system symbols.
    var symbol: String {
        switch self {
        case .activity: "flame.fill"
        case .bodyMeasurements: "figure"
        case .cycleTracking: "apple.cycletracking"
        case .hearing: "ear"
        case .heart: "heart.fill"
        case .medications: "pills.fill"
        case .mentalWellbeing: "brain.head.profile"
        case .mobility: "apple.mobility"
        case .nutrition: "apple.slice"
        case .respiratory: "lungs.fill"
        case .sleep: "bed.double.fill"
        case .symptoms: "figure.arms.open.and.exclamationmark.magnifyingglass"
        case .vitals: "waveform.path.ecg.rectangle"
        case .otherData: "capsule.cross.fill"
        }
    }

    /// HKDisplayCategory.categoryID, for comparing with Health (HealthUIProbe).
    var healthCategoryID: Int {
        switch self {
        case .vitals: 1
        case .activity: 2
        case .nutrition: 4
        case .sleep: 5
        case .bodyMeasurements: 6
        case .cycleTracking: 8
        case .mentalWellbeing: 10
        case .heart: 11
        case .hearing: 12
        case .respiratory: 13
        case .otherData: 14
        case .mobility: 23
        case .symptoms: 26
        case .medications: 31
        }
    }

    /// A public symbol for when the private ones can't be loaded.
    var fallbackSymbol: String {
        switch self {
        case .cycleTracking: "circle.dotted"
        case .mobility: "arrow.left.arrow.right"
        case .nutrition: "leaf.fill"
        case .otherData: "cross.fill"
        default: symbol
        }
    }

    /// Health's color for the category (HKDisplayCategory.color): a system
    /// color, which follows light and dark mode, except Activity's own
    /// wide-gamut orange. Multicolor symbols keep their own colors where
    /// they have them.
    var color: Color {
        Color(uiColor: uiColor)
    }

    var uiColor: UIColor {
        switch self {
        case .activity: Self.activityColor
        case .bodyMeasurements: .systemPurple
        case .cycleTracking, .sleep, .symptoms: .systemIndigo
        case .hearing, .otherData: .systemBlue
        case .heart, .vitals: .systemPink
        case .medications, .respiratory: .systemCyan
        case .mentalWellbeing: .systemMint
        case .mobility: .systemOrange
        case .nutrition: .systemGreen
        }
    }

    /// Extended sRGB, outside what a plain sRGB color can show.
    private static let activityColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.081, green: 0.343, blue: 0.073, alpha: 1)
            : UIColor(red: 1.084, green: 0.287, blue: -0.090, alpha: 1)
    }

    /// Health lists a category's types in its own order, not alphabetically
    /// (the order isn't in any table apps can read; taken from the Health app).
    /// Types not listed follow, alphabetically.
    var order: [String: Int] {
        let names: [String] =
            switch self {
            case .heart:
                [
                    "HeartRate", "RestingHeartRate", "VO2Max", "WalkingHeartRateAverage", "HeartRateVariabilitySDNN",
                    "HighHeartRateEvent", "LowHeartRateEvent", "LowCardioFitnessEvent", "HeartRateRecoveryOneMinute",
                    "IrregularHeartRhythmEvent", "Electrocardiogram", "AtrialFibrillationBurden", "PeripheralPerfusionIndex",
                ]
            case .activity:
                [
                    "StepCount", "DistanceWalkingRunning", "ActiveEnergyBurned", "BasalEnergyBurned", "AppleExerciseTime",
                    "AppleStandHour", "AppleStandTime", "AppleMoveTime", "FlightsClimbed", "Workout", "PhysicalEffort",
                    "EstimatedWorkoutEffortScore", "WorkoutEffortScore", "DistanceCycling", "DistanceSwimming",
                    "SwimmingStrokeCount", "DistanceWheelchair", "PushCount", "DistanceDownhillSnowSports",
                ]
            case .bodyMeasurements:
                [
                    "Height", "BodyMass", "BodyMassIndex", "BodyFatPercentage", "LeanBodyMass", "WaistCircumference",
                ]
            case .respiratory:
                [
                    "OxygenSaturation", "RespiratoryRate", "AppleSleepingBreathingDisturbances", "ForcedVitalCapacity",
                    "ForcedExpiratoryVolume1", "PeakExpiratoryFlowRate", "InhalerUsage",
                ]
            case .vitals:
                [
                    "BloodPressureSystolic", "BloodPressureDiastolic", "BodyTemperature", "AppleSleepingWristTemperature",
                    "BloodGlucose",
                ]
            case .mentalWellbeing: ["MindfulSession", "TimeInDaylight", "StateOfMind"]
            case .hearing: ["HeadphoneAudioExposure", "EnvironmentalAudioExposure", "EnvironmentalSoundReduction"]
            case .mobility:
                [
                    "WalkingSpeed", "WalkingStepLength", "WalkingDoubleSupportPercentage", "WalkingAsymmetryPercentage",
                    "StairAscentSpeed", "StairDescentSpeed", "SixMinuteWalkTestDistance", "AppleWalkingSteadiness",
                ]
            case .nutrition:
                [
                    "DietaryEnergyConsumed", "DietaryProtein", "DietaryCarbohydrates", "DietaryFatTotal", "DietaryFiber",
                    "DietarySugar", "DietaryWater", "DietaryCaffeine",
                ]
            case .sleep: ["SleepAnalysis"]
            default: []
            }
        return Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, $0) })
    }

    static func of(_ identifier: String) -> HealthCategory {
        if let category = explicit[DisplayNames.shortName(identifier)] {
            return category
        }
        if TypeCatalog.values(for: identifier) == .severity || TypeCatalog.values(for: identifier) == .presence {
            return .symptoms
        }
        let name = DisplayNames.shortName(identifier)
        if name.hasPrefix("Dietary") { return .nutrition }
        if name.hasPrefix("Distance") || name.hasPrefix("Running") || name.hasPrefix("Cycling") { return .activity }
        return .otherData
    }

    private static let explicit: [String: HealthCategory] = {
        var map: [String: HealthCategory] = [:]
        func add(_ category: HealthCategory, _ names: [String]) {
            for name in names { map[name] = category }
        }
        add(
            .activity,
            [
                "StepCount", "ActiveEnergyBurned", "BasalEnergyBurned", "AppleExerciseTime", "AppleMoveTime",
                "AppleStandTime", "AppleStandHour", "FlightsClimbed", "NikeFuel", "PushCount", "SwimmingStrokeCount",
                "PhysicalEffort", "EstimatedWorkoutEffortScore", "WorkoutEffortScore", "CrossCountrySkiingSpeed",
                "PaddleSportsSpeed", "RowingSpeed", "UnderwaterDepth", "Workout", "ActivitySummary",
            ])
        add(.hearing, ["Audiogram"])
        add(.activity, ["WorkoutRoute"])
        add(.heart, ["HeartbeatSeries"])
        add(.medications, ["MedicationDoseEvent"])
        add(.bodyMeasurements, ["VisionPrescription"])
        add(.mentalWellbeing, ["GAD7", "PHQ9"])
        add(
            .bodyMeasurements,
            [
                "BodyMass", "BodyMassIndex", "BodyFatPercentage", "LeanBodyMass", "Height", "WaistCircumference",
                "ElectrodermalActivity", "AppleSleepingWristTemperature", "BasalBodyTemperature",
            ])
        add(
            .cycleTracking,
            [
                "MenstrualFlow", "IntermenstrualBleeding", "CervicalMucusQuality", "OvulationTestResult",
                "PregnancyTestResult", "ProgesteroneTestResult", "SexualActivity", "Contraceptive", "Lactation",
                "Pregnancy", "BleedingAfterPregnancy", "BleedingDuringPregnancy", "BleedingAfterMenopause",
                "MenopausalState", "InfrequentMenstrualCycles", "IrregularMenstrualCycles",
                "PersistentIntermenstrualBleeding", "ProlongedMenstrualPeriods",
            ])
        add(
            .hearing,
            [
                "EnvironmentalAudioExposure", "HeadphoneAudioExposure", "EnvironmentalSoundReduction",
                "AudioExposureEvent", "HeadphoneAudioExposureEvent",
            ])
        add(
            .heart,
            [
                "HeartRate", "RestingHeartRate", "WalkingHeartRateAverage", "HeartRateVariabilitySDNN",
                "HeartRateRecoveryOneMinute", "VO2Max", "AtrialFibrillationBurden", "HighHeartRateEvent",
                "LowHeartRateEvent", "IrregularHeartRhythmEvent", "LowCardioFitnessEvent", "Electrocardiogram",
                "BloodPressureSystolic", "BloodPressureDiastolic", "BloodPressure", "HypertensionEvent",
                "PeripheralPerfusionIndex",
            ])
        add(.mentalWellbeing, ["MindfulSession", "StateOfMind", "TimeInDaylight"])
        add(
            .mobility,
            [
                "WalkingSpeed", "WalkingStepLength", "WalkingAsymmetryPercentage", "WalkingDoubleSupportPercentage",
                "AppleWalkingSteadiness", "AppleWalkingSteadinessEvent", "SixMinuteWalkTestDistance",
                "StairAscentSpeed", "StairDescentSpeed",
            ])
        add(.nutrition, ["Food", "NumberOfAlcoholicBeverages"])
        add(
            .respiratory,
            [
                "RespiratoryRate", "OxygenSaturation", "ForcedExpiratoryVolume1", "ForcedVitalCapacity",
                "PeakExpiratoryFlowRate", "InhalerUsage", "AppleSleepingBreathingDisturbances", "SleepApneaEvent",
            ])
        add(.sleep, ["SleepAnalysis"])
        add(.vitals, ["BodyTemperature", "BloodGlucose"])
        return map
    }()
}

extension SyncedType {
    var shortName: String { DisplayNames.shortName(key) }
    var localizedName: String? { DisplayNames.localized(key) }
    var category: HealthCategory { HealthCategory.of(key) }
}
