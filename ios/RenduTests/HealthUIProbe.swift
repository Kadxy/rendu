import Darwin
import HealthKit
import ObjectiveC
import UIKit
import XCTest

@testable import Rendu

/// Reads the Health app's own model on the device (HealthUI's
/// HKDisplayCategory and HKDisplayType): category colors and glyphs, and
/// every data type Health knows, to compare with Rendu's. Run with
/// TEST_RUNNER_RENDU_DUMP=1 on a device after each iOS update: the
/// test… methods fail when Health shows a new type or draws a category
/// differently.
final class HealthUIProbe: XCTestCase {
    private func load() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RENDU_DUMP"] != nil, "set TEST_RUNNER_RENDU_DUMP=1")
        XCTAssertNotNil(dlopen("/System/Library/PrivateFrameworks/HealthUI.framework/HealthUI", RTLD_NOW))
    }

    private func call(_ object: AnyObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    /// A key's value, or nil where the object doesn't have it (KVC raises).
    private func value(_ object: AnyObject, _ key: String) -> Any? {
        var result: Any?
        _ = RDCatchException { result = (object as? NSObject)?.value(forKey: key) }
        return result
    }

    /// The selectors of a class matching any of `words`, for finding what
    /// to read next.
    private func methods(_ cls: AnyClass, _ words: [String]) -> [String] {
        var count: UInt32 = 0
        guard let list = class_copyMethodList(cls, &count) else { return [] }
        defer { free(list) }
        return (0 ..< Int(count)).map { NSStringFromSelector(method_getName(list[$0])) }
            .filter { name in words.contains { name.localizedCaseInsensitiveContains($0) } }
            .sorted()
    }

    private func rgba(_ color: UIColor, dark: Bool) -> String {
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%.3f,%.3f,%.3f,%.2f", r, g, b, a)
    }

    func testCategories() throws {
        try load()
        guard let cls = NSClassFromString("HKDisplayCategory") as? NSObject.Type,
            let all = cls.perform(NSSelectorFromString("allCategories"))?.takeUnretainedValue() as? [AnyObject]
        else {
            return XCTFail("no categories")
        }
        print("PROBEMETHODS HKDisplayCategory \(methods(cls, ["image", "color", "fill", "symbol"]).joined(separator: " "))")
        for category in all {
            let id = (category.value(forKey: "categoryID") as? Int) ?? -1
            let name = category.value(forKey: "displayName") as? String ?? "?"
            let symbol = category.value(forKey: "systemImageName") as? String ?? "?"
            let color = category.value(forKey: "color") as? UIColor
            let fill = category.value(forKey: "fillStyle").map { "\($0)" } ?? "-"
            let multi = call(category, "multiColorImageConfiguration").map { "\($0)" } ?? "nil"
            let top = (category.value(forKey: "isTopLevelCategory") as? Bool) ?? false
            let app = (category.value(forKey: "isHealthAppCategory") as? Bool) ?? false
            print(
                "PROBECAT \(id)|\(name)|\(symbol)|light \(color.map { rgba($0, dark: false) } ?? "-")|dark \(color.map { rgba($0, dark: true) } ?? "-")|top \(top)|app \(app)|multi \(multi)|fill \(fill)"
            )
            // The colors the multicolor configuration draws with, if any.
            if let config = call(category, "multiColorImageConfiguration") as? AnyObject {
                for key in ["_colors", "colors", "paletteColors", "_paletteColors", "renderingStyle", "_renderingStyle"] {
                    if let colors = value(config, key) as? [UIColor] {
                        print(
                            "PROBECATCOLORS \(id)|\(key)|\(colors.map { rgba($0, dark: false) + "/" + rgba($0, dark: true) }.joined(separator: " "))"
                        )
                    } else if let other = value(config, key) {
                        print("PROBECATCONFIG \(id)|\(key)|\(other)")
                    }
                }
            }
            // The image Health draws (its symbol name and configuration).
            for selector in ["systemImage", "_image"] {
                if let image = call(category, selector) {
                    print("PROBECATIMAGE \(id)|\(selector)|\(image)")
                }
            }
            // Which system color it is, if any.
            if let color {
                let system: [(String, UIColor)] = [
                    ("red", .systemRed), ("orange", .systemOrange), ("yellow", .systemYellow), ("green", .systemGreen),
                    ("mint", .systemMint), ("teal", .systemTeal), ("cyan", .systemCyan), ("blue", .systemBlue),
                    ("indigo", .systemIndigo), ("purple", .systemPurple), ("pink", .systemPink), ("gray", .systemGray),
                ]
                let match = system.first {
                    rgba($0.1, dark: false) == rgba(color, dark: false) && rgba($0.1, dark: true) == rgba(color, dark: true)
                }
                print("PROBECATSYSTEM \(id)|\(match?.0 ?? "none")")
            }
            for key in [
                "listIconColor", "iconColor", "backgroundColor", "lightColor", "darkColor", "colorForListIcon", "keyColor",
            ] {
                if let other = value(category, key) as? UIColor {
                    print("PROBECATCOLOR \(id)|\(key)|\(rgba(other, dark: false))/\(rgba(other, dark: true))")
                }
            }
        }
    }

    /// Rendu draws each category as Health does: the same symbol and color,
    /// light and dark. Fails when an iOS update changes Health's.
    func testCategoriesMatchHealth() throws {
        try load()
        guard let cls = NSClassFromString("HKDisplayCategory") as? NSObject.Type,
            let all = cls.perform(NSSelectorFromString("allCategories"))?.takeUnretainedValue() as? [AnyObject]
        else {
            return XCTFail("no categories")
        }
        let health = Dictionary(
            all.compactMap { category in
                (category.value(forKey: "categoryID") as? Int).map { ($0, category) }
            }, uniquingKeysWith: { first, _ in first })
        for category in HealthCategory.allCases {
            guard let theirs = health[category.healthCategoryID] else {
                XCTFail("\(category): Health has no category \(category.healthCategoryID)")
                continue
            }
            XCTAssertEqual(category.symbol, theirs.value(forKey: "systemImageName") as? String, "\(category) symbol")
            if let color = theirs.value(forKey: "color") as? UIColor {
                for dark in [false, true] {
                    XCTAssertEqual(rgba(category.uiColor, dark: dark), rgba(color, dark: dark), "\(category) color, dark \(dark)")
                }
            }
        }
    }

    /// Every type Health shows that third-party apps can read is in the
    /// catalog. Health's other types are private, need per-object or
    /// clinical-records authorization, or come in another form (KNOWN).
    func testCatalogCoversHealth() throws {
        try load()
        guard let cls = NSClassFromString("HKDisplayType") as? NSObject.Type,
            let all = cls.perform(NSSelectorFromString("builtinDisplayTypes"))?.takeUnretainedValue() as? [AnyObject]
        else {
            return XCTFail("no display types")
        }
        let ours = Set(TypeCatalog.all.map(\.key)).union(Self.known)
        for type in all {
            guard let object = (call(type, "objectType") ?? call(type, "sampleType")) as? HKObjectType,
                !ours.contains(object.identifier)
            else { continue }
            // A public type: its identifier is one the SDK's types accept.
            XCTFail("Health shows \(object.identifier), which Rendu doesn't read")
        }
    }

    /// Health types Rendu doesn't read as samples, and why.
    private static let known: Set<String> = [
        // Uploaded as characteristics and activity summaries.
        "HKCharacteristicTypeIdentifierBiologicalSex", "HKCharacteristicTypeIdentifierDateOfBirth",
        "HKCharacteristicTypeIdentifierBloodType", "HKCharacteristicTypeIdentifierFitzpatrickSkinType",
        "HKCharacteristicTypeIdentifierWheelchairUse", "HKCharacteristicTypeIdentifierActivityMoveMode",
        "HKActivitySummaryTypeIdentifier",
        // Per-object authorization (each prescription, each medication).
        "HKVisionPrescriptionTypeIdentifier", "HKMedicationDoseEventTypeIdentifierMedicationDoseEvent",
        "HKDataTypeUserAnnotatedMedicationConcept",
        // Health records: need the clinical records entitlement.
        "HKDocumentTypeIdentifierCDA", "HKClinicalTypeIdentifierAllergyRecord", "HKClinicalTypeIdentifierConditionRecord",
        "HKClinicalTypeIdentifierImmunizationRecord", "HKClinicalTypeIdentifierLabResultRecord",
        "HKClinicalTypeIdentifierMedicationRecord", "HKClinicalTypeIdentifierProcedureRecord",
        "HKClinicalTypeIdentifierVitalSignRecord", "HKClinicalTypeIdentifierCoverageRecord",
        "HKClinicalTypeIdentifierClinicalNoteRecord",
        // Private: no public identifier in the SDK.
        "HKCharacteristicTypeIdentifierCardioFitnessMedicationsUse", "HKCharacteristicTypeIdentifierEthnicity",
        "HKDataTypeSleepDurationGoal", "HKDataTypeSleepSchedule", "HKDataTypeAppleSleepScore",
        "HKDataTypeAppleBalanceMetrics", "HKDataTypeOverheadSquat", "HKDataTypeIdentifierSurveyResponse",
        "HKQuantityTypeIdentifierHypertensivePatternMeasurement", "HKQuantityTypeIdentifierHeartRateVariabilityRMSSD",
        "HKQuantityTypeIdentifierHipCircumference", "HKQuantityTypeIdentifierStandardPushUpCount",
        "HKQuantityTypeIdentifierKneeBasedPushUpCount", "HKQuantityTypeIdentifierPlankTime",
        "HKQuantityTypeIdentifierFiveTimesSitToStandTime", "HKBilateralQuantityTypeIdentifierElbowFlexion",
        "HKBilateralQuantityTypeIdentifierKneeFlexion", "HKBilateralQuantityTypeIdentifierAnkleDorsiflexion",
        "HKBilateralQuantityTypeIdentifierShoulderFlexion", "HKBilateralQuantityTypeIdentifierHipFlexionKneeFlexion",
        "HKBilateralQuantityTypeIdentifierHipFlexionKneeExtension", "HKBilateralQuantityTypeIdentifierSingleLegStanceTime",
        "HKMedicalHistoryTypeIdentifierMedicalHistoryAllergyRecord",
        "HKMedicalHistoryTypeIdentifierMedicalHistoryHealthConcernRecord",
        "HKMedicalHistoryTypeIdentifierMedicalHistoryProcedureRecord",
        "HKMedicalHistoryTypeIdentifierMedicalHistoryImmunizationRecord",
        "HKMedicalHistoryTypeIdentifierMedicalHistoryLabResultRecord",
        "HKMedicalHistoryTypeIdentifierMedicalHistoryQuantitativeLabResultRecord",
    ]

    func testDisplayTypes() throws {
        try load()
        guard let cls = NSClassFromString("HKDisplayType") as? NSObject.Type,
            let all = cls.perform(NSSelectorFromString("builtinDisplayTypes"))?.takeUnretainedValue() as? [AnyObject]
        else {
            return XCTFail("no display types")
        }
        print("PROBEMETHODS HKDisplayType \(methods(cls, ["statistic", "chart", "aggregat"]).joined(separator: " "))")
        let ours = Set(TypeCatalog.all.map(\.key))
        var theirs: [String] = []
        for type in all {
            let object = (call(type, "objectType") ?? call(type, "sampleType")) as? HKObjectType
            let category = (type.value(forKey: "categoryIdentifier") as? Int) ?? -1
            let identifier = object?.identifier ?? "?"
            theirs.append(identifier)
            let mark = ours.contains(identifier) ? "ok" : "MISSING"
            print("PROBETYPE \(mark)|\(identifier)|category \(category)")
        }
        for key in ours.subtracting(theirs).sorted() {
            print("PROBETYPE ONLYOURS|\(key)")
        }
    }

    /// Which object types HealthKit shares object by object
    /// (requiresPerObjectAuthorization): Rendu asks for these on their own
    /// pages (PerObjectAccess). Every type HealthKit has, not just Rendu's.
    func testPerObjectTypes() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RENDU_DUMP"] != nil, "set TEST_RUNNER_RENDU_DUMP=1")
        var types: [HKObjectType] = TypeCatalog.all.map(\.sampleType)
        types += Array(TypeCatalog.characteristicTypes)
        types += [
            HKObjectType.activitySummaryType(), HKObjectType.userAnnotatedMedicationType(),
            HKObjectType.medicationDoseEventType(), HKObjectType.visionPrescriptionType(), HKDocumentType(.CDA),
            HKObjectType.audiogramSampleType(), HKObjectType.electrocardiogramType(),
        ]
        for identifier in [
            HKClinicalTypeIdentifier.allergyRecord, .conditionRecord, .immunizationRecord, .labResultRecord,
            .medicationRecord, .procedureRecord, .vitalSignRecord, .coverageRecord, .clinicalNoteRecord,
        ] {
            types.append(HKClinicalType(identifier))
        }
        let perObject = Set(types.filter { $0.requiresPerObjectAuthorization() }.map(\.identifier))
        print("PROBEPEROBJECT \(perObject.sorted().joined(separator: " "))")
        let expected = Set(PerObjectAccess.allCases.map(\.objectType.identifier))
        XCTAssertTrue(
            // Dose events come with medications; clinical documents aren't read.
            perObject.isSubset(
                of: expected.union([HKObjectType.medicationDoseEventType().identifier, HKDocumentType(.CDA).identifier])),
            "per-object types Rendu doesn't ask for: \(perObject.subtracting(expected))")
    }
}
