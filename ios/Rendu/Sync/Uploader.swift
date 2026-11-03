import Foundation

struct UploadResult: Sendable {
    let status: Int
    let bodySnippet: String
    let duration: TimeInterval

    var isSuccess: Bool { (200 ..< 300).contains(status) }
}

protocol Uploading: Sendable {
    func send(
        _ body: Data, gzipped: Bool, method: String, to url: URL, token: String?,
        headers: [String: String]
    ) async throws -> UploadResult
}

struct HTTPUploader: Uploading {
    private let session: URLSession

    /// This iPhone's key.
    static func authorize(_ request: inout URLRequest, token: String?) {
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false  // fail fast; the outbox owns retries
        if Demo.isOn { configuration.protocolClasses = [DemoServer.self] }
        session = URLSession(configuration: configuration)
    }

    func send(
        _ body: Data, gzipped: Bool, method: String, to url: URL, token: String?,
        headers: [String: String]
    ) async throws -> UploadResult {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if gzipped {
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        }
        HTTPUploader.authorize(&request, token: token)
        let started = Date()
        let (data, response) = try await session.upload(for: request, from: body)
        return UploadResult(
            status: (response as? HTTPURLResponse)?.statusCode ?? 0,
            bodySnippet: String(decoding: data.prefix(300), as: UTF8.self),
            duration: Date().timeIntervalSince(started)
        )
    }

    /// Plain JSON request to the server (the write queue).
    func request(_ method: String, _ path: String, base: URL, token: String?, body: Data? = nil) async throws -> (Int, Data) {
        // `path` may carry a query string; appending(path:) would escape "?".
        guard let url = URL(string: base.absoluteString + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        HTTPUploader.authorize(&request, token: token)
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// GET /v1/anchors — this iPhone's sync progress as the server holds
    /// it, archived anchors by type. nil when the server can't say (offline,
    /// or a server without the endpoint).
    func serverAnchors(base: URL, token: String?) async -> [String: Data]? {
        var request = URLRequest(url: base.appending(path: "/v1/anchors"))
        request.timeoutInterval = 15
        HTTPUploader.authorize(&request, token: token)
        guard let (data, response) = try? await session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data),
            let anchors = decoded["anchors"]
        else { return nil }
        return anchors.compactMapValues { Data(base64Encoded: $0) }
    }

    /// PUT /v1/anchors — sets this iPhone's sync progress on the server.
    func replaceServerAnchors(base: URL, token: String?, _ anchors: [String: Data]) async -> Bool {
        guard let body = try? JSONEncoder().encode(["anchors": anchors.mapValues { $0.base64EncodedString() }]),
            let result = try? await send(
                body, gzipped: false, method: "PUT",
                to: base.appending(path: "/v1/anchors"), token: token, headers: [:])
        else { return false }
        return result.isSuccess
    }
}

/// GET /v1/status as the device sees it.
struct ServerStatus: Decodable, Equatable, Sendable {
    let version: String?
    let samples: Int
    let types: Int?
    let pendingWrites: Int
    let lastIngestAt: String?

    var lastIngest: Date? { lastIngestAt.flatMap(ServerSample.parseDate) }
}

/// The server answered 401: it no longer accepts this iPhone's key (another
/// iPhone paired, or the server's data was replaced).
struct KeyRejected: Error {}

/// A credential as the server lists it (GET /v1/keys); never the key.
struct APIKey: Decodable, Identifiable, Equatable, Sendable {
    enum Scope: String, Codable, Sendable {
        case owner, read, readwrite
    }

    let id: String
    let name: String
    let scope: Scope
    let createdAt: String
    let lastUsedAt: String?

    var lastUsed: Date? { lastUsedAt.flatMap(ServerSample.parseDate) }
    var created: Date? { ServerSample.parseDate(createdAt) }
}

/// One request an API key made (GET /v1/keys/{id}/activity), as the
/// server recorded it.
struct APIActivity: Decodable, Identifiable, Equatable, Sendable {
    let at: String
    let method: String
    let path: String
    let type: String?
    let start: String?
    let end: String?
    let interval: String?
    let count: Int?
    let writeId: String?
    let status: Int

    var id: String { "\(at)|\(method)|\(path)|\(type ?? "")" }
    var date: Date? { ServerSample.parseDate(at) }
    var refused: Bool { status >= 400 }

