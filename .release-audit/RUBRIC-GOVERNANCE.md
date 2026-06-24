# RUBRIC GOVERNANCE — multi-team editing without silent cross-team degradation

**Date:** 2026-06-17 · **Branch:** fix/followups-null-lint-config @ (pre-POC) 48b234d · **Mode:** DESIGN + THIN POC.
Recommend one ownership model, build a runnable POC of the recommended model only, then STOP for the
owner's decision. No version bump, no tag, no push.

> **PRIME REQUIREMENT (governs everything).** A rubric is DETECTION LOGIC — it feeds what gets caught,
> which feeds gates. "Multiple teams edit rubrics" is a SAFETY problem, not a convenience one: the real
> risk is one team SILENTLY WEAKENING a rule another team's service depends on (lowering another team's
> detection bar). Governance = teams can edit WITHOUT one team degrading another's detection, with full
> provenance, human-approved, auditable. A design that is frictionless but lets Team A weaken Team B's
> rule has FAILED. Mechanism over convention wherever feasible.

---

## PHASE 1 — How the rubric is structured today, and does it partition by team?

**Structure (uniform, machine-parseable — verified across all three example rubrics):**
- One Markdown file per rubric (`examples/rubrics/rubric-{generic,migration,api-design}-dotnet.md`).
- Section-ID prefix per rubric (`§G`, `§M`, `§A`) declared in a header comment "to enable unambiguous
  cross-rubric reference."
- `## §<prefix><N>` = a top-level section (a CONCERN); `### §<prefix><N>.<M>` = a rule, each with three
  fields: `**Detect:**` (the pattern that fires), `**Severity:**` (one of an enumerable 4-level scale
  `blocker > major > minor > info`), `**Fix:**` (remediation).
- A rule is read by `code-reviewer` (the ONLY operative detection source); a finding cites its §ID.

**Does it partition cleanly by team? — NO.** Sections are organized by **technical concern**, not by
team: §G1 Async Correctness, §G2 Security, §G3 Error Handling, §G4 HTTP, §G5 DI, §G6 Config, §G7
Testing. These are **cross-cutting** — every team's service has security rules, async rules, config
rules. "§G2 Security" is not owned by one team; it is DEPENDED ON by all of them. There is no clean
"Team A's rules vs Team B's rules" split to draw section ownership around. This is the decisive fact
for the model choice below.

**The weakening vector is already built into the system.** The existing edit flow
(`skills/rubric-edit`, `lib/rubric-promotion-evaluator.sh`) has a **`LOOSEN`** decision: a
false-positive capture "drives rubric LOOSENING (narrow/except/remove the cited section)". That is
*exactly* the silent-degradation risk at a cross-team boundary: a LOOSEN that is legitimate for Team
A's false-positive narrows/removes a rule Team B's service still depends on. The risk is real and live,
not hypothetical.

**Provenance today:** git history (`git log`/`blame` on the rubric file) + the `chore(rubric)` PR body
+ the rubric-edit process's own audit trail. Branch protection is LIVE → every rubric PR already needs
a non-pusher human approval. The `config.local.json` overlay (`lib/config-overlay.sh`) already exists
as a deny-by-default-can't-weaken precedent.

---

## PHASE 2 — The two models, assessed against the prime requirement

### MODEL A — Sectioned rubric, ownership-per-section (CODEOWNERS-per-section)
One rubric, sections assigned to team owners; CODEOWNERS gates cross-section merges.

- **Partition fit:** POOR. Sections are concerns, not teams (Phase 1). To use CODEOWNERS-per-section you
  must first invent a team→section assignment that the rubric's structure does not naturally support.
  Who owns §G2 Security when every team depends on it? Shared/cross-cutting rules have no single owner —
  the model's core premise (sections partition by team) is false here.
- **Against the prime requirement:** it only **ATTRIBUTES**, doesn't **PREVENT**. CODEOWNERS gates a PR
  that touches *another* team's section — but WITHIN a section you own (or a shared section assigned to
  you), you can still lower a severity or narrow a Detect that another team's service depends on, and
  CODEOWNERS waves it through because it's "your" section. **Failure mode: silent within-section
  weakening of a shared rule.** The gate is on *file region*, not on *the weakening operation*.
- **Provenance / conflict / branch-protection:** git + CODEOWNERS at section granularity; two teams
  editing the same section still collide (CODEOWNERS doesn't resolve concurrent edits, just gates
  approval). Rides on live branch protection cleanly (CODEOWNERS is native).
- **Verdict:** simpler to wire (just a CODEOWNERS file), but does NOT satisfy the prime requirement for
  the cross-cutting rules that dominate this rubric. It attributes weakening; it doesn't prevent it.

### MODEL B — Layered rubric: shared base + per-team overlays that can only TIGHTEN
A shared BASE rubric all teams inherit, plus per-team OVERLAY layers that may ADD rules or STRENGTHEN
detection but can NEVER WEAKEN the base. Mirrors `config-overlay.sh`'s "allowlist / committed-wins /
can't-weaken" pattern.

