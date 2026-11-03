import Foundation
import HealthKit
import Observation

/// One type as the server holds it (GET /v1/types).
struct ServerType: Codable, Identifiable, Hashable, Sendable {
    let type: String
    let kind: String
    let count: Int
    let firstStartDate: String?
    let lastEndDate: String?

    var id: String { type }
    var lastEnd: Date? { lastEndDate.flatMap(ServerSample.parseDate) }
}

/// What the server holds, which is exactly what API clients see. Browse
/// shows this rather than the phone's own Health data (that's the Health
/// app's job). The last copy is kept on disk, so it can still be browsed
/// while the server is unreachable.
@Observable
@MainActor
final class ServerData {
    var types: [ServerType] = []
    var loadedAt: Date?
    /// Why the last refresh failed; nil once one succeeds.
    var error: String?
    @ObservationIgnored var directory: URL?

    private struct Cache: Codable {
        let types: [ServerType]
        let loadedAt: Date
    }

    private var cacheURL: URL? { directory?.appendingPathComponent("server-types.json") }

    func store(_ types: [ServerType]) {
        self.types = types
        loadedAt = Date()
        error = nil
        guard let cacheURL, let data = try? JSONEncoder().encode(Cache(types: types, loadedAt: loadedAt!)) else { return }
        try? data.write(to: cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func loadCache() {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL),
            let cache = try? JSONDecoder().decode(Cache.self, from: data)
        else { return }
        types = cache.types
        loadedAt = cache.loadedAt
    }

    func samples(in category: HealthCategory) -> Int {
        types.filter { HealthCategory.of($0.type) == category }.reduce(0) { $0 + $1.count }
    }
}

/// One sample as the server returns it, with display helpers. The JSON is
/// the wire format in docs/PROTOCOL.md.
struct ServerSample: Identifiable, Sendable {
    let json: JSON

    var id: String { json["uuid"]?.string ?? UUID().uuidString }
    var type: String { json["type"]?.string ?? "" }
    var start: Date? { json["startDate"]?.string.flatMap(Self.parseDate) }
    var end: Date? { json["endDate"]?.string.flatMap(Self.parseDate) }
    var sourceName: String? { json["sourceRevision"]?["source"]?["name"]?.string }

    /// "6,895", "72.5 kg", "18 %", "asleepREM", "牛肉面 · 4 samples".
    var value: String? {
        switch json["kind"]?.string {
        case "quantity":
            guard let number = json["quantity"]?["value"]?.number, let unit = json["quantity"]?["unit"]?.string else {
                return nil
            }
            return SampleFormat.wire(number, unit: unit)
        case "category":
            if type == HKCategoryTypeIdentifier.sleepAnalysis.rawValue,
                let stage = json["valueName"]?.string.flatMap(SleepStage.init(rawValue:))
            {
                return stage.title
            }
            return json["valueName"]?.string ?? json["value"]?.number.map { String(Int($0)) }
        case "correlation":
            let title = json["metadata"]?["HKFoodType"]?.string
            let count = json["objects"]?.array?.count ?? 0
            return [title, String(localized: "\(count) samples")].compactMap { $0 }.joined(separator: " · ")
        case "workout":
            let name = json["workoutActivityTypeName"]?.string ?? ""
            let minutes = Int(((json["duration"]?.number ?? 0) / 60).rounded())
            return "\(name) · \(minutes) min"
        case "stateOfMind":
            return json["valence"]?.number.map { "valence \($0.formatted(.number.precision(.fractionLength(0 ... 2))))" }
        case "electrocardiogram":
            return json["classification"]?.number.map { "classification \(Int($0))" }
        case "audiogram":
            let count = json["sensitivityPoints"]?.array?.count ?? 0
            return String(localized: "\(count) frequencies")
        case "scoredAssessment":
            return json["score"]?.number.map { String(localized: "Score \(Int($0))") }
        case "workoutRoute":
            return String(localized: "\(json["locations"]?.array?.count ?? 0) locations")
        case "heartbeatSeries":
            return String(localized: "\(json["beats"]?.array?.count ?? 0) beats")
        case "visionPrescription":
            return json["prescriptionType"]?.number == 2 ? String(localized: "Contacts") : String(localized: "Glasses")
        case "cdaDocument":
            return json["title"]?.string
        case "medicationDoseEvent":
            let dose = json["doseQuantity"]?.number.map { SampleFormat.wire($0, unit: json["unit"]?.string ?? "") }
            return [json["medicationName"]?.string, dose].compactMap { $0 }.joined(separator: " · ")
        default:
            return nil
        }
    }

    nonisolated static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }
}

extension HTTPUploader {
    func serverTypes(base: URL, token: String?) async throws -> [ServerType] {
        let (status, data) = try await request("GET", "/v1/types", base: base, token: token)
        guard status == 200 else { throw URLError(.badServerResponse) }
        struct Response: Decodable { let types: [ServerType] }
        return try JSONDecoder().decode(Response.self, from: data).types
    }

    /// Newest first; pass the returned cursor to continue.
    func serverSamples(
        base: URL, token: String?, type: String, limit: Int, cursor: String?
    ) async throws -> (samples: [ServerSample], next: String?) {
        var path = "/v1/samples?type=\(type)&order=desc&limit=\(limit)"
        if let cursor { path += "&cursor=\(cursor)" }
        let (status, data) = try await request("GET", path, base: base, token: token)
        guard status == 200 else { throw URLError(.badServerResponse) }
        struct Response: Decodable {
            let samples: [JSON]
            let nextCursor: String?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return (response.samples.map(ServerSample.init), response.nextCursor)
    }

    func wipeServerData(base: URL, token: String?) async throws {
        let (status, _) = try await request("DELETE", "/v1/data", base: base, token: token)
        guard status == 200 else { throw URLError(.badServerResponse) }
    }
}
