/// <reference path="../pb_data/types.d.ts" />

// Fix guest-visibility rules to use back-relations (M5 sharing).
//
// 1700000007_relation_rules.js wrote the guest-aware list/view rules using a
// cross-row `@collection.deck_guests` join:
//
//   owner = @request.auth.id ||
//   @collection.deck_guests.deck = id && @collection.deck_guests.user = @request.auth.id
//
// That form does NOT work on this PocketBase: a granted guest still gets 404 on
// the shared deck (verified live — guest GET shared deck → 404, list count 0),
// so sharing is broken end-to-end. The `@collection.X` join multiplies rows and
// the two conditions are not correlated to the SAME deck_guests row, so the
// guest clause never matches.
//
// The correct idiom is a BACK-RELATION traversal from the parent collection
// through `deck_guests.deck` (PocketBase exposes it as `deck_guests_via_deck`),
// with `?=` (any-match) so a deck with ANY grant for the caller is visible:
//
//   decks:        owner = me || deck_guests_via_deck.user ?= me
//   cards:        deck.owner = me || deck.deck_guests_via_deck.user ?= me
//   card_images:  card.deck.owner = me || card.deck.deck_guests_via_deck.user ?= me
//
// Verified live: with these rules a granted guest GETs the shared deck + its
// cards (200), and a revoke (delete the deck_guests row) returns access to 404.
// create/update/delete rules are unchanged (owner-only). This supersedes the
// join form from 1700000007 for list/view.
migrate((app) => {
  const decks = app.findCollectionByNameOrId("decks");
  decks.listRule =
    "owner = @request.auth.id || deck_guests_via_deck.user ?= @request.auth.id";
  decks.viewRule = decks.listRule;
  app.save(decks);

  const cards = app.findCollectionByNameOrId("cards");
  cards.listRule =
    "deck.owner = @request.auth.id || " +
    "deck.deck_guests_via_deck.user ?= @request.auth.id";
  cards.viewRule = cards.listRule;
  app.save(cards);

  const cardImages = app.findCollectionByNameOrId("card_images");
  cardImages.listRule =
    "card.deck.owner = @request.auth.id || " +
    "card.deck.deck_guests_via_deck.user ?= @request.auth.id";
  cardImages.viewRule = cardImages.listRule;
  app.save(cardImages);
}, (app) => {
  // Down: restore the (broken) join form from 1700000007 so the migration
  // history round-trips. (Owner access still works under it.)
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
});