    /// What it was about: the data type by Apple's name, or the endpoint.
    var title: String {
        if let type {
            // Several types of a change feed come comma-separated.
            return type.split(separator: ",").map { DisplayNames.name(forKey: String($0)) }.formatted(.list(type: .and))
        }
        switch path {
        case "/v1/status": return String(localized: "Server Status")
        case "/v1/types": return String(localized: "Data Types")
        case "/v1/activity": return DisplayNames.name(forKey: "activitySummary")
        case "/v1/characteristics": return String(localized: "Characteristics")
        case "/v1/writes", "/v1/writes/{id}": return String(localized: "Write Status")
        case "/v1/authorization": return String(localized: "Write Access")
        case "/v1/medications": return String(localized: "Medications")
        case "/v1/changes": return String(localized: "All Types")
        default: return path
        }
    }

    /// "Read 1,234 samples · Nov 1 – 7", "Submitted an entry", "Refused (403)".
    var detail: String {
        if refused { return String(localized: "Refused (HTTP \(status))") }
        let n = count ?? 0
        let what: AttributedString =
            switch (method, path) {
            case ("GET", "/v1/samples"): AttributedString(localized: "Read ^[\(n) sample](inflect: true)")
            case ("GET", "/v1/statistics"): AttributedString(localized: "Read ^[\(n) statistic](inflect: true)")
            case ("GET", "/v1/activity"): AttributedString(localized: "Read ^[\(n) day](inflect: true)")
            case ("GET", "/v1/changes"): AttributedString(localized: "Read ^[\(n) change](inflect: true)")
            case ("GET", "/v1/writes"): AttributedString(localized: "Read ^[\(n) write](inflect: true)")
            case ("POST", "/v1/writes"): AttributedString(localized: "Submitted an entry")
            default: AttributedString(localized: "Read")
            }
        var parts = [String(what.characters)]
        if let range { parts.append(range) }
        return parts.joined(separator: " · ")
    }

    private var range: String? {
        let from = start.flatMap(ServerSample.parseDate)
        let to = end.flatMap(ServerSample.parseDate)
        let style = Date.IntervalFormatStyle(date: .abbreviated, time: .omitted)
        switch (from, to) {
        case (let from?, let to?) where from <= to: return (from ..< to).formatted(style)
        case (let from?, nil): return String(localized: "Since \(from.formatted(date: .abbreviated, time: .omitted))")
        case (nil, let to?): return String(localized: "Until \(to.formatted(date: .abbreviated, time: .omitted))")
        default: return nil
        }
    }

    /// For entries without a data type.
    var symbol: String {
        switch path {
        case "/v1/status": "server.rack"
        case "/v1/types", "/v1/changes": "square.grid.2x2"
        case "/v1/characteristics": "person.crop.circle"
        case "/v1/writes", "/v1/writes/{id}": "square.and.arrow.down"
        case "/v1/authorization": "lock.open"
        case "/v1/medications": "pills"
        default: "network"
        }
    }
}

/// A write the server holds for this iPhone that hasn't run yet.
struct QueuedWrite: Decodable, Identifiable, Equatable, Sendable {
    struct Submitter: Decodable, Equatable, Sendable {
        let id: String
        let name: String
    }

    let id: String
    let op: String
    let syncIdentifier: String
    let object: JSON?
    let createdAt: String
    let submittedBy: Submitter?

    var created: Date? { ServerSample.parseDate(createdAt) }
    var type: String? { object?["type"]?.string }
    var foodName: String? { object?["metadata"]?["HKFoodType"]?.string }
}

enum PairResult: Equatable, Sendable {
    case paired
    /// The code hasn't been entered on the server yet (or it expired).
    case waiting
    /// The server has a different code.
    case wrongCode
    /// The server answered, but doesn't know pairing (an older version).
    case unsupported
    /// The request didn't get through; worth asking again.
    case unreachable
}

enum ServerCheck: Equatable, Sendable {
    case ok
    /// Something answered, but not a Rendu server.
    case notRendu
    case unreachable(String)
}

extension HTTPUploader {
    func serverStatus(base: URL, token: String?) async throws -> ServerStatus {
        let (status, data) = try await request("GET", "/v1/status", base: base, token: token)
        if status == 401 { throw KeyRejected() }
        guard status == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(ServerStatus.self, from: data)
    }

