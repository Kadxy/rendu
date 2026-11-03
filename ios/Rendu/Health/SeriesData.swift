import CoreLocation
import CryptoKit
import Foundation
import HealthKit

/// What samples carry beyond what the anchored query returns, added to the
/// serialized samples a page at a time: a quantity series' values
/// (HKQuantitySeriesSampleQuery, one query for the page), workout effort
/// (HKWorkoutEffortRelationshipQuery), ECG voltages, a route's locations,
/// a heartbeat series' beats, the medication a dose was of, a
/// prescription's attachments, and a CDA document's XML.
struct SeriesData {
    let store: HKHealthStore
    /// The shared medications by concept, for naming dose events.
    let medications: [HKHealthConceptIdentifier: Medications.Entry]

    /// `page` with each sample's series added, by uuid.
    func attach(_ page: [(sample: HKSample, json: JSON)], kind: SampleKind) async throws -> [JSON] {
        var extra: [UUID: [String: JSON]] = [:]
        switch kind {
        case .quantity:
            extra = try await quantitySeries(page.map(\.sample))
        case .workout:
            extra = try await effort(page.compactMap { $0.sample as? HKWorkout })
        case .cdaDocument:
            extra = try await documents(page.map(\.sample))
        default:
            for (sample, _) in page {
                extra[sample.uuid] = try await single(sample)
            }
        }
        return page.map { sample, json in
            guard let added = extra[sample.uuid], case .object(var object) = json else { return json }
            object.merge(added) { $1 }
            return .object(object)
        }
    }

    /// Every value of the page's series samples (count > 1), in one query.
    private func quantitySeries(_ samples: [HKSample]) async throws -> [UUID: [String: JSON]] {
        let series = samples.compactMap { $0 as? HKQuantitySample }.filter { $0.count > 1 }
        guard let type = series.first?.quantityType, let unit = TypeCatalog.unit(for: type) else { return [:] }
        let descriptor = HKQuantitySeriesSampleQueryDescriptor(
            predicate: .quantitySample(type: type, predicate: HKQuery.predicateForObjects(with: Set(series.map(\.uuid))))
        )
        var points: [UUID: [JSON]] = [:]
        for try await result in descriptor.results(for: store) {
            guard let sample = result.sample, result.quantity.is(compatibleWith: unit) else { continue }
            points[sample.uuid, default: []].append([
                "quantity": ["value": .number(result.quantity.doubleValue(for: unit)), "unit": .string(unit.unitString)],
                "startDate": .string(Self.timestamp(result.dateInterval.start)),
                "endDate": .string(Self.timestamp(result.dateInterval.end)),
            ])
        }
        return points.mapValues { ["series": .array($0)] }
    }

    /// Which effort scores rate each workout (or one of its activities).
    private func effort(_ workouts: [HKWorkout]) async throws -> [UUID: [String: JSON]] {
        guard !workouts.isEmpty else { return [:] }
        let descriptor = HKWorkoutEffortRelationshipQueryDescriptor(
            predicate: HKQuery.predicateForObjects(with: Set(workouts.map(\.uuid))), anchor: nil, option: .default
        )
        var out: [UUID: [JSON]] = [:]
        for relationship in try await descriptor.result(for: store).relationships {
            let samples = (relationship.samples ?? []).map { JSON.string($0.uuid.uuidString) }
            guard !samples.isEmpty else { continue }
            var entry: [String: JSON] = ["samples": .array(samples)]
            if let activity = relationship.activity {
                entry["activityUUID"] = .string(activity.uuid.uuidString)
            }
            out[relationship.workout.uuid, default: []].append(.object(entry))
        }
        return out.mapValues { ["effortRelationships": .array($0)] }
    }

    /// The XML of the page's CDA documents (the anchored query leaves it out).
    private func documents(_ samples: [HKSample]) async throws -> [UUID: [String: JSON]] {
        guard !samples.isEmpty else { return [:] }
        let store = store
        let predicate = HKQuery.predicateForObjects(with: Set(samples.map(\.uuid)))
        let found: [HKCDADocumentSample] = try await withCheckedThrowingContinuation { continuation in
            var all: [HKCDADocumentSample] = []
            let query = HKDocumentQuery(
                documentType: HKDocumentType(.CDA), predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil,
                includeDocumentData: true
            ) { _, results, done, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                all += (results ?? []).compactMap { $0 as? HKCDADocumentSample }
                if done { continuation.resume(returning: all) }
            }
            store.execute(query)
        }
        var out: [UUID: [String: JSON]] = [:]
        for sample in found {
            guard let document = sample.document else { continue }
            var object: [String: JSON] = ["title": .string(document.title)]
            object["patientName"] = .string(document.patientName)
            object["authorName"] = .string(document.authorName)
            object["custodianName"] = .string(document.custodianName)
            if let data = document.documentData {
                object["documentData"] = .string(String(decoding: data, as: UTF8.self))
            }
            out[sample.uuid] = object
        }
        return out
    }

