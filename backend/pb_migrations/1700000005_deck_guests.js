/// <reference path="../pb_data/types.d.ts" />

// deck_guests (ARCHITECTURE.md §3.5)
//
// Records which users have guest access to which decks. Only the deck
// owner can grant or revoke. Composite-unique on (deck, user).
migrate((app) => {
  const decks = app.findCollectionByNameOrId("decks");
  const users = app.findCollectionByNameOrId("users");

  const collection = new Collection({
    type: "base",
    name: "deck_guests",

    // Owner of the deck, or the guest themselves, may see the grant.
    listRule: "deck.owner = @request.auth.id || user = @request.auth.id",
    viewRule: "deck.owner = @request.auth.id || user = @request.auth.id",
    // Only the deck owner can grant or revoke access.
    createRule: "deck.owner = @request.auth.id",
    updateRule: "deck.owner = @request.auth.id",
    deleteRule: "deck.owner = @request.auth.id",

    fields: [
      {
        name: "deck",
        type: "relation",
        required: true,
        maxSelect: 1,
        collectionId: decks.id,
        cascadeDelete: true,
      },
      {
        name: "user",
        type: "relation",
        required: true,
        maxSelect: 1,
        collectionId: users.id,
        cascadeDelete: true,
      },
      {
        name: "granted_at",
        type: "date",
        required: false,
      },
    ],

    indexes: [
      "CREATE UNIQUE INDEX idx_deck_guests_deck_user ON deck_guests (deck, user)",
    ],
  });

  app.save(collection);
}, (app) => {
  const collection = app.findCollectionByNameOrId("deck_guests");
  app.delete(collection);
});
