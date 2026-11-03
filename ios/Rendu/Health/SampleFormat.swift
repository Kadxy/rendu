import Foundation
import HealthKit

/// Short human-readable values for samples, in the catalog's units (the same
/// numbers the server receives, except percentages shown as 0–100).
enum SampleFormat {
    static func value(_ sample: HKSample) -> String? {
        switch sample {
        case let quantitySample as HKQuantitySample:
            guard let unit = TypeCatalog.unit(for: quantitySample.quantityType) else { return nil }
            return quantity(quantitySample.quantity.doubleValue(for: unit), unit: unit)
        case let categorySample as HKCategorySample:
            return TypeCatalog.values(for: categorySample.categoryType.identifier)?.name(categorySample.value)
                ?? String(categorySample.value)
        case let workout as HKWorkout:
            let minutes = Int((workout.duration / 60).rounded())
            return "\(WorkoutActivityName.name(for: workout.workoutActivityType)) · \(minutes) min"
        case let correlation as HKCorrelation:
            let title = correlation.metadata?[HKMetadataKeyFoodType] as? String
            return [title, "\(correlation.objects.count) objects"].compactMap { $0 }.joined(separator: " · ")
        case let stateOfMind as HKStateOfMind:
            return "valence \(stateOfMind.valence.formatted(.number.precision(.fractionLength(0 ... 2))))"
        case let ecg as HKElectrocardiogram:
            return "classification \(ecg.classification.rawValue)"
        default:
            return nil
        }
    }

    static func quantity(_ value: Double, unit: HKUnit) -> String {
        display(value, unit: unit.unitString)
    }

    /// A wire quantity ({value, unit} as uploaded) for display.
    static func wire(_ value: Double, unit: String) -> String {
        display(value, unit: unit)
    }

    /// A value in an HKUnit string as people read it: units through
    /// Foundation's localized measurement names (kcal, kg, mL…), heart rate in
    /// BPM as Health shows it, percentages as 0–100, plain counts bare.
    static func display(_ value: Double, unit: String) -> String {
        let number = value.formatted(.number.precision(.fractionLength(0 ... 2)).locale(appLocale))
        switch unit {
        case "count": return number
        case "count/min": return "\(number) BPM"
        case "%": return "\((value * 100).formatted(.number.precision(.fractionLength(0 ... 1)).locale(appLocale))) %"
        case "dBASPL": return "\(number) dB"
        default: break
        }
        guard let unit = foundationUnits[unit] else { return "\(number) \(unit)" }
        let formatter = MeasurementFormatter()
        formatter.locale = appLocale
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .medium
        formatter.numberFormatter.maximumFractionDigits = 2
        return formatter.string(from: Measurement(value: value, unit: unit))
    }

    /// The language the app is showing (its own localizations, not the
    /// device's region).
    static var appLocale: Locale {
        Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    }

    private static let foundationUnits: [String: Dimension] = [
        "kg": UnitMass.kilograms, "g": UnitMass.grams, "mg": UnitMass.milligrams, "mcg": UnitMass.micrograms,
        "lb": UnitMass.pounds, "oz": UnitMass.ounces,
        "kcal": UnitEnergy.kilocalories, "kJ": UnitEnergy.kilojoules,
        "m": UnitLength.meters, "km": UnitLength.kilometers, "cm": UnitLength.centimeters, "mm": UnitLength.millimeters,
        "ft": UnitLength.feet, "in": UnitLength.inches, "mi": UnitLength.miles,
        "mL": UnitVolume.milliliters, "L": UnitVolume.liters,
        "degC": UnitTemperature.celsius, "degF": UnitTemperature.fahrenheit,
        "ms": UnitDuration.milliseconds, "s": UnitDuration.seconds, "min": UnitDuration.minutes, "hr": UnitDuration.hours,
        "mmHg": UnitPressure.millimetersOfMercury, "mg/dL": UnitConcentrationMass.milligramsPerDeciliter,
        "m/s": UnitSpeed.metersPerSecond, "W": UnitPower.watts,
    ]

    /// 1.3K, 342, 20K — compact in every language, as the Health app's
    /// English UI shows them.
    /// One decimal, cut rather than rounded so a count never reads higher
    /// than it is: 342, 1.3K, 118.3K, 1.1M.
    static func compactCount(_ count: Int) -> String {
        let locale = Locale(identifier: "en_US")
        func scaled(_ divisor: Double, _ suffix: String) -> String {
            let value = (Double(count) / divisor * 10).rounded(.towardZero) / 10
            return value.formatted(.number.precision(.fractionLength(0 ... 1)).locale(locale)) + suffix
        }
        switch abs(count) {
        case ..<1000: return count.formatted(.number.locale(locale))
        case ..<1_000_000: return scaled(1000, "K")
        default: return scaled(1_000_000, "M")
        }
    }
}
