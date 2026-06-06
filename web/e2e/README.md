# E2E tests (Playwright)

Browser-driven end-to-end tests for the Pose Deck web app. They run the real
React app (Vite dev server) against a **live PocketBase backend** and exercise
the M1 prep flows:

> login → create deck → see grouping → open deck → add/edit card → reorder →
> attach image

## Prerequisites

1. **PocketBase running** on `VITE_API_BASE_URL` (default `http://localhost:8090`),
   started with `POSEDECK_DEV=true` so the dev-seed account exists. From the repo
   root:

   ```bash
   cd backend && POSEDECK_DEV=true ./pocketbase serve
   # or: docker compose -f backend/compose.dev.yml up
   ```

   The tests sign in with the seed owner account from
   `backend/pb_migrations/1700000010_dev_seed.js`:
   `owner@posedeck.test` / `changeme123`. Override via `E2E_EMAIL` / `E2E_PASSWORD`.

2. **Chromium installed** for Playwright:

   ```bash
   npx playwright install chromium
   ```

## Run

```bash
npm run test:e2e            # headless
npm run test:e2e:ui        # Playwright UI mode
VITE_API_BASE_URL=http://localhost:8090 npm run test:e2e
```

The Vite dev server is started automatically by `playwright.config.ts`
(`webServer`), with `VITE_API_BASE_URL` threaded through so the app and the
tests target the same backend.

## Notes

- Tests run **serially** (`workers: 1`, `fullyParallel: false`) because they
  mutate a shared live backend — parallel mutations would race.
- Each test creates uniquely-named decks (`uniqueDeckName`) so repeat runs and
  the existing dev-seed data never collide. Decks are soft-deleted, not purged,
  so they accumulate in Trash over many runs; clear via the app or by resetting
  `pb_data` if needed.
- Artifacts (`test-results/`, `playwright-report/`) are git-ignored.
