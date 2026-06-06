/// <reference path="../pb_data/types.d.ts" />

// cards (ARCHITECTURE.md §3.3)
//
// Visibility inherits from the parent deck: the rules mirror the deck
// rules, joined through the `deck` relation.
migrate((app) => {
  const decks = app.findCollectionByNameOrId("decks");

  const collection = new Collection({
    type: "base",
    name: "cards",

    // The guest clause references @collection.deck_guests, which does not
    // exist yet here; the full guest-aware rule is applied later in
    // 1700000007_relation_rules.js (after deck_guests is created).
    listRule: "deck.owner = @request.auth.id",
    viewRule: "deck.owner = @request.auth.id",
    // Only the deck owner may create/modify/delete cards.
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
        // gap-based ordering (e.g. 1000, 2000, …).
        name: "position",
        type: "number",
        required: false,
      },
      {
        name: "title",
        type: "text",
        required: true,
        max: 200,
      },
      {
        name: "time_slot",
        type: "text",
        required: false,
      },
      {
        name: "subjects",
        type: "text",
        required: false,
      },
      {
        name: "direction",
        type: "text",
        required: false,
      },
      {
        // no length cap.
        name: "notes",
        type: "text",
        required: false,
      },
      {
        name: "client_updated_at",
        type: "date",
        required: false,
      },
      {
        name: "deleted_at",
        type: "date",
        required: false,
      },
      {
        name: "created",
        type: "autodate",
        onCreate: true,
        onUpdate: false,
      },
      {
        name: "updated",
        type: "autodate",
        onCreate: true,
        onUpdate: true,
      },
    ],

    indexes: [
      "CREATE INDEX idx_cards_deck ON cards (deck)",
      "CREATE INDEX idx_cards_deck_position ON cards (deck, position)",
    ],
  });

  app.save(collection);
}, (app) => {
  const collection = app.findCollectionByNameOrId("cards");
  app.delete(collection);
});
