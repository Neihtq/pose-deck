import { describe, expect, it } from "vitest";

import {
  PB_ID_LENGTH,
  isClientId,
  newClientId,
  newIdempotencyKey,
} from "../ids";

describe("newClientId", () => {
  it("mints a 15-char lowercase-alphanumeric id", () => {
    for (let i = 0; i < 200; i++) {
      const id = newClientId();
      expect(id).toHaveLength(PB_ID_LENGTH);
      expect(id).toMatch(/^[a-z0-9]{15}$/);
    }
  });

  it("is effectively unique across many mints", () => {
    const seen = new Set<string>();
    for (let i = 0; i < 5000; i++) seen.add(newClientId());
    // Collisions in 36^15 space over 5k samples are astronomically unlikely.
    expect(seen.size).toBe(5000);
  });
});

describe("isClientId", () => {
  it("accepts a freshly minted id", () => {
    expect(isClientId(newClientId())).toBe(true);
  });

  it("rejects wrong length, uppercase, symbols, and non-strings", () => {
    expect(isClientId("short")).toBe(false);
    expect(isClientId("ABCDEFGHIJKLMNO")).toBe(false); // uppercase
    expect(isClientId("abcdefghijklmn-")).toBe(false); // symbol
    expect(isClientId("a".repeat(16))).toBe(false); // too long
    expect(isClientId(123)).toBe(false);
    expect(isClientId(undefined)).toBe(false);
  });
});

describe("newIdempotencyKey", () => {
  it("returns a UUID-shaped string", () => {
    expect(newIdempotencyKey()).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
    );
  });
});
