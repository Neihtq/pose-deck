/**
 * Ephemeral PocketBase lifecycle for the INTEGRATION test layer.
 *
 * These tests assert the real server contract the M1 data layer depends on
 * (API rules, soft-delete filtering, cascade deletes, required-field
 * validation, reorder/position behaviour). They therefore need a LIVE
 * PocketBase running the version-controlled migrations in
 * `backend/pb_migrations`, with the dev seed applied (`POSEDECK_DEV=true`).
 *
 * Strategy:
 *  - If `POSEDECK_TEST_URL` is set, use that already-running server as-is
 *    (CI may provision one). We never start/stop it ourselves.
 *  - Otherwise spawn the bare `backend/pocketbase` binary on a dedicated test
 *    port, pointed at a throwaway temp data dir and the repo's pb_migrations,
 *    with `POSEDECK_DEV=true` so the two seed users + sample deck exist. The
 *    temp dir keeps the dev DB (`backend/pb_data`) untouched, and the process
 *    is killed + the dir removed on teardown.
 *
 * If no binary is present and no URL is provided, callers should SKIP the
 * suite rather than fail — a backend may be absent in CI.
 */
import { spawn, type ChildProcess } from "node:child_process";
import { mkdtempSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

/** Default port for the spawned ephemeral server (kept off the dev 8090). */
const DEFAULT_TEST_PORT = 8091;

/** Repo paths, resolved relative to this file (web/src/integration). */
const WEB_ROOT = resolve(__dirname, "..", "..");
const REPO_ROOT = resolve(WEB_ROOT, "..");
const BACKEND_DIR = join(REPO_ROOT, "backend");
const PB_BINARY = join(BACKEND_DIR, "pocketbase");
const PB_MIGRATIONS = join(BACKEND_DIR, "pb_migrations");

/** Dev seed credentials (created by 1700000010_dev_seed.js under POSEDECK_DEV). */
export const OWNER_EMAIL = "owner@posedeck.test";
export const GUEST_EMAIL = "guest@posedeck.test";
export const SEED_PASSWORD = "changeme123";

export interface PbHandle {
  /** Base URL of the live server, e.g. http://127.0.0.1:8091. */
  url: string;
  /** Stop the server (no-op if we attached to an externally-provided one). */
  stop: () => Promise<void>;
}

/** Result of attempting to obtain a live server. */
export type PbStartResult =
  | { ok: true; handle: PbHandle }
  | { ok: false; reason: string };

async function isHealthy(url: string, timeoutMs = 1000): Promise<boolean> {
  try {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), timeoutMs);
    const res = await fetch(`${url}/api/health`, { signal: ctrl.signal });
    clearTimeout(t);
    return res.ok;
  } catch {
    return false;
  }
}

async function waitForHealthy(url: string, attempts = 60): Promise<boolean> {
  for (let i = 0; i < attempts; i++) {
    if (await isHealthy(url)) return true;
    await new Promise((r) => setTimeout(r, 250));
  }
  return false;
}

/**
 * Obtain a live PocketBase for the integration suite.
 *
 * Order of preference:
 *  1. `POSEDECK_TEST_URL` env → attach to it (must already be healthy).
 *  2. Spawn `backend/pocketbase` on `POSEDECK_TEST_PORT` (default 8091).
 *
 * Returns `{ ok: false, reason }` when no backend can be obtained so the
 * caller can mark the suite skipped instead of failing.
 */
export async function startPocketBase(): Promise<PbStartResult> {
  // 1. Externally provided server.
  const externalUrl = process.env.POSEDECK_TEST_URL;
  if (externalUrl && externalUrl.trim() !== "") {
    const url = externalUrl.trim().replace(/\/$/, "");
    if (await isHealthy(url, 3000)) {
      return { ok: true, handle: { url, stop: async () => {} } };
    }
    return {
      ok: false,
      reason: `POSEDECK_TEST_URL=${url} set but server not healthy`,
    };
  }

  // 2. Spawn the bare binary.
  if (!existsSync(PB_BINARY)) {
    return {
      ok: false,
      reason:
        `No PocketBase binary at ${PB_BINARY} and POSEDECK_TEST_URL unset. ` +
        `Download it (see backend/README.md) or set POSEDECK_TEST_URL.`,
    };
  }

  const port = Number(process.env.POSEDECK_TEST_PORT ?? DEFAULT_TEST_PORT);
  const url = `http://127.0.0.1:${port}`;

  // If something is already serving on the test port, don't spawn a second
  // one — attach to it (and leave it running on teardown).
  if (await isHealthy(url)) {
    return { ok: true, handle: { url, stop: async () => {} } };
  }

  const dataDir = mkdtempSync(join(tmpdir(), "posedeck-it-"));
  let child: ChildProcess;
  try {
    child = spawn(
      PB_BINARY,
      [
        "serve",
        `--http=127.0.0.1:${port}`,
        `--dir=${dataDir}`,
        `--migrationsDir=${PB_MIGRATIONS}`,
      ],
      {
        cwd: BACKEND_DIR,
        env: { ...process.env, POSEDECK_DEV: "true" },
        stdio: "ignore",
      },
    );
  } catch (err) {
    rmSync(dataDir, { recursive: true, force: true });
    return { ok: false, reason: `Failed to spawn PocketBase: ${String(err)}` };
  }

  let exitedEarly = false;
  child.once("exit", () => {
    exitedEarly = true;
  });

  const healthy = await waitForHealthy(url);
  if (!healthy || exitedEarly) {
    try {
      child.kill("SIGKILL");
    } catch {
      /* ignore */
    }
    rmSync(dataDir, { recursive: true, force: true });
    return {
      ok: false,
      reason: `Spawned PocketBase did not become healthy at ${url}`,
    };
  }

  const stop = async (): Promise<void> => {
    await new Promise<void>((res) => {
      if (child.killed || exitedEarly) {
        res();
        return;
      }
      child.once("exit", () => res());
      child.kill("SIGTERM");
      // Hard stop if it lingers.
      setTimeout(() => {
        try {
          child.kill("SIGKILL");
        } catch {
          /* ignore */
        }
        res();
      }, 4000);
    });
    rmSync(dataDir, { recursive: true, force: true });
  };

  return { ok: true, handle: { url, stop } };
}