    private func single(_ sample: HKSample) async throws -> [String: JSON]? {
        switch sample {
        case let ecg as HKElectrocardiogram:
            var voltages: [JSON] = []
            for try await measurement in HKElectrocardiogramQueryDescriptor(ecg).results(for: store) {
                guard let quantity = measurement.quantity(for: .appleWatchSimilarToLeadI) else { continue }
                voltages.append([
                    "timeSinceSampleStart": .number(measurement.timeSinceSampleStart),
                    "appleWatchSimilarToLeadI": .number(quantity.doubleValue(for: .voltUnit(with: .micro))),
                ])
            }
            return ["voltageMeasurements": .array(voltages)]
        case let route as HKWorkoutRoute:
            var locations: [JSON] = []
            for try await location in HKWorkoutRouteQueryDescriptor(route).results(for: store) {
                locations.append(Self.locationJSON(location))
            }
            return ["locations": .array(locations)]
        case let series as HKHeartbeatSeriesSample:
            var beats: [JSON] = []
            for try await beat in HKHeartbeatSeriesQueryDescriptor(series).results(for: store) {
                beats.append([
                    "timeSinceSeriesStart": .number(beat.timeIntervalSinceStart),
                    "precededByGap": .bool(beat.precededByGap),
                ])
            }
            return ["beats": .array(beats)]
        case let dose as HKMedicationDoseEvent:
            guard let medication = medications[dose.medicationConceptIdentifier] else { return nil }
            return ["medicationId": .string(medication.id), "medicationName": .string(medication.name)]
        case let prescription as HKVisionPrescription:
            let attachments = try await HKAttachmentStore(healthStore: store).attachments(for: prescription)
            guard !attachments.isEmpty else { return nil }
            return [
                "attachments": .array(
                    attachments.map { attachment in
                        [
                            "identifier": .string(attachment.identifier.uuidString),
                            "name": .string(attachment.name),
                            "contentType": .string(attachment.contentType.identifier),
                            "size": .number(Double(attachment.size)),
                            "creationDate": .string(Self.timestamp(attachment.creationDate)),
                        ]
                    })
            ]
        default:
            return nil
        }
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter.fractional.string(from: date)
    }

    private static func locationJSON(_ location: CLLocation) -> JSON {
        [
            "timestamp": .string(timestamp(location.timestamp)),
            "latitude": .number(location.coordinate.latitude),
            "longitude": .number(location.coordinate.longitude),
            "altitude": .number(location.altitude),
            "horizontalAccuracy": .number(location.horizontalAccuracy),
            "verticalAccuracy": .number(location.verticalAccuracy),
            "speed": .number(location.speed),
            "course": .number(location.course),
        ]
    }
}

extension ISO8601DateFormatter {
    /// "2026-11-02T08:15:30.250Z".
    nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// Data the user shares object by object, in a sheet of its own
/// (requestPerObjectReadAuthorization): every type HealthKit says needs it
/// (requiresPerObjectAuthorization, checked on the device by HealthUIProbe):
/// medications (and with them the doses taken) and vision prescriptions.
/// Clinical documents need it too; Rendu doesn't read them.
enum PerObjectAccess: String, CaseIterable, Sendable {
    case medications, visionPrescriptions

    var objectType: HKObjectType {
        switch self {
        case .medications: .userAnnotatedMedicationType()
        case .visionPrescriptions: .visionPrescriptionType()
        }
    }

    private var requestedKey: String { "perObject.\(rawValue).requested" }

    /// The user has been through the sheet at least once.
    var requested: Bool {
        UserDefaults.standard.bool(forKey: requestedKey)
            // Medications were asked for before this type existed.
            || (self == .medications && UserDefaults.standard.bool(forKey: "medications.requested"))
    }

