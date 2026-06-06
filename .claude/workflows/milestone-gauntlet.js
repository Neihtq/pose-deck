export const meta = {
  name: 'milestone-gauntlet',
  description: 'Reusable Pose Deck milestone gate: adversarial review (hostile finders → independent refuters) → auto-fix EVERY confirmed finding with regression tests → 4 test layers (component/integration/e2e/regression) → re-verify green. Invoke after a milestone\'s feature code is built and building green.',
  phases: [
    { title: 'Review', detail: 'parallel hostile lenses try to break the milestone diff' },
    { title: 'Refute', detail: 'independent skeptic cross-examines each finding' },
    { title: 'Auto-fix', detail: 'fix every confirmed finding + write a regression test for it' },
    { title: 'Test layers', detail: 'component (RTL) + integration (live PB) + e2e (Playwright)' },
    { title: 'Re-verify', detail: 'build/test/lint green + handoff report' },
  ],
}

// ---- args contract (pass via Workflow({name:'milestone-gauntlet', args:{...}})) ----
// {
//   milestone: 'M1',
//   appDir:    '/Users/qthienng/projects/pose-deck/web',   // where npm build/test/lint run
//   root:      '/Users/qthienng/projects/pose-deck',
//   reviewGlobs: ['web/src/features/**', 'web/src/App.tsx'], // what to review (repo-relative)
//   specFiles: ['docs/DESIGN.md','docs/ARCHITECTURE.md'],
//   buildCmd:  'npm run build',
//   testCmd:   'npm run test',
//   lintCmd:   'npm run lint',
//   backend:   { liveUrl: 'http://127.0.0.1:8090', seedUser: 'owner@posedeck.test', seedPass: 'changeme123' },
//   testLayers: ['component','integration','e2e'],  // which layers to build/require this run
//   platform:  'web',  // 'web' | 'ios' — gates what can actually run
// }
const A = args || {}
const ROOT = A.root || '/Users/qthienng/projects/pose-deck'
const APP = A.appDir || `${ROOT}/web`
const MS = A.milestone || 'milestone'
const SPEC = (A.specFiles || ['docs/DESIGN.md', 'docs/ARCHITECTURE.md']).map((f) => `${ROOT}/${f}`).join(', ')
const GLOBS = (A.reviewGlobs || ['web/src/**']).join(', ')
const BUILD = A.buildCmd || 'npm run build'
const TEST = A.testCmd || 'npm run test'
const LINT = A.lintCmd || 'npm run lint'
const BE = A.backend || {}
const LAYERS = A.testLayers || ['component', 'integration', 'e2e']
const PLATFORM = A.platform || 'web'

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
    id: { type: 'string' },
    fixed: { type: 'boolean' },
    filesModified: { type: 'array', items: { type: 'string' } },
    regressionTest: { type: 'string', description: 'path of the test that now covers this finding' },
    detail: { type: 'string' },
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
  required: ['buildStatus', 'testStatus', 'lintStatus', 'detail'],
  properties: {
    buildStatus: { type: 'string', enum: ['pass', 'fail'] },
    testStatus: { type: 'string', enum: ['pass', 'fail'] },
    lintStatus: { type: 'string', enum: ['pass', 'fail'] },
    detail: { type: 'string' },
  },
}

const CTX = `Pose Deck ${MS} milestone gate. PROJECT ROOT: ${ROOT}. APP DIR (run build/test/lint here): ${APP}.
SPEC: ${SPEC}. Authority split (IMPORTANT — do not conflate): DESIGN.md governs PRODUCT and UI behavior, including user-facing field constraints (e.g. card Title ≤60 chars). ARCHITECTURE.md §3 governs the DATA MODEL and API rules (storage types, DB field maxes, relations, collection rules). When a product/UI constraint in DESIGN.md is stricter than the DB ceiling in ARCHITECTURE.md (e.g. title 60 vs DB max 200), DESIGN.md wins for the UI — the DB max is headroom, NOT a target. Never "relax" a UI constraint to match the DB max.
CODE UNDER REVIEW (repo-relative globs): ${GLOBS}.
Backend for live checks: ${BE.liveUrl || '(none)'}${BE.seedUser ? `, seed user ${BE.seedUser}/${BE.seedPass}` : ''}.
Commands: build='${BUILD}', test='${TEST}', lint='${LINT}'.`

