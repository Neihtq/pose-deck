import { beforeEach, describe, expect, it, vi } from "vitest";

import { db } from "@/lib/db";
import type { CardImage } from "@/lib/types";

// Mock the PocketBase client wrapper so imageApi never touches the network.
const getFullList = vi.fn();
const create = vi.fn();
const remove = vi.fn();

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
    card_images: () => ({ getFullList, create, delete: remove }),
  },
  fileUrlWithToken: vi.fn(),
  pb: { filter },
}));

import {
  deleteCardImage,
  listCardImages,
  uploadCardImage,
} from "@/features/images/imageApi";

beforeEach(async () => {
  getFullList.mockReset();
  create.mockReset();
  remove.mockReset();
  filter.mockClear();
  await db.card_images.clear();
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

describe("Dexie mirroring (M3: images stay PB-direct but mirror locally)", () => {
  it("uploadCardImage mirrors the created record into Dexie", async () => {
    getFullList.mockResolvedValue([] as CardImage[]); // under the per-card cap
    const record: CardImage = {
      id: "img1",
      card: "card1",
      position: 1000,
      file: "photo.jpg",
      created: "2026-06-07T00:00:00.000Z",
    };
    create.mockResolvedValue(record);

    const result = await uploadCardImage("card1", new Blob(["x"]), 1000);

    expect(result.id).toBe("img1");
    // PB create was called (image upload is NOT routed through the outbox).
    expect(create).toHaveBeenCalledTimes(1);
    // The result is mirrored into the local store for live queries.
    expect(await db.card_images.get("img1")).toMatchObject({
      id: "img1",
      card: "card1",
    });
  });

  it("deleteCardImage hard-deletes on PB and drops the local row", async () => {
    await db.card_images.put({
      id: "img1",
      card: "card1",
      position: 1000,
      file: "photo.jpg",
      created: "",
    });
    remove.mockResolvedValue(undefined);

    await deleteCardImage("img1");

    expect(remove).toHaveBeenCalledWith("img1");
    expect(await db.card_images.get("img1")).toBeUndefined();
  });
});
