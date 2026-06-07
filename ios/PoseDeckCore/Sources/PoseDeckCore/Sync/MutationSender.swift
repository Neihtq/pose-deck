import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Outcome of dispatching one ``OutboxEntry`` to PocketBase (M3 plan, STEP 8).
///
/// The processor uses this to decide whether to remove the entry, drop it, pause
/// for re-auth, or schedule a backed-off retry.
public enum MutationOutcome: Sendable, Equatable {
    /// The mutation was accepted (2xx), **or** it was a create whose
    /// client-supplied id already existed (PocketBase 400 with a `data.id`
    /// validation error — the idempotent lost-ack replay, invariant #1). In
    /// both cases the entry is removed from the outbox.
    case success
    /// A non-retryable client error (a 4xx other than the create-duplicate case,
    /// e.g. 403/404/422). The entry is dropped and the error surfaced.
    case drop(status: Int)
    /// Authentication expired (401). Distinct from a generic transient failure
    /// so the processor pauses and asks for a token refresh rather than
    /// retrying a dead token forever.
    case authExpired
    /// A transient failure (429, 5xx, or offline/transport error). The entry
    /// stays queued for an exponentially backed-off retry.
    case retry(reason: String)
}

/// Turns an ``OutboxEntry`` into the matching ``APIClient`` REST call and
/// classifies the result (M3 plan, STEP 8 / ARCHITECTURE.md §4.2).
///
/// Creates carry a client-supplied id (minted by ``IDGenerator`` at enqueue
/// time and embedded in the payload), so a replay after a lost ack is
/// idempotent: PocketBase rejects the duplicate id with a 400 that this sender
/// classifies as ``MutationOutcome/success``.
///
/// The sender is intentionally thin and stateless so it is trivially unit
/// testable through ``StubURLProtocol`` and reusable from the processor.
public struct MutationSender: Sendable {

    private let client: APIClient

    public init(client: APIClient) {
        self.client = client
    }

    /// Dispatch one entry and classify the result.
    ///
    /// The entry's `payload` is the raw PocketBase record body (already
    /// snake-cased, datetimes in wire format, and for creates carrying the
    /// client-supplied `id`). It is sent verbatim.
    public func send(_ entry: OutboxEntry) async -> MutationOutcome {
        do {
            switch entry.type {
            case .create:
                _ = try await client.performMutation(
                    method: "POST",
                    path: "/api/collections/\(entry.entity)/records",
                    body: entry.payload,
                    idempotencyKey: entry.idempotencyKey
                )
                return .success

            case .update:
                guard let recordId = Self.recordId(in: entry.payload) else {
                    // A malformed update payload with no id can never succeed —
                    // drop it rather than loop. Treated as a 400-class client error.
                    return .drop(status: 400)
                }
                _ = try await client.performMutation(
                    method: "PATCH",
                    path: "/api/collections/\(entry.entity)/records/\(recordId)",
                    body: entry.payload,
                    idempotencyKey: entry.idempotencyKey
                )
                return .success

            case .delete:
                guard let recordId = Self.recordId(in: entry.payload) else {
                    return .drop(status: 400)
                }
                _ = try await client.performMutation(
                    method: "DELETE",
                    path: "/api/collections/\(entry.entity)/records/\(recordId)",
                    body: nil,
                    idempotencyKey: entry.idempotencyKey
                )
                return .success
            }
        } catch let APIClientError.httpError(status, body) {
            return Self.classify(status: status, body: body, type: entry.type)
        } catch APIClientError.notAuthenticated {
            // No token at all — same remedy as a 401: pause and refresh.
            return .authExpired
        } catch {
            // URLSession transport errors (offline, DNS, timeout) surface here.
            return .retry(reason: String(describing: error))
        }
    }

    /// Map an HTTP status to an outcome.
    ///
    /// Visible for unit testing.
    static func classify(status: Int, body: Data, type: OutboxMutationType) -> MutationOutcome {
        switch status {
        case 200..<300:
            return .success
        case 401:
            return .authExpired
        case 400:
            // The idempotent lost-ack replay: a create whose client-supplied id
            // already exists. PocketBase returns 400 with a validation error on
            // `data.id` ("...value must be unique"). Treat as success so the
            // entry is removed without inserting a duplicate (invariant #1).
            if type == .create, isDuplicateIdError(body) {
                return .success
            }
            return .drop(status: status)
        case 429:
            // Rate limited → transient retry (handled before the general 4xx
            // drop range below).
            return .retry(reason: "HTTP 429 rate limited")
        case 402..<500:
            // Other non-retryable client errors (403/404/409/422/…): drop.
            return .drop(status: status)
        default:
            // 5xx and anything else unexpected → transient retry.
            return .retry(reason: "HTTP \(status)")
        }
    }

    /// Detect PocketBase's "id already exists" 400 on a create.
    ///
    /// PocketBase shapes validation failures as
    /// `{"data":{"id":{"code":"validation_...","message":"..."}}}`. We look for
    /// a `data.id` error specifically so an unrelated 400 (e.g. a bad `name`)
    /// still drops rather than being mistaken for a successful idempotent replay.
    static func isDuplicateIdError(_ body: Data) -> Bool {
        guard
            let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let data = root["data"] as? [String: Any]
        else {
            return false
        }
        // The presence of an `id` field error on a create means the
        // client-supplied id collided with an existing record.
        return data["id"] != nil
    }

    /// Pull the `id` out of a record payload (for update/delete routing).
    static func recordId(in payload: Data) -> String? {
        guard
            let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
            let id = root["id"] as? String,
            !id.isEmpty
        else {
            return nil
        }
        return id
    }
}
