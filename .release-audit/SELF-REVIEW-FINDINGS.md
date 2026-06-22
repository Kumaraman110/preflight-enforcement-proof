# Self-Review Findings — Autonomous GPS-Gated Pass

**Scope:** the 6 lib/hook files **built or touched this session** (post-v0.9.0). Stable pre-session
code was NOT reviewed (out of scope by instruction).
**Mode:** autonomous-on-the-determinable, human-gated-on-the-consequential. Every consequential change
is GPS-gated and recorded here, **not auto-applied**. Only pure-form (comment-only) cleanups were applied.
**Constraints honored:** no push, no tag, no cut. v0.9.0 untouched (`1651ecc`). origin untouched.

- **HEAD after this pass:** `89d42c9` (the one safe-cleanup commit) on `feature/preflight-framework`.
- **Review HEAD (what was reviewed):** `fec5aa9`.
- **Files reviewed:** `lib/spec-divergence.sh` (prefilter region only), `lib/coverage-gap-detect.sh`,
  `lib/capture-finding.sh`, `lib/source-of-truth-check.sh`, `hooks/pre-push-gate-check`,
  `lib/parity-check.sh` (0/1/2/3 region only).

## Method (the spine)

A workflow ran **one independent reviewer per file**, then **adversarially verified each finding** with a
verifier *biased to catch a "safe cleanup" that actually changes behavior* — the load-bearing rule here.
The verifier answered two questions independently per finding: **is_real?** (try to refute) and
**changes_behavior?** (does the proposed edit alter ANY observable output/exit/side-effect/control-flow on
ANY input — default TRUE if uncertain). Disposition: `SAFE-APPLY` only if real AND not behavior-changing;
`GPS-GATE` if real AND behavior-changing; `REJECT` if not real.

**Verifier yield: 23 findings, 0 rejected, 4 SAFE-APPLY, 19 GPS-GATE.** I then applied a STRICTER gate than
the verifier: the user's contract gates **structural moves regardless of output-equivalence**, so I
reclassified the one SAFE-APPLY that was a *helper extraction* (`rule-id-extraction-duplicated`) to
GPS-GATE. I also added one finding discovered during baselining (`o4o5-watchdog-spawn-tax`). 

**Net: 3 applied (comment-only), 21 GPS-gated.**

---

## Battery baseline & state (honest)

**Authoritative baseline at review HEAD `fec5aa9` (measured SOLO):** full battery **457 passed, 3 suites
reported failed** — but all 3 are environmental, NOT logic:

| Suite | In a *contended* full run | Solo re-run | Diagnosis |
|---|---|---|---|
| `selfcheck-liveness` | FAIL (L1/L2b) | **4/0 PASS** | pure contention from the 29 concurrent review agents (spawn saturation) |
| `pre-push-gapa-prod-pattern` | FAIL (G5/G6/G7 rc=124) | **7/0 PASS** | pure contention (watchdog 8s deadline tripped under spawn load) |
| `config-local-overlay` (O4/O5) | FAIL (rc=124) | **FAIL even solo at 9s max deadline** | the spawn-tax × watchdog interaction — see finding `o4o5-watchdog-spawn-tax` below |

The **O4/O5 logic is proven correct**: driving the HEAD hook **body-direct** (`_PFG_WATCHDOG_CHILD=1`,
bypassing the watchdog) gives O4 = `exit 2 + FORBIDDEN` and O5 = `exit 0 (ALLOW)` — exactly what the test
expects. The failure is the watchdog killing the *full body* before it can render the verdict, because this
Windows/Git-Bash box pays a pathological per-spawn cost and the body makes dozens of spawns (the hook's own
comment at lines 34-40 documents this exact host). `config-local-overlay-test.sh` is **unchanged since
v0.9.0**; the watchdog (commit `cfef95c`) is **new this session** — so a session change made a pre-existing
test fail *on this host class*. This is gated, not silently "fixed" (see below).

**Effect of this pass on the baseline:** the 3 applied edits are **comment-only** (mechanically verified:
the staged diff has zero non-`#` changed lines). Comment edits cannot change behavior. Touched-file suites
re-run **GREEN solo** after the edit: source-of-truth-check **12/0**, pre-push gapa **7/0**, wedge **6/0**,
bare-remote **10/0**, remote-guard **8/0**. **No regression.**

