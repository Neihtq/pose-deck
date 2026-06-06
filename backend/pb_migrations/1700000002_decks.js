/// <reference path="../pb_data/types.d.ts" />

// decks (ARCHITECTURE.md §3.2)
migrate((app) => {
  const users = app.findCollectionByNameOrId("users");

  const collection = new Collection({
    type: "base",
    name: "decks",

    // owner OR a guest of the deck may list/view it. The guest clause
    // references @collection.deck_guests, which does not exist yet at
    // this point, so the full rule is applied later in
    // 1700000007_relation_rules.js (after deck_guests is created).
    listRule: "owner = @request.auth.id",
    viewRule: "owner = @request.auth.id",
    // Any authenticated user can create a deck.
    createRule: "@request.auth.id != \"\"",
    // Only the owner may modify or delete.
    updateRule: "owner = @request.auth.id",
    deleteRule: "owner = @request.auth.id",

    fields: [
      {
        name: "owner",
        type: "relation",
        required: true,
        maxSelect: 1,
        collectionId: users.id,
        cascadeDelete: true,
      },
      {
        name: "name",
        type: "text",
        required: true,
        max: 200,
      },
      {
        name: "shoot_date",
        type: "date",
        required: false,
      },
      {
        // client clock at mutation time — drives last-write-wins.
        name: "client_updated_at",
        type: "date",
        required: false,
      },
      {
        // soft-delete tombstone.
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
      "CREATE INDEX idx_decks_owner ON decks (owner)",
    ],
  });

  app.save(collection);
}, (app) => {
  const collection = app.findCollectionByNameOrId("decks");
  app.delete(collection);
});
