/**
 * Typed PocketBase client wrapper.
 *
 * Wraps the official `pocketbase` JS SDK. Reads the backend base URL from
 * `VITE_API_BASE_URL` (see ARCHITECTURE.md §12 / .env).
 *
 * Auth-token storage (SEC-OBS-2): the SDK default `LocalAuthStore` persists the
 * session JWT in `localStorage`, where it lives indefinitely and is readable by
 * any script — so a single XSS can exfiltrate the highest-value secret in the
 * app. We instead back the store with `sessionStorage` (see
 * {@link createSessionAuthStore}). The token still survives reloads within the
 * tab (the documented UX), but it is scoped to the tab's lifetime: it is dropped
 * when the tab/browser closes, narrowing the XSS exfiltration window and
 * removing the durable on-disk copy. Auto-refresh on 401 is wired up in M1 auth
 * work. This is defense-in-depth, not a substitute for output escaping / CSP.
 */
import PocketBase, { AsyncAuthStore } from "pocketbase";
import type { RecordService } from "pocketbase";

import type {
  Card,
  CardCompletion,
  CardImage,
  CollectionRecordMap,
  Deck,
  DeckGuest,
  User,
} from "./types";

/**
 * localStorage key holding a user-entered backend base URL. Unlike the auth
 * token (which is tab-scoped sessionStorage for SEC-OBS-2), the backend URL is
 * a non-secret deployment pointer the user types at login; persisting it
 * durably so it survives tab/browser close is the desired UX (you pick your
 * server once). Read by {@link resolveApiBaseUrl} ahead of the build-time env.
 */
export const BACKEND_URL_STORAGE_KEY = "pose-deck-backend-url";

/** The durable backend URL the user entered at login, or null if none/unset. */
export function readStoredBackendUrl(): string | null {
  if (typeof window === "undefined" || !window.localStorage) {
    return null;
  }
  const stored = window.localStorage.getItem(BACKEND_URL_STORAGE_KEY);
  return stored && stored.trim() !== "" ? stored.trim() : null;
}

/**
 * Persist (or clear) the user-entered backend URL and point the shared client
 * at it immediately. Clearing (empty/whitespace) falls the app back to the
 * env/default on the next {@link resolveApiBaseUrl}. Setting also mutates the
 * live singleton's `baseURL` so the current page uses the new server without a
 * reload — every existing `pb` reference keeps working.
 */
export function setStoredBackendUrl(url: string): void {
  const trimmed = url.trim();
  if (typeof window !== "undefined" && window.localStorage) {
    if (trimmed === "") {
      window.localStorage.removeItem(BACKEND_URL_STORAGE_KEY);
    } else {
      window.localStorage.setItem(BACKEND_URL_STORAGE_KEY, trimmed);
    }
  }
  const nextBaseUrl = trimmed !== "" ? trimmed : resolveApiBaseUrl();
  // A file token is minted against (and only valid for) a specific server. When
  // we repoint the client at a different backend, any cached token belongs to
  // the old server and must never be appended to a /api/files URL that now
  // resolves against the new one — so invalidate it when the URL changes
  // (SEC-1). Keeps the cache-vs-baseURL invariant explicit rather than relying
  // on the fact that setStoredBackendUrl happens to run pre-auth today.
  if (nextBaseUrl !== pb.baseURL) {
    clearFileToken();
  }
  pb.baseURL = nextBaseUrl;
}

/**
 * Resolve the API base URL. Precedence: a user-entered URL persisted in
 * localStorage (set at login) → the build-time `VITE_API_BASE_URL` env → a
 * sane local default. The login override lets a single built bundle point at
 * any deployment without rebaking the env (HANDOFF.md §3).
 */
export function resolveApiBaseUrl(): string {
  const fromStorage = readStoredBackendUrl();
  if (fromStorage !== null) {
    return fromStorage;
  }
  const fromEnv = import.meta.env?.VITE_API_BASE_URL;
  if (typeof fromEnv === "string" && fromEnv.trim() !== "") {
    return fromEnv.trim();
  }
  // Local dev fallback — matches compose.dev.yml in ARCHITECTURE.md §12.
  return "http://localhost:8090";
}

/**
 * A PocketBase instance with typed `collection()` overloads for our schema.
 * Falls back to the SDK's generic `RecordService` for unknown collections.
 */
export interface TypedPocketBase extends PocketBase {
  collection<K extends keyof CollectionRecordMap>(
    idOrName: K,
  ): RecordService<CollectionRecordMap[K]>;
  collection(idOrName: string): RecordService;
}

