import Foundation

/// Made-up data for screenshots: `devicectl … process launch <bundle ID> --
/// -rendu-demo` (with `-rendu-demo-open write` to open an update's details).
/// Everything lives apart from the real app's: its own folder (and owner
/// key), its own UserDefaults, and a server answered in-process
/// (DemoServer). Nothing reads or writes Apple Health, nothing syncs.
enum Demo {
    nonisolated static let isOn = ProcessInfo.processInfo.arguments.contains("-rendu-demo")

    nonisolated static let server = URL(string: "https://rendu.example.com")!

    nonisolated static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("RenduDemo", isDirectory: true)
    }

    nonisolated static let defaults = UserDefaults(suiteName: "rendu.demo")!

    /// The record `-rendu-demo-open write` opens: the lunch, corrected.
    nonisolated static let updateID = "5B0E8C21-4D7A-4F3B-9E61-0A2C7D9F4B18"

    /// A fresh folder and defaults with the made-up history in them.
    static func prepare() -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: root)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defaults.removePersistentDomain(forName: "rendu.demo")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(writes).write(to: root.appendingPathComponent("writes.json"))
        defaults.set(try? JSONEncoder().encode(activities), forKey: "status.activities")
        defaults.set(Date().addingTimeInterval(-40), forKey: "status.lastSyncAt")
        try? JSONEncoder().encode(OwnerKey.Pairing(server: server, key: "demo"))
            .write(to: root.appendingPathComponent("owner.key"))
        return root
    }

    private static func ago(_ minutes: Double) -> Date { Date().addingTimeInterval(-minutes * 60) }

    private static let coach = (name: "Health Coach", id: "7C1D93A0")

    /// Newest first, as the log keeps them.
    private static var chinese: Bool { Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true }

    private enum ID {
        static let lunch = "8E2C4F1A-6B3D-4C7E-9A15-2F7D8B6C0E41"
        static let lunchAdded = "9D2F6A40-E85B-4C17-B3A9-5F0C1E7D2A86"
        static let run = "C7A41F06-2B9E-4D85-A3F2-6E1B08D5C94A"
        static let pressure = "5D81B3E9-0C2A-4F67-B4D8-93E6A1F05C27"
        static let mindfulDeleted = "3A6C9E15-0F48-4B2D-A7E3-D91B5C2F8064"
        static let mindful = "E41B7D93-6C2A-4F80-9D35-27A8F0B6C1E5"
        static let mood = "7F2D0A68-B3E1-4C59-8A16-C4E9D27B0F31"
    }

    /// Newest first, as the log keeps them: a lunch logged and then
    /// corrected, a run, a blood pressure reading, and older entries.
    private static var writes: [WriteRecord] {
        let food = "HKCorrelationTypeIdentifierFood"
        let energy = "HKQuantityTypeIdentifierDietaryEnergyConsumed"
        let protein = "HKQuantityTypeIdentifierDietaryProtein"
        let carbs = "HKQuantityTypeIdentifierDietaryCarbohydrates"
        let fat = "HKQuantityTypeIdentifierDietaryFatTotal"
        let mindful = "HKCategoryTypeIdentifierMindfulSession"
        let minutes = Duration.seconds(600).formatted(.units(allowed: [.minutes], width: .abbreviated))
        let lunch = chinese ? "午餐：鸡肉沙拉" : "Lunch: chicken salad"
        func record(
            _ id: String, _ minutes: Double, _ action: WriteRecord.Action, _ sync: String, _ type: String,
            _ items: [(String, String)], title: String? = nil, outcome: WriteRecord.Outcome = .written,
            error: String? = nil, sample: Double? = nil
        ) -> WriteRecord {
            WriteRecord(
                id: id, date: ago(minutes), action: action, syncIdentifier: sync, type: type, title: title,
                items: items.map { .init(type: $0.0, value: $0.1) }, outcome: outcome, error: error,
                submittedBy: coach.name, submittedByID: coach.id,
                uuids: outcome == .written ? items.indices.map { "\(id)-\($0)" } + ["\(id)-x"] : nil,
                sampleDate: sample.map(ago) ?? ago(minutes))
        }
        return [
            record(
                updateID, 6, .update, ID.lunch, food,
                [(energy, "480 kcal"), (protein, "34 g"), (carbs, "38 g"), (fat, "22 g")], title: lunch, sample: 70),
            record(
                ID.run, 7, .create, "62D9B0F7-1E4C-4A83-B5D2-9C7A0E3F6B18", "HKWorkoutTypeIdentifier",
                [
                    ("HKQuantityTypeIdentifierActiveEnergyBurned", "412 kcal"),
                    ("HKQuantityTypeIdentifierDistanceWalkingRunning", "5.2 km"),
                ],
                sample: 95),
            record(
                ID.lunchAdded, 49, .create, ID.lunch, food,
                [(energy, "560 kcal"), (protein, "34 g"), (carbs, "52 g"), (fat, "22 g")], title: lunch, sample: 70),
            record(
                ID.pressure, 50, .create, "A1F4C8E2-5D37-4B9A-8C60-3E2D7F1B9A54", "HKCorrelationTypeIdentifierBloodPressure",
                [
                    ("HKQuantityTypeIdentifierBloodPressureSystolic", "118 mmHg"),
                    ("HKQuantityTypeIdentifierBloodPressureDiastolic", "76 mmHg"),
                ]),
            record(ID.mindfulDeleted, 60 * 20, .delete, "4C7B1E9A-8D26-4F3E-A0B5-71F9C2E8D643", mindful, [(mindful, minutes)]),
            record(ID.mindful, 60 * 21, .create, "4C7B1E9A-8D26-4F3E-A0B5-71F9C2E8D643", mindful, [(mindful, minutes)]),
            record(ID.mood, 60 * 22, .create, "B95E3D07-2A6F-4C18-8E4B-D3A7F0C95E21", "HKDataTypeStateOfMind", []),
        ]
    }

    private static var activities: [Activity] {
        let name = { (id: String) in writes.first { $0.id == id }?.headline ?? "" }
        return [
            Activity(
                date: ago(6), saved: 2, names: [name(updateID), name(ID.run)], uploaded: 11,
                uploadedTypes: ["HKCorrelationTypeIdentifierFood": 5, "HKWorkoutTypeIdentifier": 6]),
            Activity(
                date: ago(38), uploaded: 1284,
                uploadedTypes: [
                    "HKQuantityTypeIdentifierHeartRate": 702, "HKQuantityTypeIdentifierStepCount": 311,
                    "HKQuantityTypeIdentifierActiveEnergyBurned": 190, "HKCategoryTypeIdentifierSleepAnalysis": 46,
                    "HKQuantityTypeIdentifierRespiratoryRate": 35,
                ]),
            Activity(
                date: ago(48), saved: 2, names: [name(ID.lunchAdded), name(ID.pressure)],
                uploaded: 8, uploadedTypes: ["HKCorrelationTypeIdentifierFood": 5, "HKCorrelationTypeIdentifierBloodPressure": 3]),
            Activity(date: ago(60 * 20), deleted: 1, names: [name(ID.mindfulDeleted)]),
        ]
    }

    /// What the made-up server holds: (type, kind, samples).
    nonisolated static let types: [(String, String, Int)] = [
        ("HKQuantityTypeIdentifierStepCount", "quantity", 184_220),
        ("HKQuantityTypeIdentifierDistanceWalkingRunning", "quantity", 171_904),
        ("HKQuantityTypeIdentifierActiveEnergyBurned", "quantity", 402_118),
        ("HKQuantityTypeIdentifierBasalEnergyBurned", "quantity", 298_331),
        ("HKQuantityTypeIdentifierAppleExerciseTime", "quantity", 21_455),
        ("HKQuantityTypeIdentifierFlightsClimbed", "quantity", 9_870),
        ("HKQuantityTypeIdentifierHeartRate", "quantity", 512_904),
        ("HKQuantityTypeIdentifierRestingHeartRate", "quantity", 1_012),
        ("HKQuantityTypeIdentifierHeartRateVariabilitySDNN", "quantity", 8_740),
        ("HKQuantityTypeIdentifierWalkingHeartRateAverage", "quantity", 988),
        ("HKQuantityTypeIdentifierVO2Max", "quantity", 214),
        ("HKQuantityTypeIdentifierOxygenSaturation", "quantity", 6_420),
        ("HKQuantityTypeIdentifierRespiratoryRate", "quantity", 30_118),
        ("HKQuantityTypeIdentifierBodyTemperature", "quantity", 12),
        ("HKQuantityTypeIdentifierBloodPressureSystolic", "quantity", 48),
        ("HKQuantityTypeIdentifierBloodPressureDiastolic", "quantity", 48),
        ("HKCorrelationTypeIdentifierBloodPressure", "correlation", 48),
        ("HKQuantityTypeIdentifierHeight", "quantity", 3),
        ("HKQuantityTypeIdentifierWalkingSpeed", "quantity", 40_225),
        ("HKQuantityTypeIdentifierWalkingStepLength", "quantity", 40_190),
        ("HKQuantityTypeIdentifierEnvironmentalAudioExposure", "quantity", 61_377),
        ("HKQuantityTypeIdentifierHeadphoneAudioExposure", "quantity", 18_502),
        ("HKCategoryTypeIdentifierSleepAnalysis", "category", 24_806),
        ("HKCategoryTypeIdentifierMindfulSession", "category", 132),
        ("HKCorrelationTypeIdentifierFood", "correlation", 1_206),
        ("HKQuantityTypeIdentifierDietaryEnergyConsumed", "quantity", 1_206),
        ("HKQuantityTypeIdentifierDietaryProtein", "quantity", 1_180),
        ("HKQuantityTypeIdentifierDietaryCarbohydrates", "quantity", 1_180),
        ("HKQuantityTypeIdentifierDietaryFatTotal", "quantity", 1_174),
        ("HKQuantityTypeIdentifierDietaryWater", "quantity", 2_390),
        ("HKCategoryTypeIdentifierAppleStandHour", "category", 14_208),
        ("HKDataTypeStateOfMind", "stateOfMind", 87),
        ("HKWorkoutTypeIdentifier", "workout", 642),
        ("HKWorkoutRouteTypeIdentifier", "workoutRoute", 410),
    ]
}

