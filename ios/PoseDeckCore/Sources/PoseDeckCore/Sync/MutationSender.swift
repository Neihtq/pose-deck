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
    /// The one collection whose deterministic-id creates carry mutable state, so
    /// a duplicate-id 400 must trigger a follow-up state PATCH rather than a bare
    /// success (`[FIX-C1]`).
    private static let completionsEntity = "card_completions"

    /// The deck-sharing collection whose `(deck, user)` composite-unique 400 on a
    /// re-grant must be treated as idempotent success rather than a hard drop
    /// (`[FIX #6-iOS]`). Unlike a duplicate-`id` replay, this 400 is keyed on the
    /// relation fields, so `isDuplicateIdError` (which only inspects `data.id`)
    /// would miss it and the entry would erroneously drop with a surfaced error.
    private static let deckGuestsEntity = "deck_guests"

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
            // `[FIX-C1]`: a `card_completions` create whose deterministic id
            // already exists carries a NEW state (the row was first created on
            // another device / an earlier session). A bare `.success` here would
            // silently drop that state change, so instead PATCH `{state,
            // changed_at}` onto the existing record id and report the PATCH's
            // outcome. Only completions need this; for every other entity a
            // duplicate-id create is a pure lost-ack replay with no new data, so
            // the existing bare-success behavior is correct.
            if status == 400,
               entry.type == .create,
               entry.entity == Self.completionsEntity,
               Self.isDuplicateIdError(body) {
                return await sendCompletionFollowUpPatch(for: entry)
            }
            return Self.classify(status: status, body: body, type: entry.type, entity: entry.entity)
        } catch APIClientError.notAuthenticated {
            // No token at all — same remedy as a 401: pause and refresh.
            return .authExpired
        } catch {
            // URLSession transport errors (offline, DNS, timeout) surface here.
            return .retry(reason: String(describing: error))
        }
    }

    /// Follow-up PATCH for a `card_completions` create that hit an existing row
    /// (`[FIX-C1]`).
    ///
    /// Re-uses the create payload's own `id`, `state`, and `changed_at` (the
    /// create body is a superset of the update body) and PATCHes them onto the
    /// existing record so the new state is persisted instead of dropped. The
    /// PATCH carries the same idempotency key; its outcome is classified normally
    /// (a transient failure stays queued, a clean 2xx removes the entry).
    private func sendCompletionFollowUpPatch(for entry: OutboxEntry) async -> MutationOutcome {
        guard let recordId = Self.recordId(in: entry.payload) else {
            // A create payload with no id can't be reconciled — drop loudly.
            return .drop(status: 400)
        }
        guard let patchBody = Self.completionStatePatchBody(from: entry.payload) else {
            return .drop(status: 400)
        }
        do {
            _ = try await client.performMutation(
                method: "PATCH",
                path: "/api/collections/\(entry.entity)/records/\(recordId)",
                body: patchBody,
                idempotencyKey: entry.idempotencyKey
            )
            return .success
        } catch let APIClientError.httpError(status, body) {
            // Classify as an update — a duplicate-id 400 has no meaning for a
            // PATCH, so any 400 here drops.
            return Self.classify(status: status, body: body, type: .update)
        } catch APIClientError.notAuthenticated {
            return .authExpired
        } catch {
            return .retry(reason: String(describing: error))
        }
    }

    /// Build the `{state, changed_at}` PATCH body from a completion create
    /// payload, preserving the wire-format `changed_at` string verbatim.
    static func completionStatePatchBody(from payload: Data) -> Data? {
        guard
            let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
            let state = root["state"]
        else {
            return nil
        }
        var patch: [String: Any] = ["state": state]
        if let changedAt = root["changed_at"] {
            patch["changed_at"] = changedAt
        }
        return try? JSONSerialization.data(withJSONObject: patch)
    }

    /// Map an HTTP status to an outcome.
    ///
    /// Visible for unit testing. `entity` lets the 400 branch recognize the
    /// `deck_guests` composite-unique re-grant as idempotent success (`[FIX #6-iOS]`);
    /// callers that don't care pass `nil`.
    static func classify(
        status: Int,
        body: Data,
        type: OutboxMutationType,
        entity: String? = nil
    ) -> MutationOutcome {
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
            // `[FIX #6-iOS]`: a re-grant of an existing `(deck, user)` deck_guests
            // row 400s on the composite-unique constraint — keyed on the relation
            // fields, NOT `data.id`, so the duplicate-id check above misses it.
            // The grant is idempotent (the row already exists with that access),
            // so treat any deck_guests create 400 as success: drop the redundant
            // create, keep the optimistic mirror row, surface no error.
            if type == .create, entity == deckGuestsEntity {
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
    /// `{"data":{"id":{"code":"validation_...","message":"..."}}}`. `[FIX-m3]`:
    /// we require the `data.id.code` to be exactly `"validation_not_unique"` —
    /// the uniqueness collision — rather than merely the presence of a `data.id`
    /// error. A *format* error on the id (e.g. `validation_invalid_value` from a
    /// malformed client id) is a real client bug and must DROP loudly instead of
    /// masquerading as an idempotent-replay success.
    static func isDuplicateIdError(_ body: Data) -> Bool {
        guard
            let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let data = root["data"] as? [String: Any],
            let idError = data["id"] as? [String: Any],
            let code = idError["code"] as? String
        else {
            return false
        }
        return code == "validation_not_unique"
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
