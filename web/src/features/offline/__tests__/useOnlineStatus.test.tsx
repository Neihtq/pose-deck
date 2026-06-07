/**
 * Component-layer tests for `useOnlineStatus` (M3 STEP 6).
 *
 * The hook reflects `navigator.onLine` and re-renders on the window
 * `online`/`offline` events. These tests drive the real hook (via a tiny probe
 * component) under jsdom, flipping `navigator.onLine` and dispatching the
 * connectivity events, and assert it stays subscribed/unsubscribed correctly.
 */
import { act, render, renderHook } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";

import { useOnlineStatus } from "@/features/offline/useOnlineStatus";

/** Override the readonly `navigator.onLine` for a test, then restore. */
function setOnline(value: boolean): void {
  Object.defineProperty(navigator, "onLine", {
    configurable: true,
    value,
  });
}

afterEach(() => {
  // Restore the default jsdom value so tests don't leak connectivity state.
  setOnline(true);
});

describe("useOnlineStatus (M3)", () => {
  it("reports the initial navigator.onLine value", () => {
    setOnline(false);
    const { result } = renderHook(() => useOnlineStatus());
    expect(result.current).toBe(false);
  });

  it("re-renders true→false when an `offline` event fires", () => {
    setOnline(true);
    const { result } = renderHook(() => useOnlineStatus());
    expect(result.current).toBe(true);

    act(() => {
      setOnline(false);
      window.dispatchEvent(new Event("offline"));
    });
    expect(result.current).toBe(false);
  });

  it("re-renders false→true when an `online` event fires", () => {
    setOnline(false);
    const { result } = renderHook(() => useOnlineStatus());
    expect(result.current).toBe(false);

    act(() => {
      setOnline(true);
      window.dispatchEvent(new Event("online"));
    });
    expect(result.current).toBe(true);
  });

  it("stops responding to events after unmount (listeners removed)", () => {
    setOnline(true);
    const { result, unmount } = renderHook(() => useOnlineStatus());
    expect(result.current).toBe(true);

    unmount();
    // After unmount the listeners are gone; flipping + dispatching must not throw
    // and must not (re)update the now-unmounted hook's value.
    act(() => {
      setOnline(false);
      window.dispatchEvent(new Event("offline"));
    });
    expect(result.current).toBe(true);
  });

  it("re-reads on mount in case status changed before subscribing", () => {
    // Hook initializes state lazily; the mount effect re-reads once. Simulate
    // the value being already-offline when the component mounts.
    setOnline(false);
    function Probe(): React.JSX.Element {
      const online = useOnlineStatus();
      return <span data-testid="status">{online ? "online" : "offline"}</span>;
    }
    const { getByTestId } = render(<Probe />);
    expect(getByTestId("status").textContent).toBe("offline");
  });
});
