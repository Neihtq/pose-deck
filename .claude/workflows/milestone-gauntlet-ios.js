export const meta = {
  name: 'milestone-gauntlet-ios',
  description: 'iOS variant of the Pose Deck milestone gate: adversarial review (hostile lenses → independent refuters) → auto-fix EVERY confirmed finding with a regression test in PoseDeckCore → test layers (core unit + live-PB integration via swift test + app compile-check in lieu of runnable e2e) → re-verify swift test + xcodebuild green. Invoke after an iOS milestone is built and compiling.',
  phases: [
    { title: 'Review', detail: 'hostile lenses scan the iOS diff' },
    { title: 'Refute', detail: 'independent skeptic cross-examines each finding' },
    { title: 'Auto-fix', detail: 'fix every confirmed finding + PoseDeckCore regression test' },
    { title: 'Test layers', detail: 'core unit + live-PB integration + app compile-check' },
    { title: 'Re-verify', detail: 'swift test + xcodebuild build green + handoff' },
  ],
}

// args: { milestone, root, iosDir, coreDir, appDir, appProject, appScheme, reviewGlobs, specFiles,
//         backend:{liveUrl,seedUser,seedPass} }
const A = args || {}
const ROOT = A.root || '/Users/qthienng/projects/pose-deck'
const IOS = A.iosDir || `${ROOT}/ios`
const CORE = A.coreDir || `${IOS}/PoseDeckCore`
const APP = A.appDir || `${IOS}/PoseDeck`
const PROJ = A.appProject || 'PoseDeck.xcodeproj'
const SCHEME = A.appScheme || 'PoseDeck'
const MS = A.milestone || 'iOS milestone'
const SPEC = (A.specFiles || ['docs/DESIGN.md', 'docs/ARCHITECTURE.md']).map((f) => `${ROOT}/${f}`).join(', ')
const GLOBS = (A.reviewGlobs || ['ios/**']).join(', ')
const BE = A.backend || {}

const XCB = `xcodebuild -project ${PROJ} -scheme ${SCHEME} -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO`

const FINDINGS_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['lens', 'findings'],
  properties: {
    lens: { type: 'string' },
    findings: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['id', 'title', 'file', 'line', 'severity', 'claim', 'evidence', 'suggestedFix'],
        properties: {
          id: { type: 'string' }, title: { type: 'string' },
          file: { type: 'string' }, line: { type: 'string' },
          severity: { type: 'string', enum: ['critical', 'high', 'medium', 'low'] },
          claim: { type: 'string' }, evidence: { type: 'string' }, suggestedFix: { type: 'string' },
        },
      },
    },
  },
}
const VERDICT_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['id', 'verdict', 'confidence', 'reasoning', 'correctedSeverity'],
  properties: {
    id: { type: 'string' },
    verdict: { type: 'string', enum: ['confirmed', 'refuted', 'partial'] },
    confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
    reasoning: { type: 'string' },
    correctedSeverity: { type: 'string', enum: ['critical', 'high', 'medium', 'low', 'not-a-bug'] },
  },
}
const FIX_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['id', 'fixed', 'filesModified', 'regressionTest', 'detail'],
  properties: {
    id: { type: 'string' }, fixed: { type: 'boolean' },
    filesModified: { type: 'array', items: { type: 'string' } },
    regressionTest: { type: 'string' }, detail: { type: 'string' },
  },
}
const LAYER_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['layer', 'status', 'testsAdded', 'detail', 'filesCreated'],
  properties: {
    layer: { type: 'string' },
    status: { type: 'string', enum: ['pass', 'fail', 'skipped'] },
    testsAdded: { type: 'number' },
    filesCreated: { type: 'array', items: { type: 'string' } },
    detail: { type: 'string' },
  },
}
const VERIFY_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['coreTestStatus', 'appCompileStatus', 'detail'],
  properties: {
    coreTestStatus: { type: 'string', enum: ['pass', 'fail'] },
    appCompileStatus: { type: 'string', enum: ['pass', 'fail', 'skipped'] },
    detail: { type: 'string' },
  },
}

const CTX = `Pose Deck ${MS} iOS milestone gate. PROJECT ROOT: ${ROOT}.
iOS: app at ${APP} (${PROJ}, scheme ${SCHEME}), logic core Swift package at ${CORE} (PoseDeckCore).
SPEC: ${SPEC}. Authority split: DESIGN.md governs product/UI constraints (e.g. card Title <=60); ARCHITECTURE.md section 3 governs the data model (DB max 200 is headroom, not a target). DESIGN.md wins for UI limits.
CODE UNDER REVIEW (repo-relative globs): ${GLOBS}.
Backend for live checks: ${BE.liveUrl || '(none)'}${BE.seedUser ? `, seed user ${BE.seedUser}/${BE.seedPass}` : ''}.
ENVIRONMENT: xcodegen installed; the iOS Simulator CANNOT boot here. So: PoseDeckCore is unit-testable via 'cd ${CORE} && swift test'; the app is COMPILE-checkable via 'cd ${APP} && xcodegen generate && ${XCB}' but NOT runnable. Behavioral reference for parity: the web M1 implementation under ${ROOT}/web/src/features.`