- **What "can only tighten, never weaken" means concretely for a rubric:**
  - ALLOWED (tighten): ADD a new rule (new §ID not in base); RAISE a base rule's severity
    (minor→major→blocker); ADD a stricter team-specific rule alongside a base rule.
  - BLOCKED (weaken): REMOVE / omit a base rule; LOWER a base rule's severity; REDEFINE a base rule's
    `Detect` (narrowing scope / broadening an exception is a Detect rewrite — an overlay must not touch
    base Detect text at all; it adds rules, it doesn't edit base ones).
- **Mechanically enforceable?** YES for the crisp cases, reusing the config-overlay precedent: severity
  is an enumerable rank, rules are keyed by §ID — so "every base §ID still present" and "overlay
  severity ≥ base severity for any shared §ID" and "overlay does not alter a base rule's Detect" are
  deterministic checks. (See the POC: `lib/rubric-overlay-check.sh`.)
  - **Honest boundary:** rule-removal and severity-lowering are caught ROBUSTLY (structural). A subtle
    *semantic* narrowing buried inside NEW prose the overlay adds to its OWN rules is not "weakening the
    base" (the base rule is untouched) — it can only make the overlay stricter or add scope, never relax
    a base rule, because the base rule is immutable from the overlay's side. The check enforces "base
    rules are immutable + overlay-only-adds-or-raises"; it does NOT try to NLP-judge free prose. That
    boundary is the right one: it makes base detection a floor that an overlay cannot lower, full stop.
- **Cost/complexity:** moderate — a resolver (base ∪ overlay, with overlay tightening) + the
  no-weaken check + a parse of the rubric Markdown into {§ID → severity, detect}. The parse is simple
  given the uniform schema. Higher than Model A's CODEOWNERS-only, but the mechanism is the product.
- **Who owns the base / how is a base change governed:** the BASE is the shared safety floor — it is
  the highest-governance artifact. Base changes go through the strictest path: a `chore(rubric-base)`
  PR requiring approval from a designated base-owners group (CODEOWNERS on the base file) — ideally a
  cross-team rubric council, not any single team. A base *weakening* (lowering a base severity /
  removing a base rule) is the one operation that genuinely lowers everyone's floor; it must be the
  most-scrutinized change, never routine. Overlays need NO such ceremony because they can only tighten —
  that's the asymmetry the model buys: cheap to strengthen locally, expensive to weaken globally.
- **Provenance / conflict / branch-protection:** git + a structured rubric changelog (below); two teams'
  overlays are independent files → no collision (the whole point of layering); base file gets
  CODEOWNERS at base-owner granularity. Rides on live branch protection.
- **Verdict:** satisfies the prime requirement MECHANICALLY (an overlay cannot lower the base floor —
  enforced by a check, not a convention), at moderate complexity, reusing an existing precedent.

---

## PHASE 2 — RECOMMENDATION

**Recommend MODEL B (layered base + tighten-only overlays).** Decision criteria, applied:

1. **Does the rubric partition cleanly by team?** NO (Phase 1) — rules are cross-cutting concerns
   shared by all teams. This directly disqualifies Model A's premise and favors B (a shared base every
   team inherits is the honest representation of cross-cutting rules).
2. **Prevent vs attribute?** The prime requirement is to PREVENT silent cross-team degradation. Model A
   only attributes (CODEOWNERS gates cross-section edits; within-section weakening of a shared rule
   still merges). Model B PREVENTS it mechanically (an overlay cannot lower the base; a base weakening
   is forced onto the highest-scrutiny path).
3. **Is mechanism-enforced no-weakening worth the complexity for an accountability product?** YES — it
   is preflight's entire ethos (mechanism over convention; the gates are `if` statements, not
   suggestions). A governance model that relies on "the section owner won't weaken the shared rule" is
   a convention; a check that rejects a weakening overlay is a mechanism.

**Honest tradeoff (it is not unconditionally B):**
- Model A is genuinely SIMPLER (a CODEOWNERS file, zero new code) and would be the right call IF the
  rubric partitioned cleanly by team AND teams only ever ADDED disjoint rules. It does not, and they do
  not (the LOOSEN path exists). 
