# CUT-READINESS — preflight 0.9.1 (pre-cut accounting)

**Purpose:** the anti-dangling artifact. This names, in writing, every fix proven this effort, every item
deferred, and every caveat that bounds what 0.9.1 may honestly claim — so the cut is HONEST, not merely
complete-looking. The owner cuts only after reading this. **No tag has been created; nothing is cut.**

- **Branch:** `feature/preflight-framework` @ `2a3d5a4` (local; **NOT pushed to origin/feature**).
- **v0.9.0:** tag → commit `1651ecc` (tag object `af0c153`) — **UNTOUCHED**. No tag created or moved this effort.
- **origin/feature/preflight-framework:** `1651ecc` — **UNCHANGED** (no push to the shared branch).
- **Backup:** prior new commits cherry-picked (`-x`) onto `pr/contract-guard-scorer-governance`
  (origin `0bb573c`), PR **#11 OPEN**, base `feature/preflight-framework`. The incident regression commit
  (`2db7d56`) is **local only — not yet backed up or pushed** (remediation hold; see §0).

---

## 0. REPOSITORY-TARGET SAFETY INCIDENT — RAISED then RESOLVED (read first)

**Blocker (raised):**
> Repository-target safety incident: the executing pre-push/PR gate interpreted a legacy production
> remote as canonical and emitted dangerous steering. Cut blocked pending root-cause confirmation,
> installed-artifact verification, and regression proof.

**Resolution:**

- **Exact root cause — C (clone-local configuration) + B (stale/drifted installed hook) in the CONSUMER
  clone; NOT A (a source defect).** The incident did NOT occur in this `code-forge` SOURCE repo (here
  `origin` = `United-Airlines-Org/preflight`, there is no `poc` remote, and the framework is not
  installed). It occurred in a migration consumer clone with the inverted topology (`origin` →
  `United-Airlines-Org/CPSL` legacy prod; `poc` → `United-Airlines-Org/cyf.cpsl_core` intended). The
  shipped SOURCE was verified to handle every incident shape correctly **when the consumer config carries
  `branch.remote=poc` + `forbiddenRemotes:["origin"]` + `forbiddenRepos:["United-Airlines-Org/CPSL"]`**
  (the A1 forbidden-destination + issue-#6 overlay fixes, already committed). With the **degraded incident
  config** (`branch.remote=origin`, no forbidden lists, no `config.local.json`) the guard is **fail-open**
  (additive-guard posture) — and `CPSL` is deliberately NOT a built-in prod-pattern (it would
  false-positive on the safe `cyf.cpsl_core` target). So the protection depends on the consumer's
  configuration, which was missing/incorrect — and/or the consumer's installed hook predated the A1/overlay
  fixes (a stale install, which `preflight-verify.sh` now detects as drift).

- **Affected artifact/version:** the CONSUMER clone's `.preflight/config.json` (missing forbidden lists /
  wrong `branch.remote`) and/or `.claude/hooks/pre-push-gate-check` (stale blob). Source artifacts at
  `feature/preflight-framework` HEAD are correct: `hooks/pre-push-gate-check` blob `1fb0863`,
  `lib/config-overlay.sh` blob `2231ec3`, `defaults/config-template.json` blob `ce2b242`.

- **Corrective change (incident):** NO change to the repository-target guard (the source hook is correct —
  confirmed by the full incident invariant matrix). Added
  `tests/behavioral/pre-push-installed-cpsl-incident-test.sh` (+12, against the INSTALLED artifact) closing
  three coverage gaps the incident exposed (alias→slug identity, direct-URL, installed-artifact + verifier
  drift/reinstall lifecycle). Test-harness fix: `config-local-overlay-test.sh` `run_hook` is now
  watchdog-isolated (the O4/O5 failures were a G17 spawn-tax watchdog timeout, not a logic error).
  Commit `2db7d56`.

