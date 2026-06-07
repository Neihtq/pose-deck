import { describe, expect, it } from "vitest";

import { RecentlyConfirmed } from "../recentlyConfirmed";

describe("RecentlyConfirmed", () => {
  it("suppresses exactly one echo per mark, then stops", () => {
    let t = 0;
    const rc = new RecentlyConfirmed(5000, () => t);
    rc.mark("decks", "d1");
    expect(rc.shouldSuppress("decks", "d1")).toBe(true); // consumed
    expect(rc.shouldSuppress("decks", "d1")).toBe(false); // already consumed
  });

  it("does not suppress unmarked keys", () => {
    const rc = new RecentlyConfirmed(5000, () => 0);
    expect(rc.shouldSuppress("decks", "nope")).toBe(false);
  });

  it("expires marks after the TTL", () => {
    let t = 0;
    const rc = new RecentlyConfirmed(5000, () => t);
    rc.mark("cards", "c1");
    t = 6000; // past TTL
    expect(rc.shouldSuppress("cards", "c1")).toBe(false);
  });

  it("scopes by entity + id", () => {
    const rc = new RecentlyConfirmed(5000, () => 0);
    rc.mark("decks", "x");
    expect(rc.shouldSuppress("cards", "x")).toBe(false);
    expect(rc.shouldSuppress("decks", "x")).toBe(true);
  });

  it("clear() drops all marks", () => {
    const rc = new RecentlyConfirmed(5000, () => 0);
    rc.mark("decks", "d1");
    rc.clear();
    expect(rc.shouldSuppress("decks", "d1")).toBe(false);
  });

  // Regression (C4): a concurrent remote write strictly newer than what we
  // confirmed must NOT be swallowed by the self-echo suppression within the
  // TTL — it has to flow through to LWW. Our own echo (same clock) is still
  // suppressed, and the mark survives a passed-through newer event.
  it("suppresses our own echo (tie clock) but lets a strictly-newer remote write through", () => {
    const rc = new RecentlyConfirmed(5000, () => 0);
    rc.mark("decks", "d1", "2026-06-06T10:00:00.000Z");

    // A different writer's strictly-newer edit arrives first, within the TTL.
    expect(
      rc.shouldSuppress("decks", "d1", "2026-06-06T10:00:05.000Z"),
    ).toBe(false);

    // The mark is NOT consumed by that pass-through, so our own echo (same
    // clock we sent) is still suppressed when it lands.
    expect(
      rc.shouldSuppress("decks", "d1", "2026-06-06T10:00:00.000Z"),
    ).toBe(true);
  });

  it("suppresses an echo whose clock is <= the confirmed clock", () => {
    const rc = new RecentlyConfirmed(5000, () => 0);
    rc.mark("cards", "c1", "2026-06-06T10:00:00.000Z");
    // Older-or-equal clock is treated as our own echo and suppressed.
    expect(
      rc.shouldSuppress("cards", "c1", "2026-06-06T09:59:59.000Z"),
    ).toBe(true);
  });

  it("falls back to id-only suppression when no clock is recorded (images/guests)", () => {
    const rc = new RecentlyConfirmed(5000, () => 0);
    rc.mark("card_images", "img1"); // no clock for non-LWW entities
    expect(rc.shouldSuppress("card_images", "img1", undefined)).toBe(true);
    expect(rc.shouldSuppress("card_images", "img1", undefined)).toBe(false);
  });
});
