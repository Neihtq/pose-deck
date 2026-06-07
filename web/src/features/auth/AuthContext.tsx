/**
 * Auth context for Pose Deck.
 *
 * Wraps the shared PocketBase `authStore` (see lib/pocketbase.ts). The SDK
 * persists the auth token in localStorage, so sessions survive reloads; this
 * context mirrors that store into React state and keeps the two in sync via
 * `authStore.onChange`.
 *
 * M1 only needs sign-in / sign-out. Token auto-refresh on background 401s is
 * SDK-handled; here we additionally clear the store if a token is rejected as
 * invalid so the UI can fall back to the login route.
 */
import * as React from "react";

import { ClientResponseError } from "pocketbase";

import {
  clearFileToken,
  collections,
  currentUser,
  isAuthenticated,
  pb,
} from "@/lib/pocketbase";
import { startSync, stopSync } from "@/sync";
import type { User } from "@/lib/types";

/** Value exposed by {@link useAuth}. */
export interface AuthContextValue {
  /** The currently authenticated user, or null when signed out. */
  user: User | null;
  /** Convenience flag mirroring `pb.authStore.isValid`. */
  isAuthenticated: boolean;
  /** Authenticate with email + password; throws on failure. */
  signIn: (email: string, password: string) => Promise<void>;
  /** Clear the session (local only — no network call needed). */
  signOut: () => void;
  /**
   * True until the initial auth state has been read from the store. Always
   * resolves synchronously on mount, but kept for API symmetry with async
   * session validation flows.
   */
  loading: boolean;
}

const AuthContext = React.createContext<AuthContextValue | null>(null);

/** Snapshot the current auth state from the shared PocketBase store. */
function readAuthState(): { user: User | null; isAuthenticated: boolean } {
  return { user: currentUser(), isAuthenticated: isAuthenticated() };
}

/**
 * Provides auth state + actions to the tree. Mount once near the app root.
 */
export function AuthProvider({
  children,
}: {
  children: React.ReactNode;
}): React.JSX.Element {
  const [state, setState] = React.useState(readAuthState);
  const [loading, setLoading] = React.useState(true);

  React.useEffect(() => {
    // Sync once on mount in case the store changed before this effect ran.
    const initial = readAuthState();
    setState(initial);
    setLoading(false);

    // Drive the sync runtime off auth transitions. We start the engine +
    // realtime + hydrate when we become authenticated and stop + wipe the
    // local store when we sign out, gating on the *edge* (was→now) so a token
    // refresh (still authenticated) doesn't restart sync. Sign-out's purge is
    // intentionally async here (fire-and-forget) so `clearAuthOnUnauthorized`
    // and `signOut` stay synchronous — the purge is triggered via this
    // onChange, not inline in those callers.
    let wasAuthed = initial.isAuthenticated;
    if (wasAuthed) {
      void startSync();
    }

    // Keep React state in lock-step with the PocketBase auth store. The
    // callback fires on sign-in, sign-out, token refresh, and cross-tab
    // localStorage changes. `onChange` returns an unsubscribe function.
    const unsubscribe = pb.authStore.onChange(() => {
      const next = readAuthState();
      setState(next);
      if (next.isAuthenticated && !wasAuthed) {
        void startSync();
      } else if (!next.isAuthenticated && wasAuthed) {
        void stopSync();
      }
      wasAuthed = next.isAuthenticated;
    });

    return () => {
      unsubscribe();
      // Tearing down the provider (e.g. unmount) stops sync defensively.
      void stopSync();
    };
  }, []);

  const signIn = React.useCallback(
    async (email: string, password: string): Promise<void> => {
      await collections.users().authWithPassword(email, password);
      // `onChange` will fire and update state; no manual setState needed.
    },
    [],
  );

  const signOut = React.useCallback((): void => {
    clearFileToken();
    pb.authStore.clear();
  }, []);

  const value = React.useMemo<AuthContextValue>(
    () => ({
      user: state.user,
      isAuthenticated: state.isAuthenticated,
      signIn,
      signOut,
      loading,
    }),
    [state.user, state.isAuthenticated, signIn, signOut, loading],
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

/** Access the auth context. Throws if used outside an {@link AuthProvider}. */
export function useAuth(): AuthContextValue {
  const ctx = React.useContext(AuthContext);
  if (ctx === null) {
    throw new Error("useAuth must be used within an <AuthProvider>");
  }
  return ctx;
}

/**
 * Clear the session if an error is a 401 token-invalid response. Call this
 * from data-fetch error handlers so the app falls back to the login route
 * when a persisted token has been rejected by the server.
 *
 * @returns true if the error was a 401 and the store was cleared.
 */
export function clearAuthOnUnauthorized(error: unknown): boolean {
  if (error instanceof ClientResponseError && error.status === 401) {
    // Drop the cached short-lived file token too, mirroring signOut. Otherwise
    // a previously minted token stays usable for protected file URLs after the
    // server has rejected the session.
    clearFileToken();
    pb.authStore.clear();
    return true;
  }
  return false;
}
