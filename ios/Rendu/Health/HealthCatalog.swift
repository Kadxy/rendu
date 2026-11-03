import Foundation
import HealthKit

/// What this iPhone's HealthKit has, for the server's schema (PUT
/// /v1/catalog): each type Rendu reads, with Apple's name, the unit Rendu
/// reads it in and the user's own, how it aggregates, its values, its
/// duration limits, and whether it's shared object by object. With the SDK's
/// definitions on the server, an agent can look up exactly how to write a
/// type, from what this iPhone actually supports.
enum HealthCatalog {
    static func json(_ store: HKHealthStore) async -> JSON {
        let quantities = TypeCatalog.all.compactMap { $0.sampleType as? HKQuantityType }
        let preferred = (try? await store.preferredUnits(for: Set(quantities))) ?? [:]
        var types: [JSON] = []
        for type in TypeCatalog.all {
            let sampleType = type.sampleType
            var entry: [String: JSON] = ["type": .string(type.key), "kind": .string(type.kind.rawValue)]
            var name: [String: JSON] = [:]
            if let en = DisplayNames.en[type.key] { name["en"] = .string(en) }
            if let zh = DisplayNames.zhHans[type.key] { name["zh-Hans"] = .string(zh) }
            if !name.isEmpty { entry["name"] = .object(name) }
            if let quantity = sampleType as? HKQuantityType {
                if let unit = TypeCatalog.unit(for: quantity) { entry["unit"] = .string(unit.unitString) }
                if let unit = preferred[quantity] { entry["preferredUnit"] = .string(unit.unitString) }
                entry["aggregation"] = .string(aggregation(quantity.aggregationStyle))
            }
            if let values = TypeCatalog.values(for: type.key) {
                entry["values"] = .array(
                    (0 ... 16).compactMap { raw in
                        values.name(raw).map { ["value": .number(Double(raw)), "name": .string($0)] }
                    })
            }
            if sampleType.isMinimumDurationRestricted {
                entry["minimumDuration"] = .number(sampleType.minimumAllowedDuration)
            }
            if sampleType.isMaximumDurationRestricted {
                entry["maximumDuration"] = .number(sampleType.maximumAllowedDuration)
            }
            if sampleType.requiresPerObjectAuthorization() {
                entry["perObject"] = true
            }
            types.append(.object(entry))
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return [
            "os": .string("\(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : "")),
            "types": .array(types),
        ]
    }

    private static func aggregation(_ style: HKQuantityAggregationStyle) -> String {
        switch style {
        case .cumulative: "cumulative"
        case .discreteArithmetic: "discreteArithmetic"
        case .discreteTemporallyWeighted: "discreteTemporallyWeighted"
        case .discreteEquivalentContinuousLevel: "discreteEquivalentContinuousLevel"
        @unknown default: "discrete"
        }
    }
}
