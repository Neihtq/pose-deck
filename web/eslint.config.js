// Focused ESLint config for the M8 accessibility (a11y) lint.
//
// Scope is deliberately narrow: this config only runs the `jsx-a11y`
// recommended ruleset over the app's React source (`src/**/*.tsx`). The
// project's general type/lint gate is `tsc --noEmit` (see `npm run lint`);
// this is the dedicated `npm run lint:a11y` gate, so we do NOT pull in broad
// stylistic/TS rules here — that would add noise unrelated to accessibility.
import tseslint from "typescript-eslint";
import jsxA11y from "eslint-plugin-jsx-a11y";

export default tseslint.config(
  {
    // Only lint TSX (the files that render markup). Plain .ts modules have no
    // JSX, and tests / generated / service-worker code are out of scope.
    files: ["src/**/*.tsx"],
    ignores: ["src/**/__tests__/**", "src/test/**"],
    languageOptions: {
      parser: tseslint.parser,
      parserOptions: {
        ecmaFeatures: { jsx: true },
      },
    },
    plugins: {
      "jsx-a11y": jsxA11y,
    },
    rules: {
      ...jsxA11y.flatConfigs.recommended.rules,
      // `autoFocus` is intentionally retained in a few deliberate
      // focus-management spots and downgraded to a warning (documented
      // deferral, M8):
      //   - the first field of each modal dialog (New/Rename deck, Share, card
      //     delete): moving focus INTO the dialog's primary input on open is
      //     expected modal behaviour and is more accessible than landing on the
      //     auto-focused close/cancel button that Radix would otherwise pick;
      //   - the login email field and the card-editor title field: the primary
      //     field of a single-purpose, freshly-navigated screen.
      // The rule's blanket ban targets autofocus that yanks focus on a busy
      // page; these uses don't, so we keep them but surface them as warnings so
      // any NEW autofocus still gets reviewed.
      "jsx-a11y/no-autofocus": "warn",
    },
  },
);
