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

  it("revokes the re-resolved pinned blob on unmount when a NETWORK <img> errors into the cache (no blob leak)", async () => {
    // Initial resolve: a NETWORK url (release is a no-op). While viewing, the
    // deck gets pinned, so the error-retry re-resolves into a CACHED blob whose
    // release REVOKES an object URL. That release must be owned by the component
    // so unmount revokes it — otherwise the object URL leaks.
    const cachedRelease = vi.fn();
    resolveImage
      .mockResolvedValueOnce(handle("https://pb/file?token=stale", false))
      .mockResolvedValueOnce(handle("blob:re-pinned", true, cachedRelease));

    const { unmount } = render(<OfflineImage image={IMAGE} />);
    const img = await findImg();
    expect(img).toHaveAttribute("src", "https://pb/file?token=stale");

    // The network <img> fails (expired token); retry resolves a pinned blob.
    img.dispatchEvent(new Event("error"));
    await waitFor(() =>
      expect(document.querySelector("img")).toHaveAttribute(
        "src",
        "blob:re-pinned",
      ),
    );

    // Unmount must revoke the now-live cached blob URL.
    unmount();
    expect(cachedRelease).toHaveBeenCalledTimes(1);
  });

  it("does not setState or leak if a NETWORK <img> errors and re-resolves AFTER unmount", async () => {
    const lateRelease = vi.fn();
    let resolveRetry!: (h: ImageHandle) => void;
    resolveImage
      .mockResolvedValueOnce(handle("https://pb/file?token=stale", false))
      .mockReturnValueOnce(
        new Promise<ImageHandle>((res) => {
          resolveRetry = res;
        }),
      );

    const { unmount } = render(<OfflineImage image={IMAGE} />);
    const img = await findImg();

    // Kick off the retry, then unmount before it resolves.
    img.dispatchEvent(new Event("error"));
    unmount();

    // The retry lands post-unmount: it must self-release (no leak) and must not
    // setState on the dead component.
    resolveRetry(handle("blob:late-pinned", true, lateRelease));
    await waitFor(() => expect(lateRelease).toHaveBeenCalledTimes(1));
  });

  it("does not adopt a STALE error-path resolve into a newer cycle after image/opts change (react-3)", async () => {
    // Regression for react-3: a NETWORK <img> errors and the error-path token
    // refresh starts an in-flight resolve for the CURRENT image/opts. While that
    // network round-trip is pending, the props change (e.g. `thumb`), tearing
    // down the old resolve cycle and starting a new one with its own resolve.
    // When the STALE error-path resolve finally lands, it must NOT adopt: the
    // shared `mountedRef` is already true again for the new cycle, so without a
    // per-cycle generation tag it would revoke the live handle and briefly show
    // the wrong (stale) image variant.
    const newCycleRelease = vi.fn();
    const staleRetryRelease = vi.fn();

    // Hold the error-path retry resolve open so we control exactly when it lands.
    let landStaleRetry!: (h: ImageHandle) => void;

    resolveImage
      // 1) Initial effect resolve: a NETWORK url whose token will "expire".
      .mockResolvedValueOnce(handle("https://pb/file?token=stale", false))
      // 2) Error-path retry resolve: PENDING until we land it manually.
      .mockReturnValueOnce(
        new Promise<ImageHandle>((res) => {
          landStaleRetry = res;
        }),
      )
      // 3) New cycle's effect resolve (after the `thumb` change): the correct,
      //    current variant the component should be displaying.
      .mockResolvedValueOnce(
        handle("https://pb/file?token=new-variant", false, newCycleRelease),
      );

    const { rerender } = render(<OfflineImage image={IMAGE} />);
    const img = await findImg();
    expect(img).toHaveAttribute("src", "https://pb/file?token=stale");

    // The network <img> fails: kick off the error-path retry (now pending).
    img.dispatchEvent(new Event("error"));
    await waitFor(() => expect(resolveImage).toHaveBeenCalledTimes(2));

    // Props change mid-flight → old cycle torn down, new cycle resolves.
    rerender(<OfflineImage image={IMAGE} thumb="200x200" />);
    await waitFor(() =>
      expect(document.querySelector("img")).toHaveAttribute(
        "src",
        "https://pb/file?token=new-variant",
      ),
    );
    expect(resolveImage).toHaveBeenCalledTimes(3);

    // NOW the stale error-path retry lands. It belongs to the OLD cycle and must
    // self-release (no adoption): the displayed src must stay on the new variant
    // and the new cycle's live handle must NOT be revoked.
    landStaleRetry(handle("https://pb/file?token=stale-variant", false, staleRetryRelease));
    await waitFor(() => expect(staleRetryRelease).toHaveBeenCalledTimes(1));

    expect(document.querySelector("img")).toHaveAttribute(
      "src",
      "https://pb/file?token=new-variant",
    );
    expect(newCycleRelease).not.toHaveBeenCalled();
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
