/// <reference path="../pb_data/types.d.ts" />

// users — auth collection (ARCHITECTURE.md §3.1)
//
// PocketBase 0.39.x bootstraps a default `users` auth collection on a
// fresh install (with id, email, password, tokenKey, verified, name,
// created, updated already provisioned). We therefore CONFIGURE that
// existing collection rather than create a new one (creating a second
// "users" collection fails the unique-name check).
//
// Email + password auth only. Public signup is disabled: the owner
// pre-creates the friend's account via the PocketBase admin UI (/_/).
migrate((app) => {
  const collection = app.findCollectionByNameOrId("users");

  // Authentication options.
  collection.passwordAuth = {
    enabled: true,
    identityFields: ["email"],
  };
  collection.oauth2 = { enabled: false };
  // No username-based auth: identity is email only.

  // Public self-registration disabled — owner creates accounts.
  collection.createRule = null;

  // A user can list/view/update only their own record.
  collection.listRule = "id = @request.auth.id";
  collection.viewRule = "id = @request.auth.id";
  collection.updateRule = "id = @request.auth.id";
  collection.deleteRule = null;

  // Constrain the display-name field to the spec's 200-char cap. The
  // field already exists on the default collection (max 255); narrow it.
  const nameField = collection.fields.getByName("name");
  if (nameField) {
    nameField.max = 200;
  }

  app.save(collection);
}, (app) => {
  // Down: revert the API rules to PocketBase defaults (do NOT delete the
  // system-provided users collection).
  const collection = app.findCollectionByNameOrId("users");
  collection.listRule = "id = @request.auth.id";
  collection.viewRule = "id = @request.auth.id";
  collection.createRule = "";
  collection.updateRule = "id = @request.auth.id";
  collection.deleteRule = "id = @request.auth.id";
  app.save(collection);
});
