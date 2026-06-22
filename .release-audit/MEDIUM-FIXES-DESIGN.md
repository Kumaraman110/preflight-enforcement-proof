# MEDIUM Findings (M1–M15) — Fix Designs (READ-ONLY, no code written)

Completeness-argued fix designs for all 15 MEDIUM findings from FRAMEWORK-SCRUTINY-FINDINGS.md, clustered
by shared file, each with a no-false-positive / no-new-fail-open argument, RED→GREEN tests, residual, and
effort/risk. **Design only** — nothing was edited, nothing committed, nothing pushed. HEAD `43ea84d`,
v0.9.0 = `1651ecc` untouched. Every finding was re-confirmed reproducing read-only against /tmp copies or
crafted stdin before designing. The dominant discipline (the audit's lesson): **close the CLASS, not the
one spelling**; and where a fix tightens a matcher or adds a fail-closed path, **prove it doesn't
over-block or open a new hole.**

**Category split** (so the owner knows which are logic vs doc):
- **SAFETY-FALSE-GREEN (a gate gives a wrong verdict)** — M2, M3, M4, M5, M6, M8, M10, M12, M13, M15
- **HONESTY-LABEL (mechanism mislabeled but behaves correctly / fails safe — doc-only or near-doc)** — M1, M14 (and M13 has a doc component)
- **CORRECTNESS-QUALITY (latent / robustness)** — M7 (over-block direction), M9

**HIGH-interaction clusters** (must be implemented in concert): spec-integrity **H5 + M4 + M7**;
preflight-verify **H7 + M11**.

---

## CLUSTER A — `lib/spec-integrity-check.sh` (M4 + M7, interacts with HIGH H5)

### M4 · PASS when the source dir has zero `.cs` files — SAFETY-FALSE-GREEN
- **Confirmed:** a spec declaring `E1001`/a field/a proc/a route against a source dir that exists but holds
  only `readme.txt` (zero `.cs`) → "PASSED (all mechanical anchors consistent)" exit 0. All four `SOURCE_*`
  extractions are gated on `find … -name '*.cs' -print -quit | grep -q .` (lines 78/147/185/220); zero `.cs`
  → all `SOURCE_*` empty → both directions skipped → falls through to PASS.
- **Fix:** compute the `.cs`-presence fact ONCE near the top (`HAS_CS=false; find … -print -quit | grep -q
  . && HAS_CS=true`), replace the four inline guards with `[ "$HAS_CS" = true ]`, and add a **could-not-verify
  FAIL** per category fired on `[ "$HAS_CS" = false ] && [ -n "$SPEC_<TYPE>" ]` (after each of SPEC_CODES,
  SPEC_FIELDS, SPEC_PROCS, SPEC_ROUTES). Each `fail()` increments FAILURES → verdict FAILED exit 1.
- **Completeness:** fires for **every** anchor category (a spec declaring only a proc, or only a route, is
  still caught); covers both "source dir empty" and "source dir present-but-zero-`.cs`" (one `HAS_CS` flag
  is the single source of the fact).
- **No-false-positive / no-new-fail-open:** the new FAIL fires only when source has zero `.cs` **AND** the
  spec declares an anchor of that type — a real C# tree sets `HAS_CS=true` and never trips it; an empty spec
  (`SPEC_<TYPE>` empty) does not trip it (empty spec + empty source = legitimate PASS). Only adds `fail()`
  calls; removes no existing check. Correct fail-closed direction for an anti-forgery check ("I could not
  read any source to confirm your claims" must not read as verified).
- **RED→GREEN:** (1) spec `E1001` + readme-only dir → RED exit 0 PASS, GREEN exit 1 "result_code
  could-not-verify"; (2)/(3)/(4) same for a field/proc/route; (5) empty-source-dir variant = (1).
  **No-false-positive green (must stay exit 0):** (6) anchorless spec `{}` + zero-`.cs` → PASS; (7) real
  spec + matching real `.cs` source → PASS.
- **Residual:** does NOT close the sibling sub-gap where `.cs` files exist but none match
  `*Response*/*Request*/*Model*` (MODEL_FILES empty → a field still silently unverified) — a parallel
  could-not-verify gate keyed on (HAS_CS=true AND SPEC_FIELDS≠∅ AND MODEL_FILES=∅), flagged, out of M4's
  literal "zero `.cs`" scope.
- **Effort/risk:** LOW (logic).

### M7 · False-FAIL on a `public class Foo {` (K&R brace) line — CORRECTNESS-QUALITY (over-block)
- **Confirmed:** an HONEST spec declaring the real fields, with a source `public class TokenResponse { … }`
  (same-line brace), → "FAILED … property TokenResponse … MISSING from spec (possible forge)" exit 1. The
  MODEL_FIELDS regex (line 150) treats the keyword `class` as the type token and `TokenResponse` as the
  field name.
- **Fix:** insert a negative-match BEFORE the sed capture: pipe the `grep -hE 'public … {'` output through
  `grep -vE 'public[[:space:]]+(abstract |sealed |partial |static )*(class|interface|struct|enum|record)\b'`
  then into the existing sed. Drops type-declaration lines before a "field name" is harvested from them.
- **Completeness:** covers `class|interface|struct|enum|record` (not just `class`) + modifier-prefixed decls;
  Allman brace style was never captured by the line-anchored `{` regex so it produces no phantom.
- **No-false-positive (load-bearing, verified by me):** the `\b` word-boundary means a real field whose
  TYPE merely *starts* with a keyword survives — `public ClassRoom Building {`, `public Record Recorder {`,
  `public classy Thing {` all keep their field name. The filter only fires when the type-position token IS
  exactly the keyword. **I verified directly** that the negative-match drops `TokenResponse`/`FooDto` (class
  names) while keeping `Token`, `ExpiresIn`, `Scopes`, `IsActive` (real fields).
- **H5-interaction guard (the load-bearing cross-check, verified):** M7 narrows MODEL_FIELDS, and H5 makes
  the source→spec forge-catch fire on more inputs — the danger would be M7 dropping a REAL field that H5's
  now-aggressive catch then fails to flag. **This cannot happen:** a genuine property line's type-position
  token is the field's type (`string`/`int`/`Guid`/…), never the literal keyword, so the filter never
  removes a real property. After M7, MODEL_FIELDS = exactly the real-property set — which is precisely what
  H5's unguarded catch should police. **M7 makes H5 more accurate, not weaker.**
- **RED→GREEN:** (1) honest spec + `public class TokenResponse {…}` → RED exit 1, GREEN exit 0; (2) extraction
  unit: MODEL_FIELDS excludes the 5 decl-keyword names, keeps real fields; (3) no-false-positive: keyword-
  prefixed-type fields stay in MODEL_FIELDS; (4) **H5-slip guard:** a real source property OMITTED from the
  spec still FAILs source→spec (proves M7 didn't blunt the catch).
- **Residual:** only K&R single-line-brace properties are parsed at all (expression-bodied `=> …`, Allman,
  record positional params are pre-existing extraction limits, unchanged).
- **Effort/risk:** LOW (logic).

### Cluster-A interaction (H5 + M4 + M7) — three-way, mutually reinforcing, NO conflict
- **H5** (already designed): drop the inner `[ -n "$SPEC_*" ]` guards on the source→spec forge-catch →
  fail-closed when **source present, spec empty**.
- **M4**: fail-closed when **spec present, source absent** — the orthogonal complement of H5. Different seam
  (M4 adds new could-not-verify `fail()`s keyed on HAS_CS; H5 edits the inner guards of the source→spec
  blocks). No seam collision.
- **M7**: narrows the source-side set (MODEL_FIELDS) to real fields — makes H5's catch *more* accurate
  (verified the narrowing never drops a real field).
- **Implementation order (serial, atomic commits per CLAUDE.md rule 9):** M4's `HAS_CS` hoist first
  (structural) → H5's inner-guard drop → M7's negative-match filter. The shared regression guard is M7
  test #4 ("a real stripped field still FAILs after M7") — it proves M7 didn't open H5's fail-open.

---

## CLUSTER B — `tools/preflight-verify.sh` (M11, interacts with HIGH H7)

### M11 · PASS on an empty/null/missing-`artifacts` manifest — SAFETY-FALSE-GREEN
- **Confirmed:** crafted manifests with ZERO framework files on disk: (A) all `artifacts.*={}` → "Checked: 0
  artifacts (0 drifted) … Integrity: PASS" exit 0; (B) `artifacts.agents=null` → jq error swallowed inside
  the `< <(jq …)` process substitution (set -e can't abort a procsub) → iterate nothing → PASS; (E)
  `artifacts` key absent → PASS; (F) `artifacts:"oops"` → PASS. (Malformed JSON already FAILs at the
  standalone `PINNED_REF=$(jq …)` assignment — that's the only currently-safe shape.)
- **Fix (three seams):** (1) **artifacts-shape + mandatory-surface floor** after Step 1: assert
  `.artifacts | type == "object"`, and for each MANDATORY surface `{agents, skills}` assert it's a non-empty
  object (`length >= 1`) → else exit 1. (2) **CHECKED_COUNT backstop** before the final PASS: `[
  "$CHECKED_COUNT" -eq 0 ]` → exit 1. (3) **harden the per-surface jq feeders** so a null/non-object surface
  FAILs loudly: replace the optional-surface `// "absent"` with a type classifier (`absent`→skip,
  `object`→iterate, else→FAIL).
- **Why `{agents, skills}` are the mandatory anchors:** they're the only two surfaces with no sanctioned
  `// "absent"` legacy-absence path AND guaranteed ≥1 entry in every real install (5 agents, 11 skills) —
  anchoring the floor there closes A/B/C/E/F without misclassifying a legitimate pre-multi-surface manifest
  (which still has agents+skills populated) as corrupt.
- **Completeness:** enumerated — `{}`→floor; `agents=null`→floor type check; partial (only agents)→floor
  (skills missing); `artifacts` absent→type check; non-object→type check; optional-surface null→seam 3
  FAIL; optional-surface absent→seam 3 skip (preserved); CHECKED_COUNT==0→backstop.
- **No-false-positive:** old install (agents+skills populated, optional surfaces absent) passes the floor;
  the CHECKED_COUNT backstop can't fire on a conforming manifest (agents≥1 guarantees ≥1 checked); seam-3
  `absent`→skip reproduces existing sanctioned behavior, narrower than today (today null ALSO skips). The one
  documented coupling: if the framework ever legitimately ships zero agents/skills, the floor's mandatory set
  must update in lockstep (cross-reference `preflight-install.sh` manifest shape).
- **RED→GREEN:** all five degenerate manifests + a real-install null-optional-surface → exit 1 (each asserts
  NO "Integrity: PASS" line printed); GREEN: a real populated install → exit 0; a legacy manifest
  (agents+skills present, optional keys absent) → exit 0; malformed JSON → exit 1 (pin the already-safe path).
- **Residual:** the floor proves ≥1 agent and ≥1 skill ENTRY exist (and, with H7, that their content
  matches) — it does NOT assert the COMPLETE expected set (a manifest with 1 of 5 agents, all matching,
  still passes). Detecting an under-complete-but-consistent manifest needs an expected-cardinality check vs
  the pinned ref — out of M11's "truncated to nothing" scope.
- **Effort/risk:** MEDIUM (interacts with H7).

### Cluster-B interaction (H7 + M11) — compose as one fail-closed pass over verify Step 2
- **Order:** M11's floor runs FIRST (cheap "is the manifest shaped like a real install?"); if it FAILs, H7's
  per-skill subtree compare never runs (correct — a null/empty skills object can't be content-checked). M11
  guarantees H7's skills loop is fed a non-empty object, so H7 needn't defend against a null feeder — M11
  owns that.
- **Shared invariant:** "empty/missing skill == DRIFT/FAIL." M11 catches "manifest lost ALL skills"
  (truncation); H7 catches "a listed skill drifted/vanished on disk" (per-skill). Both exit-1 on the unsafe
  direction; neither weakens the other. M11's "per-known-surface non-empty" floor is the manifest-side mirror
  of H7's disk-side per-skill compare.
- **CHECKED_COUNT coupling:** H7's per-skill compare must keep incrementing CHECKED_COUNT so M11's backstop
  reflects real work.
- **Shared seam:** both edit the skills-loop region and the area around the final PASS — implement serially,
  commit M11 floor and H7 content-check separately (each with its own behavioral test). The joint regression
  guard is the GREEN "fully-populated real install → exit 0" test.

---

## CLUSTER C — `lib/parity-check.sh` (M6)

### M6 · CLEAN on a wrong-keyed or zero-behavior baseline — SAFETY-FALSE-GREEN
- **Confirmed:** baseline `{"behaviour":[2 high-confidence behaviors]}` (typo'd key) vs a current that
  DROPPED+CHANGED a behavior → verdict CLEAN, `baseline_behaviors:0`, exit 0. Also `{}` and
  `{"behaviors":[]}` → CLEAN exit 0. (A *type* error like `behaviors:null` already fails closed exit 3 via
  the BaseException guard; a missing/renamed KEY fails OPEN.)
- **Fix:** in Python `main()`, after each `json.load`, add `require_behaviors(doc, which)` that raises a
  dedicated `ParityCheckError` when `"behaviors" not in doc OR not isinstance(doc["behaviors"], list)`; then
  use `doc["behaviors"]` directly (no `.get(..., [])`). Route the error to the existing **exit 3**
  (could-not-run) via the BaseException arm — **reuses the 0/1/2/3 contract, no new code**. Run the guard
  on BOTH baseline and current (symmetry).
- **Completeness:** `not in doc` catches **any** rename/typo of **any** spelling (it requires the one correct
  key, not a misspelling enumeration); `not isinstance(…, list)` makes the wrong-type case a deterministic
  message-bearing exit 3 instead of relying on an incidental downstream crash. Symmetric → covers the
  current-side variant too (which today produces a *phantom* exit-2 drift verdict).
- **No-false-positive (load-bearing):** the "non-trivial" definition is the MINIMAL one — **"key present AND
  is a list."** A genuine zero-behavior service is `{"behaviors":[]}` (present, list, len 0) → PASSES the
  guard → normal empty diff. Deliberately REJECTED the stronger definitions: requiring the
  `completeness_check`/`service` envelope would over-block (the engine is stack-neutral; existing fixtures
  P0/P1/P2 + wire-format tests feed bare `{"behaviors":[…]}` with no envelope, and P2 feeds `{"behaviors":[]}`
  expecting exit 2); requiring `len>0` would false-fail the genuine zero-behavior service. Adds only exit-3
  paths; never converts an existing 0/1/2.
- **RED→GREEN:** baseline `{}` → exit 3 (was 0); typo-key baseline that masks a drop+change → exit 3 (was 0,
  the headline); current-side typo → exit 3 (was a phantom 2); **no-false-positive guard:** `{"behaviors":[]}`
  vs `{"behaviors":[]}` → exit 0 CLEAN (must stay green both before and after); `behaviors:null` → exit 3
  (preserved). Re-run P0/P1/P2/P3 unchanged.
- **Residual:** per-behavior key typos (`observable`/`confidence`/`id`) still degrade silently inside the loop
  (spec-analyst's Self-Check's job, out of scope); the guard doesn't verify the spec is a REAL extraction
  (spec-integrity's job).
- **Effort/risk:** LOW (logic). **Interaction:** reuses the session's parity 0/1/2/3 fix — exit 3 already
  means could-not-run and callers (migrate Check 6, CI status map) already treat it as FAIL.

---

## CLUSTER D — Standalone SAFETY-false-green mediums (M2, M3, M5, M8, M10)

*(Designed directly here — the workflow's standalone-safety agent stalled under spawn-tax load; each finding
re-confirmed read-only by me.)*

### M2 · Adjudication citation check passes on incidental `word:digit` prose — SAFETY-FALSE-GREEN
- **Confirmed (re-run by me):** the `CITES` regex (`adjudication-output-gate:135`) ACCEPTs prose
  `"…2.5:1 retry ratio"`, `"…at v1.2:3 behaves…"`, `"…since 2024.10:00 deploy"` — a DEFENDED verdict with no
  real file:line passes. **Also found:** the regex's `§[0-9]+` branch **rejects a genuine `§G2.1`** rule id
  (letter prefix) — so the current regex is simultaneously too loose (prose) and too tight (real `§<letter>`
  ids).
- **Fix:** replace the loose `\.[A-Za-z0-9]+:[0-9]+` file:line branch with one anchored to a **real source
  extension allow-list** and a `/`-or-start boundary, e.g.
  `(^|[\s/(])[\w./-]+\.(cs|csproj|sln|cshtml|razor|json|xml|ya?ml|sql|java|ts|js|py|md|sh):[0-9]+\b` ; and
  widen the rule branch from `§[0-9]+` to `§[A-Za-z]*[0-9][A-Za-z0-9.]*` so genuine `§G2.1`/`§M4.3` ids match.
  Keep the named-artifact branches. (Optionally require the citation to be a token, not an arbitrary
  substring, but the extension allow-list is the load-bearing change.)
- **Completeness:** covers the prose-collision CLASS — a version (`v1.2:3`), ratio (`2.5:1`), timestamp
  (`2024.10:00`), or any `word:digit` whose left side is not a real-source-extension filename no longer
  matches; covers the under-tight `§` class by accepting real alphanumeric rule ids.
- **No-false-positive (load-bearing both directions):** the stricter file:line branch must STILL accept
  `TokenProvider.cs:142`, `path/Bar.java:88` — the extension allow-list includes the real source/spec
  extensions, so genuine citations pass; and the widened `§` branch newly accepts genuine `§G2.1` (a
  *fix* to a pre-existing over-tightness, not a regression). Risk: a prose sentence that happens to contain
  `foo.cs:12` is still accepted — acceptable, because that *is* a file:line shaped token (the gate is
  deliberately lexical, deferring substantive validity to human audit per `lib/adjudication-record.md`); the
  fix closes the "no citation token at all" hole, not the "token present but doesn't support the claim" layer.
- **RED→GREEN:** ratio/version/timestamp prose DEFENDED → RED exit 0 (allow), GREEN exit 2 (block);
  **no-false-positive:** `Foo.cs:142` / `path/Bar.java:88` DEFENDED → exit 0 (allow, must stay); `§G2.1`
  DEFENDED → exit 0 (allow — newly correct); bare "verified manually" → exit 2 (block, unchanged).
- **Residual:** a prose excuse that embeds a real-source-extension `file:line`-shaped token still passes
  (lexical gate; substantive support is the human-audit layer downstream of the SHA-keyed record).
- **Effort/risk:** LOW (logic — a regex change; the no-false-positive surface is real, so test the genuine
  citations carefully).

### M3 · dependency-map-validator FRESH + re-stamp on empty/incomplete `mapFiles` — SAFETY-FALSE-GREEN
- **Confirmed (code-read + audit repro):** empty/`[]`/incomplete `mapFiles` → `comm -12` overlap empty →
  falls through to Step 3 which **re-stamps `validAtHEAD` to current HEAD** and exits 0 FRESH; the re-stamp
  makes the staleness permanent. Correct single-entry list → STALE exit 1; bad JSON → STALE exit 1 (so the
  hole is specific to empty/incomplete).
- **Fix:** after `MAP_FILES=$(node … d.mapFiles …)` (line 53), add a non-validatable guard: if `MAP_FILES`
  is empty (no entries) → `echo "STALE: sidecar declares no mapFiles — cannot validate freshness, refresh
  needed."; exit 1` **and do NOT re-stamp**. Optionally promote the existing count-mismatch WARNING
  (lines 63-65) to a STALE exit-1 when `MAP_FILE_COUNT != SIDECAR_FILE_COUNT` (an incomplete list).
- **Completeness:** covers empty, missing (`d.mapFiles||[]` → empty), and — via the count-mismatch promotion
  — the incomplete-list shape (the most dangerous: a list omitting the file that actually changed). The
  "empty → STALE, don't re-stamp" change alone fixes the permanence; the count promotion closes the
  incomplete shape.
- **No-false-positive:** a legitimately-empty `mapFiles` is itself meaningless for a freshness gate (nothing
  to validate against), so STALE (forcing a refresh) is the correct conservative direction — it does not
  block any real operation, it triggers a map regeneration. The count-mismatch promotion fires only when the
  sidecar and the actual map disagree on file count (genuinely inconsistent state).
- **RED→GREEN:** empty `mapFiles` → RED FRESH exit 0 + re-stamp, GREEN STALE exit 1 + NO re-stamp; `[]` same;
  incomplete (count mismatch) → STALE exit 1; **no-regression:** correct single-entry list with a touched map
  file → STALE exit 1 (unchanged); correct list, untouched → FRESH exit 0 + re-stamp (the legitimate path,
  unchanged).
- **Residual:** freshness still rests on `git diff --name-only` + the sidecar's self-declared `mapFiles`; a
  sidecar that lies about which files it covers (names files it doesn't actually map) is out of scope — the
  count cross-check catches a cardinality lie, not a content lie.
- **Effort/risk:** LOW (logic, isolated).

### M5 · rubric-source-check `--added` swallows git failure → CLEAN — SAFETY-FALSE-GREEN (fail-open)
- **Confirmed (code-read + audit repro):** `--added` builds the file list via
  `git diff --name-only "$BASE_REF"...HEAD 2>/dev/null | grep … || true` (line 72); a git failure (bad
  base-ref, non-repo, shallow clone) is swallowed → empty FILES → "nothing to check (CLEAN)" exit 0. Raw git
  exits 128/129 but the pipe + `|| true` yields 0.
- **Fix:** run git SEPARATELY and check `$?` before the grep: `RAW=$(git diff --name-only "$BASE_REF"...HEAD
  2>/dev/null); GIT_RC=$?; if [ "$GIT_RC" -ne 0 ]; then echo "rubric-source-check (--added): git diff vs
  '$BASE_REF' FAILED (rc=$GIT_RC) — could not compute changed rubric files; failing closed (could-not-run)."
  >&2; exit 2; fi` — then grep `$RAW`. Distinguishes "git failed" (exit 2, could-not-run) from "diff is empty"
  (exit 0, CLEAN — nothing changed).
- **Completeness:** covers every git-failure shape (bad/unknown base-ref → 128; not-a-repo → 129; shallow
  clone where `...` merge-base can't be computed; detached) because it checks git's real exit status, not the
  pipe's. The "diff legitimately empty" case (no rubric files changed) still correctly returns CLEAN exit 0.
- **No-false-positive:** an empty diff (genuinely no rubric changes) is NOT a git failure (`$?`=0), so it
  still returns CLEAN — the fix only newly fails on a non-zero git exit, which is genuinely could-not-run.
- **RED→GREEN:** `--added` in a non-git dir → RED CLEAN exit 0, GREEN exit 2; `--added bad-ref-xyz` in a real
  repo → RED CLEAN exit 0, GREEN exit 2; **no-false-positive:** `--added <valid-ref>` with no rubric changes
  → CLEAN exit 0 (unchanged); `--added <valid-ref>` with a rubric change missing a Source line → exit 1
  (unchanged, the real check still runs).
- **Residual:** `--added` has no live caller today (CI uses `files` mode); this hardens the documented
  future-promotion-to-blocking path so promoting it later doesn't arm a broken green gate on a
  shallow/detached CI runner.
- **Effort/risk:** LOW (logic, isolated; latent until `--added` is wired).

### M8 · detector.sh exits 0 on a failed state-file write — SAFETY-FALSE-GREEN
- **Confirmed (re-run by me):** making `state.json.tmp` a directory so the redirect fails → detector exits
  **0** with NO `state.json` written (a stale prior file would be retained). Violates the docstring's "exit 0
  on success, exit 1 on critical failure."
- **Fix:** capture the `&&` chain status and fail on it: replace
  `generate_json > "$OUTPUT_PATH.tmp" && mv "$OUTPUT_PATH.tmp" "$OUTPUT_PATH"` + unconditional `exit 0` with
  `if generate_json > "$OUTPUT_PATH.tmp" && mv "$OUTPUT_PATH.tmp" "$OUTPUT_PATH"; then exit 0; else echo
  "detector: FAILED to write state to $OUTPUT_PATH (disk/permission/path error) — state NOT updated." >&2;
  rm -f "$OUTPUT_PATH.tmp" 2>/dev/null; exit 1; fi`. Also guard the `mkdir -p` (line 199) with `|| { echo
  "detector: cannot create $(dirname "$OUTPUT_PATH")" >&2; exit 1; }`.
- **Completeness:** covers both failure points — `mkdir` failure and the generate/mv chain failure (ENOSPC,
  unwritable path, occupied `.tmp` from a crashed run, RO FS). The `if … then exit 0 else exit 1` makes the
  exit code honestly track whether `state.json` was actually written.
- **No-false-positive:** the normal path (write succeeds) still exits 0 with the state written — unchanged;
  the new exit-1 fires only on a genuine write failure.
- **RED→GREEN:** `.tmp` target made a directory → RED exit 0 + no file, GREEN exit 1 + diagnostic + no stale
  file left as "current"; un-creatable parent dir → exit 1; **no-regression:** a normal run → exit 0 with
  `state.json` written.
- **Residual:** consumer is the prompt-level bootstrap skill whose fallback is also prompt-level, so even a
  correct exit 1 doesn't mechanically halt — it makes the failure honest/visible, which is the fix's scope.
- **Effort/risk:** LOW (logic, isolated, near-trivial).

### M10 · generate-wire-golden-test.sh emits an assertion-less test on `|` in sample/golden — SAFETY-FALSE-GREEN
- **Confirmed (code-read + audit repro):** per-case `… | sed -e "s|{{SAMPLE}}|$SAMPLE|g" …` (lines 157/186);
  a `|` in a sample/golden value (enum flags `"Read|Write"`, delimited IDs) breaks the `s|…|` expression →
  sed emits nothing → the case scaffold lands WITHOUT the serialize/compare body → yet "Generated … N
  case(s)." exit 0.
- **Fix:** two parts — (1) **detect the swallow:** capture `${PIPESTATUS[*]}` after the `emit_case_body | sed`
  pipeline and `exit 2` with a diagnostic if any element is non-zero; AND/OR (2) **substitute
  delimiter-safely:** stop using `sed` with data-controlled `s|…|` delimiters — fill the placeholders via a
  mechanism that doesn't treat data as a delimiter (e.g. `awk` with literal-string replacement, or build the
  body in a here-doc with shell `${var}` expansion of pre-escaped values). The robust fix is (2) (closes the
  class); (1) is the fail-closed backstop that turns any residual substitution failure into exit 2 instead of
  a silent assertion-less artifact.
- **Completeness:** (2) closes the whole delimiter-collision CLASS — not just `|` in SAMPLE/GOLDEN but any
  character that collides with a chosen sed delimiter (the current code already varies `/` vs `|` per
  placeholder, which is itself the smell); a delimiter-free substitution can't collide. (1) backstops every
  residual case (an unforeseen metachar) by failing loudly. A `/` in NAME/TYPE (the `s/…/` branches) is the
  same class and is covered by the same delimiter-free rewrite.
- **No-false-positive:** a clean contract (no metachars) produces the identical output under the
  delimiter-safe substitution — verified shape-equivalence is the test; the PIPESTATUS backstop only fires on
  a genuine substitution failure.
- **RED→GREEN:** contract with `"sample":{"f":"Read|Write"}` → RED "Generated … 1 case(s)." exit 0 with
  `grep -c string.Equals` = 0, GREEN exit 2 (PIPESTATUS) OR a complete body with the literal `Read|Write`
  preserved (delimiter-safe) and `string.Equals` present; multi-case (one clean + one pipe) → RED claims 2
  wired with 1 assertion-less, GREEN either exit 2 or both bodies complete; **no-regression:** a clean
  contract → unchanged valid `.cs`, exit 0 "Generated … N case(s)."
- **Residual:** if only the PIPESTATUS backstop (1) is taken, the generator fails loudly on a `|`-bearing
  contract rather than generating it — correct fail-closed, but the contract still can't be generated until
  the delimiter-safe rewrite (2) lands. Recommend (2) as the real fix, (1) as the guard.
- **Effort/risk:** LOW (logic; (1) alone is near-trivial, (2) is a contained rewrite of the substitution).

---

## CLUSTER E — Honesty-label + correctness-quality (M1, M9, M12, M14) + the matcher fix (M13) + migrate (M15)

### M1 · behavioral-contract-gate header says "NOT registered / does not fire" but it IS live — HONESTY-LABEL (DOC-ONLY)
- **Confirmed:** header box (lines 4-10) claims "AWAITING OWNER DECISION — NOT registered … does NOT fire …
  prompt-level," but `hooks.json:75-89` registers it under the `Agent|Task` matcher and it ships live; a
  spec-analyst spawn with no `## Behavioral Contract` → exit 2 BLOCKED. `docs/parity-gate-limitations.md` is
  already reconciled — the stale claim is confined to this file's header (two spots: the line-1/2 summary and
  the box).
- **Fix (DOC-ONLY, zero logic):** replace the line-1/2 "STAGED, NOT-YET-WIRED" summary AND the lines-4-10 box
  with "LIVE — registered in hooks/hooks.json under the Agent|Task PreToolUse matcher (commit 611a6e0), merged
  into consumer settings.json by preflight-install.sh; fires on every spec-analyst spawn, fails closed (exit
  2) on a missing/DRAFT ## Behavioral Contract. Honest ceiling: agent-tool-only; platform→hook delivery
  inferred from the shared Agent|Task seam — see docs/parity-gate-limitations.md." Keep the accurate
  WHAT-IT-CLOSES / INPUT-CONTRACT / FAIL-DIRECTION bodies.
- **Completeness:** both stale spots in the file changed; no other file repeats the claim (doc reconciled;
  README/FRAMEWORK don't enumerate it). **No-false-positive:** N/A (comment); the replacement carries the
  inferred-delivery ceiling forward so it doesn't swing from understated to overstated.
- **RED→GREEN:** consistency lint — RED: `grep -E 'NOT.{0,3}registered|NOT-YET-WIRED|AWAITING OWNER|does NOT
  fire'` matches the file WHILE hooks.json registers it; GREEN: that grep returns zero matches AND
  registration intact AND the existing behavioral test still blocks. Optional CI lint: "a hook named in
  hooks.json must not say NOT-registered."
- **Residual:** the inferred platform→hook delivery ceiling persists by design (labeled, not closed).
- **Effort/risk:** TRIVIAL (doc-only).

### M14 · fix-and-close "Artifact rejection gate (pre-commit)" is prose, not a hook — HONESTY-LABEL (DOC)
- **Confirmed:** `fix-and-close/SKILL.md:176-182` uses hook-grade language ("the commit is BLOCKED", "the
  gate fires BEFORE the commit") but it's a shell snippet the agent runs in its own session — `exit 1` only
  exits that subshell; no PreToolUse hook matches `git commit` (the only Bash-matcher hook is
  pre-push-gate-check, which guards push). Confirmed by the audit: the snippet printed BLOCKED, exited the
  subshell 1, and the next `git commit` succeeded.
- **Fix (cheaper-correct = DOC honesty label):** demote to prompt-level, mirroring migrate's "A note on
  enforcement." Rename heading to "Artifact rejection check (pre-commit, agent-run)"; "the commit is BLOCKED"
  → "you MUST NOT proceed to commit"; "the gate fires BEFORE the commit" → "run this in your session BEFORE
  git commit — a prompt-level discipline you execute, NOT a PreToolUse hook; `exit 1` ends only this snippet,
  nothing mechanically intercepts git commit." (The real-hook option — a `git commit` PreToolUse Bash hook
  parsing `git diff --cached` — is feasible but a LOGIC change with its own false-positive surface;
  disproportionate to relabeling. Note as future defense-in-depth.)
- **Completeness:** the three+one hook-grade phrases in :176-182 all relabeled; must NOT touch the
  legitimately-mechanical hook invocations elsewhere in the file (pre-push-gate, coupled-edit-gate,
  write-gate-evidence stay mechanical). **No-false-positive:** N/A (doc); risk is under-stating a real guard —
  avoided because this snippet genuinely is not a hook.
- **RED→GREEN:** consistency lint — RED: hook-grade language in :176-182 with NO `git commit` matcher in
  hooks.json; GREEN: region no longer claims mechanical interception + carries a "prompt-level / not a hook"
  note + `grep git.commit hooks/hooks.json` still empty.
- **Residual:** remains prompt-level (a non-compliant agent can skip it); the honest label states this.
- **Effort/risk:** TRIVIAL (doc-only).

### M9 · `--check-blob-syntax` blind to `N|` corruption for minimal scripts — CORRECTNESS-QUALITY (latent)
- **Confirmed:** `1|#!/usr/bin/env bash\n2|echo hi\n3|exit 0` → `bash -n` rc=0 (N| parses as command N piped
  into a comment); the multi-line control-flow shape → rc=2. So `pre-branch-cut-check.sh:80-84` is blind to a
  single-statement-per-line `N|` corruption (today's shipped files all have control flow, so blast radius is
  empty — but the gate rests on an unenforced invariant).
- **Fix (LOGIC, additive):** capture `BLOB=$(git show "HEAD:$f")` once; add two structural assertions
  alongside the existing `bash -n`: (1) **line-prefix scan** — flag if the blob matches the `^[0-9]+\|`
  signature on multiple lines (the `c0e01a4` corruption prefixes EVERY line); (2) **shebang sanity** — head-1
  must match `^#!`. Any of the three failing → exit 1.
- **Completeness:** the CLASS is "corruption that is valid bash grammar yet not the intended script"; the
  `N|`-prefix family is fully covered by the anchored multi-line `^[0-9]+\|` scan independent of statement
  structure (single- or multi-line); a mangled shebang `1|#!/…` is caught by both the scan and the head-1
  check.
- **No-false-positive (load-bearing):** a legitimate shebang starts with `#`, not a digit, so it can't trip
  `^[0-9]+\|`; an incidental `5|x` inside a heredoc won't reach the **multi-line threshold** (require ≥2
  consecutive `^[0-9]+\|` lines, or head-1 itself prefixed) so a single legit table-row line doesn't fire;
  scope is the location-scoped executable set (lib/*.sh, tools/*.sh, extensionless hooks/*) so config/data
  files with legit `N|` rows are never scanned.
- **RED→GREEN:** N|-prefixed single-statement blob → RED exit 0, GREEN exit 1; mangled shebang `1|#!/…` →
  exit 1; **no-false-positive:** clean hook → exit 0; a hook containing a legit heredoc line with one
  incidental `3|two` → exit 0 (below threshold); **regression:** the existing multi-line `c0e01a4`-shape →
  exit 1 (stays green).
- **Residual:** still blind to corruption that is BOTH valid bash AND structurally indistinguishable from
  intended code (a logic typo, a syntactically-clean injected line that isn't `N|`-prefixed) — a structural
  check, not a semantic-equivalence oracle.
- **Effort/risk:** LOW (logic; latent — empty blast radius today).

### M12 · preflight-selftest.sh reports SKIP+green on a deleted/renamed gate — SAFETY-FALSE-GREEN
- **Confirmed:** `test_gate`'s missing-file branch (lines 33-36) calls `skp` (SKIP++), FAIL stays 0 → a
  deleted/renamed gate → exit 0 green. The sibling `preflight-selfcheck.sh:110-112` correctly reports a
  missing hook as DEAD exit 1. Also: selftest never tests behavioral-contract-gate at all (registered live
  but absent from the selftest body — ties to M1).
- **Fix (LOGIC):** change the missing-file branch from `skp` to `dead` for MANDATORY gates; add an explicit
  `optional` flag to `test_gate` and use it ONLY for the genuinely-optional helper (dependency-map-validator).
  To define "mandatory": add an assertion that **every PreToolUse-registered gate in hooks.json is in the
  selftest's tested set** (option a — minimal; also retroactively catches the behavioral-contract-gate
  omission); option b (fuller) enumerates gates by parsing hooks.json. Recommend (a). SessionStart hooks
  (session-start, drift-detector) stay excluded (non-blocking).
- **Completeness:** the CLASS is "a registered blocking gate silently absent reads as green" — three shapes:
  (1) a tested gate's file deleted → fixed by dead-on-missing; (2) a NEW gate added to hooks.json but never to
  selftest → fixed by the coverage assertion (also catches the existing behavioral-contract-gate omission);
  (3) a genuinely-optional helper absent → STAYS a legitimate SKIP via the explicit flag.
- **No-false-positive:** DEAD is the default, SKIP is opt-in per-hook with a stated reason (so the optional
  helper isn't over-flagged); the coverage assertion scopes to the PreToolUse block only (SessionStart hooks
  not counted). The change makes the tool STRICTER (fails visibly, never silently passes).
- **RED→GREEN:** point test_gate at a non-existent mandatory hook → RED exit 0 "skipped", GREEN exit 1 "DEAD …
  MISSING"; coverage assertion with behavioral-contract-gate registered-but-untested → RED exit 0, GREEN
  exit 1 until added; **no-false-positive:** dependency-map-validator absent + flagged optional → SKIP exit 0;
  all gates present+alive → exit 0.
- **Residual:** selftest still proves only hook-SCRIPT behavior on crafted stdin (the issue-#10 runtime-
  invocation slice is unproven — same ceiling selfcheck states).
- **Effort/risk:** LOW (logic).

### M13 · Coupling enforcement is Edit-only — Write/Bash mutations bypass — SAFETY-FALSE-GREEN (logic) + honesty note
- **Confirmed:** `coupled-edit-gate` extracts `.tool_input.file_path` (separator-agnostic) and is registered
  **only under the `Edit` matcher** (hooks.json:52-59). A Write-shape tool_input → `jq -r
  '.tool_input.file_path'` yields the path fine (the gate handles the Write shape), but a Write is never
  routed to the gate. SKILL.md:135 calls it "the mechanical enforcement of read-ALL-before-fixing-ANY."
- **Fix (RECOMMEND option a, LOGIC):** register coupled-edit-gate under a `Write|Edit` matcher (mirror
  bootstrap-write-gate / adjudication-output-gate, already registered under both). The gate body needs NO
  change (it only reads `file_path`, which Write carries; it never touches old_string/new_string). Add a Write
  entry to the existing `Write` matcher block; keep the Edit registration. Plus a SKILL.md residual note about
  the Bash seam.
- **Completeness:** Edit (already) + Write (matcher add) closes the in-tool write seams; if a MultiEdit tool
  exists in this CC version, add it to the alternation (verify the name). The Bash seam (`sed -i`, `tee`, `>`,
  `perl -pi`) is NOT closed — detecting a coupled-file mutation inside arbitrary Bash is brittle and out of
  scope; belongs in residual + a SKILL.md honesty note.
- **No-false-positive:** adding Write can't over-block — the gate exits 0 immediately when file_path is empty,
  no active-groups.json exists, or the basename isn't grouped; a Write only blocks if it targets a file in an
  UNACKNOWLEDGED group (the intended block, identical to Edit). No new fail-open (the fail-closed-on-unreadable
  logic runs regardless of trigger tool).
- **RED→GREEN:** registration assertion — RED: `grep` under the `Write` matcher does NOT list
  coupled-edit-gate, GREEN: it does (and a registration-check test asserts it appears under both Write and
  Edit); behavioral: a Write to a coupled file in an unacknowledged group → exit 2; **no-false-positive:**
  Write to an unrelated file → exit 0; Write to a coupled file in an ACKNOWLEDGED group → exit 0.
- **Residual:** the Bash mutation seam remains ungated (labeled in SKILL.md).
- **Effort/risk:** MEDIUM — **coordinate with the H3/H4 fix** (same gate body). Do the matcher edit and any
  H3/H4 body edit in one coherent sequence; verify the H3/H4 design assumes only `file_path` (it must, since
  Write omits old_string/new_string — already confirmed the gate only reads file_path).

### M15 · migrate Check-3 silently passes a missing short-named REACHABLE proc — SAFETY-FALSE-GREEN
- **Confirmed (audit repro):** `[ ${#PROC} -lt 5 ] && continue` (line 845) drops any contracted identifier
  <5 chars from the existence check → a genuinely-absent REACHABLE `usp` (3 chars) → "CHECK 3 PASS". The `<5`
  guard is in the proc loop only, not the param loop (asymmetric).
- **Fix (LOGIC):** (1) DELETE the `[ ${#PROC} -lt 5 ] && continue`; (2) replace the regex-scrape of `$PROCS`
  (line 830) with a **structured single-column extraction** (parse the proc identifier from a known column —
  e.g. the first `|`-delimited cell of each data row, or rows under a `### \`<proc>\`` heading) so header words
  (Name/Type/Reachable) never enter the loop. The explicit chain-word denylist (line 846) then becomes a
  belt-and-suspenders backstop. Minimal alternative: delete the `<5` skip and rely on the denylist (which must
  then be verified complete for the template's column headers).
- **Completeness:** the CLASS is "a genuinely-absent REACHABLE identifier escapes the existence check" —
  shapes: short proc (<5) dropped → fixed by deleting the guard; header/chain-word noise → excluded by
  structured extraction (so deleting the guard doesn't spike false MISSING); the param loop already has no <5
  guard so the proc/param asymmetry is eliminated; NOT-REACHABLE short procs still correctly skipped via the
  membership test (length-independent).
- **No-false-positive:** deleting `<5` risks re-admitting header words (false MISSING) — mitigated by
  structured extraction so they never enter `$PROCS`; the failure direction if any noise slips is over-flag
  (a recorded decision, the SAFE direction), never under-flag.
- **RED→GREEN:** REACHABLE 3-char `usp` absent → RED "CHECK 3 PASS", GREEN "CHECK 3 FAIL" naming `usp`;
  **no-false-positive:** header cells Name/Type/Reachable → NOT reported MISSING; **regression:** present long
  proc → not MISSING; NOT-REACHABLE short proc → correctly skipped; short absent REACHABLE param → MISSING
  (already true, confirm unchanged).
- **Residual:** the existence test is a `grep -r --include=*.cs` substring match — can false-PASS if the
  identifier appears in a comment/unrelated string (pre-existing, orthogonal to the `<5` fix).
- **Effort/risk:** LOW (logic; structured extraction is the larger half).

### Cluster-E interactions
- **M13 ↔ H3/H4:** same gate (`coupled-edit-gate`). M13 is a hooks.json **matcher** change (Edit → Write|Edit)
  + a residual note; it touches the hook body zero. The H3/H4 design hardens the body — verify it assumes only
  `file_path` (Write omits old_string/new_string; the gate already only reads file_path, so safe). Land the
  matcher edit and any H3/H4 body edit in one coherent sequence.
- **M12 ↔ M1:** M12 surfaced that selftest OMITS behavioral-contract-gate entirely — which is live (M1). The
  M12 coverage assertion (every registered gate is tested) closes that omission; M1 relabels the gate as live.
  Do M1 (trivial doc) first so the gate's status is unambiguous when M12's assertion starts requiring it.
- **M1 ↔ M14:** both HONESTY-LABEL doc relabels, same root pattern (self-description ahead of mechanism), same
  corrective template (migrate's "A note on enforcement" / parity-gate-limitations.md) — but OPPOSITE
  directions: M1 is under-stated (live gate labeled not-wired), M14 is over-stated (prompt snippet labeled a
  hook).

---

## RECOMMENDED IMPLEMENTATION ORDER (sequence by value/risk; serial atomic commits per CLAUDE.md rule 9)

**Wave 1 — TRIVIAL doc-only honesty fixes (ship first, zero logic risk):**
- **M1** (behavioral-contract-gate header relabel) — DOC-ONLY.
- **M14** (artifact-rejection "gate" → prompt-level relabel) — DOC-ONLY.

**Wave 2 — LOW isolated logic fixes (one file each, clear, no HIGH interaction):**
- **M8** (detector failed-write → exit 1) — near-trivial.
- **M3** (dependency-map empty mapFiles → STALE, no re-stamp).
- **M5** (rubric-source-check `--added` git-failure → exit 2; latent).
- **M2** (adjudication citation regex — tighten file:line to source extensions, widen `§` to real ids; test
  genuine citations).
- **M10** (wire-golden delimiter-safe substitution + PIPESTATUS backstop).
- **M9** (blob-syntax structural `^[0-9]+\|` + shebang check; latent).
- **M12** (selftest missing-hook → DEAD + hooks.json coverage assertion).
- **M15** (migrate Check-3 drop `<5` skip + structured extraction).
- **M6** (parity require `behaviors` present+list → exit 3; reuses 0/1/2/3).

**Wave 3 — interacting clusters (implement the HIGH + MEDIUMs in concert, one coherent pass per file):**
- **spec-integrity-check.sh:** M4 (`HAS_CS` hoist) → **H5** (inner-guard drop) → M7 (decl-keyword filter),
  serial; the shared regression guard is "a real stripped field still FAILs after M7."
- **preflight-verify.sh:** M11 (manifest floor + CHECKED_COUNT backstop) and **H7** (skill content-check) as
  one fail-closed Step-2 pass, committed separately, joint guard = "fully-populated real install → exit 0."
- **M13** (coupled-edit-gate `Write|Edit` matcher) coordinated with the **H3/H4** body hardening (same gate).

**Rationale:** Wave 1 clears the two load-bearing honesty mislabels at zero risk (an overstated/understated
guard is itself a defect class here). Wave 2 closes eight independent fail-opens/false-greens that don't
touch a HIGH finding — each a contained, separately-testable commit. Wave 3 is the careful work: three files
where a MEDIUM shares the seam with an already-designed HIGH; these must be implemented together so the
fail-closed paths compose rather than collide, each with the joint regression guard named above.

**Read-only design. No code written, nothing changed, nothing committed. v0.9.0 = `1651ecc` untouched.**
