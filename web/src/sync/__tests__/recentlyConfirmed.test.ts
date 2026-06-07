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
});
