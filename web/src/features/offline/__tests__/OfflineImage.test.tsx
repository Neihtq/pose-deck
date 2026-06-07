/**
 * Component-layer tests for `<OfflineImage>` (M3 STEP 6, invariant #5).
 *
 * The component resolves a card image to either a pinned-blob object URL or a
 * network token URL via `resolveImage`, owns the object-URL lifecycle (revoke on
 * unmount / url-change), renders a `fallback` while resolving, and re-mints a
 * fresh token URL when a NETWORK image's `<img>` fails to load (expired token) —
 * but never retries a cached blob and never loops on an unchanged URL. We mock
 * `resolveImage` to script each path and assert behavior + the release contract.
 */
import { render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { ImageHandle } from "@/lib/offlineImages";
import type { CardImage } from "@/lib/types";

/**
 * Find the rendered `<img>` element. We query the raw element rather than
 * `getByRole("img")` because an `<img>` with an empty `alt` (the component's
 * default, correct for decorative/card thumbnails) has the implicit ARIA role
 * `presentation`, not `img` — so role queries would miss it.
 */
function findImg(): Promise<HTMLImageElement> {
  return waitFor(() => {
    const img = document.querySelector("img");
    if (!img) {
      throw new Error("no <img> yet");
    }
    return img;
  });
}

const resolveImage = vi.fn<(...args: unknown[]) => Promise<ImageHandle>>();

vi.mock("@/lib/offlineImages", () => ({
  resolveImage: (...args: unknown[]) => resolveImage(...args),
}));

import { OfflineImage } from "@/features/offline/OfflineImage";

const IMAGE: CardImage = {
  id: "img-1",
  card: "card-1",
  position: 0,
  file: "pose.jpg",
  created: "2026-01-01T00:00:00Z",
} as CardImage;

function handle(
  url: string,
  fromCache: boolean,
  release = vi.fn(),
): ImageHandle {
  return { url, fromCache, release };
}

beforeEach(() => {
  resolveImage.mockReset();
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("<OfflineImage> (M3)", () => {
  it("renders the fallback while the source is resolving", () => {
    // Never resolves during this test → the component stays in the fallback.
    resolveImage.mockReturnValue(new Promise<ImageHandle>(() => {}));
    render(
      <OfflineImage image={IMAGE} fallback={<span data-testid="ph">…</span>} />,
    );
    expect(screen.getByTestId("ph")).toBeInTheDocument();
    expect(document.querySelector("img")).toBeNull();
  });

  it("renders an <img> with the resolved network URL", async () => {
    resolveImage.mockResolvedValue(handle("https://pb/file?token=abc", false));
    render(<OfflineImage image={IMAGE} alt="Pose" thumb="200x200" />);

    const img = await findImg();
    expect(img).toHaveAttribute("src", "https://pb/file?token=abc");
    expect(img).toHaveAttribute("alt", "Pose");
    // The thumb spec is forwarded to the resolver.
    expect(resolveImage).toHaveBeenCalledWith(
      IMAGE,
      expect.objectContaining({ thumb: "200x200" }),
    );
  });

  it("renders the pinned-blob object URL when served from cache", async () => {
    resolveImage.mockResolvedValue(handle("blob:cached-1", true));
    render(<OfflineImage image={IMAGE} />);
    const img = await findImg();
    expect(img).toHaveAttribute("src", "blob:cached-1");
  });

  it("re-mints a fresh token URL when a NETWORK <img> errors (expired token)", async () => {
    resolveImage
      .mockResolvedValueOnce(handle("https://pb/file?token=stale", false))
      .mockResolvedValueOnce(handle("https://pb/file?token=fresh", false));

    render(<OfflineImage image={IMAGE} />);
    const img = await findImg();
    expect(img).toHaveAttribute("src", "https://pb/file?token=stale");

    // Simulate the browser failing to load the stale-token URL.
    img.dispatchEvent(new Event("error"));

    await waitFor(() =>
      expect(document.querySelector("img")).toHaveAttribute(
        "src",
        "https://pb/file?token=fresh",
      ),
    );
    expect(resolveImage).toHaveBeenCalledTimes(2);
  });

  it("does NOT retry when the errored image was served from cache", async () => {
    resolveImage.mockResolvedValue(handle("blob:cached-1", true));
    render(<OfflineImage image={IMAGE} />);
    const img = await findImg();

    img.dispatchEvent(new Event("error"));
    // A cached blob never expires → no second resolve.
    await Promise.resolve();
    expect(resolveImage).toHaveBeenCalledTimes(1);
    expect(img).toHaveAttribute("src", "blob:cached-1");
  });

  it("does not loop when the re-resolved URL is unchanged (genuine 404)", async () => {
    const releaseRetry = vi.fn();
    resolveImage
      .mockResolvedValueOnce(handle("https://pb/file?token=same", false))
      .mockResolvedValueOnce(handle("https://pb/file?token=same", false, releaseRetry));

    render(<OfflineImage image={IMAGE} />);
    const img = await findImg();

    img.dispatchEvent(new Event("error"));
    await waitFor(() => expect(resolveImage).toHaveBeenCalledTimes(2));
    // Unchanged URL → the retry handle is released (no leak) and src stays put.
    await waitFor(() => expect(releaseRetry).toHaveBeenCalledTimes(1));
    expect(document.querySelector("img")).toHaveAttribute(
      "src",
      "https://pb/file?token=same",
    );
  });

  it("revokes the cached object URL on unmount (no blob leak)", async () => {
    const release = vi.fn();
    resolveImage.mockResolvedValue(handle("blob:cached-1", true, release));
    const { unmount } = render(<OfflineImage image={IMAGE} />);
    await findImg();

    unmount();
    expect(release).toHaveBeenCalledTimes(1);
  });

  it("releases immediately if it resolves AFTER unmount (no late leak)", async () => {
    const release = vi.fn();
    let resolveHandle!: (h: ImageHandle) => void;
    resolveImage.mockReturnValue(
      new Promise<ImageHandle>((res) => {
        resolveHandle = res;
      }),
    );

    const { unmount } = render(<OfflineImage image={IMAGE} />);
    unmount();
    // The async resolve lands after unmount → the handle must self-release.
    resolveHandle(handle("blob:late", true, release));
    await waitFor(() => expect(release).toHaveBeenCalledTimes(1));
  });

  it("forwards extra img props (e.g. className)", async () => {
    resolveImage.mockResolvedValue(handle("https://pb/file", false));
    render(<OfflineImage image={IMAGE} className="rounded" />);
    const img = await findImg();
    expect(img).toHaveClass("rounded");
  });
});
