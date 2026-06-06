/**
 * Typed PocketBase client wrapper.
 *
 * Wraps the official `pocketbase` JS SDK. Reads the backend base URL from
 * `VITE_API_BASE_URL` (see ARCHITECTURE.md §12 / .env). Auth tokens are
 * persisted by the SDK's default `LocalAuthStore` (localStorage) so sessions
 * survive reloads; auto-refresh on 401 is wired up in M1 auth work.
 */
import PocketBase from "pocketbase";
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

/** Resolve the API base URL from the Vite env, with a sane local default. */
export function resolveApiBaseUrl(): string {
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

/** Create a new typed PocketBase client pointed at the given base URL. */
export function createPocketBase(
  baseUrl: string = resolveApiBaseUrl(),
): TypedPocketBase {
  return new PocketBase(baseUrl) as TypedPocketBase;
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
