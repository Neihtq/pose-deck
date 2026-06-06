/// <reference path="../pb_data/types.d.ts" />

// DEV-ONLY SEED — NOT FOR PRODUCTION.
//
// Creates two users and one sample deck with a few cards so the web /
// iOS clients have something to render during development.
//
// Guards:
//   * Only runs when the POSEDECK_DEV environment variable is "true".
//     The prod stack (docker-compose.yml) never sets it.
//   * Idempotent — checks for existing records before creating, so
//     re-running migrations (or restarting the dev container) is safe.
//   * The down migration removes only the records it created.
//
// Dev credentials (change/remove before any non-local use):
//   owner@posedeck.test  / changeme123
//   guest@posedeck.test  / changeme123

const OWNER_EMAIL = "owner@posedeck.test";
const GUEST_EMAIL = "guest@posedeck.test";
const SEED_PASSWORD = "changeme123";
const SEED_DECK_NAME = "Sample Shoot (dev seed)";

migrate((app) => {
  if ($os.getenv("POSEDECK_DEV") !== "true") {
    // Not a dev environment — do nothing.
    return;
  }

  // --- users -------------------------------------------------------
  const users = app.findCollectionByNameOrId("users");

  function ensureUser(email, name) {
    try {
      return app.findAuthRecordByEmail("users", email);
    } catch (_) {
      const rec = new Record(users);
      rec.set("email", email);
      rec.set("name", name);
      rec.set("verified", true);
      rec.setPassword(SEED_PASSWORD);
      app.save(rec);
      return rec;
    }
  }

  const owner = ensureUser(OWNER_EMAIL, "Dev Owner");
  ensureUser(GUEST_EMAIL, "Dev Guest");

  // --- sample deck -------------------------------------------------
  const decks = app.findCollectionByNameOrId("decks");

  // Idempotency: bail if the sample deck already exists.
  let existingDeck = null;
  try {
    existingDeck = app.findFirstRecordByFilter(
      "decks",
      "name = {:name}",
      { name: SEED_DECK_NAME }
    );
  } catch (_) {
    existingDeck = null;
  }
  if (existingDeck) {
    return;
  }

  const now = new Date().toISOString().replace("T", " ").replace("Z", "Z");

  const deck = new Record(decks);
  deck.set("owner", owner.id);
  deck.set("name", SEED_DECK_NAME);
  deck.set("shoot_date", now);
  deck.set("client_updated_at", now);
  app.save(deck);

  // --- sample cards ------------------------------------------------
  const cards = app.findCollectionByNameOrId("cards");

  const sampleCards = [
    {
      title: "Golden hour portrait",
      time_slot: "07:30",
      subjects: "Model A",
      direction: "Backlit, face the sun, soft squint",
      notes: "Bring reflector for fill.",
      position: 1000,
    },
    {
      title: "Wide environmental",
      time_slot: "08:15",
      subjects: "Model A, Model B",
      direction: "Walking toward camera, candid",
      notes: "",
      position: 2000,
    },
    {
      title: "Detail / hands",
      time_slot: "08:45",
      subjects: "Model B",
      direction: "Close crop, shallow DOF",
      notes: "85mm wide open.",
      position: 3000,
    },
  ];

  for (const c of sampleCards) {
    const card = new Record(cards);
    card.set("deck", deck.id);
    card.set("title", c.title);
    card.set("time_slot", c.time_slot);
    card.set("subjects", c.subjects);
    card.set("direction", c.direction);
    card.set("notes", c.notes);
    card.set("position", c.position);
    card.set("client_updated_at", now);
    app.save(card);
  }
}, (app) => {
  // Down: remove seeded records (only if present). Cards cascade-delete
  // with the deck, so deleting the deck and the two users is enough.
  try {
    const deck = app.findFirstRecordByFilter(
      "decks",
      "name = {:name}",
      { name: SEED_DECK_NAME }
    );
    app.delete(deck);
  } catch (_) {}

  for (const email of [OWNER_EMAIL, GUEST_EMAIL]) {
    try {
      const u = app.findAuthRecordByEmail("users", email);
      app.delete(u);
    } catch (_) {}
  }
});