- **Adjacent fix found DURING the investigation (separate defect, same hook file) — commit `2a3d5a4`:** the
  full behavioral suite surfaced a pre-existing FAIL-OPEN in the gap-#5 sentinel-mint tripwire (NOT the
  repository-target guard, NOT caused by the incident). `hooks/pre-push-gate-check:244`'s variable-expansion
  obfuscation branch was written `grep -qE "(\$[A-Za-z_]…"`; in a double-quoted string the `\$[` collapses
  to `$[`, which bash parses as legacy ARITHMETIC expansion `$[expr]` — under `set -u` it (1) spammed
  `line 244: A: unbound variable` to stderr on any command reaching that block, and (2) CORRUPTED the
  pattern so the branch NEVER MATCHED (verified: OLD `$[A-Za-z_]` does not match `$VAR>sentinel`; the fixed
  `[$]` char-class does). Fixed with `[$]` (a literal-dollar char class that cannot begin an arithmetic
  expansion). +2 regression assertions (G9 no-warning, G10 still-blocks); sentinel-tripwire now 10/0;
  RED→GREEN proven against pre-fix `1a9637e`. Re-verified the CPSL incident matrix STILL holds against the
  modified hook (0/2/2/2, no stray warning). This is a genuine safety improvement to a DIFFERENT guard.

- **CONSUMER remediation (the actual fix — to be applied in the consumer clone, NOT here):**
  1. In the consumer's gitignored `.preflight/config.local.json` (per-clone topology — never committed):
     `{ "branch": { "remote": "poc" } }`.
  2. In the consumer's committed `.preflight/config.json`:
     `branch.forbiddenRemotes` includes `"origin"`; `branch.forbiddenRepos` includes
     `"United-Airlines-Org/CPSL"`. (These are NOT overlayable — a local file can never weaken them.)
  3. Re-install the framework into the consumer from a current pinned ref
     (`tools/preflight-install.sh <consumer> <ref>`) and run `tools/preflight-verify.sh <consumer>` to
     confirm no drift.

- **Targeted test results:** `pre-push-installed-cpsl-incident` **12/0** (against the installed artifact);
  `pre-push-remote-guard` 8/0; `config-local-overlay` 10/0 (after the harness fix); `pre-push-bare-remote`
  10/0; `pre-push-gapa-prod-pattern` 7/0 (incl. G4: the safe `cyf.cpsl_core` target is NOT prod-flagged);
  `pre-push-parser-bypass` 26/0; `pre-push-crlf-denylist` 4/0; `pre-push-wedge-failclosed` 6/0;
  `sentinel-tripwire` **10/0** (after the line-244 fix).

- **Full-suite result:** the behavioral battery at `2db7d56` (before the line-244 fix) was **585 passed,
  2 failed** — the 2 fails were (a) `sentinel-tripwire` (the line-244 misparse — fixed in `2a3d5a4`, now
  10/0) and (b) `gate-liveness selfcheck` L1/L2b (a G17 load-contention flake — see §3.5; confirmed
  non-deterministic: passes 5/0 in isolation, v0.9.0 baseline passes 4/0, the dangerous-direction L2 still
  detects a real dead gate). The fresh full run at the new HEAD `2a3d5a4` (clean worktree) came back
  **599 passed, 0 failed (exit 0)** — both prior fails resolved: sentinel-tripwire fixed by the line-244
  change, and the gate-liveness G17 flake did not trip this run (lower ambient load), confirming it as the
  non-deterministic load-contention artifact rather than a logic failure.

### Full-suite result — the TWO distinct runs (do not conflate)

These are two SEPARATE aggregate runs on byte-identical code. Both are recorded; neither is rewritten as the
other.