- Model B costs a resolver + a check + the Markdown parse, and introduces the "who owns the base"
  governance question (answered above: a base-owners group; base weakening is the most-scrutinized
  change). If the org has NO cross-team-shared rules in practice (every rule is genuinely one team's),
  Model A's simplicity would win — but that is not what the rubric looks like today.
- **Close call?** No — the cross-cutting structure + the live LOOSEN weakening-vector + the
  mechanism-over-convention ethos all point the same way. B.

This is a RECOMMENDATION. The owner may accept B, override to A (accepting that it attributes rather
than prevents within-section weakening), or adjust (e.g. A-with-a-no-weaken-check bolted on, which is
really B in disguise).

---

## PHASE 3 — THIN POC (Model B), what it proves

Built (thin — proves the mechanism, not the full governance flow):
- `examples/rubrics/governance-poc/base-rubric.md` — a minimal shared base (2 rules: a blocker, a major).
- `examples/rubrics/governance-poc/overlay-tighten.md` — a VALID overlay (adds a rule + raises a base
  severity). Must be ALLOWED.
- `examples/rubrics/governance-poc/overlay-weaken.md` — an INVALID overlay (lowers a base severity).
  Must be BLOCKED.
- `lib/rubric-overlay-check.sh` — the load-bearing ENFORCEMENT CHECK: parses base + overlay, rejects
  any overlay that (a) omits/removes a base §ID, (b) lowers a base §ID's severity, or (c) alters a base
  §ID's Detect text. Exit 0 = overlay only tightens (allowed); exit 1 = overlay weakens the base
  (BLOCKED, with the offending §ID + reason). Reuses the config-overlay "committed-wins, can't-weaken"
  shape.
- `tests/behavioral/rubric-overlay-check-test.sh` — the core-property test.

**RED→GREEN (the load-bearing proof):**
- RED: `overlay-weaken.md` (lowers §B2 major→minor) → check exits 1, BLOCKED, names §B2.
- RED: an overlay that REMOVES a base rule → BLOCKED. An overlay that REDEFINES a base Detect → BLOCKED.
- GREEN: `overlay-tighten.md` (adds §T1, raises §B1 major→blocker) → check exits 0, allowed.

**What the POC does NOT prevent (honest boundary):** it enforces that the BASE is an immutable floor an
overlay cannot lower — rule-removal and severity-lowering are caught structurally. It does NOT
NLP-judge whether free prose an overlay adds to its OWN new rules is "really" strict, and it does not
govern a change to the BASE file itself (that is the base-owners-CODEOWNERS path in Phase 4, not the
overlay check). The boundary is deliberate: base detection is a hard floor; overlays are add-or-raise
only; base changes are the separately-governed, highest-scrutiny path.

---

## PHASE 4 — Provenance + interaction with branch protection (spec; light)

**Provenance = git + a structured rubric changelog. NOT an agent-memory layer** (per MEMORY-DESIGN.md:
rubric provenance is governance/git, not agent-memory — git already keeps an exact, immutable
who/what/when; a fuzzy memory layer would be strictly worse). The light addition that git alone lacks
is the *why* in a structured, queryable form:
- **who/what/when:** `git log`/`git blame` on the base + overlay files — already immutable & complete.
- **why (structured):** a `## Changelog` block convention in each rubric/overlay file (or a sidecar
  `CHANGELOG` per rubric) — one entry per change: `date | §ID | operation (add/raise/loosen-base) |
  rationale | capture/PR ref`. This makes "did this change help?" answerable by correlating the entry
  against subsequent `metrics.json` round-count trends (the framework's stated contract), exactly the
  G2 finding in MEMORY-DESIGN.md. Cheap: it's a documented PR-template field, version-controlled.

**Branch-protection interaction (CODEOWNERS granularity):**
- **Base rubric file** → CODEOWNERS owned by the **base-owners group** (cross-team council). A base
  change — especially a weakening — needs their approval. This is where the highest scrutiny rides on
  the live PR+approval protection.
- **Per-team overlay files** → CODEOWNERS owned by that team. A team approves its own overlay; because
  the overlay-check mechanically guarantees an overlay can only tighten, a team approving its own
  overlay CANNOT lower anyone else's floor. (This is the asymmetry that makes overlays low-ceremony.)
- The overlay-check should run in CI on every rubric PR (advisory→blocking is a promotion decision like
  WIRE-B): a PR whose overlay weakens the base fails the check before a human ever approves it.

---

## Battery + staging
- Full behavioral battery re-run after the POC: must stay green (now 31 + the new overlay-check suite).
- Staged not shipped: POC + this doc committed atomically; no version bump, no tag, no push; v0.9.0 at
  1651ecc untouched.

## THE DECISION THE OWNER NOW NEEDS TO MAKE (to proceed to full build)
1. **Accept Model B** (layered base + tighten-only overlays, mechanism-enforced no-weakening) — or
   override to A / adjust?
2. If B: **who is the base-owners group** (the cross-team rubric council that governs base changes)?
   The model is defined; the human membership/authority is an org decision, not a code one.
3. **CI enforcement level for the overlay-check**: advisory first, or blocking from the start? (Mirrors
   the WIRE-B advisory→blocking promotion question.)
4. **Provenance depth**: is git + the structured `## Changelog` convention sufficient, or does the org
   want a richer queryable provenance store? (Recommendation: start with git + changelog.)
Only after (1) is decided does the full build proceed (full resolver wiring into code-reviewer's rubric
load, the base-owners CODEOWNERS, the CI step, the changelog template).