/**
 * sessionStorage key holding the serialized PocketBase auth payload. Distinct
 * from the SDK's default `pocketbase_auth` localStorage key so a stale token
 * from an older build can't leak in.
 */
export const AUTH_STORAGE_KEY = "pose-deck-auth";

/**
 * Build an {@link AsyncAuthStore} backed by `sessionStorage` instead of the
 * SDK default `localStorage`. The token is read back synchronously on
 * construction (so it survives reloads within the tab) but never written to the
 * durable `localStorage`, keeping the JWT out of the longest-lived,
 * always-readable browser store. See SEC-OBS-2 / ARCHITECTURE.md.
 *
 * Falls back to an in-memory-only store when `sessionStorage` is unavailable
 * (SSR / privacy modes), so the client still works without persistence.
 */
export function createSessionAuthStore(): AsyncAuthStore {
  const storage: Pick<Storage, "getItem" | "setItem" | "removeItem"> | null =
    typeof globalThis !== "undefined" &&
    typeof globalThis.sessionStorage !== "undefined"
      ? globalThis.sessionStorage
      : null;

  return new AsyncAuthStore({
    save: async (serialized) => {
      storage?.setItem(AUTH_STORAGE_KEY, serialized);
    },
    clear: async () => {
      storage?.removeItem(AUTH_STORAGE_KEY);
    },
    initial: storage?.getItem(AUTH_STORAGE_KEY) ?? undefined,
  });
}

/** Create a new typed PocketBase client pointed at the given base URL. */
export function createPocketBase(
  baseUrl: string = resolveApiBaseUrl(),
): TypedPocketBase {
  return new PocketBase(baseUrl, createSessionAuthStore()) as TypedPocketBase;
}

/** Shared singleton client for the app. */
export const pb: TypedPocketBase = createPocketBase();

/** Typed accessors for each collection. */
export const collections = {
  users: () => pb.collection("users") as RecordService<User>,
  decks: () => pb.collection("decks") as RecordService<Deck>,
  cards: () => pb.collection("cards") as RecordService<Card>,
  card_images: () => pb.collection("card_images") as RecordService<CardImage>,
  deck_guests: () => pb.collection("deck_guests") as RecordService<DeckGuest>,
  card_completions: () =>
    pb.collection("card_completions") as RecordService<CardCompletion>,
} as const;

/** Is there a valid, authenticated session on the shared client? */
export function isAuthenticated(): boolean {
  return pb.authStore.isValid;
}

/** The currently authenticated user, or null. */
export function currentUser(): User | null {
  const model = pb.authStore.record;
  return (model as User | null) ?? null;
}

/** Build an absolute file URL for a record's file field (see §5). */
export function fileUrl(
  record: { id: string; collectionId?: string; collectionName?: string },
  filename: string,
  queryParams?: Record<string, unknown>,
): string {
  return pb.files.getURL(record, filename, queryParams);
}

/**
 * Short-lived file token cache.
 *
 * Files in collections with a non-empty view rule (e.g. `card_images`) are
 * **protected**: `GET /api/files/...` requires a `?token=` query param and
 * ignores the Authorization header. The token is short-lived, so we cache it
 * briefly and refresh on expiry. See ARCHITECTURE.md §5.
 */
let cachedFileToken: { token: string; expiresAt: number } | null = null;

/** How long to trust a minted file token before refreshing (PocketBase issues ~2 min tokens; we refresh well before). */
const FILE_TOKEN_TTL_MS = 90_000;

/** Get a (cached) file access token for protected file URLs. */
export async function getFileToken(): Promise<string> {
  const now = Date.now();
  if (cachedFileToken && cachedFileToken.expiresAt > now) {
    return cachedFileToken.token;
  }
  const token = await pb.files.getToken();
  cachedFileToken = { token, expiresAt: now + FILE_TOKEN_TTL_MS };
  return token;
}

/** Clear the cached file token (e.g. on sign-out). */
export function clearFileToken(): void {
  cachedFileToken = null;
}

/**
 * Build an absolute file URL carrying a short-lived access `token`, so
 * protected files load in `<img src>`. Async because minting the token may hit
 * the server. Prefer this over {@link fileUrl} for any protected collection.
 */
export async function fileUrlWithToken(
  record: { id: string; collectionId?: string; collectionName?: string },
  filename: string,
  queryParams?: Record<string, unknown>,
): Promise<string> {
  const token = await getFileToken();
  return pb.files.getURL(record, filename, { ...queryParams, token });
}
