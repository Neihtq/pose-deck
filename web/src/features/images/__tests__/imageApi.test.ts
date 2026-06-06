import { beforeEach, describe, expect, it, vi } from "vitest";

import type { CardImage } from "@/lib/types";

// Mock the PocketBase client wrapper so imageApi never touches the network.
const getFullList = vi.fn();

// Mirror PocketBase's `pb.filter()` autoescaping so the binding-based filter
// (finding SEC-1) builds a real, escaped clause in this test. Defined via
// vi.hoisted so it exists when the (hoisted) vi.mock factory runs.
const { filter } = vi.hoisted(() => ({
  filter: vi.fn((raw: string, params?: Record<string, unknown>) =>
    raw.replace(/\{:(\w+)\}/g, (_match, key: string) => {
      const value = params?.[key];
      if (typeof value === "string") {
        return `'${value.replace(/'/g, "\\'")}'`;
      }
      return String(value);
    }),
  ),
}));

vi.mock("@/lib/pocketbase", () => ({
  collections: {
    card_images: () => ({ getFullList }),
  },
  fileUrlWithToken: vi.fn(),
  pb: { filter },
}));

import { listCardImages } from "@/features/images/imageApi";

beforeEach(() => {
  getFullList.mockReset();
  filter.mockClear();
});

describe("listCardImages (filter binding)", () => {
  // Regression (finding SEC-1): the card id originates from a URL-derived,
  // attacker-controllable value and MUST be bound via `pb.filter()` rather than
  // string-interpolated into the filter clause.
  it("binds the card id via pb.filter instead of raw interpolation", async () => {
    getFullList.mockResolvedValue([] as CardImage[]);

    await listCardImages('x" || position > 0 || card = "');

    expect(filter).toHaveBeenCalledTimes(1);
    const [raw, params] = filter.mock.calls[0];
    expect(raw).toContain("{:card}");
    expect(params).toEqual({ card: 'x" || position > 0 || card = "' });

    const builtFilter = getFullList.mock.calls[0][0].filter;
    expect(builtFilter).not.toContain('card = "x" || position > 0');
  });
});