    /// Shows the sheet; the user picks what Rendu may read.
    func request(_ store: HKHealthStore) async throws {
        try await store.requestPerObjectReadAuthorization(for: objectType, predicate: nil)
        UserDefaults.standard.set(true, forKey: requestedKey)
    }

    /// One shared object, for the list of what's shared.
    struct Item: Identifiable, Sendable {
        let id: String
        let title: String
        let detail: String?
    }

    /// What is shared now (all of it HealthKit lets Rendu read).
    func items(_ store: HKHealthStore) async -> [Item] {
        switch self {
        case .medications:
            let all = (try? await HKUserAnnotatedMedicationQueryDescriptor().result(for: store)) ?? []
            return all.map { item in
                let name = item.medication.displayText
                var detail: [String] = []
                if let nickname = item.nickname, !nickname.isEmpty, nickname != name { detail.append(nickname) }
                if item.isArchived { detail.append(String(localized: "Archived")) }
                return Item(
                    id: name + (item.nickname ?? ""), title: name, detail: detail.isEmpty ? nil : detail.joined(separator: " · "))
            }
        case .visionPrescriptions:
            let descriptor = HKSampleQueryDescriptor(
                predicates: [.sample(type: .visionPrescriptionType())],
                sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)])
            let all = (try? await descriptor.result(for: store)) ?? []
            return all.compactMap { $0 as? HKVisionPrescription }.map { prescription in
                let contacts = prescription.prescriptionType == .contacts
                let issued = prescription.dateIssued.formatted(date: .abbreviated, time: .omitted)
                return Item(
                    id: prescription.uuid.uuidString,
                    title: contacts ? String(localized: "Contacts") : String(localized: "Glasses"),
                    detail: String(localized: "Issued \(issued)"))
            }
        }
    }

    /// How many objects are shared; nil before the sheet was ever shown.
    func sharedCount(_ store: HKHealthStore) async -> Int? {
        guard requested else { return nil }
        switch self {
        case .medications:
            return (try? await Medications.shared(store))?.count
        case .visionPrescriptions:
            guard let type = objectType as? HKSampleType else { return nil }
            let descriptor = HKSampleQueryDescriptor(predicates: [.sample(type: type)], sortDescriptors: [])
            return (try? await descriptor.result(for: store))?.count
        }
    }
}

/// The medications the user shares with Rendu (iOS 26).
enum Medications {
    struct Entry: Sendable {
        /// Stable across launches: derived from the concept identifier,
        /// which has no string form of its own.
        let id: String
        let name: String
    }

    /// The shared medications; none before the sheet was shown.
    static func shared(_ store: HKHealthStore) async throws -> [HKUserAnnotatedMedication] {
        guard PerObjectAccess.medications.requested else { return [] }
        return try await HKUserAnnotatedMedicationQueryDescriptor().result(for: store)
    }

    static func entries(_ medications: [HKUserAnnotatedMedication]) -> [HKHealthConceptIdentifier: Entry] {
        var out: [HKHealthConceptIdentifier: Entry] = [:]
        for item in medications {
            out[item.medication.identifier] = Entry(id: id(item.medication.identifier), name: item.medication.displayText)
        }
        return out
    }

    /// The wire form (docs/PROTOCOL.md, PUT /v1/medications). Absent
    /// values are left out, an empty nickname too.
    static func json(_ item: HKUserAnnotatedMedication) -> JSON {
        let concept = item.medication
        let codings: [JSON] = concept.relatedCodings
            .sorted { ($0.system, $0.code) < ($1.system, $1.code) }
            .map { coding in
                var entry: [String: JSON] = ["system": .string(coding.system), "code": .string(coding.code)]
                if let version = coding.version, !version.isEmpty { entry["version"] = .string(version) }
                return .object(entry)
            }
        var object: [String: JSON] = [
            "id": .string(id(concept.identifier)),
            "medication": [
                "displayText": .string(concept.displayText),
                "generalForm": .string(concept.generalForm.rawValue),
                "relatedCodings": .array(codings),
            ],
            "isArchived": .bool(item.isArchived),
            "hasSchedule": .bool(item.hasSchedule),
        ]
        if let nickname = item.nickname, !nickname.isEmpty {
            object["nickname"] = .string(nickname)
        }
        return .object(object)
    }

    private static func id(_ identifier: HKHealthConceptIdentifier) -> String {
        let data = (try? NSKeyedArchiver.archivedData(withRootObject: identifier, requiringSecureCoding: true)) ?? Data()
        return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