// ---------------- Phase 1+2: Review → Refute (pipelined) ----------------
const lenses = [
  { key: 'correctness', focus: 'logic bugs: boundary conditions, off-by-one, ordering/sort, soft-delete leaks into list queries, optimistic-update revert correctness, position/id math.' },
  { key: 'spec', focus: 'conformance to DESIGN.md/ARCHITECTURE.md field-by-field: required vs optional fields, max lengths, enums, every create/update sets client_updated_at, grouping/ordering rules, soft-delete (not hard-delete) in UI paths, image caps & compression params.' },
  { key: 'security', focus: 'auth token handling/clearing, route guards covering ALL protected routes, filter-string injection on user-supplied values (use pb.filter binding), protected file URLs carrying a token, reliance on server API rules (correct) vs client-only enforcement (wrong), no secrets in committed source.' },
  { key: 'react', focus: 'stale closures / missing effect deps, async races (optimistic ops, create-then-edit), missing loading/error states, list key props, event-listener leaks, setState-after-unmount, check-then-act races (e.g. caps).' },
]

phase('Review')
log(`${MS} gauntlet — ${lenses.length} hostile lenses → independent refutation (pipelined)`)

const perLens = await pipeline(
  lenses,
  (l) => agent(
    `${CTX}

YOUR LENS: ${l.key.toUpperCase()}. Be a HOSTILE reviewer — assume bugs exist. Focus: ${l.focus}
Read the code under review in full. Every finding MUST cite real code (file + line + snippet) and state concrete impact. No style nitpicks, no speculation. If an area is clean, return fewer/zero findings rather than inventing issues.`,
    { label: `review:${l.key}`, phase: 'Review', schema: FINDINGS_SCHEMA },
  ),
  (found, l) => {
    const findings = (found && found.findings) || []
    if (findings.length === 0) return { lens: l.key, verified: [] }
    return parallel(findings.map((f) => () =>
      agent(
        `You are an INDEPENDENT SKEPTIC cross-examining a ${MS} code-review finding (lens: ${l.key}). Your DEFAULT POSITION is that it is a FALSE POSITIVE. Only confirm if you prove it against the real code.
${CTX}

FINDING: id=${f.id} | ${f.title} | ${f.file}:${f.line} | severity=${f.severity}
claim: ${f.claim}
evidence: ${f.evidence}
suggestedFix: ${f.suggestedFix}

Open ${f.file}, read the cited lines + surrounding context (and related files / spec sections the claim depends on). Catch common false positives: the guard exists elsewhere; the value IS correct; the race can't occur given control flow; the spec doesn't require it; server-side PB behavior makes it moot. Verdict 'confirmed' only if verified; 'refuted' if not real (explain the misread); 'partial' if real but overstated. Cite the actual lines you read. correctedSeverity='not-a-bug' if refuted.`,
        { label: `refute:${l.key}:${f.id}`, phase: 'Refute', schema: VERDICT_SCHEMA },
      ).then((v) => ({ finding: f, verdict: v })),
    )).then((vs) => ({ lens: l.key, verified: vs.filter(Boolean) }))
  },
)

const allVerified = perLens.filter(Boolean).flatMap((r) => (r.verified || []).map((v) => ({ lens: r.lens, ...v })))
const confirmed = allVerified.filter((v) => v.verdict && v.verdict.verdict !== 'refuted' && v.verdict.correctedSeverity !== 'not-a-bug')
const refuted = allVerified.filter((v) => !confirmed.includes(v))
log(`Review complete — ${allVerified.length} findings cross-examined: ${confirmed.length} confirmed, ${refuted.length} refuted`)

// ---------------- Phase 3: Auto-fix EVERY confirmed finding (+regression test) ----------------
phase('Auto-fix')
let fixes = []
if (confirmed.length > 0) {
  log(`Auto-fixing ${confirmed.length} confirmed findings (all severities) with regression tests`)
  // Serialize fixes (they may touch overlapping files) — pipeline of 1-wide per item would still race on shared files,
  // so run sequentially via reduce.
  for (const c of confirmed) {
    const f = c.finding
    const fix = await agent(
      `${CTX}

Fix this CONFIRMED ${MS} finding and add a regression test that fails before the fix and passes after.
FINDING: id=${f.id} | ${f.title} | ${f.file}:${f.line} | severity=${c.verdict.correctedSeverity}
claim: ${f.claim}
suggestedFix: ${f.suggestedFix}
skeptic reasoning: ${c.verdict.reasoning}

1. Apply a minimal, correct fix (address root cause, match surrounding code style).
2. Add/extend a unit or component test that specifically covers this bug (prefer the existing test file for that module).
3. Run '${TEST}' in ${APP} to confirm the regression test passes and nothing else broke. If the fix needs a live backend check and ${BE.liveUrl || 'no backend'} is available, curl-verify too.
Report fixed=true only if the test is green. Be precise about files modified.`,
      { label: `fix:${f.id}`, phase: 'Auto-fix', schema: FIX_SCHEMA },
    )
    fixes.push(fix)
  }
} else {
  log('No confirmed findings — skipping auto-fix')
}

