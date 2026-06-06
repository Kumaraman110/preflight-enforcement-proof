# Adjudication Record — the parent's verdict-of-record

After the parent's **context-before-fix** adjudication (`fix-and-close` SKILL "Context-before-fix
— parity defends"), every behavioral Copilot finding reaches a verdict: FIXED or DEFENDED (or the
AMBIGUOUS variants). That verdict — **with its cited legacy evidence** — is the authoritative
decision-of-record. It is written to a durable, SHA-keyed artifact, NOT to metrics.

## Why this is separate from metrics and from gate evidence

Three different concerns, three different homes — do not conflate them:

| Concern | Artifact | Format | Who consumes |
|---|---|---|---|
| **Decision-of-record** (which finding was fixed vs defended, and on what evidence) | `.preflight/adjudications/PR<n>-<HEAD>.json` | JSON, SHA-keyed | the reconciliation step; future verdict-aware convergence cap; human audit |
| **Telemetry** (how many findings, how many rounds) | `.preflight/metrics.json` | JSON, append-only | trend analysis |
| **Gate pass/fail** (did tests/stage1/parity pass at this HEAD) | `.preflight/gate/<name>` | `HEAD=` text | `pre-push-gate` |

The adjudicated verdict is **load-bearing decision infrastructure**, not a side-log. Burying it in
the free-form metrics blob would let a fabricated verdict look native (the `verifiedAgainstSource`
disease — a correctness claim with nothing behind it). It gets its own artifact so the record is
unambiguous and so a future consumer reads a structured, SHA-keyed source.

## Location and SHA-keying

Path: `.preflight/adjudications/PR<pr-number>-<HEAD-sha>.json` (one file per PR per HEAD).

The `head` field is the full git HEAD SHA at adjudication time. A consumer treats the record as
**fresh** only if `head` equals the current HEAD or its immediate parent (HEAD^) — the same
staleness rule `pre-push-gate`'s `check_evidence` applies to gate evidence. Any new commit beyond
HEAD^ invalidates the record (the code changed; the verdicts must be re-adjudicated). This makes
the artifact correct-by-construction for the SHA-keyed consumer that 1B's validator and any future
verdict-aware cap will require.

## Schema

```json
{
  "pr": 92,
  "head": "<full git HEAD sha at adjudication time>",
  "adjudicatedAt": "<ISO-8601 timestamp>",
  "adjudications": [
    {
      "commentId": "<github review-comment id>",
      "threadNodeId": "<PRRT_… graphql thread node id>",
      "path": "<file>:<line>",
      "parentVerdict": "FIXED | DEFENDED | AMBIGUOUS-FIXED | AMBIGUOUS-DEFENDED",
      "citedEvidence": "<see citedEvidence rule below>",
      "handlerStability": "stable | trivial-stable | unstable | contradicts-rubric",
      "securityEscalated": false,
      "residualUncertainty": "<text, or null>"
    }
  ]
}
```

### Field rules

- **`parentVerdict`** — the closed verbatim set above. No other value is valid. This is the
  parent's decision, NOT the handler's recommendation (the handler emits FORM + ROUTING only and
  has no correctness authority — see the external-review-handler boundary).

- **`citedEvidence` — the constraint that prevents soft defenses (mechanized by 1B):**
  - For **`DEFENDED`** and **`AMBIGUOUS-DEFENDED`**: `citedEvidence` MUST be a concrete citation —
    a specific **legacy `file:line`** showing the legacy behavior matches, OR a **rubric `§N`** that
    explicitly sanctions the behavior. A prose excuse such as `"no evidence — <reason>"`,
    `"intentional"`, `"legacy-faithful"`, or `"matches CLAUDE.md"` (without a specific citation) is
    **INVALID** for these verdicts. This mirrors the SKILL's evidence requirement: *"A finding may
    be classified DEFENDED only with CITED EVIDENCE: a specific legacy file:line ... A bare
    assertion ... is NOT sufficient."* A defended verdict without a citation is the
    `verifiedAgainstSource` pattern in miniature — a defense asserted with nothing behind it — and
    is rejected.
  - For **`FIXED`** and **`AMBIGUOUS-FIXED`**: `citedEvidence` MAY be `"n/a — fixed, not defended"`
    (you do not cite legacy to justify changing code). A real citation is still permitted (e.g. the
    legacy file:line that proved the migrated code was wrong), but `"n/a — fixed, not defended"` is
    the accepted default.

- **`residualUncertainty`** — required (non-null) for the `AMBIGUOUS-*` verdicts: record what
  evidence was found (or "no evidence found — legacy source does not cover this path") and what
  doubt remains. `null` for unambiguous FIXED/DEFENDED.

- **`securityEscalated`** — `true` when the finding touched auth/authz/fail-open/SSRF/injection/
  secrets/privilege-escalation and was escalated to the human (security findings never auto-defend).

## Enforcement (mechanical — `adjudication-output-gate`)

The parent writes this artifact directly, and the write is **mechanically gated** by the
`adjudication-output-gate` hook (registered as a `PreToolUse:Write` matcher in `hooks/hooks.json`,
alongside `bootstrap-write-gate`). The hook intercepts any Write whose `file_path` matches
`.preflight/adjudications/*.json`, two-level-parses `tool_input.content`, and blocks the write
(exit 2) on either enforcement target:

1. **Forbidden keys** — any per-finding key outside the closed allow-list above is rejected. A
   smuggled correctness-attestation field (`verifiedAgainstSource`, `isRealBug`, `legacyConfirmed`)
   cannot enter the record — this is what makes the `verifiedAgainstSource` fabrication
   *unrepresentable*, not merely discouraged.
2. **No-DEFENDED-without-evidence** — a `DEFENDED` / `AMBIGUOUS-DEFENDED` entry whose `citedEvidence`
   does not match a concrete citation (a legacy `file:line`, a rubric `§N`, or a named design-doc
   artifact: `MIGRATION_PATTERNS.md`, `behavior-spec*`, `name-contract`, `dependency-map.json`,
   `legacy-db-name-contract`) is rejected as a prose excuse.

The gate **fails closed** for this path: malformed tool JSON, unparseable content, or no available
JSON parser all block the write — a malformed verdict-of-record must not reach disk. Every
non-adjudication write passes through untouched. The accepted-citation forms are deliberately
lexical (presence of a real citation token), not semantic: the gate blocks *un-auditable* defenses
(bare adjectives); whether a named artifact substantively supports the claim is the parent's
context-before-fix job plus human audit, not the gate's.
