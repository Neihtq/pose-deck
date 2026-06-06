/// <reference path="../pb_data/types.d.ts" />

// card_completions (ARCHITECTURE.md §3.6)
//
// Per-user shoot progress. You only ever see your own progress.
// Composite-unique on (card, user).
migrate((app) => {
  const cards = app.findCollectionByNameOrId("cards");
  const users = app.findCollectionByNameOrId("users");

  const collection = new Collection({
    type: "base",
    name: "card_completions",

    // You only see your own progress.
    listRule: "user = @request.auth.id",
    viewRule: "user = @request.auth.id",
    // You may only write your own progress, and only for a card whose
    // deck you own or are a guest of.
    createRule:
      "user = @request.auth.id && (" +
      "card.deck.owner = @request.auth.id || " +
      "@collection.deck_guests.deck = card.deck && @collection.deck_guests.user = @request.auth.id" +
      ")",
    updateRule:
      "user = @request.auth.id && (" +
      "card.deck.owner = @request.auth.id || " +
      "@collection.deck_guests.deck = card.deck && @collection.deck_guests.user = @request.auth.id" +
      ")",
    deleteRule: "user = @request.auth.id",

    fields: [
      {
        name: "card",
        type: "relation",
        required: true,
        maxSelect: 1,
        collectionId: cards.id,
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
        name: "state",
        type: "select",
        required: true,
        maxSelect: 1,
        values: ["done", "skipped", "pending"],
      },
      {
        name: "changed_at",
        type: "date",
        required: false,
      },
    ],

    indexes: [
      "CREATE UNIQUE INDEX idx_card_completions_card_user ON card_completions (card, user)",
    ],
  });

  app.save(collection);
}, (app) => {
  const collection = app.findCollectionByNameOrId("card_completions");
  app.delete(collection);
});