- **Local byte-identical tree:**
  - Commit: `2a3d5a4`
  - Result: **599 passed, 0 failed**
  - Exit: **0**
  - (This is the historical local-feature run; the G17 flake did not trip under that run's lower load.)

- **Exact PR-head aggregate (the RC validation run):**
  - Commit: `11ef370` (the PR #11 head; tree byte-identical to `2a3d5a4` — same tree SHA `5dbe93d`)
  - Result: **595 passed, 1 failed**
  - Exit: **1**

**Failure disposition (the single PR-head failure):**
- The one failure was the documented **G17 `gate-liveness selfcheck` false-DEAD** condition (the `ls`
  allow-probe returning 2 instead of 0 — `DEAD pre-push-gate-check (allow=2 expected 0)`).
- It occurred under **concurrent process-spawn / load contention** (the hook's 8s self-watchdog tipped over
  on the slow-spawn host while the full battery ran all gates).
- The **same G17 test passed in isolation at PR head** (`selfcheck-liveness` = 4 passed, 0 failed at
  `11ef370`), proving the failure is load-contention timing, not a logic defect.
- The tree at `11ef370` is **byte-identical** to the previously-green `2a3d5a4` tree (identical tree SHA),
  so the code did not change between the 599/0 and 595/1 runs — only ambient concurrent load differed.
- The failure affects a **human-run diagnostic** (`tools/preflight-selfcheck.sh`). A tree-wide search found
  **no caller that consumes its verdict in any gate, push, or evidence path** (session-start emits only a
  passive "no action needed" advisory).
- A false-DEAD therefore **cannot** bypass a gate, permit a push, mark evidence clean, recommend an unsafe
  destination, or corrupt persistent state.
- The **dangerous direction — an actually-dead gate being detected as DEAD — continued to pass** (the
  selfcheck L2 case: a stubbed-dead gate is reported DEAD with exit 1, in both runs).
- **G17 is NOT fixed in v0.9.1.** It remains a disclosed, non-deterministic, fail-closed reliability caveat
  (see §3.5); mitigation is deferred to a future pass.

**Scope/disclosure statements (must travel with this evidence):**
- **GitHub's registered check did NOT execute the complete behavioral suite.** The only registered check is
  the advisory `rubric-governance-advisory` workflow; the 595/1 and 599/0 aggregates were run by hand from
  clean worktrees, not by GitHub CI.
- **Consumer validation was performed using a faithful throwaway FIXTURE** (a temp git repo reproducing the
  inverted topology, with inert CPSL/poc remote URL strings), not the real production clone.
- **The actual production consumer clone has NOT been remediated** — it is not present on this workstation.
- **Real-consumer remediation remains MANDATORY before tagging or releasing v0.9.1** (set the committed
  forbidden repo/remote policy + clone-local `branch.remote=poc`, reinstall from the final merge commit /
  future tag, run manifest verification + installed-hook repository-target validation).
- **Nothing has been tagged or released.** No `v0.9.1` tag exists; no GitHub release exists; `v0.9.0`
  remains at `1651ecc`.

- **Proof no CPSL/origin push occurred:** no `git push` was run during remediation; the only git writes were
  local commits + a throwaway worktree/install under `$TMPDIR`. This `code-forge` repo's `origin` is
  `United-Airlines-Org/preflight` (not CPSL); origin/feature is unchanged at `1651ecc`.

- **Proof no tag/release created:** `git tag` list is unchanged; v0.9.0 still → `1651ecc`; no new annotated
  tag exists.

**Status: the incident is RESOLVED as a SOURCE/coverage matter.** It remains an OPEN consumer-side action
(apply the config + reinstall in the consumer clone) — which is outside this repo and requires the consumer
operator. The cut of 0.9.1 (the framework) is not blocked by the source, but the release notes MUST carry
the consumer-configuration requirement (§4).

---

## 1. CLOSED (proven) — IN THE TEST HARNESS ONLY

> **READ THIS FIRST, do not soft-pedal it:** every fix below is proven **in the framework's own
> author-written test harness** (RED→GREEN against the actual pre-fix code via a throwaway worktree, plus a
> no-false-positive set). **NONE has been validated in a live consumer `scaffold`/`migrate` run.** The
> harness is written by the same author as the fixes; it exercises each hook/engine on crafted stdin and
> reads the exit code. That proves the gate *logic* fires on the crafted input. It does **NOT** prove the
> gate fires when Claude Code actually invokes it mid-session in a real consumer repo — that path
> (platform → hook delivery → real tool input) is **assumed, not observed**. See §3.

### This effort — the four NEEDS-CARE mediums (each NFP-proven against REAL repo artifacts)

| Fix | File | What it closes | RED→GREEN (vs pre-fix) | NFP source (REAL artifacts) | Commit |
|-----|------|----------------|------------------------|------------------------------|--------|
| **M2** | `hooks/adjudication-output-gate` | citation regex too-loose (prose `word:digit` allowed a DEFENDED verdict) AND too-tight (rejected real letter-prefixed §-ids) | 12/7 → **19/0** | real file:line in `tests/fixtures/agent-scorer/adjudications/PR99-abc1234.json`, `CLAUDE.md` (`lib/resolve-config.sh:58`), demo; real §-ids `§G2.1`/`§M4.3` (`FRAMEWORK.md:125-126`), `§D1` (scan-profiles), `§M3` (rubric-edit-process) | `f701aa8` |
| **M6** | `lib/parity-check.sh` | missing/renamed/typo'd/non-list top-level `behaviors` → was CLEAN exit 0 (masked a dropped behavior) or phantom exit 2 | 6/3 → **9/0** | real fixtures: `parity-check-exit-codes` P0-P8, `wire-format` legacy/migrated, genuine `{"behaviors":[]}` | `14136d4` |
| **M10** | `lib/generate-wire-golden-test.sh` | `\|` in a sample/golden value collided with the `sed s\|…\|` delimiter → assertion-less "green" test at exit 0 | 4/2 → **6/0** | byte-identical output proven on real `tests/fixtures/wire-golden/*.json` (both runners) | `c7500de` |
| **M15** | `skills/migrate/SKILL.md` (Check-3) | a genuinely-absent REACHABLE proc passing Check-3 (short-name `<5` skip; dual-format heading bypass; NR misclassification) | see M15 note below → **12/0** | documented format-example rows (`cpsl_setCCToken_v2` REACHABLE, `cpsl_setMPToken_v1` NOT REACHABLE) | `366bd63` + `065c420` + `e2e528b` + `1a9637e` |

**M15 took FOUR iterations under adversarial verification** (this is the discipline working, not a defect
hidden):
- `366bd63` (M15) — deleted the `<5` length skip + structured column-1 extraction. **Adversary found** a
  dual-format bypass: procs also appear as `` ### `<proc>` `` headings; a heading-only REACHABLE proc
  absent from the table passed silently.
- `065c420` (M15b) — added heading-form extraction. **Adversary found 3 new defects** the heading-NR
  machinery introduced: (1) body-prose "NOT REACHABLE" flipped a REACHABLE proc to skipped (fail-OPEN);
  (3) the next heading's NR marker bled back (fail-OPEN); (2) prose `### ` headings became phantom procs
  (false-MISSING).
- `e2e528b` (M15c) — made heading-NR line-scoped + backtick-required. **Adversary found** a *pre-existing*
  fail-OPEN: a whole-line `grep "NOT REACHABLE"` skipped a REACHABLE proc whose NOTES cell merely mentioned
  the phrase.
- `1a9637e` (M15d) — made NR detection marker-COLUMN-scoped. **Adversary verdict: CONVERGED-SOLID** — no
  fail-open on any reachable+absent proc; all probes land in the safe over-flag direction.
- **Residual (named, §4):** a contract row with **no leading pipe** is invisible to extraction. It is the
  safe direction, not the documented format, and not a regression (no prior version handled it).

### Prior-effort HIGHs and MEDIUMs already closed (same harness-proven discipline)

All proven RED→GREEN in `tests/behavioral/` and wired into `tests/run-all-tests.sh`. Same caveat as above:
**harness-proven, not live-validated.**

- **H1+H2** `43ea84d` — structural push parser (detection+extraction bypass).
- **H3+H4** `915a009` + matcher `87b367a` (M13) — coupled-edit path-form + missing-acknowledged fail-opens; Write/MultiEdit bypass.
- **H5** `af75760` — spec-integrity empty/empty-category skip.
- **H7** `559865f` — verify content-checks skills by tree-SHA (tampered/deleted SKILL.md → DRIFT).
- **G1** `763cc04` — CRLF fail-open in the forbidden-destination denylist.
- **G3/G4/G5/G6** — coverage-gap body-match, capture write-failure, jq-absent mixed-source, evidence-gate passthrough.
- **M3** `8adeaa6`, **M4** `59ad7a8`, **M5** `d5cd40d`, **M7** `c4de4de`, **M8** `ed2f1a3`, **M9** `d387691`, **M11** `3eab12c`, **M12** `173964f`.
- **M1/M14** `0667ad8` — honesty-label doc relabels (no logic).

### Adversarial verification performed this effort

- M2, M6, M10 — independent skeptic agent (prompted to BREAK each): **all SOLID** (bypass / false-positive /
  regression attempts all failed; the documented allow-list and real fixtures hold).
- M15 — **three** adversarial rounds, each found a real fail-open or regression that was then closed;
  final round **CONVERGED-SOLID**. This is the falsify-don't-confirm discipline (CLAUDE.md rule 2)
  producing its intended result: defects surfaced and closed before the cut, not after.

---

## 2. DEFERRED (named) — NOT fixed in 0.9.1

### H6 — `preflight-eval-gate.sh --proposal` does not evaluate the proposal (REWORK, not a guard-add)
- **What:** the `--proposal <rubric-dir>` flag is parsed (`tools/preflight-eval-gate.sh:38`) but **never
  read**; the golden-task loop always runs against the **live** rubric, so the proposal-vs-baseline
  auto-reject can never fire on a genuinely-worse proposal.
- **Why deferred:** Phase 1 established this is a REWORK (staging mechanism + parameterized golden tasks +
  a baseline-vs-proposal differential run) — too large and too core-logic to safely batch the night before
  a cut.
- **Bounded blast radius:** `--proposal` is **not auto-invoked by any shipped hook or skill**
  (manual/CI-pipeline tool only); the documented no-`--proposal` mode works correctly; the risk is strictly
  to a future self-learning flow that would lean on `--proposal`. Full release-note text:
  `.release-audit/H6-RELEASE-NOTE-LIMITATION.md`.

### M15 no-leading-pipe contract rows (minor, safe direction)
- A name-contract row written without a leading `|` is invisible to proc extraction. **Not the documented
  format** (every documented/exemplified row uses leading pipes), **not a regression** (no prior version
  handled it), and the failure direction is **uniform over-flag** (cannot selectively skip a reachable
  proc as NR). Recommend a one-line doc note that contract rows MUST be leading-pipe; not a code change.

### Per-fix residuals carried forward (in-scope-but-bounded)
- **M2** is deliberately LEXICAL: a prose excuse embedding a real-extension `file:line`-shaped token still
  passes (substantive support is the downstream human-audit layer). Also: VB.NET `.vb`, `web.config`,
  MSBuild `.props/.targets`, `.resx`, and uppercase `.CS` are **not** in the extension allow-list — they
  BLOCK (over-block, the safe direction), worth a future allow-list extension for .NET-on-Windows targets.
- **M6** does not catch per-behavior INNER key typos (spec-analyst Self-Check's job); does not verify the
  spec is a real extraction (spec-integrity's job).
- **M10** if a future contract carries a metachar in a value, the index()-splice preserves it; the
  PIPESTATUS backstop fails closed on any residual substitution failure.

---

## 3. THE UNVALIDATED-IN-REALITY CAVEAT (state plainly)

1. **The entire hardened gate-set has never executed in a live run.** Every fix is proven in the
   author-written test harness on crafted stdin. No fix has been exercised by Claude Code actually invoking
   the hook mid-session in a fresh consumer scaffold/migrate. The fixes' live-firing behavior is **ASSUMED,
   not observed.** A harness PASS proves the gate logic; it does not prove the platform→hook delivery path
   on a real tool call. (The behavioral-contract-gate's own header already labels its delivery as
   "inferred… not separately re-observed.")
2. **The G17 spawn-tax may break gates on THIS box.** CrowdStrike Falcon scan-on-exec adds ~1s per
   subprocess spawn here, so a push-gate / liveness hook may (a) over-block (fail-closed, safe) or (b) not
   complete within Claude Code's 10s `PreToolUse` timeout — in which case the platform's behavior on a hook
   timeout governs, not the gate. This is an environment property of this machine; it has not been measured
   on a clean consumer host.
3. **Server-side branch/repo protection remains the genuine enforcement ceiling.** All push/coupling/write
   gates are **agent-Bash-tool-only and fail-open at that ceiling** (no config = no gating; a non-agent
   push path is ungated). They are NOT server-side branch protection. See
   `docs/parity-gate-limitations.md`. The reversibility-tiered push policy classifies by blast radius for
   the *agent's* pushes only.
4. **Known pre-existing test-environment failures persist** (documented in CLAUDE.md): `resolve-config` /
   `tdd-skill-resolution` (jq `\x00` escape), `drift-detector` (tempdir), `bootstrap-write-gate` /
   `rubric-validity-gate` / `run-coupled-group` (stale argv-interface tests). These are environmental /
   stale-test, not regressions — verify any "new" failure against a clean baseline worktree of the prior tag.
5. **G17 watchdog/selfcheck load-contention flake (gate-liveness L1/L2b).** `tools/preflight-selfcheck.sh`'s
   ALLOW-case probe for `pre-push-gate-check` (a benign `ls`) intermittently returns 2 instead of 0 when the
   full behavioral battery runs all gates under high concurrent spawn load: the hook's Layer-1 self-watchdog
   (added after v0.9.0) re-execs the body under an 8s deadline, and on this CrowdStrike-scan-on-exec box the
   re-exec's own spawn tax can tip past 8s, fail-CLOSED (124→2) — the selfcheck then misreports that gate
   DEAD. It is **non-deterministic** (passes 5/0 in isolation; the v0.9.0 baseline passes 4/0 because the
   watchdog did not exist then), the **fail direction is benign** (a FALSE-DEAD over-reports — never a real
   dead gate read as alive; the dangerous-direction L2 still correctly detects a stubbed-dead gate), and it
   is **a host/test-timing interaction, not a product regression**. On a sub-second-spawn production host the
   `ls` probe completes well under 8s and the selfcheck passes. Mitigation options for a future pass (not
   done here): give the selfcheck allow-probe a longer per-gate budget, or have it drive the body
   watchdog-isolated (`_PFG_WATCHDOG_CHILD=1`) the way the behavioral tests do.

---

## 4. WHAT A HONEST 0.9.1 MAY CLAIM vs MUST NOT CLAIM

**MAY claim:**
- The specific RED→GREEN-proven gate/engine fixes listed in §1, each closing a named fail-open or false-green
  **as exercised by the test harness**.
- That each fix ships with a behavioral test wired into `run-all-tests.sh` (this effort added 4 medium
  suites: M2 19, M6 9, M10 6, M15 12 = **46 assertions**; M15 alone survived 3 adversarial rounds).
- That the framework's gates are **fail-closed by design** on the dangerous direction and on unparseable input.

**MUST NOT claim:**
- Live-validated **end-to-end** enforcement. No fix has run in a live consumer scaffold/migrate.
- **Server-side** protection. The gates are agent-Bash-tool-only and fail-open at the server ceiling.
- That the gates are **proven to fire in a real session.** Harness-proven ≠ live-proven; the delivery path
  is inferred.
- Any maturity beyond **n=0/n=1**. The framework has not closed the loop on a real ServiceN+1 end-to-end.

**The release notes MUST carry the §3 caveats** (unvalidated-in-reality, G17, server-side ceiling) and the
H6 known-limitation text.

**The release notes MUST ALSO carry the consumer-configuration requirement (from the §0 incident):** the
push/PR guard's protection of an inverted/migration clone is **conditional on consumer configuration** — on
ANY clone where a remote (often `origin`) points at a legacy/production repo, the consumer MUST set
`branch.forbiddenRemotes` / `branch.forbiddenRepos` (the denylist, NOT overlayable) and set the intended
target via `branch.remote` (per-clone topology via the gitignored `.preflight/config.local.json`). With no
such config the guard is **fail-open** (additive-guard posture), and a project-specific legacy repo name
(e.g. `CPSL`) is deliberately NOT a built-in prod-pattern. State this plainly: **the guard does not
auto-detect a project's legacy-prod repo; the operator must declare it.**

---

## 4b. P0 BASH-AVAILABILITY INCIDENT — cut REOPENED after merge (read with §0)

After the PR #11 source merge (`7abdd02`), a **P0 availability defect** was found and the 0.9.1 cut was
**reopened**. This section is the honest record.

**The defect (every-Bash watchdog denial).** The monolithic `hooks/pre-push-gate-check` ran its heavyweight
body (dozens of git/jq/grep spawns) **and a self-watchdog** for EVERY Bash command, because it was the
registered Bash `PreToolUse` hook. On the Windows/Git-Bash scan-on-exec host, an ORDINARY command's spawn
tax exceeded the 8–9s watchdog deadline, so the gate returned exit 2 (block) for **every** Bash command —
disabling autonomous coding. Six demonstrated sub-defects: (1) every-Bash watchdog denial; (2) heavy engine
on ordinary commands; (3) branch checkout replacing the active runtime; (4) unsafe partial upgrades; (5)
install/recovery friction; (6) failure propagation across unrelated capabilities.

**G17 REFRAME (supersedes the prior "isolated selfcheck inconvenience" conclusion).** The earlier read of
G17 — that the slow-spawn tax was merely a conservative selfcheck flake — was **wrong about blast radius**.
The selfcheck flake itself WAS conservative (it failed safe). But the **same timeout architecture also lived
in the live Bash gate**, and there it caused **total Bash denial** — a release-impacting availability
failure, not a test-only inconvenience. The corrective architecture **separates the diagnostic and
enforcement timing models**: the heavy enforcement body no longer carries an in-line self-watchdog at all;
the deadline is owned by the fast router, scoped to candidate commands only, and DERIVED from the platform
timeout so it can never again turn "slow gate" into "every Bash blocked."

**The corrective architecture (this P0 effort).**
- **Split routing from enforcement** (committed `b43cabd`, harness-proven): `pre-bash-risk-router`
  (builtins-only, ZERO external spawns on the ordinary fast path) + `pre-push-gate-engine` (heavy body,
  watchdog-free, invoked only for candidates). Defects #1, #2, #6 closed structurally. Engine enforcement is
  byte-for-byte the old body minus the watchdog (adversarially verified). The **timeout-budget invariant**
  (router deadline derived from the hooks.json platform timeout, env override clamped to the ceiling) closes
  a fail-OPEN found in adversarial review and is guarded by a single-source coupling test.
- **Branch-stable runtime** (harness-proven; **defect #3**): the active Bash gate registration moves from
  the TRACKED `.claude/settings.json` to the UNTRACKED `.claude/settings.local.json`, pinned to a SHA-named
  runtime under `<git-common-dir>` (outside branch control). Atomic install + rollback + uninstall +
  `--scan-local-branches` close defects #4/#5. **AUTHORIZED scoped contract change** (owner-approved):
  installer registers the Bash gate only in the local layer and performs an ownership-aware migration out of
  the tracked layer (non-Bash hooks + non-Preflight settings preserved; ambiguous ownership ABORTS). See
  `docs/branch-stable-runtime.md`.

**HONEST closure status for defect #3:** *closed for MIGRATED checkouts; OPEN for LEGACY branches.* A
historical branch whose tracked `settings.json` still carries the Preflight Bash registration remains a
**migration hazard** (Claude Code runs hooks additively) — detected by `preflight-verify.sh` (duplicate/
legacy → FAIL) and `--scan-local-branches`, **not** auto-rewritten. Do not claim "fully closed everywhere."

**Platform-delivery is INFERRED, not live-confirmed.** That Claude Code actually loads & invokes the pinned
local-layer hook, that ordinary Bash hits only the fast router, that a candidate push invokes exactly one
engine, and that a branch switch between migrated branches does not change the active runtime — **must be
confirmed in a real Claude Code consumer session.** It is NOT inferable from JSON structure or unit tests.
Until that live run passes, **v0.9.1 is NOT cut-eligible** for the P0 fix.

**Emergency installed-file repair (the CPSL consumer):** the live consumer clone that hit the every-Bash
denial received a tightly-scoped emergency in-file repair (fast router prepended before the watchdog; the
watchdog scoped to candidates with a retuned deadline + 120s platform timeout; input preservation; and a
restored fail-closed on malformed candidates — the last being a PRE-EXISTING gate-body fail-open, proven by
driving the body directly). 8/8 case matrix green; zero external spawns on the fast path confirmed. This is a
temporary stopgap in that consumer; the durable fix is the committed source split.

**Product-architecture scope (owner directive):** this P0 is an infrastructure + delivery-contract
correction, NOT a product rewrite. The established workflow (bootstrap → discovery → Behavioral Contract →
baseline spec → impl/migrate → migrated spec → parity → evidence → review → external-review → adjudication →
rubric evolution → server governance), agent separation, parity engine, evidence model, reviewer/adjudicator
roles, external-review loop, and manifest/integrity concepts are **unchanged**.

---

## 4c. P0 ACCEPTANCE GATES — status at head `22fd039` (draft PR #12)

Four acceptance gates were defined; Gates 1–3 are closed, Gate 4 is intentionally deferred. The eight P0
commits are `b43cabd` (split), `67d68ab` (branch-stable runtime), `9d63fa9` (E/F docs), `dcf7786`
(verify-advisory fix), `4a794f2` (selftest router coverage), `baabee5` + `22fd039` (slow-host test
tolerance), `72728f9` (unified one-command installer).

| Gate | What | Status |
| --- | --- | --- |
| 1 | Complete behavioral suite at exact final head `22fd039` (clean worktree, `all` incl. spawn-delay) | **PASSED — 699 passed, 0 failed, exit 0** |
| 2 | Unified installation contract — one `preflight-install.sh` command produces the branch-stable model | **PASSED** (fresh-consumer end-to-end: tracked Bash removed, local pin added, manifest==runtime, verify PASS+0 drift, idempotent, rollback coherent) |
| 3 | Eliminate consumer split-brain — real consumer upgraded to `22fd039` | **PASSED** (manifest==runtime==`22fd039`, verify PASS, 0 drift; app work byte-identical, 10/10 stashes, archives preserved) |
| 4 | Live Claude Code platform validation | **NOT YET PERFORMED** (requires a real CC session rooted in the consumer; a headless agent cannot observe CC's own PreToolUse dispatch) |

**Status distinction (the required honest framing):**
- Mechanical acceptance: **passed**
- Exact final-head full suite: **passed (699/0)**
- Installation coherence: **passed**
- Live Claude Code delivery: **pending**

> **P0 mechanical acceptance passed; live platform acceptance not yet performed.**

v0.9.1 remains **blocked** on Gate 4 (the live session) — NOT on any failed test. Do not call the release
cut-ready, and do not promote PR #12 from draft, until the live Claude Code consumer session passes.

---

## 5. CUT DECISION INPUTS (for the owner)

- **Go-ahead-able:** the 4 mediums + all prior HIGHs/MEDIUMs are harness-proven and backed up; M15 converged
  under adversarial pressure; invariants (v0.9.0, origin/feature) intact.
- **The honest gap that gates a TRUE readiness claim:** no live run. If 0.9.1 is cut, it must be positioned
  as "hardened gate logic, harness-proven, not yet live-validated" — the survival thesis (close the loop
  once on a real ServiceN+1) is still open.
- **Recommended:** cut 0.9.1 as a hardening release with the §3/§4 caveats in the notes, OR hold the tag
  until one live consumer run validates at least the push + coupling + adjudication gates fire in-session.
  That is the owner's call; this document ensures it is made with the gap NAMED, not hidden.
