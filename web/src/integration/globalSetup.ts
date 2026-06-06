/**
 * Vitest globalSetup for the integration suite.
 *
 * Starts ONE live PocketBase for the whole run (or attaches to an existing
 * one), publishes its URL via `provide()` so specs can read it, and tears it
 * down afterwards. If no backend can be obtained, it still publishes a skip
 * reason instead of throwing — the specs detect this and mark themselves
 * skipped (a backend may legitimately be absent in CI).
 */
import type { TestProject } from "vitest/node";

import { startPocketBase, type PbHandle } from "./pbServer";

let handle: PbHandle | null = null;

export default async function setup(project: TestProject): Promise<() => Promise<void>> {
  const result = await startPocketBase();

  if (result.ok) {
    handle = result.handle;
    project.provide("pbUrl", handle.url);
    project.provide("pbSkipReason", "");
  } else {
    project.provide("pbUrl", "");
    project.provide("pbSkipReason", result.reason);
  }

  return async () => {
    if (handle) {
      await handle.stop();
      handle = null;
    }
  };
}

declare module "vitest" {
  export interface ProvidedContext {
    pbUrl: string;
    pbSkipReason: string;
  }
}
