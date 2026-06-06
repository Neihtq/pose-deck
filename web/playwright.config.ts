import { defineConfig, devices } from "@playwright/test";

/**
 * Playwright E2E config for the Pose Deck web app (M1).
 *
 * Drives the real React app served by the Vite dev server against the LIVE
 * PocketBase backend (ARCHITECTURE.md §12). Tests sign in with the dev-seed
 * owner account (backend/pb_migrations/1700000010_dev_seed.js) and exercise
 * the M1 prep flows end-to-end:
 *   login → create deck → see grouping → open deck → add/edit card → reorder
 *   → attach image.
 *
 * Prerequisites (see e2e/README or the spec gate notes):
 *   - PocketBase running on VITE_API_BASE_URL (default http://localhost:8090)
 *     started with POSEDECK_DEV=true so the seed user exists.
 *   - Chromium installed via `npx playwright install chromium`.
 *
 * The dev server is started automatically via the `webServer` block and the
 * API base URL is threaded through so the app talks to the same backend the
 * tests assume.
 */

const API_BASE_URL = process.env.VITE_API_BASE_URL ?? "http://localhost:8090";
const PORT = Number(process.env.E2E_PORT ?? 5173);
const BASE_URL = `http://localhost:${PORT}`;

export default defineConfig({
  testDir: "./e2e",
  // Mutations against a shared live backend must not race each other.
  fullyParallel: false,
  workers: 1,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? [["github"], ["list"]] : [["list"]],
  timeout: 60_000,
  expect: { timeout: 10_000 },

  use: {
    baseURL: BASE_URL,
    trace: "on-first-retry",
    screenshot: "only-on-failure",
    video: "retain-on-failure",
  },

  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],

  webServer: {
    command: `npm run dev -- --port ${PORT} --strictPort`,
    url: BASE_URL,
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
    env: {
      VITE_API_BASE_URL: API_BASE_URL,
    },
  },
});
