/**
 * Regression test for SEC-OBS-2: the session JWT must NOT be persisted to the
 * durable, always-script-readable `localStorage`. We back the PocketBase auth
 * store with `sessionStorage` instead, which still survives reloads within the
 * tab but is dropped when the tab/browser closes — narrowing the XSS
 * exfiltration window and removing the durable on-disk copy of the token.
 */
import { beforeEach, describe, expect, it } from "vitest";

import {
  AUTH_STORAGE_KEY,
  createPocketBase,
  createSessionAuthStore,
} from "../pocketbase";

/** A throwaway, syntactically-valid (unsigned) JWT for store round-trips. */
const FAKE_TOKEN = "eyJhbGciOiJub25lIn0.eyJpZCI6InUxIn0.";

/** A minimal but type-complete auth record for `authStore.save`. */
const FAKE_RECORD = {
  id: "u1",
  collectionId: "users",
  collectionName: "users",
};

/** The localStorage key the SDK's default LocalAuthStore would have used. */
const SDK_DEFAULT_LOCAL_KEY = "pocketbase_auth";

/**
 * AsyncAuthStore persists via an internal promise queue, so saves/clears land
 * on a microtask, not synchronously. Drain the queue before asserting storage.
 */
async function flush(): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, 0));
}

describe("pocketbase auth store (SEC-OBS-2)", () => {
  beforeEach(() => {
    localStorage.clear();
    sessionStorage.clear();
  });

  it("persists the auth token to sessionStorage, never localStorage", async () => {
    const pb = createPocketBase("http://localhost:8090");

    pb.authStore.save(FAKE_TOKEN, FAKE_RECORD);
    await flush();

    // The token lands in sessionStorage under our key.
    expect(sessionStorage.getItem(AUTH_STORAGE_KEY)).toContain(FAKE_TOKEN);

    // ...and the durable, XSS-readable localStorage holds NO token, under
    // either our key or the SDK default LocalAuthStore key.
    expect(localStorage.getItem(AUTH_STORAGE_KEY)).toBeNull();
    expect(localStorage.getItem(SDK_DEFAULT_LOCAL_KEY)).toBeNull();
    // Belt-and-suspenders: no localStorage entry anywhere contains the token.
    const localValues = Object.keys(localStorage).map((k) =>
      localStorage.getItem(k),
    );
    expect(localValues.every((v) => !v?.includes(FAKE_TOKEN))).toBe(true);
  });

  it("loads an existing sessionStorage token on construction (survives reload)", async () => {
    sessionStorage.setItem(
      AUTH_STORAGE_KEY,
      JSON.stringify({
        token: FAKE_TOKEN,
        record: FAKE_RECORD,
      }),
    );

    const pb = createPocketBase("http://localhost:8090");
    await flush();

    expect(pb.authStore.token).toBe(FAKE_TOKEN);
    expect(pb.authStore.record?.id).toBe("u1");
  });

  it("clears the sessionStorage entry on sign-out", async () => {
    const store = createSessionAuthStore();
    store.save(FAKE_TOKEN, FAKE_RECORD);
    await flush();
    expect(sessionStorage.getItem(AUTH_STORAGE_KEY)).toContain(FAKE_TOKEN);

    store.clear();
    await flush();

    expect(sessionStorage.getItem(AUTH_STORAGE_KEY)).toBeNull();
    expect(store.token).toBe("");
  });
});