// ---------------- Phase 4: Test layers (parallel; each builds + runs its layer) ----------------
phase('Test layers')
const layerPrompts = {
  component: `${CTX}

Build/extend the COMPONENT test layer (React Testing Library + vitest, mocked PocketBase). Cover the ${MS} pages/components under review: render, key interactions, loading/error states, form validation, optimistic flows. Co-locate as *.test.tsx next to components or in __tests__. Run '${TEST}' in ${APP}; report pass only if green. Do NOT hit a real backend (mock the pb client).`,
  integration: `${CTX}

Build/extend the INTEGRATION test layer: vitest hitting a LIVE ephemeral PocketBase. ${BE.liveUrl ? `A backend is running at ${BE.liveUrl} (seed ${BE.seedUser}/${BE.seedPass}).` : 'Start the bare PocketBase binary from backend/ with POSEDECK_DEV=true on a test port if none is running.'} Assert the contract the ${MS} data layer relies on: API rules (owner vs guest visibility), soft-delete filtering, cascade deletes, required-field validation, reorder/position behavior, and any milestone-specific server shapes. Keep tests idempotent (clean up created records). Put them under a clearly-separated integration test path/config so they don't run in the default unit suite if a backend may be absent in CI. Report pass only if green against the live server. If no backend can be started, status='skipped' with the reason.`,
  e2e: `${CTX}

Build/extend the E2E test layer with Playwright. If @playwright/test is not installed in ${APP}, install it (npm i -D @playwright/test) and 'npx playwright install chromium'. Add a playwright config and tests covering the core ${MS} browser flows (for M1: login → create deck → see grouping → open deck → add/edit card → reorder → attach image). Drive against the running web dev server + live backend. If the browser/runtime cannot run in this environment, scaffold the tests + config and set status='skipped' with the exact blocker so the dev can run them. Report pass only if specs actually executed green.`,
}
const layerResults = (await parallel(
  LAYERS.map((layer) => () =>
    agent(layerPrompts[layer] || `${CTX}\nBuild the ${layer} test layer for ${MS}.`,
      { label: `tests:${layer}`, phase: 'Test layers', schema: LAYER_SCHEMA }),
  ),
)).filter(Boolean)

// ---------------- Phase 5: Re-verify green + handoff ----------------
phase('Re-verify')
const verify = await agent(
  `${CTX}

Final ${MS} verification after fixes + new test layers. Run, in ${APP}, IN ORDER and capture output:
1. ${BUILD}
2. ${TEST}
3. ${LINT}
All three MUST pass. If anything fails, fix it (or report precisely why it can't be fixed here) and re-run. Report exact status per command.`,
  { label: 'final-verify', phase: 'Re-verify', schema: VERIFY_SCHEMA },
)

const report = await agent(
  `Write the ${MS} milestone-gauntlet handoff report (markdown). Data:
CONFIRMED findings + fixes: ${JSON.stringify(confirmed.map((c) => ({ lens: c.lens, finding: c.finding, severity: c.verdict.correctedSeverity })), null, 2)}
FIXES: ${JSON.stringify(fixes, null, 2)}
REFUTED (considered, not bugs): ${JSON.stringify(refuted.map((r) => ({ id: r.finding.id, title: r.finding.title, why: r.verdict && r.verdict.reasoning })), null, 2)}
TEST LAYERS: ${JSON.stringify(layerResults, null, 2)}
FINAL VERIFY: ${JSON.stringify(verify, null, 2)}

Sections: (1) one-line gate result (PASS only if final build/test/lint all pass AND every confirmed finding fixed=true), (2) confirmed-issues-fixed table (severity|lens|file|fix|regression test), (3) test-layer status table (layer|status|tests added), (4) anything SKIPPED with the blocker for the dev (e.g. e2e needs a browser, ios needs device), (5) refuted list (brief), (6) explicit DoD checklist for ${MS}: review passed / 0 unaddressed confirmed / component+integration+e2e+regression present. Be factual; do not claim a gate passed if statuses say otherwise.`,
  { label: 'handoff', phase: 'Re-verify' },
)

return {
  milestone: MS, platform: PLATFORM,
  findings: { total: allVerified.length, confirmed: confirmed.length, refuted: refuted.length },
  fixes: fixes.map((f) => ({ id: f.id, fixed: f.fixed })),
  layers: layerResults.map((l) => ({ layer: l.layer, status: l.status, testsAdded: l.testsAdded })),
  verify,
  report,
}