/// The made-up server: answers the requests the app makes, in-process.
final class DemoServer: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == Demo.server.host() }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url?.path() ?? ""
        let now = ISO8601DateFormatter().string(from: Date())
        let body: Any
        var status = 200
        switch path {
        case "/v1/health":
            body = ["ok": true]
        case "/v1/status":
            body = ["version": "0.1.0", "samples": 2_712_458, "types": Demo.types.count, "pendingWrites": 0, "lastIngestAt": now]
        case "/v1/types":
            body = [
                "types": Demo.types.map {
                    ["type": $0.0, "kind": $0.1, "count": $0.2, "firstStartDate": "2019-05-02T08:00:00Z", "lastEndDate": now]
                }
            ]
        case "/v1/keys":
            body = [
                "keys": [
                    [
                        "id": "0A11CE00", "name": "This iPhone", "scope": "owner", "createdAt": "2026-10-01T08:00:00Z",
                        "lastUsedAt": now,
                    ],
                    [
                        "id": "7C1D93A0", "name": "Health Coach", "scope": "readwrite", "createdAt": "2026-10-02T08:00:00Z",
                        "lastUsedAt": now,
                    ],
                    [
                        "id": "52B8E461", "name": "Weekly Report", "scope": "read", "createdAt": "2026-10-09T08:00:00Z",
                        "lastUsedAt": "2026-11-02T21:00:00Z",
                    ],
                ]
            ]
        case "/v1/writes":
            body = ["writes": []]
        default:
            status = 404
            body = ["error": "not in the demo"]
        }
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
