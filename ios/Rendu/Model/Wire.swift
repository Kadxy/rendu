import Foundation

/// Device-scope server endpoints the outbox delivers to.
enum Endpoint: String, Codable, Sendable {
    case ingest = "/v1/ingest"
    case statistics = "/v1/statistics"
    case activitySummaries = "/v1/activity-summaries"
    case characteristics = "/v1/characteristics"

    var method: String { self == .characteristics ? "PUT" : "POST" }
}

/// The outbox file format before 0.2 (one JSON file holding payload and
/// anchor). Still read, so batches queued by an older build get delivered.
struct Batch: Codable, Sendable {
    let id: UUID
    let endpoint: Endpoint
    /// Catalog key the batch belongs to (for status and logs).
    let typeKey: String
    let createdAt: Date
    let anchor: Data?
    /// Samples for ingest batches, rows otherwise.
    let count: Int
    let payload: JSON
}

/// Wire-format constants and encoders.
enum Wire {
    /// Uncompressed batch ceiling (one query result of up to 20k samples).
    /// Gzips to roughly 8 MB; the server accepts 64 MB decompressed.
    static let maxBatchBytes = 32 * 1024 * 1024

    static func encode(_ value: some Encodable) throws -> Data {
        try bodyEncoder().encode(value)
    }

    static func bodyEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func fileEncoder() -> JSONEncoder {
        let encoder = bodyEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func fileDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func tombstone(_ uuids: [String]) -> JSON {
        ["deleted": .array(uuids.map(JSON.string))]
    }

    static func isTombstone(_ element: JSON) -> Bool {
        element["deleted"] != nil
    }
}

enum BatchSlicer {
    /// Splits elements in half recursively until every slice encodes under
    /// maxBytes, returning each slice with its encoding (so nothing is
    /// encoded twice). A single element is never split, whatever its size.
    static func encodedSlices(_ elements: [JSON], maxBytes: Int) throws -> [(elements: [JSON], body: Data)] {
        let encoded = try Wire.encode(elements)
        guard encoded.count > maxBytes, elements.count > 1 else { return [(elements, encoded)] }
        let mid = elements.count / 2
        return try encodedSlices(Array(elements[..<mid]), maxBytes: maxBytes)
            + encodedSlices(Array(elements[mid...]), maxBytes: maxBytes)
    }
}
