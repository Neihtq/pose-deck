import Foundation

/// Injectable clock for backoff math so the processor is deterministically
/// testable without `Task.sleep` or wall-clock time (M3 plan, STEP 8).
public protocol SyncClock: Sendable {
    /// "Now", used to stamp `nextAttemptAt` deadlines.
    func now() -> Date
}

/// Default wall-clock ``SyncClock``.
public struct SystemSyncClock: SyncClock {
    public init() {}
    public func now() -> Date { Date() }
}

/// A test ``SyncClock`` whose `now()` is settable, so backoff deadlines can be
/// asserted exactly and advanced on demand.
///
/// Lock-backed (not actor-isolated) so `now()` can satisfy the synchronous
/// protocol requirement while `advance`/`set` remain callable from `await`-ing
/// test code. The `advance`/`set` methods are `async` only so existing call
/// sites keep their `await`; the storage is the single locked value.
public final class MutableSyncClock: SyncClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.current = start
    }

    public func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func advance(by interval: TimeInterval) async {
        lock.withLock { current = current.addingTimeInterval(interval) }
    }

    public func set(_ date: Date) async {
        lock.withLock { current = date }
    }
}

/// Result of one drain pass over the outbox (M3 plan, STEP 8).
///
/// CRITICAL: the processor never `Task.sleep`s inside the actor. When the head
/// entry fails transiently it returns ``deferred(until:)`` and an *external*
/// scheduler re-invokes ``drain()`` after the deadline, so the actor is never
/// stalled holding its isolation.
public enum DrainResult: Sendable, Equatable {
    /// Nothing pending (or everything sent). The queue is idle.
    case idle
    /// All currently-sendable entries were processed in this pass; call again to
    /// continue (used when entries were dropped/sent and more may remain).
    case progressed
    /// The head entry failed transiently. Re-invoke ``drain()`` no earlier than
    /// `until`. Head-of-line: nothing behind the head is attempted this pass.
    case deferred(until: Date)
    /// The processor is paused awaiting a token refresh (a 401/auth-expired head).
    /// Resume by calling ``resumeAfterAuthRefresh()`` then ``drain()``.
    case authPaused
}