---

## APPLIED — safe, pure-form cleanups (commit `89d42c9`)

All three are honesty-label corrections (doc lagged code — the inverse of the "prose ahead of mechanism"
class). GPS triage: cheap + reversible + provably no behavior change → ship.

| # | File:line | What | Why safe |
|---|---|---|---|
| A1 | `hooks/pre-push-gate-check:118` | `"7s self-watchdog backstop"` → `"8s"` | stale number; the deadline default is 8s (lines 23/40/47). Comment only. |
| A2 | `hooks/pre-push-gate-check:395,678` | drop `cpsl` from the two prod-pattern comments | built-in set (line 407) is `prod production prd release live legacy`; lines 402-406 EXPLICITLY exclude cpsl (false-positives on safe target `cyf.cpsl_core`). Comments contradicted code + adjacent rationale. Comment only. |
| A3 | `lib/source-of-truth-check.sh:32` | document the `"<...>"` catch-all placeholder rule + its conservative fail-safe | code's `"<"*">"` glob (line 111) is broader than the documented token list; doc now matches code. Comment only. |

Verification: every changed line is a comment (mechanical grep check passed); touched suites green solo.

---

## GPS-GATED — consequential, NOT applied (awaiting human decision)

Each is `is_real=true` and either behavior-changing or structural. Per the contract these are surfaced with
rationale and **must not be auto-applied**. Ordered by severity. "Triage" is the gps-decide reversibility
call; all are gated because applying them changes what the code DOES and at least one branch is a one-way
door (a wrong fail-closed/fail-open flip in a safety gate).

### HIGH severity

**G1 — `crlf-forbidden-list-failopen`** · `hooks/pre-push-gate-check` (helpers at 366-384, 408-426, 436-445)
- **Finding:** On this box `jq -r '.branch.field[]?'` emits **CRLF per array element**. `$(...)` strips only
  the *final* `\r\n`, so every entry **except the last** keeps a trailing `\r`. `_pfg_remote_forbidden`
  then compares `origin\r` != `origin` → **a forbidden/denylisted prod remote listed anywhere but last is
  NOT detected = FAIL-OPEN** on a push to a denylisted prod remote. `_pfg_repo_forbidden` is worse (the
  `\r` also breaks the slug `.git$` anchor). The prodPatterns loop fails open the same way; safeRemotes
  fails *safe* (extra CONFIRM). Reproduced end-to-end on-box. This is the **exact CRLF class CLAUDE.md flags
  as having bitten twice this session.**
- **Proposed fix:** strip `\r` at the single producer seam — in `_pfg_branch_array`, pipe each backend
  through `tr -d '\r'` (and the node/grep fallbacks); or `line="${line%$'\r'}"` per loop.
- **Why gated (behavior change, one-way-door direction):** flips a forbidden-remote push from `exit 0`
  (allowed) to `exit 2` (blocked) and a prod match from `allow` to `ask` on real multi-element configs —
  a safety-gate fail-direction change. Real fix, but it alters the gate's verdict and **needs a NEW
  multi-element-array regression test** (current tests use single-element arrays = the last element, whose
  `\r` is stripped, so they pass *despite* the bug — they cannot certify the fix).
- **Recommendation to human:** this is the highest-value finding; the `tr -d '\r'` seam fix + a new
  non-last-forbidden-entry test is the right close. Apply under your eyes, then run the push battery.

### MEDIUM severity

**G2 — `prefilter-not-always-exit0-on-python-crash`** · `lib/spec-divergence.sh:103-107`
- **Finding:** the prefilter doc (89-90) promises "Exit 0 always … never skip on an error", but the embedded
  Python does `int(os.environ['PF_MINLEN'])` unguarded; a malformed env override
  (`PREFLIGHT_SPEC_PREFILTER_MINLEN=notanumber`) raises ValueError → Python exits 1, no `RUN-CHECK` line.
  Under `set -uo pipefail` (no `set -e`) the case arm propagates exit 1 → **contradicts the fail-safe
  contract.** Latent today (prefilter is built but unwired — no skill calls it; the output-line consumer
  `[ "$out" = SKIP ]` still fails safe).