const lenses = [
  { key: 'correctness', focus: 'logic bugs: DeckGrouping today-boundary & sort order, reorder/position integer-gap math & restripe, soft-delete leaking into list queries, duplicateDeck copying deleted cards or omitting owner, optimistic UI revert correctness.' },
  { key: 'spec', focus: 'conformance: card Title <=60 enforced in UI; images 0-5 cap; 1080px/q0.8 compression exact; client_updated_at set on EVERY create/update (incl rename, soft-delete, reorder, duplicate); owner set on deck create; grouping order Upcoming/Undated/Past; soft-delete (never hard-delete) on decks AND cards; PocketBase wire date format parsed (space+millis+Z) and empty-string unset handled.' },
  { key: 'security', focus: 'JWT/token handling: stored in Keychain not UserDefaults, cleared on signOut; protected card_images file URLs carry a ?token=; no secrets/seed creds hardcoded in app source; reliance on server API rules (correct) vs client-only checks; PocketBase filter strings built from user input without escaping.' },
  { key: 'swift', focus: 'Swift/SwiftUI correctness: Swift 6 concurrency (actor isolation, @Sendable captures, @MainActor on view models), async races (create-then-edit card id, concurrent reorder), retain cycles in closures, NavigationStack path/destination correctness, AsyncImage token expiry, force-unwraps/fatalError on the happy path (e.g. currentUserId!), missing loading/error states.' },
]

phase('Review')
log(`${MS} iOS gauntlet — ${lenses.length} hostile lenses → independent refutation`)

const perLens = await pipeline(
  lenses,
  (l) => agent(
    `${CTX}\n\nYOUR LENS: ${l.key.toUpperCase()}. Be a HOSTILE reviewer — assume bugs exist. Focus: ${l.focus}\nRead the code under review in full (both PoseDeckCore and the app). Every finding MUST cite real code (file + line + snippet) and concrete impact. No style nitpicks. If an area is clean, return fewer/zero findings rather than inventing issues.`,
    { label: `review:${l.key}`, phase: 'Review', schema: FINDINGS_SCHEMA },
  ),
  (found, l) => {
    const findings = (found && found.findings) || []
    if (findings.length === 0) return { lens: l.key, verified: [] }
    return parallel(findings.map((f) => () =>
      agent(
        `You are an INDEPENDENT SKEPTIC cross-examining a ${MS} iOS review finding (lens: ${l.key}). DEFAULT POSITION: it is a FALSE POSITIVE. Only confirm if proven against the real code.\n${CTX}\n\nFINDING: id=${f.id} | ${f.title} | ${f.file}:${f.line} | severity=${f.severity}\nclaim: ${f.claim}\nevidence: ${f.evidence}\nsuggestedFix: ${f.suggestedFix}\n\nOpen ${f.file}, read the cited lines + surrounding context (and related files / spec). Catch false positives: guard exists elsewhere; value is correct; race can't occur given actor/MainActor isolation; spec doesn't require it; server rule makes it moot. Verdict 'confirmed' only if verified; 'refuted' if not real (explain the misread); 'partial' if real but overstated. correctedSeverity='not-a-bug' if refuted.`,
        { label: `refute:${l.key}:${f.id}`, phase: 'Refute', schema: VERDICT_SCHEMA },
      ).then((v) => ({ finding: f, verdict: v })),
    )).then((vs) => ({ lens: l.key, verified: vs.filter(Boolean) }))
  },
)

const allVerified = perLens.filter(Boolean).flatMap((r) => (r.verified || []).map((v) => ({ lens: r.lens, ...v })))
const confirmed = allVerified.filter((v) => v.verdict && v.verdict.verdict !== 'refuted' && v.verdict.correctedSeverity !== 'not-a-bug')
const refuted = allVerified.filter((v) => !confirmed.includes(v))
log(`Review complete — ${allVerified.length} findings: ${confirmed.length} confirmed, ${refuted.length} refuted`)

phase('Auto-fix')
let fixes = []
if (confirmed.length > 0) {
  log(`Auto-fixing ${confirmed.length} confirmed findings (all severities)`)
  for (const c of confirmed) {
    const f = c.finding
    const fix = await agent(
      `${CTX}\n\nFix this CONFIRMED ${MS} finding and add a regression test. PREFER putting the fix + test in PoseDeckCore (unit-testable via swift test) when the logic can live there; app-only SwiftUI fixes must still compile via xcodebuild but may not be unit-testable in this env (note that).\nFINDING: id=${f.id} | ${f.title} | ${f.file}:${f.line} | severity=${c.verdict.correctedSeverity}\nclaim: ${f.claim}\nsuggestedFix: ${f.suggestedFix}\nskeptic reasoning: ${c.verdict.reasoning}\n\n1. Apply a minimal, correct fix (root cause, match surrounding style).\n2. Add/extend a PoseDeckCore XCTest that covers this bug (or, if purely app-UI, explain why it's compile-verified only).\n3. Run 'cd ${CORE} && swift test' to confirm green. If the fix touches the app target, also 'cd ${APP} && xcodegen generate && ${XCB}'.\nReport fixed=true only if tests/compile are green.`,
      { label: `fix:${f.id}`, phase: 'Auto-fix', schema: FIX_SCHEMA },
    )
    fixes.push(fix)
  }
} else {
  log('No confirmed findings — skipping auto-fix')
}

