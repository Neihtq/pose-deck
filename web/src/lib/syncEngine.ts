/**
 * Outbox FIFO drain loop (M3 sync, ARCHITECTURE.md §4.2).
 *
 * The sync engine drains the Dexie outbox in strict FIFO order, one entry at a
 * time (single-flight), sending each through {@link send}. It owns the retry /
 * backoff policy and the head-of-line semantics:
 *
 *  - 2xx success      → delete the entry, reconcile the local row's canonical
 *                        timestamps, mark it recently-confirmed (self-echo
 *                        suppression for the realtime layer), continue.
 *  - 4xx drop         → remove the entry, invoke the rollback hook, surface an
 *                        error to the UI, continue (the bad mutation can't make
 *                        progress; blocking the queue on it would wedge sync).
 *  - 401 auth         → pause the loop until re-auth wakes it (do not drop).
 *  - 429/5xx/offline  → bump retry + exponential backoff on THIS entry and stop
 *                        the pass (head-of-line: a later entry may depend on
 *                        this one, e.g. a card create before its image).
 *  - max retries hit  → drop + rollback + surface, so a permanently-failing
 *                        entry can't wedge the queue forever.
 *
 * Wake triggers (browser): `online`, `visibilitychange`, an interval tick, and
 * explicit `wake()` after an enqueue. Cross-tab single-drainer coordination
 * (Web Locks) is layered by the caller; this module is single-flight within one
 * runtime via an in-progress guard.
 */
import type { PoseDeckDB } from "./db";
import type { OutboxEntry } from "./db";
import {
  bumpRetry,
  deleteEntry,
  markInflight,
  markPending,
  peekFifo,
} from "./outbox";
import { type MutationTransport, pocketBaseTransport, send } from "./serverEntities";

/** Hooks the engine calls so the data/UI layers stay decoupled. */
export interface SyncEngineHooks {
  /** Merge server-canonical fields into the local row after a 2xx. */
  reconcile?(entry: OutboxEntry, serverRecord: unknown): Promise<void> | void;
  /** Best-effort local revert when an entry is dropped on a 4xx / max-retries. */
  rollback?(entry: OutboxEntry, reason: string): Promise<void> | void;
  /** Surface a user-visible error when an entry is dropped. */
  onError?(entry: OutboxEntry, reason: string): void;
  /**
   * Record `(entity,id,clientClock)` as just-confirmed so the realtime layer
   * suppresses the echo of our own mutation (ARCHITECTURE.md §4.4 self-echo).
   */
  onConfirmed?(entry: OutboxEntry, serverRecord: unknown): void;
}

export interface SyncEngineOptions {
  db: PoseDeckDB;
  transport?: MutationTransport;
  hooks?: SyncEngineHooks;
  /** Max send attempts before dropping an entry. */
  maxRetries?: number;
  /** Backoff base / cap (ms) passed to `bumpRetry`. */
  backoff?: { baseMs?: number; maxMs?: number };
  /** Interval (ms) for the periodic wake tick. 0 disables. */
  pollMs?: number;
  /** Injectable clock for deterministic tests. */
  now?: () => number;
}

/** Engine run states (for UI/status surfaces). */
export type SyncEngineState = "idle" | "draining" | "paused";

export class SyncEngine {
  private readonly db: PoseDeckDB;
  private readonly transport: MutationTransport;
  private readonly hooks: SyncEngineHooks;
  private readonly maxRetries: number;
  private readonly backoff: { baseMs?: number; maxMs?: number };
  private readonly pollMs: number;
  private readonly now: () => number;

  private running = false;
  private paused = false;
  /** In-flight drain promise; concurrent callers await the same pass. */
  private drainPromise: Promise<void> | null = null;
  private pollTimer: ReturnType<typeof setInterval> | null = null;
  private boundWake = () => {
    void this.drain();
  };

  constructor(opts: SyncEngineOptions) {
    this.db = opts.db;
    this.transport = opts.transport ?? pocketBaseTransport;
    this.hooks = opts.hooks ?? {};
    this.maxRetries = opts.maxRetries ?? 8;
    this.backoff = opts.backoff ?? {};
    this.pollMs = opts.pollMs ?? 15_000;
    this.now = opts.now ?? (() => Date.now());
  }

  /** Begin draining and register browser wake triggers. Idempotent. */
  start(): void {
    if (this.running) return;
    this.running = true;
    this.paused = false;
    if (typeof window !== "undefined") {
      window.addEventListener("online", this.boundWake);
      document.addEventListener("visibilitychange", this.boundWake);
    }
    if (this.pollMs > 0) {
      this.pollTimer = setInterval(this.boundWake, this.pollMs);
    }
    void this.drain();
  }

  /** Stop draining and remove wake triggers. Safe to call when not started. */
  stop(): void {
    this.running = false;
    if (typeof window !== "undefined") {
      window.removeEventListener("online", this.boundWake);
      document.removeEventListener("visibilitychange", this.boundWake);
    }
    if (this.pollTimer) {
      clearInterval(this.pollTimer);
      this.pollTimer = null;
    }
  }

  /** Re-enable a paused engine (e.g. after re-authentication) and drain. */
  resume(): void {
    this.paused = false;
    void this.drain();
  }

  /** Nudge the loop to drain now (e.g. right after an enqueue). */
  wake(): void {
    void this.drain();
  }

  get state(): SyncEngineState {
    if (this.paused) return "paused";
    return this.drainPromise ? "draining" : "idle";
  }

  /**
   * Drain eligible entries FIFO until none remain or a transient failure stops
   * the pass. Single-flight: concurrent callers await the SAME in-flight pass
   * (so `await drain()` always reflects a completed pass, even if another call
   * is already draining).
   */
  drain(): Promise<void> {
    if (this.paused) return Promise.resolve();
    if (this.drainPromise) return this.drainPromise;
    this.drainPromise = this.runDrain().finally(() => {
      this.drainPromise = null;
    });
    return this.drainPromise;
  }

  private async runDrain(): Promise<void> {
    // Loop until no eligible entry OR a transient failure halts the pass.
    for (;;) {
      if (this.paused) break;
      const entry = await peekFifo(this.db, this.now);
      if (!entry) break;

      await markInflight(this.db, entry.id as number);
      const outcome = await send(entry, this.transport);

      if (outcome.kind === "success") {
        await deleteEntry(this.db, entry.id as number);
        await this.hooks.reconcile?.(entry, outcome.record);
        this.hooks.onConfirmed?.(entry, outcome.record);
        continue; // next entry
      }

      if (outcome.kind === "auth") {
        // Return to pending (so it re-sends after re-auth) and pause.
        await markPending(this.db, entry.id as number);
        this.paused = true;
        break;
      }

      if (outcome.kind === "drop") {
        await deleteEntry(this.db, entry.id as number);
        await this.hooks.rollback?.(entry, outcome.reason);
        this.hooks.onError?.(entry, outcome.reason);
        continue; // the bad entry is gone; keep draining the rest
      }

      // retry: bump backoff on this entry and STOP this pass (head-of-line).
      const attempts = await bumpRetry(
        this.db,
        entry,
        outcome.reason,
        this.backoff,
        this.now,
      );
      if (attempts >= this.maxRetries) {
        await deleteEntry(this.db, entry.id as number);
        await this.hooks.rollback?.(entry, `max retries: ${outcome.reason}`);
        this.hooks.onError?.(entry, `max retries: ${outcome.reason}`);
        continue; // give up on this one, keep going
      }
      break; // back off; a later wake (or poll) retries the head
    }
  }
}
