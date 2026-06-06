/// <reference path="../pb_data/types.d.ts" />

// Guest-aware visibility rules (ARCHITECTURE.md §3.2–§3.4)
//
// The decks / cards / card_images collections are created earlier with
// owner-only list/view rules, because their full rules reference
// @collection.deck_guests — a collection that does not exist until
// 1700000005_deck_guests.js runs. Now that deck_guests exists, apply the
// complete rules so guests can read decks (and their cards/images) they
// have been granted access to.
migrate((app) => {
  const decks = app.findCollectionByNameOrId("decks");
  decks.listRule =
    "owner = @request.auth.id || " +
    "@collection.deck_guests.deck = id && @collection.deck_guests.user = @request.auth.id";
  decks.viewRule = decks.listRule;
  app.save(decks);

  const cards = app.findCollectionByNameOrId("cards");
  cards.listRule =
    "deck.owner = @request.auth.id || " +
    "@collection.deck_guests.deck = deck && @collection.deck_guests.user = @request.auth.id";
  cards.viewRule = cards.listRule;
  app.save(cards);

  const cardImages = app.findCollectionByNameOrId("card_images");
  cardImages.listRule =
    "card.deck.owner = @request.auth.id || " +
    "@collection.deck_guests.deck = card.deck && @collection.deck_guests.user = @request.auth.id";
  cardImages.viewRule = cardImages.listRule;
  app.save(cardImages);
}, (app) => {
  // Down: revert to owner-only rules.
  const decks = app.findCollectionByNameOrId("decks");
  decks.listRule = "owner = @request.auth.id";
  decks.viewRule = "owner = @request.auth.id";
  app.save(decks);

  const cards = app.findCollectionByNameOrId("cards");
  cards.listRule = "deck.owner = @request.auth.id";
  cards.viewRule = "deck.owner = @request.auth.id";
  app.save(cards);

  const cardImages = app.findCollectionByNameOrId("card_images");
  cardImages.listRule = "card.deck.owner = @request.auth.id";
  cardImages.viewRule = "card.deck.owner = @request.auth.id";
  app.save(cardImages);
});
