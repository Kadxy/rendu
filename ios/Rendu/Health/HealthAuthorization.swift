import Foundation
import HealthKit

/// Requests read access to every catalog type and share access to every type
/// HealthKit lets third-party apps write — as decided by HealthKit, not by a
/// hand-kept list: share access to an Apple-only type raises an exception
/// naming it, so the request starts from every candidate, drops the named
/// types, remembers them (per OS version), and retries. Only if a refusal
/// can't be parsed does it fall back to the catalog's READ_ONLY guess.
enum HealthAuthorization {
    private static let disallowedKey = "auth.shareDisallowed"
    private static let disallowedOSKey = "auth.shareDisallowed.os"
    private static let fallbackKey = "auth.usePresumedShareTypes"
    /// Each attempt costs nothing visible: the raise happens before any UI.
    private static let maxAttempts = 64

    struct Rejected: LocalizedError {
        let reason: String
        var errorDescription: String? { "HealthKit rejected the authorization request: \(reason)" }
    }

    private static let askedKey = "auth.asked"

    /// iOS has asked the user for access on this install (or nothing was
    /// left to ask). Until then Rendu doesn't sync: HealthKit answers every
    /// query with nothing, and a pass would take that for the truth.
    nonisolated static var asked: Bool {
        get { UserDefaults.standard.bool(forKey: askedKey) }
        set { UserDefaults.standard.set(newValue, forKey: askedKey) }
    }

    static func request(_ store: HKHealthStore, log: LogStore) async throws {
        try await withShareRetry(log: log) { share, read, completion in
            store.requestAuthorization(toShare: share, read: read) { _, error in
                completion(error.map { .failure($0) } ?? .success(()))
            }
        }
        asked = true
        let refused = UserDefaults.standard.stringArray(forKey: disallowedKey) ?? []
        await log.info(
            "authorization requested: write access for \(shareTypes.count) types; HealthKit allows no third-party writes to \(refused.count): \(refused.sorted().joined(separator: ", "))"
        )
    }

    /// Whether the prompt still has anything to ask.
    static func needsRequest(_ store: HKHealthStore, log: LogStore) async throws -> Bool {
        let status: HKAuthorizationRequestStatus = try await withShareRetry(log: log) { share, read, completion in
            store.getRequestStatusForAuthorization(toShare: share, read: read) { status, error in
                completion(error.map { .failure($0) } ?? .success(status))
            }
        }
        return status == .shouldRequest
    }

    /// Whether access was turned off in Settings after it was granted: iOS
    /// tells apps only about writing (reading looks the same as no data),
    /// so this is true when writing is off for every type. Turning off all
    /// of an app's categories turns off both.
    static func accessTurnedOff(_ store: HKHealthStore) -> Bool {
        let statuses = shareTypes.map { store.authorizationStatus(for: $0) }
        return !statuses.isEmpty && statuses.allSatisfy { $0 == .sharingDenied }
    }

    private static let readFromOthersKey = "auth.readFromOthers"

    /// A type's samples from other sources (Apple Watch, other apps) were
    /// read: from then on, none of theirs means reading is most likely off.
    nonisolated static func noteReadFromOthers(_ key: String) {
        let keys = UserDefaults.standard.stringArray(forKey: readFromOthersKey) ?? []
        if !keys.contains(key) { UserDefaults.standard.set(keys + [key], forKey: readFromOthersKey) }
    }

    private static let readFromOthersLearnedKey = "auth.readFromOthers.learned"

    /// Once per install, after access was asked: notes every type HealthKit
    /// gives others' data of now, so types that rarely get new data are
    /// known too (noteReadFromOthers learns as syncs read).
    nonisolated static func learnReadFromOthers(_ store: HKHealthStore) async {
        guard asked, !UserDefaults.standard.bool(forKey: readFromOthersLearnedKey) else { return }
        let all = Set(TypeCatalog.all.map(\.key))
        let off = Set(await othersMissing(all, store))
        for key in all.subtracting(off) { noteReadFromOthers(key) }
        UserDefaults.standard.set(true, forKey: readFromOthersLearnedKey)
    }

    /// Types reading looks off for. iOS doesn't tell apps what they may
    /// read; with reading off, an app sees only the data it wrote itself.
    /// So a type read from other sources before, of which HealthKit now
    /// gives none but Rendu's, has most likely had reading turned off (or
    /// all of that data was deleted).
    nonisolated static func readingLooksOff(_ store: HKHealthStore) async -> [String] {
        await othersMissing(Set(UserDefaults.standard.stringArray(forKey: readFromOthersKey) ?? []), store)
    }

