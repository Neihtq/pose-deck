/**
 * Service-worker registration entry (M3 STEP 6).
 *
 * Uses vite-plugin-pwa's virtual `virtual:pwa-register` module to register the
 * worker built from `src/sw.ts`. Registration is intentionally minimal: the SW
 * only precaches the static app shell (NetworkOnly for everything else), so a
 * silent auto-update is fine — there is no cached API data that a stale shell
 * could surface incorrectly.
 *
 * In dev the plugin is configured `enabled: false`, in which case the virtual
 * module's `registerSW` is a no-op, so this is safe to call unconditionally.
 */
import { registerSW } from "virtual:pwa-register";

/** Register the app-shell service worker. Safe to call once at startup. */
export function registerServiceWorker(): void {
  registerSW({ immediate: true });
}