    /// GET /v1/health: whether a Rendu server answers at this address.
    func check(base: URL) async -> ServerCheck {
        do {
            let (status, data) = try await request("GET", "/v1/health", base: base, token: nil)
            struct Health: Decodable { let ok: Bool }
            guard status == 200, (try? JSONDecoder().decode(Health.self, from: data))?.ok == true else { return .notRendu }
            return .ok
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    /// POST /v1/pair: presents the code this iPhone shows and the key it
    /// generated; succeeds once the code was entered on the server.
    func pair(base: URL, code: String, key: String) async -> PairResult {
        guard let body = try? JSONEncoder().encode(["code": code, "key": key]),
            let (status, _) = try? await request("POST", "/v1/pair", base: base, token: nil, body: body)
        else { return .unreachable }
        switch status {
        case 200: return .paired
        case 404: return .waiting
        case 403: return .wrongCode
        case 500...: return .unreachable
        default: return .unsupported
        }
    }

    func apiKeys(base: URL, token: String?) async throws -> [APIKey] {
        let (status, data) = try await request("GET", "/v1/keys", base: base, token: token)
        if status == 401 { throw KeyRejected() }
        guard status == 200 else { throw URLError(.badServerResponse) }
        struct Response: Decodable { let keys: [APIKey] }
        return try JSONDecoder().decode(Response.self, from: data).keys
    }

    /// Creates an API key; the returned string is the only copy of the key.
    func createAPIKey(base: URL, token: String?, name: String, scope: APIKey.Scope) async throws -> (APIKey, String) {
        let body = try JSONEncoder().encode(["name": name, "scope": scope.rawValue])
        let (status, data) = try await request("POST", "/v1/keys", base: base, token: token, body: body)
        guard status == 201 else {
            throw URLError(
                .badServerResponse, userInfo: [NSLocalizedDescriptionKey: String(decoding: data.prefix(160), as: UTF8.self)])
        }
        struct Response: Decodable { let key: String }
        return (try JSONDecoder().decode(APIKey.self, from: data), try JSONDecoder().decode(Response.self, from: data).key)
    }

    /// Writes waiting for this iPhone (GET /v1/writes?status=pending),
    /// oldest first.
    func pendingWrites(base: URL, token: String?) async throws -> [QueuedWrite] {
        let (status, data) = try await request("GET", "/v1/writes?status=pending&limit=1000", base: base, token: token)
        if status == 401 { throw KeyRejected() }
        guard status == 200 else { throw URLError(.badServerResponse) }
        struct Response: Decodable { let writes: [QueuedWrite] }
        return try JSONDecoder().decode(Response.self, from: data).writes.reversed()
    }

    /// GET /v1/writes/pending, waiting up to `wait` seconds for a write
    /// submitted after `anchor` (at once without one). Returns the server's
    /// writes anchor, nil from a server that can't wait.
    func awaitWrites(base: URL, token: String?, anchor: String?, wait: Int) async throws -> String? {
        var path = "/v1/writes/pending?wait=\(wait)"
        if let anchor, let escaped = anchor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            path += "&anchor=\(escaped)"
        }
        guard let url = URL(string: base.absoluteString + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = TimeInterval(wait + 15)
        HTTPUploader.authorize(&request, token: token)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw KeyRejected() }
        guard status == 200 else { throw URLError(.badServerResponse) }
        struct Response: Decodable { let anchor: String? }
        return try JSONDecoder().decode(Response.self, from: data).anchor
    }

    /// Asks the server to delete an entry from Apple Health
    /// (POST /v1/writes, op delete): this iPhone runs it on its next sync,
    /// like any write, so the server's write list has it too.
    func submitDelete(base: URL, token: String?, syncIdentifier: String) async throws {
        let body = try JSONEncoder().encode(["op": "delete", "syncIdentifier": syncIdentifier])
        let (status, data) = try await request("POST", "/v1/writes", base: base, token: token, body: body)
        guard status == 201 else {
            struct Failure: Decodable { let error: String }
            let message = (try? JSONDecoder().decode(Failure.self, from: data))?.error ?? "HTTP \(status)"
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    /// A key's requests, newest first, a page at a time.
    func keyActivity(
        base: URL, token: String?, id: String, before: String?
    ) async throws -> (activity: [APIActivity], next: String?) {
        var path = "/v1/keys/\(id)/activity?limit=100"
        if let before, let escaped = before.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "&before=\(escaped)"
        }
        let (status, data) = try await request("GET", path, base: base, token: token)
        if status == 401 { throw KeyRejected() }
        guard status == 200 else { throw URLError(.badServerResponse) }
        struct Response: Decodable {
            let activity: [APIActivity]
            let next: String?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return (response.activity, response.next)
    }

    func revokeAPIKey(base: URL, token: String?, id: String) async throws {
        let (status, _) = try await request("DELETE", "/v1/keys/\(id)", base: base, token: token)
        guard status == 200 else { throw URLError(.badServerResponse) }
    }
}