- **Why gated:** the preferred fix (defensive int coercion) flips exit 1→0 and adds stdout on the malformed
  input = behavior change. **Plus the verifier caught a latent bug in the finding's own proposed helper**
  (it returns the string default where an int is expected → would TypeError on `len(text) >= minlen`). Needs
  human review before applying.

**G3 — `signal-body-match-dropped`** · `lib/coverage-gap-detect.sh:147-159`
- **Finding:** the signal-keyword path is *documented* (line 39, the comment, the test header) to match the
  *whole rubric (any rule block)*; line 150 does a whole-file grep that succeeds on a body match, but the
  attribution at 151-152 re-greps **only headers** — so a signal token in a rule **body but not a header**
  is silently dropped and the defect mis-classifies **UNCOVERED-CLASS instead of BLIND-SPOT** (the
  *less-conservative* direction — a covered defect reported as not-covered). Reproduced against the shipped
  `rubric-generic-dotnet.md` (`allowlist`, `IHttpClientFactory`, `ValidateOnStart` all live in bodies).
- **Why gated:** the fix flips stdout line 1, the capture bucket (checklist-additions→calibration-log), and
  `--emit-capture` confidence (medium→high) — observable behavior. The current suite **does not exercise
  the signal path at all**, so it can neither detect the bug nor certify a fix; needs a new signal-path test.

**G4 — `write-failure-fail-open`** · `lib/capture-finding.sh:98-128`
- **Finding:** the script prints `captured: …` and exits 0 **even when the write failed** (`mkdir -p` or the
  `>>` redirect failing only emits to stderr; control still reaches the success echo + `exit 0`). This
  contradicts the file's own contract (line 36 "0 = entry written", lines 20-21 "a defect is NEVER silently
  dropped") and the sole caller (`coverage-gap-detect.sh:209`) *wants* to detect failure via non-zero exit
  but never gets it. A dropped capture is invisible — the exact failure mode the file's header warns about.
- **Why gated:** fix flips exit 0→2 + suppresses the false `captured:` on the write-failure input =
  behavior change (and makes the caller's currently-dead non-fatal branch reachable).

**G5 — `jq-absent-mixed-source-fail-open`** · `lib/source-of-truth-check.sh:83-97`
- **Finding:** if `--json` is supplied but `jq` is absent, the JSON block is silently skipped. JSON-only
  fails safe (empty-set → ESCALATE), but a **MIXED** `--json desc --require file:present` with jq absent
  silently drops ALL json-declared sources and can emit **PROCEED (exit 0) on a strict subset** of the
  operator's declared sources = **fail-OPEN for a fail-closed gate** (the tool-may-be-absent class CLAUDE.md
  flags). No "jq not found" diagnostic anywhere.
- **Why gated:** the fix (an else-branch that fails loud) changes exit codes on the jq-absent path; design
  nuance for the human — should it ESCALATE(3) for consistency rather than exit-2 (which overloads "usage
  error")? A human should pick the code.

**G6 — `evidence-gate-nonblocking-rc-failopen`** · `hooks/pre-push-gate-check:732-739`
- **Finding:** after the sibling evidence gate, only 124/137/>128 remap to BLOCK; a plain non-zero non-2
  (e.g. **127** if `pre-push-gate` is missing/non-exec, or a `set -e` abort = 1) is passed through verbatim
  via `exit "$EVIDENCE_RC"`. Under the PreToolUse protocol only exit 2 blocks → **127/1 is non-blocking →
  ungated push.** Reachable on a host *without* `timeout` (watchdog degrades to inline; line 43 documents
  it); on a host *with* `timeout` (this one) the parent watchdog already remaps the child's 127→2, so it's
  defense-in-depth there. Narrow window (corrupted/partial install, lost exec bit) but the file's whole
  thesis is fail-closed.
- **Why gated:** the fix normalizes any non-zero non-2 to exit 2 — changes the dangerous-direction exit code
  on a no-timeout host. Cheap, correct, fail-closed insurance — but a safety-gate exit-code change.

### LOW severity (real, behavior-changing or structural — gated, lower priority)

**G7 — `rule-id-extraction-duplicated`** · `lib/coverage-gap-detect.sh:128,139,154`
*(verifier said SAFE-APPLY as byte-equivalent; **I reclassified to GPS-GATE** because the contract gates
structural moves regardless of output-equivalence.)*
- **Finding:** the `printf '%s' "$X" | grep -oE '§[A-Za-z0-9.]+' | head -1` §id-extraction idiom is
  repeated verbatim 3×. A `_rule_id` helper centralizes the §id grammar.
- **Why gated:** it is a **structural move** (introduces a new helper, re-points 3 sites). Byte-equivalent
  on every input the verifier could construct, and no test would break — but "structural change" is a gate
  trigger per the contract. Lowest-risk of the gated set; a clean DRY win if you want it.

**G8 — `dead-whole-file-signal-grep`** · `lib/coverage-gap-detect.sh:150`
- Same root cause as G3: line 150's whole-file grep does no discriminating work *as written* (its result is
  re-gated by the header grep at 152). The finding **explicitly forbids removing it in isolation** — the
  intended behavior is to honor the body match (G3), so the right resolution is G3's fix, not deletion.
  Gated as part of G3.

