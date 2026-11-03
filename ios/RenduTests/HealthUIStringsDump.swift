import XCTest

/// One-off: prints Apple's own strings from the Health frameworks on the
/// device (they aren't on the Mac), for baking into HealthUIStrings.
final class HealthUIStringsDump: XCTestCase {
    /// Run with TEST_RUNNER_RENDU_DUMP=1 xcodebuild test … on a device.
    func testDump() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RENDU_DUMP"] != nil, "set TEST_RUNNER_RENDU_DUMP=1 to dump")
        let wanted: Set<String> = [
            "Activity", "Body Measurements", "Cycle Tracking", "Hearing", "Heart", "Medications", "Mental Wellbeing",
            "Mobility", "Nutrition", "Respiratory", "Sleep", "Symptoms", "Vitals", "Other Data", "Health Categories",
            "Awake", "REM", "Core", "Deep", "In Bed", "Asleep", "Unspecified", "Sample Details", "Device Details",
            "Source Details", "All Recorded Data", "Date Added to Health", "Time Zone", "Start Time", "End Time",
            "Source", "Details", "Browse", "Summary", "Search", "Show All Data", "Date",
        ]
        let root = URL(fileURLWithPath: "/System/Library/PrivateFrameworks")
        let frameworks = [
            "HealthUI", "HealthExperienceUI", "HealthToolbox", "HealthDomainsUI", "HealthRecordsUI",
            "HealthPlatform", "HealthExperience", "HealthAppServicesUI", "SleepHealthUI",
        ]
        for framework in frameworks {
            let dir = root.appendingPathComponent("\(framework).framework")
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            let tables = files.filter { $0.pathExtension == "loctable" }
            print("DUMP framework \(framework): \(files.count) files, \(tables.count) loctables")
            for table in tables {
                guard let data = try? Data(contentsOf: table),
                    let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                    let en = plist["en"] as? [String: Any]
                else { continue }
                let zh = plist["zh_CN"] as? [String: Any] ?? plist["zh-Hans"] as? [String: Any] ?? [:]
                for (key, value) in en {
                    if !(value is String), "\(value)".lowercased().contains("interval") || key.contains("INTERVAL_COUNT") {
                        print(
                            "DUMPDICT \(framework)/\(table.lastPathComponent) \(key) = \(value) | \(zh[key].map { "\($0)" } ?? "-")"
                        )
                    }
                    guard let value = value as? String else { continue }
                    let lower = value.lowercased()
                    if wanted.contains(value) || lower.contains("interval") {
                        let zhValue = zh[key].map { "\($0)" } ?? "-"
                        print(
                            "DUMP \(framework)/\(table.lastPathComponent) \(key) = \(value.debugDescription) | \(zhValue.debugDescription)"
                        )
                    }
                }
            }
        }
    }
}
