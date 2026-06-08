# Behavioral Contract — Template / Scaffold

This is the template bootstrap stamps into a consumer's `CLAUDE.md` (Generate mode). It is a
SCAFFOLD, not a finished contract: bootstrap fills the parts it can derive mechanically (clearly
labelled `AUTO-DERIVED — VERIFY`) and leaves the load-bearing behaviour list for a human to author
(`OPERATOR: COMPLETE`).

## Why a scaffold and not auto-generation

The Behavioral Contract is the input the `spec-analyst` reads to extract `behavior-spec.json` — the
**parity baseline**. If bootstrap silently auto-authored the behaviour list and got it wrong, the
parity gate would run GREEN against a baseline that itself omits behaviours — so a migration that
drops those same behaviours would PASS. That false-green is the exact failure the framework exists
to prevent, and it would be caused BY the convenience feature. A loud "parity unavailable" is safer
than a confident-but-wrong baseline. Therefore bootstrap **never** authors the behaviour list; it
scaffolds the structure, pre-fills only the cheap/eyeballable parts, and a human ratifies before the
contract is trusted.

## Heading contract (required by spec-analyst)

The `spec-analyst` reads three elements by heading name. Keep these headings verbatim or the analyst
returns BLOCKED:
- a **recognition pattern** (heading containing "recognition pattern" or "result codes")
- a **Behavior categories** heading (the closed category vocabulary)
- a **Comparison surfaces** heading

## DRAFT-state marker

While any `<!-- OPERATOR: COMPLETE -->` / `OPERATOR:` placeholder or `TODO` remains in the behaviour
sections, the contract is a DRAFT. Bootstrap Validate mode reports it as DRAFT and migrate warns that
parity is not yet protecting the migration. The contract is "done" only when a human has replaced
every `OPERATOR:` section against the legacy source.

---

<!-- ===== EVERYTHING BELOW THIS LINE IS WHAT BOOTSTRAP STAMPS INTO CLAUDE.md ===== -->

# Behavioral Contract

> This section declares the externally-observable behavior a migration MUST preserve. It is the
> input the spec-analyst reads to extract behavior-spec.json — the parity baseline. WITHOUT a
> faithful contract here, the parity gate cannot protect you.
>
> ⚠️ THIS IS A SCAFFOLD, NOT A FINISHED CONTRACT. Bootstrap generated the STRUCTURE and pre-filled
> only the parts it could detect mechanically (marked AUTO-DERIVED — VERIFY). The load-bearing
> part — the behavior list — MUST be authored by a human who knows the behavior (marked
> OPERATOR: COMPLETE). An incomplete or wrong contract is WORSE than none: the gate will pass
> GREEN against a baseline that itself omits behaviors, so a migration dropping those same
> behaviors slips through. Parity protection is NOT real until a human confirms this contract is
> faithful to the legacy code.
>
> TRUTH SOURCE: describe what the **legacy code being migrated** actually does. The contract is the
> OLD system's observable behavior — the behavior the migration must preserve. Read the legacy
> source, not the new code.

## Recognition pattern
<!-- AUTO-DERIVED — VERIFY: bootstrap proposes the regex below from result-code-like string literals
     it found assigned to *ResultCode/Code/Status fields. CONFIRM it matches your codes; if it
     missed a family or over-matched, replace it. If bootstrap could NOT confidently derive a
     pattern, this is left blank with an OPERATOR note — declare it yourself. -->
<!-- OPERATOR: COMPLETE if blank — e.g. [EWS]\d{4} for codes like W0011/E1000, or describe your
     result-indicator (HTTP status enum, gRPC code, domain result object). -->

## Behavior categories
<!-- Standard 5-category set — adjust only if your domain genuinely differs. -->
- result_code        — a result/status value emitted to the caller on a specific condition
- wire_contract      — a request/response field (name + type) or an endpoint (METHOD + route)
- side_effect        — an outbound operation crossing a process boundary (logging, downstream call, DB)
- state_transition   — an observable change of persisted or propagated state
- error_path         — a distinct caller-observable error outcome (trigger → code / HTTP status)

## Comparison surfaces
<!-- AUTO-DERIVED candidate files — VERIFY each maps to a real surface; add/remove as needed.
     ⚠️ Most of the wire contract often lives in the repository/service layer, NOT the entry point.
     Confirm you have the FULL transitive scope, not just the controller — this is a top cause of
     missed behaviors. -->
1. Entry point / controller         — <!-- AUTO: <detected entry-point file> | OPERATOR: confirm -->
2. Business logic / data access      — <!-- AUTO: <detected repository/service file(s)> | OPERATOR: confirm + add downstream -->
3. Wire format (request/response)    — <!-- AUTO: <detected request/response model file(s)> | OPERATOR: confirm -->
4. Auth / channel gate               — <!-- AUTO: <detected auth filter, or "none detected"> | OPERATOR: confirm -->

## Observable behavior list
<!-- OPERATOR: COMPLETE — author this from the LEGACY source. Bootstrap CANNOT fill this faithfully
     (a guessed behavior list = a false parity baseline). Transcribe the EXACT conditions from the
     legacy code. -->

### Result-code map
<!-- OPERATOR: COMPLETE — one row per result code. Condition must be exact and caller-observable. -->
| Result code | Condition (caller-observable, transcribed from legacy) | HTTP status |
|---|---|---|
| <!-- e.g. W0011 --> | <!-- e.g. identifier present but Version empty/whitespace --> | <!-- 400 --> |

### Result determination (pass-through vs local)
<!-- OPERATOR: COMPLETE — for each SUCCESS path, does the entry point SET the result code locally,
     or PASS IT THROUGH from a downstream/repository response? A migration that changes this
     mechanism (legacy delegates, migrated hardcodes) is a drift even if the value matches. This is
     subtle and easy to drift — state it explicitly per success path. -->

### Side effects & state transitions
<!-- OPERATOR: COMPLETE — list observable side effects (request/response logging, downstream HTTP,
     DB writes) and state changes. Note timing/ordering if a caller can observe it (e.g.
     fire-and-forget vs awaited). -->

## Constraint handling
- PRESERVE EXACTLY (caller-observable):
  <!-- OPERATOR: result codes + conditions, HTTP status per condition, response field names/types,
       identifier precedence ORDER, version-routing behavior, endpoint routes -->
- MODERNIZE FREELY (caller does NOT observe): hosting model, DI container, sync→async, serialization
  library (verify output equivalence), logging framework, exception-handling idiom — as long as the
  observable result code / HTTP status outcomes above are preserved.

<!-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
     FAITHFULNESS GATE — this contract is NOT done until a human has confirmed every OPERATOR
     section against the legacy source. While any "OPERATOR:" placeholder or TODO remains, the
     contract is a DRAFT and parity is NOT protecting you. Bootstrap Validate reports DRAFT until
     the OPERATOR placeholders are replaced.
     ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ -->
