/**
 * Minimal SSE `EventSource` polyfill for the integration suite (node env).
 *
 * The integration tests run in vitest's `node` environment, which has global
 * `fetch` but NOT `EventSource`. PocketBase's realtime client (`pb.*.subscribe`)
 * does `new EventSource(url)` against the global, so without a polyfill the
 * realtime contract tests throw `ReferenceError: EventSource is not defined`.
 *
 * We do NOT pull a new npm dependency for a test-only shim. This implements the
 * exact subset of the EventSource API the PocketBase SDK touches, backed by
 * `fetch` + a streamed `text/event-stream` body:
 *   - `addEventListener(type, cb)` for named events (PB uses `PB_CONNECT` plus a
 *     per-subscription event whose name is the realtime client id),
 *   - the default `message` event,
 *   - `onerror`,
 *   - `close()`.
 *
 * It parses the SSE wire format (event:/data:/id: lines, blank-line dispatch)
 * and delivers `MessageEvent`-shaped objects ({ data, lastEventId }). This is a
 * genuine HTTP/SSE connection to the live server, so the realtime tests still
 * exercise the real end-to-end contract.
 */

type Listener = (event: { data: string; lastEventId: string }) => void;

export class SseEventSource {
  static readonly CONNECTING = 0;
  static readonly OPEN = 1;
  static readonly CLOSED = 2;

  readonly url: string;
  readyState = SseEventSource.CONNECTING;
  onopen: (() => void) | null = null;
  onerror: ((err?: unknown) => void) | null = null;
  onmessage: Listener | null = null;

  private readonly listeners = new Map<string, Set<Listener>>();
  private readonly controller = new AbortController();
  private closed = false;

  constructor(url: string) {
    this.url = url;
    void this.connect();
  }

  addEventListener(type: string, cb: Listener): void {
    let set = this.listeners.get(type);
    if (!set) {
      set = new Set();
      this.listeners.set(type, set);
    }
    set.add(cb);
  }

  removeEventListener(type: string, cb: Listener): void {
    this.listeners.get(type)?.delete(cb);
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.readyState = SseEventSource.CLOSED;
    this.controller.abort();
  }

  private dispatch(type: string, data: string, lastEventId: string): void {
    const event = { data, lastEventId };
    if (type === "message" && this.onmessage) this.onmessage(event);
    const set = this.listeners.get(type);
    if (set) for (const cb of set) cb(event);
  }

  private emitError(err?: unknown): void {
    if (this.onerror) this.onerror(err);
  }

  private async connect(): Promise<void> {
    try {
      const res = await fetch(this.url, {
        method: "GET",
        headers: { Accept: "text/event-stream" },
        signal: this.controller.signal,
      });
      if (!res.ok || !res.body) {
        this.emitError(new Error(`SSE connect failed: ${res.status}`));
        return;
      }
      this.readyState = SseEventSource.OPEN;
      this.onopen?.();

      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";

      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });

        // SSE dispatches on a blank line; events are separated by \n\n.
        let sep: number;
        while ((sep = buffer.indexOf("\n\n")) !== -1) {
          const raw = buffer.slice(0, sep);
          buffer = buffer.slice(sep + 2);
          this.parseAndDispatch(raw);
        }
      }
    } catch (err) {
      if (!this.closed) this.emitError(err);
    }
  }

  private parseAndDispatch(raw: string): void {
    let eventType = "message";
    let lastEventId = "";
    const dataLines: string[] = [];

    for (const line of raw.split("\n")) {
      if (line === "" || line.startsWith(":")) continue;
      const colon = line.indexOf(":");
      const field = colon === -1 ? line : line.slice(0, colon);
      // Per spec, strip a single leading space after the colon.
      let val = colon === -1 ? "" : line.slice(colon + 1);
      if (val.startsWith(" ")) val = val.slice(1);

      switch (field) {
        case "event":
          eventType = val;
          break;
        case "data":
          dataLines.push(val);
          break;
        case "id":
          lastEventId = val;
          break;
        default:
          break;
      }
    }

    this.dispatch(eventType, dataLines.join("\n"), lastEventId);
  }
}

/** Install the polyfill on `globalThis` if no `EventSource` exists. */
export function installEventSourcePolyfill(): void {
  const g = globalThis as { EventSource?: unknown };
  if (typeof g.EventSource === "undefined") {
    g.EventSource = SseEventSource as unknown;
  }
}
