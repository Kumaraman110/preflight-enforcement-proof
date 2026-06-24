# H2 Fix Design — push-gate detection bypass (READ-ONLY design, no code written)

**Finding:** H2 (highest priority, from FRAMEWORK-SCRUTINY-FINDINGS.md). `git -C <dir> push …` and ~16
other invocation forms evade the push-gate detector, so `hooks/pre-push-gate-check` exits 0 **before every
guard** — a full bypass of the forbidden-remote / force-to-protected / CONFIRM tiers.

**This document is a DESIGN ONLY.** No file was edited, nothing committed, nothing pushed. HEAD `b8b294d`,
v0.9.0 = `1651ecc` untouched. The actual edit to a safety gate is supervised work for a rested session.

**Why a one-line "broaden the regex" is insufficient** (the task's premise, now proven): H2 is itself a
too-narrow-matcher bug. Below I show the bypass surface is **17 of 21 tested forms**, spans **two**
string-matching layers (detection AND extraction), and includes classes (subshells, `eval`, env-prefixes)
that **no regex can enumerate**. The deliverable is a *provably-scoped* fix with an honest residual, plus a
fail-closed fallback so an unanticipated future syntax **blocks rather than bypasses**.

---

## 1. Confirmed bug (read-only reproduction)

The detector is a single line:

```
hooks/pre-push-gate-check:531
  if ! printf '%s' "$COMMAND" | grep -qE '(^|&&|\|\||;|")\s*git\s+push'; then exit 0; fi
```

It requires the literal token sequence `git` `\s+` `push` anchored at start-of-string or after one of
`&& || ; "`. Reproduced live (real hook, body-direct `_PFG_WATCHDOG_CHILD=1`, throwaway `/tmp` repo with a
config whose `forbiddenRemotes=["poc"]`):

| Command | Result |
|---|---|
| `cd <dir> && git push --force poc main` (control) | **exit 2 BLOCKED** — "FORBIDDEN destination 'poc'" |
| `git -C <dir> push --force poc main` (H2) | **exit 0, no output — fully ungated** |

The `cd && git push` form matches (after `&&`); the `git -C … push` form does not (a `-C <dir>` token sits
between `git` and `push`), so line 531 short-circuits to `exit 0` before the forbidden-destination check
(line 602), the force-to-protected BLOCK (658), the bare/wrong-remote/protected CONFIRM tiers (672/679/712),
and the evidence gate (738). **The detector regex is confirmed as the cause.**

---

## 2. The COMPLETE bypass enumeration (MATCH = gated, MISS = bypass)

Tested each form against the **actual** regex `(^|&&|\|\||;|")\s*git\s+push`, read-only:

### Baseline — correctly MATCHED (the only forms the gate sees)
| Form | Result |
|---|---|
| `git push origin main` | MATCH |
| `cd /repo && git push origin main` | MATCH |
| `echo hi; git push origin main` | MATCH |
| `a && git push origin main` | MATCH |
| `\t git push origin main` (leading tab) | MATCH (`\s*` covers it) |

### Class 1 — global git options between `git` and `push` (the named H2 class) — **all MISS**
| Form | Result |
|---|---|
| `git -C /repo push …` | **MISS** |
| `git -c http.sslVerify=false push …` | **MISS** |
| `git --git-dir=… --work-tree=… push …` | **MISS** |
| `git -C . -c k=v push …` | **MISS** |
| `git -P push …` / `git --no-pager push …` | **MISS** |
| `git --bare push …` | **MISS** |

Git accepts an arbitrary, repeatable, order-independent run of global options before the subcommand. Per
`git --help`: value-taking options whose value is a **separate token** (`-C <path>`, `--git-dir <path>`,
`--work-tree <path>`, `--namespace <path>`, `--super-prefix <path>`), `=`-joined single-token options
(`-c name=value`, `--git-dir=…`, `--exec-path[=…]`, `--config-env=…`), and bare flags (`-p`/`--paginate`,
`-P`/`--no-pager`, `--bare`, `--no-replace-objects`, `--no-optional-locks`, `--literal-pathspecs`, …).

### Class 2 — shell grouping / control structures — **all MISS**
| Form | Result |
|---|---|
| `(git push origin main)` (subshell) | **MISS** |
| `{ git push origin main; }` (brace group) | **MISS** |
| `if true; then git push origin main; fi` | **MISS** |

### Class 3 — command prefixes / alternate git spellings — **all MISS**
| Form | Result |
|---|---|
| `command git push …` | **MISS** |
| `\git push …` (quote-the-name to bypass alias) | **MISS** |
| `GIT_DIR=/repo/.git git push …` (env-prefix) | **MISS** |
| `/usr/bin/git push …` (absolute path) | **MISS** |
| `/mingw64/bin/git.exe push …` (Windows abs path) | **MISS** |

### Class 4 — indirection — **all MISS**
| Form | Result |
|---|---|
| `eval 'git push origin main'` | **MISS** |
| `echo origin main \| xargs git push` | **MISS** |
| `bash -c 'git push origin main'` | **MISS** |

**Tally: 17 of 21 forms bypass the detector.** The audit named ~6; there are at least 17, across four
distinct classes. Classes 1 and 3 are *idiomatic, non-evasive* agent forms (the hook's own body uses
`git -C` throughout); classes 2 and 4 shade toward evasion but are trivially reachable.

### Second matching layer — the extractor ALSO fails (a regex-only fix is doubly insufficient)
Even if line 531 detection were broadened, the **downstream** extractor on line 548
(`PUSH_CMD="$(… | grep -oE 'git[[:space:]]+push[^&|;]*' …)"`) depends on the **same** narrow `git\s+push`
adjacency. Tested read-only:

| Command | `PUSH_CMD` extracted |
|---|---|
| `git push origin main` | `git push origin main` ✓ |
| `git -C /repo push --force poc main` | `` (empty) — **extraction fails** |
| `git -c k=v push origin main` | `` (empty) — **extraction fails** |
| `(git push origin main)` | `git push origin main)` — **trailing `)` leaks into args** |

So a naive "broaden line 531" fix would *detect* the push, then extract an **empty** `PUSH_CMD` → `ARG_REMOTE`
empty → the forbidden/wrong-remote checks (which guard on `[ -n "$ARG_REMOTE" ]`) silently skip → **still a
fail-open**, now harder to spot. The bug is structural across two layers, and the `(…)` form corrupts the
arg tokenization. **Any fix must replace both the detector and the extractor with one correct parse.**

---

## 3. Options evaluated

### Option A — broaden the regex
Extend line 531 (and 548) to tolerate intervening global options, e.g. conceptually
`git( +(-C +\S+|-c +\S+|--git-dir(=| +)\S+|--work-tree(=| +)\S+|-[pP]|--paginate|--no-pager|--bare|…))* +push`.

**Assessment — provably INCOMPLETE.** A regex can be made to cover Class 1 (global options) if the full
option set is enumerated and kept in sync with git — but:
- It is brittle to the exact thing H2 *is*: a missed option synonym (a new git global option, `-c` vs
  `--config-env`, `--super-prefix`) silently re-opens the bypass. "Broaden the regex" reproduces the
  original defect's failure mode.
- It **cannot** cover Class 2 (subshell/brace/`if` — these change the *prefix anchor*, not the git-to-push
  span), Class 3 (`command`/`\git`/absolute-path/env-prefix — the leading token isn't `git`), or Class 4
  (`eval`/`xargs`/`bash -c` — the push lives inside a quoted string the outer regex can't structurally see).
- Adding `(` and `{` to the prefix anchor set (the audit's secondary suggestion) helps Class 2 only
  partially and adds false-positive risk.

A regex over a free-form shell string fundamentally cannot parse shell. **Reject as the primary mechanism.**

### Option B — tokenize and parse the git invocation structurally
Inside the hook, treat `$COMMAND` as a sequence of shell words, then for **each** git invocation: identify
the git program token (`git`, `/path/to/git[.exe]`, optionally preceded by `command`/`env`-assignments/a
leading `\`), **skip the known global-option run** (consuming a separate-value token after `-C`/`--git-dir`/
`--work-tree`/`--namespace`/`--super-prefix`; treating `=`-joined and bare-flag options as single tokens),
and read the **next** token as the subcommand. If subcommand == `push`, the remaining tokens ARE the push
args — extract remote/refspec/flags from *that token list* directly (no second `grep`).

**Assessment — feasible and the most complete tractable mechanism.** The hook already receives the command
as a string and already does ad-hoc tokenization (the `for tok in $PUSH_ARGS` loop at line 587, and
`_pfg_target_cwd` parses a leading `cd`). A disciplined tokenizer:
- **Covers Class 1 completely** — skipping the global-option run is exactly what git itself does; a small,
  documented option table (value-taking vs flag) handles every current global option, and an *unknown*
  `-…`/`--…` token before the subcommand can be treated conservatively (see fail-closed below).
- **Covers Class 3** — recognize the program token as `git` OR `*/git`/`*/git.exe` OR after `command`/a
  leading `\`/leading `VAR=val` env-assignments. This is enumerable because it's the *shell's* command-prefix
  grammar, which is small and stable (unlike "every git synonym").
- **Covers Class 2 partially** — split the command on shell separators that the hook can see (`;`, `&&`,
  `||`, `|`, and a leading `(`/`{`/`then`/`do`) and parse each resulting segment as a potential command. A
  subshell `(git push …)` becomes a segment starting `git push` once the leading `(` is stripped as a
  separator. (`if/then/while/do` keywords are separators too.)
- **Does NOT cover Class 4** — `eval '…'`, `bash -c '…'`, `xargs git push`: the push lives inside a quoted
  string or is assembled at runtime. No static parser of the outer command can reliably see it. This is the
  honest residual (handled by the fail-closed fallback below, not by parsing).

This also **fixes the extractor problem for free**: once the tokenizer has located the push subcommand, the
remaining tokens are the args — the line-548 `grep` and the line-587 re-tokenization both disappear, and the
`(…)` trailing-`)` corruption goes away.

### Option C — a different seam (don't parse the command string at all)
Is there a more reliable "a push is happening" signal than the command text?

**Assessment — not available at this seam.** A PreToolUse hook fires *before* the Bash tool runs and receives
**only** `tool_input.command` (a string) — there is no structured "operation = push, remote = X" event, no
post-hoc `reflog`/`FETCH_HEAD` signal (those are pre-execution), and the hook cannot run the command to
observe it. The truly reliable seam is **server-side** (branch protection / required reviewers / a
pre-receive hook on the remote) — which is the documented mechanical ceiling (`docs/parity-gate-limitations.md`)
and is *out of scope* for this agent-Bash-tool guard. So C is "the real fix lives server-side" — true, and
worth restating in the honesty label, but it does not replace fixing the agent-side guard. **Reject as the
in-scope mechanism; reaffirm as the ceiling.**

---

## 4. RECOMMENDATION — Option B (structural parse) + a fail-closed fallback

Replace the single detector regex (531) **and** the extractor (548) with one tokenize-and-parse pass that:
1. Segments `$COMMAND` on shell separators the hook can see (`; && || |`, leading `( { ` , `then`/`do`).
2. For each segment, strips leading env-assignments (`VAR=val`) and a `command`/`\` prefix, then matches the
   program token as `git` | `*/git` | `*/git.exe`.
3. Skips the global-option run using a small option table (separate-value: `-C --git-dir --work-tree
   --namespace --super-prefix`; `=`-joined and bare flags: single token).
4. Reads the next token as the subcommand; if `push`, parses the remaining tokens as the push arg list
   (remote, refspec, flags) — feeding the **existing** B0/B/C tier logic unchanged.

### Completeness argument
- **Every enumerated Class-1 form is covered** because step 3 mirrors git's own global-option parsing — the
  span between `git` and `push` is exactly the global-option run, and skipping it is definitional, not a
  pattern guess. Adding a future global option is a one-line table entry, and an *unknown* pre-subcommand
  option triggers the fail-closed path (below) rather than silently slipping.
- **Every Class-3 form is covered** because the command-prefix grammar (env-assignments, `command`, leading
  `\`, absolute program path) is the *shell's*, which is small and closed — unlike the open-ended "git
  synonym" space a regex chases.
- **Class 2 is covered** for the forms the hook can segment (subshell, brace group, `if/then`), because after
  separator-splitting each becomes an ordinary `git … push` segment.
- **It is robust to the dominant pattern (surface-syntax variance)** because it parses the *structure* (git →
  options → subcommand → args) instead of matching one surface spelling. The same parse yields detection AND
  extraction, eliminating the two-layer divergence that makes the current bug doubly bad.

### The fail-closed fallback (covers Class 4 and any unanticipated future syntax)
A static parser cannot see a push inside `eval '…'`/`bash -c '…'`/`xargs git push`, and cannot prove a novel
syntax is *not* a push. So the fix must invert the current fail-**open** default. Concretely:

> If the command contains a `git` program token followed (in `git … push` **order**, with only option-shaped
> tokens between) by a `push` token **that the parser could not fully resolve into a clean arg list** — OR
> contains an indirection wrapper (`eval`/`bash -c`/`sh -c`/`xargs … git`) with a `git`+`push` payload it
> cannot statically parse — then treat it as **needing the guard**: emit **CONFIRM** (`permissionDecision:ask`,
> the human confirms) rather than `exit 0` (silent allow). An *unparseable-but-plausibly-a-push* command
> escalates to a human; it does not bypass.

This is the same fail-closed discipline the framework just applied to G5/G6 ("a check that cannot verify must
escalate/block, never silently pass"). **CONFIRM, not exit 2**, is the right tier for the fallback: a hard
block would over-punish a benign false-positive, while CONFIRM removes the *silent* bypass (the actual H2
harm) and keeps a human in the loop — matching the existing bare-push CONFIRM treatment.

**False-positive boundary (verified read-only):** the fallback must key on `git … push` **order**, not mere
co-occurrence. A co-occurrence signal over-blocks `git commit -m 'push the button'`, `echo 'do not push'`,
`npm run push-docs`. The ordered signal (a `git`/`*/git` token, then only option-shaped tokens, then a bare
`push` token) correctly passes `git status`, `git log`, `git commit -m '…push…'` and `npm run push-docs`
while catching every real push form. This scoping is essential and is the line between "fail-closed safety"
and "an unusable gate that blocks normal git work."

### Honest residual
- **Runtime-assembled pushes remain undetectable** by any static parse: `eval "$(printf 'git push …')"`,
  a push hidden in a script file the command invokes, a base64-decoded command, a git **alias** that expands
  to a push (`git mypush` where `push.mypush = push --force …`). The ordered-`git…push` fallback catches the
  *literal* `eval 'git push …'` / `bash -c 'git push …'` (the push tokens are present in the string) but
  **not** a push whose tokens never appear literally in `$COMMAND`. That residual is irreducible at this seam
  and must be stated in the honesty label.
- **The mechanical ceiling is unchanged and must stay labeled:** this is an agent-Bash-tool guard, fail-open
  without a config, not server-side protection (`docs/parity-gate-limitations.md`). The fix narrows the
  agent-side bypass from "17 trivial forms silently allowed" to "only runtime-assembled/aliased pushes evade,
  and those escalate to CONFIRM if their tokens are literally present" — a large reduction, not a closure.

### Behavioral tests the fix must ship with (certification is behavioral)
RED→GREEN, one assertion per bypass class, each driving the real hook body-direct:
- Class 1: `git -C <dir> push --force <forbidden> main` → BLOCK (was exit 0). Plus `-c`, `--git-dir=`,
  `-P`, `--bare`, and a `-C . -c k=v` combo.
- Class 3: `command git push …`, `/usr/bin/git push …`, `GIT_DIR=… git push …` → gated.
- Class 2: `(git push …)`, `{ git push …; }` → gated.
- Class 4 (fail-closed): `eval 'git push <forbidden> main'`, `bash -c 'git push …'` → **CONFIRM** (not exit 0).
- **No-regression / no-false-positive:** `git status`, `git log`, `git commit -m 'push the feature'`,
  `npm run push-docs`, `echo 'do not push to prod'` → **exit 0 (unchanged)**; and every existing
  pre-push-bare-remote / remote-guard / gapa / wedge assertion stays green.
- **Extractor correctness:** for each gated form, assert the *correct* `ARG_REMOTE`/refspec is parsed (so the
  forbidden/wrong-remote checks actually fire on the right target — guarding against the empty-`PUSH_CMD`
  silent-skip the current extractor exhibits).

---

## 5. H1 interaction (the `+`-refspec force bypass) — fix together

H1 lives in the **same parse path** the H2 fix rebuilds:
- `hooks/pre-push-gate-check:580` — `HAS_FORCE` regex matches `--force/-f/--force-with-lease` but **not** a
  leading `+` on a refspec (git's force shorthand: `git push poc +main` = refspec `+main:main`).
- `hooks/pre-push-gate-check:651` — `TARGET_BRANCH="${ARG_REFSPEC##*:}"` does not strip a leading `+`, so
  `+main` ≠ `main` and the protected-branch check misses too.

Both H1 root causes are *refspec/flag parsing on the push arg list* — exactly the token list the Option B
parser produces. **They should be fixed in one change:** when the structural parser builds the push arg list,
it should (a) recognize a refspec whose **source** side begins with `+` (or a `--force*`/`-f` flag) as a
force signal → `HAS_FORCE=true`, and (b) strip a leading `+` from the refspec before deriving
`TARGET_BRANCH`. Doing H2 and H1 separately would mean tokenizing the push args twice and risks the two fixes
disagreeing on how args are parsed. One parser, one arg list, both signals derived from it — fix together.

> Note: also fold in the related observation that `ARG_REMOTE` resolution must run on the *parsed* token list
> (not the broken line-548 extraction), so the empty-`PUSH_CMD` silent-skip cannot recur for any covered form.

---

## 6. Summary for the implementer (rested session)

- **Do NOT broaden the regex (Option A)** — it cannot be complete and reproduces the H2 failure mode.
- **Replace detector (531) + extractor (548) with one structural tokenize-and-parse (Option B):** git program
  token (incl. `command`/`\`/env-prefix/abs-path) → skip global-option run via a small option table → next
  token is the subcommand → if `push`, parse remaining tokens as the arg list feeding the existing tiers.
- **Add a fail-closed fallback:** an ordered `git … push` (or literal `eval`/`bash -c`/`xargs git` push
  payload) the parser cannot cleanly resolve → **CONFIRM** (ask), never silent `exit 0`. Key on `git…push`
  **order**, not co-occurrence (verified false-positive boundary: passes `git commit -m '…push…'`,
  `npm run push-docs`).
- **Fix H1 in the same change** (force-via-`+`-refspec + `+`-strip on TARGET_BRANCH) — same parse path.
- **Ship RED→GREEN behavioral tests** for each bypass class + the no-false-positive set + extractor-correctness,
  and confirm the existing push-gate suites stay green (run solo — the G17 spawn-tax contention caveat applies).
- **Keep the honesty labels:** agent-Bash-tool guard, fail-open without config, server-side is the ceiling;
  and state the irreducible residual (runtime-assembled / aliased pushes whose tokens never appear literally).

**Read-only design. No code written, nothing changed, nothing committed. v0.9.0 = `1651ecc` untouched.**
