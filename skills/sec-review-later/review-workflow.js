export const meta = {
  name: 'sec-review-later',
  description: 'Adversarial security review of a [sec-review-later] sprint: one reviewer per dimension, then refute-verify each finding',
  phases: [
    { title: 'Review', detail: 'one senior security reviewer per attack-surface dimension' },
    { title: 'Verify', detail: 'a skeptic tries to refute each finding; drop the refuted' },
  ],
}

// ── FILL THESE IN from scan.sh digest before running ───────────────────────
const SPRINT = 'app-isolation'                       // bucket key from the digest
const REPO = '/Users/tomtang/code/edgevector/fold'
const RANGE = 'PASTE_RANGE_FROM_DIGEST'              // <oldest>^..<newest>
const PRS = 'PASTE_PR_LIST'                          // "#699, #707, …"

// One entry per attack surface. files = the changed files this reviewer owns.
const DIMENSIONS = [
  {
    key: 'TCP-LOOPBACK OWNER-BYPASS CLOSURE',
    files: [
      'fold_db_node/src/server/middleware/owner_verb_gate.rs',
      'fold_db_node/src/server/middleware/host_guard.rs',
      'fold_db_node/src/server/routes/setup.rs',
      'fold_db/crates/core/src/app_isolation.rs',
    ],
    hunt: 'Can a non-owner local process forge owner authority? How is the X-Folddb-Session token minted/stored — readable, guessable, world-readable, logged? Constant-time compare? Replayable / bound to nonce+expiry? Can a request get itself tagged InProcess (most-privileged) via header spoof or a route that hardcodes it? Is owner_verb_gate applied to ALL owner-authority verbs (default-deny) or is there a route that skips it? After the flip, is unattested fail-closed?',
  },
  // … add the remaining dimensions for this sprint (see SKILL.md Step 1) …
]
// ───────────────────────────────────────────────────────────────────────────

const FINDINGS_SCHEMA = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          severity: { type: 'string', enum: ['crit', 'high', 'med', 'low'] },
          title: { type: 'string' },
          location: { type: 'string', description: 'file:line' },
          what: { type: 'string' },
          impact: { type: 'string', description: 'concrete attacker steps' },
          fix: { type: 'string', description: 'fix sketch' },
        },
        required: ['severity', 'title', 'location', 'what', 'impact', 'fix'],
      },
    },
  },
  required: ['findings'],
}

const VERDICT_SCHEMA = {
  type: 'object',
  properties: {
    refuted: { type: 'boolean', description: 'true if NOT a real exploitable finding' },
    reason: { type: 'string' },
  },
  required: ['refuted', 'reason'],
}

const reviewPrompt = (d) => `You are a senior security reviewer auditing the EdgeVector **${SPRINT}** sprint flagged \`[sec-review-later]\`. Your dimension: **${d.key}**.
Repo: ${REPO} (cd there; cargo workspace). Review range: \`${RANGE}\`. PRs: ${PRS}.
PRIMARY FILES (read the full current file AND the diff over the range):
${d.files.map((f) => '  - ' + f).join('\n')}
HUNT FOR (adversarial — assume a hostile local process / malicious peer): ${d.hunt}
For EACH finding return: severity / title / location file:line / what / impact (concrete attacker steps) / fix sketch. If you find nothing real in your dimension, return an empty findings array — do NOT invent findings.`

const verifyPrompt = (f) => `Adversarially REFUTE this security finding from a ${SPRINT} review. Repo: ${REPO} (range ${RANGE}).
  severity: ${f.severity}
  title: ${f.title}
  location: ${f.location}
  what: ${f.what}
  impact: ${f.impact}
Read the cited code. Is the line actually reachable over the claimed transport/path? Is there already an upstream guard that neutralizes it? Is the posture/threat assumption wrong? Default to refuted=true if you are not confident the exploit is real and reachable.`

const results = await pipeline(
  DIMENSIONS,
  (d) => agent(reviewPrompt(d), { label: `review:${d.key.slice(0, 24)}`, phase: 'Review', schema: FINDINGS_SCHEMA }),
  (review, d) =>
    parallel(
      (review?.findings || []).map((f) => () =>
        agent(verifyPrompt(f), { label: `verify:${f.title.slice(0, 24)}`, phase: 'Verify', schema: VERDICT_SCHEMA })
          .then((v) => ({ ...f, dimension: d.key, verdict: v }))
      )
    )
)

const confirmed = results
  .flat()
  .filter(Boolean)
  .filter((f) => f.verdict && f.verdict.refuted === false)

const refuted = results.flat().filter(Boolean).filter((f) => f.verdict && f.verdict.refuted === true)

log(`sec-review-later/${SPRINT}: ${confirmed.length} confirmed, ${refuted.length} refuted`)
return { sprint: SPRINT, range: RANGE, confirmed, refuted }
