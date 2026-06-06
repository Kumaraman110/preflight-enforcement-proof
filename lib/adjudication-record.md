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

## Enforcement boundary (1A is un-gated; 1B mechanizes this)

1A is written by the **parent** directly and is **not yet gated** — the parent is instructed to
honor the schema, but nothing mechanically blocks a malformed write. This is a known transitional
gap: until 1B lands, the verdict-of-record is agent-mintable (the same class as the
`verifiedAgainstSource` fabrication and the parity-clean self-clear).

**1B closes it** with a `PreToolUse:Write` validator (`adjudication-output-gate`) that intercepts
any Write to `.preflight/adjudications/*.json` and blocks (exit 2) on **two** enforcement targets
defined here:
1. **Forbidden keys** — any key outside the closed per-finding schema above (e.g. a smuggled
   `verifiedAgainstSource`/`isRealBug`/`legacyConfirmed` correctness-attestation field).
2. **No-DEFENDED-without-evidence** — a `DEFENDED`/`AMBIGUOUS-DEFENDED` entry whose `citedEvidence`
   is not a concrete `file:line` or `§N` citation (i.e. matches a prose-excuse pattern).

Both rules are stated here precisely so 1B has an unambiguous spec to mechanize.