**G9 — `enumerated-regex-evaluated-twice`** · `lib/spec-divergence.sh:128`
- The `enumerated` marker evaluates the same non-trivial regex twice (`re.search(PAT) and
  len(re.findall(PAT))>=2`); the `re.search` conjunct is value-inert (findall≥2 implies search-true).
  Verifier proved byte-identical output across 12 adversarial inputs + end-to-end. **Gated** because it
  removes an *executed* short-circuiting conjunct (not provably-dead code) — fail-closed review won't stamp
  it no-care. Pure DRY; safe to apply under your eyes.

**G10 — `emit-capture-validation-after-output`** · `lib/coverage-gap-detect.sh:203-204`
- The `--emit-capture requires --capture-source` check runs **after** the full classification is printed, so
  a misconfigured call prints a well-formed result *then* errors+exits 2. Fix (move the check up) suppresses
  that stdout = behavior change on the misconfig input.

**G11 — `empty-rubric-passes-required-guard`** · `lib/coverage-gap-detect.sh:68,95`
- `--rubric` as the final arg with no value appends `""`; the guard counts elements not non-empty paths, so
  it passes and emits **UNCOVERED-CLASS exit 0** instead of a usage error — masking a missing-arg mistake as
  a real "no coverage" verdict. Fix (reject empty at parse time) flips it to exit 2. Prefer the *narrow*
  parse-time reject over the broader "require existing rubric in guard" (larger blast radius).

**G12 — `crlf-robustness-implicit-not-explicit`** · `lib/coverage-gap-detect.sh:123-159`
- CRLF handling here is **correct today** but only because this box's grep/sed strip the trailing `\r` and
  `MATCHED_RULE` is extracted via a `\r`-excluding char class. On a **CR-preserving toolchain** the raw
  header-tail `${hdr#### }` could leak a `\r` into the META string passed to `capture-finding.sh --meta`.
  Optional hardening: explicit `${hdr%$'\r'}` strips. Gated because it changes downstream bytes on a
  CR-preserving platform.

**G13 — `cap-echo-dash-value`** · `lib/capture-finding.sh:74`
- `_cap` emits with `echo "$v"`; a config value literally `-n`/`-e`/`-E` would be eaten as a flag → empty
  path → DEST collapses. `printf '%s\n'` is the robust idiom (used elsewhere in the file). Gated: changes
  stdout on the dash-leading edge input. Pathological config, low severity.

**G14 — `typo-bucket-confidence`** · `lib/capture-finding.sh:86,90`
- A typo'd `--bucket` falls through to checklist-additions (same as omitted) but keeps **medium** confidence
  while an omitted bucket gets **low** — inconsistent with the "uncertain ⇒ low" rationale. Two options:
  comment clarification (pure-form) OR `BUCKET_DEFAULTED=1` in the `*` case (behavior change). Gated so the
  human picks; the behavior-changing branch must not be auto-applied.

**G15 — `single-colon-require-aliases-label-to-path`** · `lib/source-of-truth-check.sh:60-67`
- `--require "file:r.txt"` (one colon) parses label=path=`r.txt` and is silently accepted as if 3-field,
  printing the path as the label — masks an operator typo. Fix (reject, or default the label) changes exit
  code / stdout on the 2-field input. Low severity; verdict is still correct, just the label display.

