/**
 * Offline unit tests for the auth context.
 *
 * The `@/lib/pocketbase` module is fully mocked so no network or real SDK is
 * involved. The mock implements a minimal `authStore` (record / isValid /
 * onChange / clear) plus `authWithPassword`, mirroring the slice of the SDK
 * the context relies on.
 */
import * as React from "react";

import { act, render, renderHook, screen, waitFor } from "@testing-library/react";
import { ClientResponseError } from "pocketbase";
import { beforeEach, describe, expect, it, vi } from "vitest";

import type { User } from "@/lib/types";

// --- Mock the shared PocketBase module ------------------------------------

/** A user returned by a successful sign-in. */
const FAKE_USER: User = {
  id: "u1",
  email: "owner@posedeck.test",
  name: "Owner",
  created: "2026-06-06T10:00:00.000Z",
  updated: "2026-06-06T10:00:00.000Z",
  verified: true,
};

/**
 * Minimal in-memory auth store that fires onChange listeners on mutation,
 * matching the behaviour the context depends on.
 */
class FakeAuthStore {
  record: User | null = null;
  private listeners = new Set<() => void>();

  get isValid(): boolean {
    return this.record !== null;
  }

  onChange(cb: () => void): () => void {
    this.listeners.add(cb);
    return () => this.listeners.delete(cb);
  }

  private emit(): void {
    for (const cb of this.listeners) cb();
  }

  /** Test helper: simulate a successful auth save. */
  save(user: User): void {
    this.record = user;
    this.emit();
  }

  clear(): void {
    this.record = null;
    this.emit();
  }
}

const fakeAuthStore = new FakeAuthStore();

const authWithPassword = vi.fn(async (_email: string, _password: string) => {
  fakeAuthStore.save(FAKE_USER);
  return { token: "tok", record: FAKE_USER };
});

vi.mock("@/lib/pocketbase", () => {
  return {
    pb: {
      get authStore() {
        return fakeAuthStore;
      },
    },
    collections: {
      users: () => ({ authWithPassword }),
    },
    isAuthenticated: () => fakeAuthStore.isValid,
    currentUser: () => fakeAuthStore.record,
    clearFileToken: vi.fn(),
  };
});

// AuthContext starts/stops the sync runtime on auth transitions. Stub it so the
// context unit tests don't construct a real engine / open realtime subscriptions
// against the mocked PocketBase.
const startSync = vi.fn(async () => {});
const stopSync = vi.fn(async () => {});
vi.mock("@/sync", () => ({
  startSync: () => startSync(),
  stopSync: () => stopSync(),
}));

// Import after the mock is registered so the context binds to the fake.
import { clearFileToken } from "@/lib/pocketbase";

import { AuthProvider, clearAuthOnUnauthorized, useAuth } from "../AuthContext";

// Typed handle to the mocked clearFileToken so we can assert on it.
const clearFileTokenMock = vi.mocked(clearFileToken);

function wrapper({ children }: { children: React.ReactNode }) {
  return <AuthProvider>{children}</AuthProvider>;
}

beforeEach(() => {
  fakeAuthStore.clear();
  authWithPassword.mockClear();
  clearFileTokenMock.mockClear();
  startSync.mockClear();
  stopSync.mockClear();
});

describe("AuthProvider / useAuth", () => {
  it("starts unauthenticated and resolves loading", async () => {
    const { result } = renderHook(() => useAuth(), { wrapper });

    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(result.current.isAuthenticated).toBe(false);
    expect(result.current.user).toBeNull();
  });

  it("signIn authenticates and updates state from the store", async () => {
    const { result } = renderHook(() => useAuth(), { wrapper });
    await waitFor(() => expect(result.current.loading).toBe(false));

    await act(async () => {
      await result.current.signIn("owner@posedeck.test", "changeme123");
    });

    expect(authWithPassword).toHaveBeenCalledWith(
      "owner@posedeck.test",
      "changeme123",
    );
    await waitFor(() => expect(result.current.isAuthenticated).toBe(true));
    expect(result.current.user).toEqual(FAKE_USER);
  });

  it("signOut clears state", async () => {
    const { result } = renderHook(() => useAuth(), { wrapper });
    await waitFor(() => expect(result.current.loading).toBe(false));

    await act(async () => {
      await result.current.signIn("owner@posedeck.test", "changeme123");
    });
    await waitFor(() => expect(result.current.isAuthenticated).toBe(true));

    act(() => {
      result.current.signOut();
    });

    await waitFor(() => expect(result.current.isAuthenticated).toBe(false));
    expect(result.current.user).toBeNull();
  });

  it("starts sync on sign-in and stops it on sign-out (M3)", async () => {
    const { result } = renderHook(() => useAuth(), { wrapper });
    await waitFor(() => expect(result.current.loading).toBe(false));
    // Mounted while signed out → no start yet.
    expect(startSync).not.toHaveBeenCalled();

    await act(async () => {
      await result.current.signIn("owner@posedeck.test", "changeme123");
    });
    await waitFor(() => expect(startSync).toHaveBeenCalled());
    expect(stopSync).not.toHaveBeenCalled();

    act(() => {
      result.current.signOut();
    });
    await waitFor(() => expect(stopSync).toHaveBeenCalled());
  });

  it("reflects external store changes (e.g. cross-tab / token refresh)", async () => {
    const { result } = renderHook(() => useAuth(), { wrapper });
    await waitFor(() => expect(result.current.loading).toBe(false));

    act(() => {
      fakeAuthStore.save(FAKE_USER);
    });

    await waitFor(() => expect(result.current.user).toEqual(FAKE_USER));
  });

  it("useAuth throws when used outside a provider", () => {
    function Probe() {
      useAuth();
      return null;
    }
    // Suppress the expected React error boundary console noise.
    const spy = vi.spyOn(console, "error").mockImplementation(() => {});
    expect(() => render(<Probe />)).toThrow(
      /useAuth must be used within an <AuthProvider>/,
    );
    spy.mockRestore();
  });

  it("renders children inside the provider", async () => {
    function Greeting() {
      const { user } = useAuth();
      return <span>{user ? `Hi ${user.name}` : "anon"}</span>;
    }
    render(
      <AuthProvider>
        <Greeting />
      </AuthProvider>,
    );
    await waitFor(() => expect(screen.getByText("anon")).toBeInTheDocument());
  });
});

describe("clearAuthOnUnauthorized", () => {
  it("ignores non-401 errors and leaves the session intact", () => {
    fakeAuthStore.save(FAKE_USER);

    const handled = clearAuthOnUnauthorized(
      new ClientResponseError({ status: 500 }),
    );

    expect(handled).toBe(false);
    expect(fakeAuthStore.isValid).toBe(true);
    expect(clearFileTokenMock).not.toHaveBeenCalled();
  });

  it("clears the cached file token AND the auth store on a forced 401 (SEC-2)", () => {
    // Simulate an authenticated session whose token the server later rejects.
    fakeAuthStore.save(FAKE_USER);
    expect(fakeAuthStore.isValid).toBe(true);

    const handled = clearAuthOnUnauthorized(
      new ClientResponseError({ status: 401 }),
    );

    expect(handled).toBe(true);
    // Auth store is invalidated...
    expect(fakeAuthStore.isValid).toBe(false);
    // ...and the short-lived file-token cache is dropped, so a previously
    // minted token cannot keep fetching protected images after sign-out.
    expect(clearFileTokenMock).toHaveBeenCalledTimes(1);
  });
});