/// Drains an ``OutboxQueue`` FIFO against a ``MutationSender``, applying
/// causal-chain head-of-line blocking, exponential backoff, and maxRetries
/// dropping (M3 plan, STEP 8 / ARCHITECTURE.md §4.2).
///
/// Design notes:
///  - **No in-actor sleep.** Backoff is expressed as a `nextAttemptAt` deadline
///    on the entry and a ``DrainResult/deferred(until:)`` return; an external
///    scheduler owns the timer. This keeps the actor responsive (e.g. to a new
///    `enqueue` that should wake the drainer early).
///  - **Single-flight.** One `drain()` runs at a time per actor; FIFO order is
///    preserved because each pass takes the head, sends it, and only advances
///    past it on a terminal outcome (success/drop).
///  - **Head-of-line on transient failure.** A 5xx/429/offline head stops the
///    pass — entries behind it (which may causally depend on it, e.g. a card
///    create after its deck create) are not attempted until the head clears.
///  - **maxRetries.** After `maxRetries` transient attempts an entry is dropped
///    (logged via the `onDrop` hook) so a permanently-failing head can't wedge
///    the queue forever.
///  - **Self-echo seam.** On success the entry's `(entity, id)` is reported to
///    the `onConfirmed` hook so ``SyncEngine`` can suppress the realtime echo of
///    our own write (invariant #4).
public actor OutboxProcessor {

    /// A confirmed mutation, surfaced so the realtime layer can suppress the echo.
    public struct Confirmed: Sendable, Equatable {
        public let entity: String
        public let recordId: String
    }

    private let queue: OutboxQueue
    private let sender: MutationSender
    private let clock: SyncClock
    private let maxRetries: Int
    private let baseBackoff: TimeInterval
    private let maxBackoff: TimeInterval

    /// Reported on every successful send so the engine can populate its
    /// recently-confirmed set (invariant #4). Optional.
    private let onConfirmed: (@Sendable (Confirmed) async -> Void)?
    /// Reported when an entry is dropped (4xx or retries exhausted). Optional.
    private let onDrop: (@Sendable (OutboxEntry, String) async -> Void)?

    /// Per-entry earliest next-attempt deadline, keyed by entry id. Driven by
    /// backoff; checked before re-sending the head.
    private var nextAttemptAt: [UUID: Date] = [:]
    /// True after a 401; blocks draining until ``resumeAfterAuthRefresh()``.
    private var authPaused = false

    public init(
        queue: OutboxQueue,
        sender: MutationSender,
        clock: SyncClock = SystemSyncClock(),
        maxRetries: Int = 8,
        baseBackoff: TimeInterval = 1.0,
        maxBackoff: TimeInterval = 300.0,
        onConfirmed: (@Sendable (Confirmed) async -> Void)? = nil,
        onDrop: (@Sendable (OutboxEntry, String) async -> Void)? = nil
    ) {
        self.queue = queue
        self.sender = sender
        self.clock = clock
        self.maxRetries = maxRetries
        self.baseBackoff = baseBackoff
        self.maxBackoff = maxBackoff
        self.onConfirmed = onConfirmed
        self.onDrop = onDrop
    }

    /// Clear the auth-paused flag after the caller has refreshed the token.
    public func resumeAfterAuthRefresh() {
        authPaused = false
    }

    /// Whether the processor is currently paused on a dead token.
    public func isAuthPaused() -> Bool { authPaused }

    /// Run one drain pass. Re-invoke per the returned ``DrainResult``.
    ///
    /// Processes entries front-to-back, removing each on a terminal outcome and
    /// stopping at the first transient/auth head. Returns once it hits a
    /// non-progressing state.
    public func drain() async -> DrainResult {
        if authPaused { return .authPaused }

        var progressedAny = false
        while true {
            let pending = await queue.pending()
            guard let head = pending.first else {
                return progressedAny ? .progressed : .idle
            }

            // Respect backoff: if the head isn't due yet, defer.
            if let due = nextAttemptAt[head.id], clock.now() < due {
                return .deferred(until: due)
            }

            let outcome = await sender.send(head)
            switch outcome {
            case .success:
                await reportConfirmed(head)
                await queue.remove(id: head.id)
                nextAttemptAt[head.id] = nil
                progressedAny = true
                continue // advance to the next entry

            case .drop(let status):
                await onDrop?(head, "HTTP \(status)")
                await queue.remove(id: head.id)
                nextAttemptAt[head.id] = nil
                progressedAny = true
                continue // a dropped head unblocks the queue; keep going

            case .authExpired:
                // Do NOT retry a dead token. Pause; the caller refreshes and resumes.
                authPaused = true
                return .authPaused

            case .retry(let reason):
                // Causal-chain head-of-line: stop the pass and back off the head.
                var updated = head
                updated.retryCount += 1
                updated.lastError = reason

                if updated.retryCount > maxRetries {
                    await onDrop?(updated, "max retries exceeded: \(reason)")
                    await queue.remove(id: head.id)
                    nextAttemptAt[head.id] = nil
                    progressedAny = true
                    continue // give up on this head, try the next entry
                }

                await queue.update(updated)
                let delay = backoff(forAttempt: updated.retryCount)
                let due = clock.now().addingTimeInterval(delay)
                nextAttemptAt[head.id] = due
                return .deferred(until: due)
            }
        }
    }

    private func reportConfirmed(_ entry: OutboxEntry) async {
        guard let onConfirmed else { return }
        // For creates the id is in the payload; for update/delete likewise.
        if let recordId = MutationSender.recordId(in: entry.payload) {
            await onConfirmed(Confirmed(entity: entry.entity, recordId: recordId))
        }
    }

    /// Exponential backoff with a cap: `base * 2^(attempt-1)`, clamped to
    /// `maxBackoff`. Attempt is 1-based (first retry → `base`).
    func backoff(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return baseBackoff }
        let exp = pow(2.0, Double(attempt - 1))
        return min(baseBackoff * exp, maxBackoff)
    }
}
