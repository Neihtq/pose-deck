import { defineConfig } from "vitest/config";
import path from "node:path";

// INTEGRATION test config — separate from vitest.config.ts so these specs do
// NOT run in the default unit suite (`npm run test`). They require a LIVE
// PocketBase (the globalSetup starts an ephemeral one, or attaches to
// POSEDECK_TEST_URL). Run with `npm run test:integration`.
//
// node environment (no jsdom): these are pure server-contract tests using the
// PocketBase JS SDK over HTTP. A single fork keeps the shared seed DB sane and
// avoids port contention from a spawned server.
export default defineConfig({
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
  test: {
    globals: true,
    environment: "node",
    include: ["src/**/*.integration.{test,spec}.ts"],
    globalSetup: ["./src/integration/globalSetup.ts"],
    pool: "forks",
    poolOptions: { forks: { singleFork: true } },
    // Spawning a server + many HTTP round-trips can exceed the 5s default.
    testTimeout: 30_000,
    hookTimeout: 60_000,
  },
});
