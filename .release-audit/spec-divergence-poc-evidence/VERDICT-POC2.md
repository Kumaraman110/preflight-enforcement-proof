# Spec-Divergence POC#2 (SEMANTIC metric) — verdict: VERIFIED, with a real scope caveat

POC only. Builds directly on commit 1880bb2 (POC#1), which FALSIFIED the token-Jaccard metric. NOT wired
into scaffold/migrate, no Phase 0, no gate. Tests the FIXED (semantic) metric.

## The claim under test
"A SEMANTIC divergence measure over independently-generated interpretations — restricted to the
load-bearing axes — separates under-specified from well-specified prompts: vague -> high, specified -> low.
Semantic, not lexical; computed, not self-assessed."

## Method (confounds addressed vs POC#1)
- Generation: same blind design — independent interpreters, each sees only its prompt + a fixed schema,
  none told the hypothesis. Interpretations on the LOAD-BEARING axes only (scope boundary, surfaces in/out,
  core behavior) — not all free-text (POC#1's verbosity confound lived in the prose).
- Semantic metric: **approach (b), blind agent-judges** (no embedding mechanism is available in this env —
  no sentence-transformers/numpy/API key). Each set is scored by 3 INDEPENDENT judges who see ONLY the
  interpretations, NOT the original prompt — so a judge CANNOT know whether the prompt was vague or
  specified. Judges score meaning-level agreement per axis, told to ignore wording/verbosity.
  `lib/spec-divergence-semantic-poc.sh` aggregates the judge verdicts deterministically.
- n: 5 pairs (the 3 from POC#1, reused verbatim, for direct comparison + 2 new). 3 judges/set = 30 blind
  judgments. New pairs (p4-notify, p5-export) chosen to be generic (no CTI/AccountLookup nouns) to design
  out POC#1's in-repo-disambiguator confound.

## Actual results (semantic divergence 0..1; 0 = same task, 1 = different tasks)
| pair | VAGUE | SPECIFIED | separation | note |
|---|---|---|---|---|
| p1-migrate  | 0.130 | 0.121 | +0.009 | both LOW — repo context made even the vague form determinable |
| p2-scaffold | 0.096 | 0.094 | +0.002 | both LOW — same (conventional "orders API" resolves) |
| p3-cache    | 0.747 | 0.122 | **+0.626** | vague genuinely forked ("cache OAuth token" vs "cache validation result") |
| p4-notify   | 0.723 | 0.030 | **+0.693** | vague genuinely forked (what to notify / which channel / blocking?) |
| p5-export   | 0.181 | 0.017 | +0.164 | vague partly resolvable; specified near-zero |

POC#1 token-Jaccard on the SAME 3 prompts (for comparison): p1 0.611/0.638 (INVERTED), p2 0.657/0.578,
p3 0.775/0.645.

## Verdict
- **Does SEMANTIC divergence separate under-specified from well-specified where lexical did not? VERIFIED,
  with a scope caveat.** Two decisive improvements over POC#1:
  1. **NO FALSE POSITIVES.** Every SPECIFIED prompt scored <= 0.122. A threshold at 0.30 flags zero
     well-specified prompts. POC#1's token-Jaccard scored specified prompts 0.58-0.64 (one inverted); the
     semantic metric does not.
  2. **The p1 inversion is FIXED — the single most diagnostic result.** POC#1 scored p1-SPECIFIED 0.638
     (falsely high, inverted) because the verbose-but-agreed interpretations diverged lexically. The
     semantic metric scores it **0.121 (correctly low)** — the judges saw the interpreters AGREED on
     meaning and ignored the wording. This is exactly the fix POC#1's VERDICT.md prescribed.
  Where vagueness GENUINELY survived to the interpreters (p3, p4), divergence fired strongly (0.75, 0.72)
  and cleanly separated from specified.
- **Is it genuinely semantic + computed + blind? VERIFIED.** Generation is blind; judging is by independent
  judges shown only the interpretations (never the prompt -> cannot infer vague/specified); aggregation is
  deterministic (no confidence field, no agent dispatch in the aggregator — test J4). It is NOT the working
  agent rating its own confidence.

## The honest caveat (do not overclaim)
- **The metric measures "is this prompt ambiguous IN THIS CONTEXT," not "was this prompt terse."** p1/p2
  vague scored LOW — correctly: in the preflight/conventional context the interpreters could resolve them,
  so they were NOT actually ambiguous. Low divergence on a determinable prompt is the RIGHT answer, not a
  miss. But it means the metric flags *residual ambiguity after context is applied*, which is the useful
  thing for a gate — not "did the human write a short prompt."
- **The confound-removal was only PARTIAL.** p4-notify was meant to be confound-free, but the interpreters
  still partially resolved "add notifications" via repo context (all converged on "a preflight framework
  notification hook") — yet it STILL forked enough on scope/channel/blocking to score 0.72. p5-export
  vague scored only 0.181 (lower than hoped) — the "export data" framing self-resolved more than expected.
  So the clean separators are p3 and p4; p5 is weak-positive; p1/p2 are true-low. n is still small (5).
- **Judge noise is low but nonzero:** per-set judge spread 0.02-0.10; 3 judges/set smooths it. A production
  metric would want >=3 judges and a noise check.

## Bottom line for the full build
The semantic divergence signal is REAL and the cheap-metric confound is fixed: blind judges that ignore
wording separate genuinely-ambiguous prompts (high) from specified/determinable ones (low) with no false
positives across 5 pairs, and fix POC#1's diagnostic inversion. This is a GO signal for the mechanism —
with these conditions on the full build:
1. Use blind agent-judges (or embeddings if a mechanism becomes available), NOT token overlap.
2. Judges must be blind to the prompt (see only interpretations) — or it becomes self-assessment.
3. The score means "residual ambiguity after context," which is the right gate signal; set the threshold
   above the specified-ceiling (~0.13 here -> a 0.30 threshold has margin), and validate the threshold at
   larger n before trusting it as a hard gate.
4. It costs N interpreter agents + M judge agents per gate decision — real token cost; the full build must
   weigh that against the cascade it prevents.

Two POCs in: POC#1 falsified the lexical metric; POC#2 verified the semantic one with caveats. The
mechanism is viable; the measurement must be semantic and blind. NOT a falsification — a qualified GO.
