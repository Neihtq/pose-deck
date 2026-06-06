/// <reference path="../pb_data/types.d.ts" />

// card_images (ARCHITECTURE.md §3.4)
//
// Visibility inherits from the parent card (and thus the parent deck),
// joined through card.deck. Max 1 file per record.
migrate((app) => {
  const cards = app.findCollectionByNameOrId("cards");

  const collection = new Collection({
    type: "base",
    name: "card_images",

    // The guest clause references @collection.deck_guests, which does not
    // exist yet here; the full guest-aware rule is applied later in
    // 1700000007_relation_rules.js (after deck_guests is created).
    listRule: "card.deck.owner = @request.auth.id",
    viewRule: "card.deck.owner = @request.auth.id",
    // Only the deck owner manages images.
    createRule: "card.deck.owner = @request.auth.id",
    updateRule: "card.deck.owner = @request.auth.id",
    deleteRule: "card.deck.owner = @request.auth.id",

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
        // ordering within a card.
        name: "position",
        type: "number",
        required: false,
      },
      {
        name: "file",
        type: "file",
        required: true,
        maxSelect: 1,
        maxSize: 10485760, // 10 MB — compressed JPEGs are far smaller.
        mimeTypes: ["image/jpeg", "image/png", "image/webp"],
      },
      {
        name: "created",
        type: "autodate",
        onCreate: true,
        onUpdate: false,
      },
    ],

    indexes: [
      "CREATE INDEX idx_card_images_card ON card_images (card)",
      "CREATE INDEX idx_card_images_card_position ON card_images (card, position)",
    ],
  });

  app.save(collection);
}, (app) => {
  const collection = app.findCollectionByNameOrId("card_images");
  app.delete(collection);
});