**G16 — `prod-confirm-without-config-vs-inert-claim`** · `hooks/pre-push-gate-check:670-697`
- Several comments claim the guard is "inert / never newly blocks a repo that didn't opt in", but the GAP-A
  prod-pattern net is **always-on**: with no config, a push to a prod-named remote flips AUTO→CONFIRM
  (friction, never a block). Largely *masked* (the evidence gate hard-blocks a no-evidence repo first), so
  it's only observable in the evidence-present-but-no-`branch.remote` window. **This is a design tension,
  not a bug:** the always-on net is deliberate (closes silent-push-to-prod with no opt-in). Gated as a
  design call — either gate the heuristic behind opt-in (reopens the hole the net closed) OR soften the
  "inert" comments to admit the net is intentionally always-on. **Recommend: soften the comments** (keep the
  safety net).

**G17 — `o4o5-watchdog-spawn-tax`** · `hooks/pre-push-gate-check` watchdog (commit `cfef95c`) × `config-local-overlay-test.sh` (unchanged since v0.9.0)
*(discovered during baselining; not from the file reviewers.)*
- **Finding:** the session's self-watchdog kills the full hook body at its 8-9s deadline on this slow-spawn
  box **before the body can render a verdict**, so `config-local-overlay` O4/O5 — which drive the hook
  *through* the watchdog (they don't set `_PFG_WATCHDOG_CHILD=1` like the gapa/wedge tests) — fail with
  rc=124 even solo at the max 9s deadline. The **decision logic is correct** (proven body-direct). At v0.9.0
  the body ran inline (slow but eventually correct → O4/O5 passed); the watchdog is the new variable.
- **Why gated (genuine design call, not a clean fix):** options each have a real downside —
  (a) **drive the test body-direct** (`_PFG_WATCHDOG_CHILD=1`), like gapa/wedge do — *but* then the test no
      longer exercises the watchdog path at all on any host;
  (b) **raise the watchdog clamp ceiling** above 9s — *but* it must stay under the 10s platform kill, so
      there's no room, and a higher deadline weakens the fail-closed guarantee on real hosts;
  (c) **accept it as a documented env caveat** (like the other Git-Bash spawn-tax test failures already in
      CLAUDE.md) and add `config-local-overlay` O4/O5 to that known-caveat list.
- **Recommendation to human:** (a) — make `config-local-overlay` drive body-direct for the O4/O5 *logic*
  assertions (matching how every other push-gate logic test isolates from the watchdog), and keep ONE
  separate watchdog-path assertion that tolerates the deadline-kill on slow hosts. This restores a green
  battery on this box without weakening any guarantee. Gated because it edits a test + touches the safety
  posture story — your call.

### LOW severity (real, but note-only / defense-in-depth — gated for completeness)

**G18 — `wedge-flag-temp-leak-on-kill`** · `hooks/pre-push-gate-check:125-127`
- The child's `_PFG_WEDGE_FLAG` (empty, PID-unique file) leaks in TMPDIR when the child is SIGKILLed by the
  watchdog (EXIT trap doesn't run on SIGKILL). Harmless to correctness. The reviewer recommends **no change**;
  any actual cleanup (broad glob) risks deleting a *concurrent* hook's live wedge flag → flipping its
  checkpoint fail-closed→fall-through. **Gated = do not "fix" this**; the note stands, the cleanup is more
  dangerous than the leak.

**G19 — `duplicated-remote-slug-resolution`** · `hooks/pre-push-gate-check:469-470,479-480,595-600,683-686`
- The "get-url → `_pfg_url_to_slug` → inline-URL fallback" idiom recurs at 4 sites; the inline-URL `case` is
  byte-identical at 2. **Structural** factoring tempting — but the verifier proved the sites are
  **asymmetric** (sites 1-2 have NO inline-URL fallback; site 4 alone reads the raw URL afterward for the
  prod heuristic). A naive one-size `_pfg_resolve_slug` would change CANON_SLUG resolution and the prod
  classification on crafted inputs. Gated: a correct factoring must thread back the raw URL and gate the
  fallback per-site, then re-run the push battery. Not a safe cleanup.

**G20 — `doc-prefilter-noted-not-built-now-stale`** · `lib/spec-divergence.md:78-80` (cross-file)
- The orchestration doc still calls the prefilter "Noted, not built", but it IS built+tested (`f80bb87`).
  More importantly **no skill invokes `prefilter`** before the 7-agent check — the cost-saving is unwired.
  Gated because (a) the doc is the prompt-level orchestration contract skills follow, and wiring step-0 in
  changes run flow; (b) the doc is test-inspected by `spec-divergence-wiring-test.sh` W6, so a careless edit
  could break W6. A faithful "mark built + add optional step-0" edit is a design decision, not a cleanup.

**G21 — `systemexit-nonint-maps-to-advisory-not-checkerror`** · `lib/parity-check.sh:282-285`
- In the new main() guard, a SystemExit with a **non-int payload** (e.g. `sys.exit('msg')`) maps to code 1
  (ADVISORY) and re-raises — the exact "a crash must not look like advisory" anti-pattern the commit closes.
  **Unreachable today** (main() only ever `sys.exit(0|1|2)`), but the guard is the defensive backstop for
  "any other exception", and this sub-branch leaks toward advisory instead of exit-3. Fix routes unknown
  SystemExit payloads to exit 3. Gated: changes exit code on those inputs (defense-in-depth, consistency).

---

## UPDATE — fail-open holes FIXED (follow-up pass)

The five fail-open / silent-pass safety holes were subsequently fixed, each RED→GREEN with an atomic
commit (the unifying principle: a safety check that CAN'T verify must FAIL CLOSED, never fail open):

| Finding | Commit | Fix | RED→GREEN |
|---|---|---|---|
| **G1** (HIGH) | `763cc04` | `_pfg_branch_array` pipes each backend through `tr -d '\r'` — denylist robust to CRLF on every element | crlf-denylist 2→0 fail (C1/C2 ALLOW→BLOCK) |
| **G3** (MED) | `a03c7b2` | signal body-match attributed to the containing rule (nearest preceding `### §`), not dropped | signal-body 1→0 fail (S1 UNCOVERED→BLIND-SPOT) |
| **G4** (MED) | `419c1f9` | every write step guarded; failed capture → error + exit 3, no false "captured:" | write-failclosed 2→0 fail (W1 exit0→exit3) |
| **G5** (MED) | `8edddc0` | `--json` + jq absent → ESCALATE (exit 3), no subset-PROCEED | jq-absent 1→0 fail (J1 PROCEED→ESCALATE) |
| **G6** (MED) | `b8b294d` | any evidence-gate rc not 0/2 → normalized to BLOCK (exit 2) | evidence-rc 2→0 fail (E1/E2 127/1→2) |

**14 new behavioral assertions**, all wired into the battery and passing. Post-fix battery: **475 passed,
3 suites failed** — the 3 are the **same G17 environmental spawn-tax×watchdog set** (O4/O5, L1/L2b,
gapa-internal G5/G6/G7), proven NOT a regression: (a) the failing set + line numbers are identical to the
pre-fix baseline; (b) the affected suites pass when isolated body-direct / idle; (c) body-direct timing is
**44-45s pre-fix AND post-fix** (the `tr` additions did not change it); (d) back-to-back idle selfcheck
reports ALIVE for both pre-fix and post-fix hooks, identically, 3/3 rounds. G17 remains gated (separate
design call), not a fail-open.

## Summary for the human

- **Applied (1 commit, `89d42c9`):** 3 comment-only honesty-label corrections. Battery not regressed
  (touched suites green solo; comment edits can't change behavior).
- **Gated (21, NOT applied):** ranked above. The highest-value real defects are **G1 (CRLF forbidden-list
  fail-open, HIGH)**, **G3/G4/G5/G6 (medium fail-open / contract violations)**, and **G17 (the watchdog ×
  spawn-tax test failure this session introduced)**. Each is recorded with its fix, its behavior-change, and
  its test-risk so you can decide and apply under your own eyes.
- **Honest state:** v0.9.0 untouched (`1651ecc`), origin untouched, nothing pushed/tagged/cut. The review
  was adversarial (biased to catch dangerous "cleanups"); 0 findings were false. The conservative gate
  means several genuinely-safe-looking improvements (G7/G9 in particular) were gated rather than applied —
  that is the intended fail-closed posture, not timidity.
