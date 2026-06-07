/**
 * React binding for Dexie live queries (M3 sync).
 *
 * Thin re-export of `dexie-react-hooks`' `useLiveQuery` so the app imports it
 * from one place (and we can swap the implementation later without touching
 * call sites). A live query re-runs and re-renders whenever any of the Dexie
 * rows it touched change — which is how realtime/sync writes propagate to the
 * UI without manual refetching.
 *
 * Convention: a result of `undefined` means "still loading" (the query has not
 * resolved yet); an empty array means "loaded, no rows".
 */
export { useLiveQuery } from "dexie-react-hooks";
