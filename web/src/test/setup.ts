import "@testing-library/jest-dom/vitest";
// Provide an in-memory IndexedDB so Dexie works under jsdom/node.
import "fake-indexeddb/auto";

// Radix UI (dropdown menu, dialog, alert-dialog) relies on PointerEvent +
// pointer-capture + scrollIntoView APIs that jsdom does not implement. Polyfill
// them globally so any component test driving a Radix overlay can open it.
// (Mirrors the per-file polyfills previously inlined in DeckCardPendingGuard.)
if (typeof window !== "undefined") {
  if (typeof window.PointerEvent === "undefined") {
    class PointerEventPolyfill extends MouseEvent {
      public pointerId: number;
      public pointerType: string;
      constructor(type: string, params: PointerEventInit = {}) {
        super(type, params);
        this.pointerId = params.pointerId ?? 1;
        this.pointerType = params.pointerType ?? "mouse";
      }
    }
    // @ts-expect-error assigning a test polyfill onto the jsdom window
    window.PointerEvent = PointerEventPolyfill;
  }
  if (!Element.prototype.hasPointerCapture) {
    Element.prototype.hasPointerCapture = () => false;
  }
  if (!Element.prototype.setPointerCapture) {
    Element.prototype.setPointerCapture = () => {};
  }
  if (!Element.prototype.releasePointerCapture) {
    Element.prototype.releasePointerCapture = () => {};
  }
  if (!Element.prototype.scrollIntoView) {
    Element.prototype.scrollIntoView = () => {};
  }
  // jsdom lacks matchMedia, which ThemeProvider uses to read the OS color
  // scheme. Provide a stub that reports "light" and ignores listeners.
  if (typeof window.matchMedia !== "function") {
    window.matchMedia = (query: string): MediaQueryList =>
      ({
        matches: false,
        media: query,
        onchange: null,
        addEventListener: () => {},
        removeEventListener: () => {},
        addListener: () => {},
        removeListener: () => {},
        dispatchEvent: () => false,
      }) as unknown as MediaQueryList;
  }
}
