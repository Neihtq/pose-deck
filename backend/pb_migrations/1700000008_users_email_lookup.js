/// <reference path="../pb_data/types.d.ts" />

// users — relax listRule for share-by-email guest discovery (M5, ARCHITECTURE.md §6).
//
// Sharing (deck_guests) requires the deck owner to resolve a friend's user id
// from an email they type. The base `users.listRule` is `id = @request.auth.id`
// (you can only list yourself), which blocks that lookup. We widen it just
// enough: an authenticated caller may also list a user record whose email
// EXACTLY equals the `email` query param they pass.
//
//   listRule = id = @request.auth.id
//              || (@request.auth.id != "" && email = @request.query.email)
//
// Tradeoff (documented per the M5 review): this is an existence oracle — any
// authenticated user can confirm whether a given email has an account (a query
// returns 1 row vs 0). It does NOT allow enumerating the user table: a list
// with no `email` query param still returns only the caller's own record, and
// `viewRule` stays `id = @request.auth.id` so no other fields of another user
// are exposed beyond what the email match itself reveals. Acceptable for this
// 2-user private project; revisit if signup is ever re-enabled.
//
// Only `listRule` changes; view/create/update/delete are untouched.
migrate((app) => {
  const collection = app.findCollectionByNameOrId("users");
  collection.listRule =
    'id = @request.auth.id || (@request.auth.id != "" && email = @request.query.email)';
  app.save(collection);
}, (app) => {
  // Down: restore the own-record-only list rule.
  const collection = app.findCollectionByNameOrId("users");
  collection.listRule = "id = @request.auth.id";
  app.save(collection);
});