    /// Of `keys`, the types HealthKit gives no samples of but Rendu's.
    private nonisolated static func othersMissing(_ keys: Set<String>, _ store: HKHealthStore) async -> [String] {
        let types = TypeCatalog.all.filter { keys.contains($0.key) }
        let notMine = NSCompoundPredicate(notPredicateWithSubpredicate: HKQuery.predicateForObjects(from: [HKSource.default()]))
        return await withTaskGroup(of: String?.self) { group in
            for type in types {
                let (key, sampleType) = (type.key, type.sampleType)
                group.addTask {
                    let query = HKSampleQueryDescriptor(
                        predicates: [.sample(type: sampleType, predicate: notMine)], sortDescriptors: [], limit: 1)
                    let found = (try? await query.result(for: store))?.isEmpty == false
                    return found ? nil : key
                }
            }
            var off: [String] = []
            for await key in group {
                if let key { off.append(key) }
            }
            return off
        }
    }

    /// Writing, per type HealthKit lets apps write: what iOS says of each.
    /// (Reading it doesn't say.)
    static func writeAccess(_ store: HKHealthStore) -> (allowed: [String], off: [String], notAsked: [String]) {
        var access: (allowed: [String], off: [String], notAsked: [String]) = ([], [], [])
        for type in shareTypes {
            switch store.authorizationStatus(for: type) {
            case .sharingAuthorized: access.allowed.append(type.identifier)
            case .sharingDenied: access.off.append(type.identifier)
            default: access.notAsked.append(type.identifier)
            }
        }
        return access
    }

    static var shareTypes: Set<HKSampleType> {
        // An OS update may open types up (or close them); re-learn.
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        if UserDefaults.standard.string(forKey: disallowedOSKey) != os {
            UserDefaults.standard.removeObject(forKey: disallowedKey)
            UserDefaults.standard.removeObject(forKey: fallbackKey)
            UserDefaults.standard.set(os, forKey: disallowedOSKey)
        }
        let base = UserDefaults.standard.bool(forKey: fallbackKey) ? TypeCatalog.presumedShareTypes : TypeCatalog.shareCandidates
        let disallowed = Set(UserDefaults.standard.stringArray(forKey: disallowedKey) ?? [])
        return base.filter { !disallowed.contains($0.identifier) }
    }

    private enum Outcome<T: Sendable>: Sendable {
        case value(T)
        case raised(String)
    }

    private static func withShareRetry<T: Sendable>(
        log: LogStore,
        _ call: (Set<HKSampleType>, Set<HKObjectType>, @escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        for _ in 0 ..< maxAttempts {
            let share = shareTypes
            let read = TypeCatalog.readTypes
            let outcome: Outcome<T> = try await withCheckedThrowingContinuation { continuation in
                let once = ResumeOnce(continuation)
                let reason = RDCatchException {
                    call(share, read) { result in
                        switch result {
                        case .success(let value): once.resume(returning: .value(value))
                        case .failure(let error): once.resume(throwing: error)
                        }
                    }
                }
                // A raise happens before HealthKit schedules the completion.
                if let reason { once.resume(returning: .raised(reason)) }
            }
            let raised: String
            switch outcome {
            case .value(let value): return value
            case .raised(let reason): raised = reason
            }

            // Exact tokens: HeartRate must not match HeartRateRecoveryOneMinute.
            let named = Set(raised.matches(of: #/HK[A-Za-z0-9]+/#).map { String($0.output) })
            let rejected = share.map(\.identifier).filter(named.contains)
            guard !rejected.isEmpty else {
                if UserDefaults.standard.bool(forKey: fallbackKey) { throw Rejected(reason: raised) }
                UserDefaults.standard.set(true, forKey: fallbackKey)
                await log.warn("unrecognized HealthKit refusal, falling back to the catalog's read-only list: \(raised)")
                continue
            }
            var disallowed = UserDefaults.standard.stringArray(forKey: disallowedKey) ?? []
            disallowed.append(contentsOf: rejected)
            UserDefaults.standard.set(disallowed, forKey: disallowedKey)
            await log.warn("share access refused for \(rejected.joined(separator: ", ")) — requesting read only")
        }
        throw Rejected(reason: "still rejected after \(maxAttempts) attempts")
    }
}

/// Resumes a continuation at most once; later calls are ignored.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let taken = continuation
        continuation = nil
        return taken
    }
}