phase('Test layers')
const layerPrompts = {
  'core-unit': `${CTX}\n\nStrengthen the CORE UNIT test layer (PoseDeckCore, offline via URLProtocol stub or pure). Cover ${MS} logic not yet tested: repository CRUD payloads (correct collection, client_updated_at present, owner on deck create, soft-delete sets deleted_at, filters exclude deleted), reorder restripe, duplicate excludes deleted cards, DeckGrouping edge cases, PocketBaseDate round-trip. Run 'cd ${CORE} && swift test'; report pass only if green. status=pass/fail, testsAdded=count.`,
  'integration-live': `${CTX}\n\nBuild/extend an INTEGRATION test layer that exercises PoseDeckCore repositories against the LIVE PocketBase at ${BE.liveUrl} (seed ${BE.seedUser}/${BE.seedPass}). Use a dedicated XCTest target/suite (e.g. PoseDeckCoreIntegrationTests) GATED behind an env var (e.g. POSEDECK_INTEGRATION=1) so the default 'swift test' stays offline/green when no backend is present. Assert the real contract: auth, deck create (owner required), list excludes soft-deleted, card create/reorder positions, card_images upload + protected file token fetch, guest visibility if feasible. Keep idempotent (clean up created records). Run it with the env var set against the live server; report pass only if it actually executed green, else status=skipped with the exact blocker.`,
  'app-compile': `${CTX}\n\nThe APP-COMPILE layer stands in for runnable e2e (the simulator can't boot here). Ensure 'cd ${APP} && xcodegen generate && ${XCB}' succeeds with zero compiler errors after all fixes, exercising every screen file (they must be referenced in the build). Optionally add SwiftUI #Preview coverage / a compile-only smoke that references each view so dead code is caught. Report status=pass only if BUILD SUCCEEDED. Document that on-device run + UI/gesture/photo-picker verification remains a developer (on-device) task — list exactly what the dev must check.`,
}
const layerResults = (await parallel(
  ['core-unit', 'integration-live', 'app-compile'].map((layer) => () =>
    agent(layerPrompts[layer], { label: `tests:${layer}`, phase: 'Test layers', schema: LAYER_SCHEMA }),
  ),
)).filter(Boolean)

phase('Re-verify')
const verify = await agent(
  `${CTX}\n\nFinal ${MS} verification after fixes + test layers. Run and capture:\n1. cd ${CORE} && swift test  (ALL pass)\n2. cd ${APP} && xcodegen generate && ${XCB}  (BUILD SUCCEEDED, zero compiler errors)\nFix anything broken (or report precisely why it can't be fixed here) and re-run. Report coreTestStatus + appCompileStatus with exact output excerpts.`,
  { label: 'final-verify', phase: 'Re-verify', schema: VERIFY_SCHEMA },
)

const report = await agent(
  `Write the ${MS} iOS milestone-gauntlet handoff report (markdown). Data:\nCONFIRMED + fixes: ${JSON.stringify(confirmed.map((c) => ({ lens: c.lens, finding: c.finding, severity: c.verdict.correctedSeverity })), null, 2)}\nFIXES: ${JSON.stringify(fixes, null, 2)}\nREFUTED: ${JSON.stringify(refuted.map((r) => ({ id: r.finding.id, title: r.finding.title, why: r.verdict && r.verdict.reasoning })), null, 2)}\nTEST LAYERS: ${JSON.stringify(layerResults, null, 2)}\nFINAL VERIFY: ${JSON.stringify(verify, null, 2)}\n\nSections: (1) one-line gate result (PASS only if final swift test passes AND app compiles AND every confirmed finding fixed=true), (2) confirmed-fixed table (severity|lens|file|fix|regression test), (3) test-layer status table, (4) what is SKIPPED + the blocker — ESPECIALLY the on-device verification the developer must do (the simulator can't run here): list concrete steps (sign in, deck CRUD, reorder, image pick/compress/upload, etc.), (5) refuted list (brief), (6) DoD checklist for ${MS}. Be factual.`,
  { label: 'handoff', phase: 'Re-verify' },
)

return {
  milestone: MS,
  findings: { total: allVerified.length, confirmed: confirmed.length, refuted: refuted.length },
  fixes: fixes.map((f) => ({ id: f.id, fixed: f.fixed })),
  layers: layerResults.map((l) => ({ layer: l.layer, status: l.status, testsAdded: l.testsAdded })),
  verify,
  report,
}
