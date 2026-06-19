# Spec-Divergence POC — empirical verdict (MIXED, leaning FALSIFIED-as-built)

POC only. The scorer (`lib/spec-divergence-poc.sh`) is NOT wired into scaffold/migrate. This note records
the actual experiment so the result is reproducible and the full subsystem is NOT built on an unproven signal.

## The claim under test
"Generating N candidate interpretations of a prompt and measuring their DIVERGENCE is a real mechanical
signal for under-specification: a vague prompt yields HIGH divergence; a well-specified prompt yields LOW
divergence; the score is computed from the interpretations, not self-reported."

## Method
- 3 matched prompt pairs (same underlying task, one VAGUE / one SPECIFIED).
- n=4 INDEPENDENT BLIND interpreters per prompt (24 agents total). Each saw ONLY its prompt + a fixed
  structured schema (scope, in_scope, comparison_surfaces, key_behaviors, assumptions). NONE was told the
  hypothesis, told whether its prompt was "vague" or "specified", or told that divergence was being measured.
- Score = mean pairwise Jaccard token-set DISTANCE across interpretations on each axis (deterministic,
  computed). Fixtures committed in this directory; `lib/spec-divergence-poc.sh <set>.json`.

## Actual results (divergence 0..1; higher = more under-specified)
| pair | VAGUE | SPECIFIED | separation (vague − specified) |
|---|---|---|---|
| p1-migrate ("migrate the account service") | 0.6108 | 0.6379 | **−0.0271 (INVERTED)** |
| p2-scaffold ("build an orders API")        | 0.6565 | 0.5775 | +0.0790 (expected) |
| p3-cache ("add caching to the token service") | 0.7747 | 0.6446 | +0.1301 (expected) |

Vague range {0.61, 0.66, 0.77} and specified range {0.58, 0.64, 0.64} **OVERLAP** — no single threshold
separates them. 2 of 3 pairs lean the right way; 1 of 3 inverts.

## Why (diagnosed from the interpretations, not guessed)
- **p1 SPECIFIED interpreters semantically AGREED** (all 4: "port AccountLookup GET /account/{ani} +
  CustomerInfoRepository, proc cpsl_getAccount_v2") yet scored 0.64 — HIGHER than its vague twin. The
  richer prompt produced token-RICHER interpretations whose extra detail didn't overlap, so token-Jaccard
  registered "distance" on agreement. **The metric conflates lexical verbosity with semantic disagreement.**
- **p3 separated best** because the vague prompt caused a GENUINE semantic fork (one interpreter read
  "cache the fetched OAuth token", others read "cache validation results"). Where a real fork exists,
  divergence catches it.
- **Confound:** repo context let interpreters resolve "account service" → AccountLookup, collapsing some of
  the intended vagueness of p1. A cleaner test would use prompts with no in-repo disambiguator.

## Verdict
- **Does divergence separate vague from specified? MIXED — leaning FALSIFIED for the token-Jaccard scorer
  as built.** The signal is real where prompts genuinely fork semantically (p3), but the chosen metric is
  confounded by interpretation verbosity and does not reliably separate (p1 inverted; ranges overlap; n=3).
- **Is the score computed-from-interpretations, not self-assessed? VERIFIED.** Generation is by independent
  blind agents; scoring is deterministic Jaccard with no confidence field and no agent dispatch (test D4).
- **Failure modes observed:** false-positive on a well-specified-but-verbose prompt (p1 specified scored
  high despite agreement); no clean threshold at n=3.

## What would have to change for the mechanism to work (NOT built here)
1. Score SEMANTIC divergence, not token overlap — e.g. an embedding distance over interpretations, or a
   structured per-axis "do these readings AGREE?" judged by an independent agent (careful: that reintroduces
   an agent judgment — keep it independent + blind), or normalize for interpretation length.
2. Measure divergence on the LOAD-BEARING decision axes only (scope boundary, which surfaces) rather than
   all free-text, since verbosity noise lives in the prose.
3. Larger n and prompts without in-repo disambiguators before trusting any threshold.

**Bottom line for the full build:** do NOT build the Issues-1+2+3 subsystem on the token-Jaccard divergence
score as-is. The interpretation-divergence IDEA has a real kernel (genuine semantic forks are detectable),
but the measurement needs to be semantic, not lexical, and re-validated at larger n before it can anchor a
gate. This POC did its job: it falsified the cheap version before the expensive build.
