/**
 * `useOnlineStatus` — reactive `navigator.onLine` (M3 STEP 6).
 *
 * Reflects the browser's connectivity flag, updating on the `online`/`offline`
 * window events. Used by the offline toggle to label/disable pinning when there
 * is no network. `navigator.onLine` is a coarse signal (it only knows whether
 * there is *a* network interface, not whether the server is reachable), which
 * is exactly the granularity the UI needs here.
 */
import * as React from "react";

/** Read the current online flag, defaulting to `true` where unavailable (SSR). */
function readOnline(): boolean {
  if (typeof navigator === "undefined") {
    return true;
  }
  return navigator.onLine;
}

/** Subscribe to connectivity changes; re-renders on `online`/`offline`. */
export function useOnlineStatus(): boolean {
  const [online, setOnline] = React.useState<boolean>(readOnline);

  React.useEffect(() => {
    const update = () => setOnline(readOnline());
    window.addEventListener("online", update);
    window.addEventListener("offline", update);
    // Re-read once on mount in case the status changed before we subscribed.
    update();
    return () => {
      window.removeEventListener("online", update);
      window.removeEventListener("offline", update);
    };
  }, []);

  return online;
}
