#!/usr/bin/env bash
# Behavioral test for the sentinel-mint hardening (gap #5: Option A de-steer + Bash tripwire).
#
# Proves, by feeding crafted tool JSON to the hooks and reading exit codes + stderr:
#   G1. bootstrap-write-gate still BLOCKS (exit 2) a Write to an existing CLAUDE.md
#       with no approval sentinel (validation behavior unchanged).
#   G2. its block stderr NO LONGER prints the mint recipe (no 'approvedAtHEAD',
#       no mkdir+echo sentinel recipe) — the Option A de-steer.
#   G3. pre-push-gate-check tripwire BLOCKS a shell redirection minting
#       .preflight/gate/bootstrap-write-approved (exit 2).
#   G4. tripwire BLOCKS any `write-gate-evidence parity-clean` invocation (any path
#       form) — parity-clean is human-only by convention (exit 2).
#   G5. ALLOWS legitimate agent evidence: `write-gate-evidence tests-pass` (exit 0).
#   G6. ALLOWS read-shaped reference: `cat .preflight/gate/parity-clean` (exit 0).
#   G7. ALLOWS unrelated command `ls` (exit 0 — preflight-selfcheck contract).
#   G8. BLOCKS tee / sed -i write-shaped variants targeting parity-clean (exit 2).
#
# The tripwire under test is HEURISTIC (agent Bash tool only, obfuscation-bypassable);
# this test certifies the heuristic fires on the plain-shaped cases, nothing more.
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOT="${SCRIPT_DIR}/../../hooks/bootstrap-write-gate"
HOOK="${SCRIPT_DIR}/../../hooks/pre-push-gate-check"

for h in "$BOOT" "$HOOK"; do
  [ -f "$h" ] || { echo "FAIL: hook not found at $h" >&2; exit 1; }
done

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

# run_bash_hook <command-string> → sets RC and OUT (stderr+stdout merged).
# Command strings here contain no double-quotes/backslashes → direct interpolation
# is valid JSON (same idiom as pre-push-remote-guard-test.sh; avoids per-call
# encoder subprocesses that dominate wall-clock on Windows/Git-Bash).
run_bash_hook() {
  local cmd="$1" json
  # jq-build so a command embedding a sentinel/gate path (which is a BACKSLASH path D:\a\... on a
  # windows-latest CI checkout) is escaped correctly; raw "${cmd}" interpolation made it invalid JSON there
  # → engine jq-extract failed → the tripwire write-shape was not recognized (spurious FAIL, not a defect).
  json="$(jq -n --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')"
  # _PFG_WATCHDOG_CHILD=1 drives the hook BODY directly, bypassing the Layer-1 self-watchdog re-exec —
  # same posture as the sibling pre-push-*-test.sh helpers. This isolates the tripwire DECISION logic
  # (what is under test) from the watchdog's 8s deadline, which a normal full-body run exceeds on this
  # slow-subprocess-spawn host (fail-CLOSED rc=124->2, an environment artifact, not a logic error). The
  # watchdog's own fail-closed behavior is covered by pre-push-wedge-failclosed-test.sh.
  OUT="$(printf '%s' "$json" | _PFG_WATCHDOG_CHILD=1 bash "$HOOK" 2>&1)"; RC=$?
}

# ── Workspace: temp dir with an EXISTING CLAUDE.md (no sentinel) ──────────────
TMP="$(mktemp -d)"
echo existing-content > "$TMP/CLAUDE.md"
cd "$TMP"

# G1 + G2: Write to existing CLAUDE.md → block, and block output is de-steered.
# Build the Write JSON with jq so $TMP (a cygwin backslash mktemp path on the runner) is escaped to VALID
# JSON; raw interpolation made it invalid → bootstrap-write-gate's jq extract returned empty → not-protected
# → exit 0 (the G1 'expected BLOCK got RC=0' spurious fail). Product gate is correct.
WJSON="$(jq -n --arg fp "$TMP/CLAUDE.md" '{tool_name:"Write",tool_input:{file_path:$fp,content:"x"}}')"
OUT="$(printf '%s' "$WJSON" | bash "$BOOT" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qi 'BLOCKED'; then
  ok "G1 bootstrap-write-gate still blocks Write-to-existing-CLAUDE.md (exit 2)"
else bad "G1 expected BLOCK(2), got RC=$RC OUT=$OUT"; fi

if printf '%s' "$OUT" | grep -q 'approvedAtHEAD' \
   || printf '%s' "$OUT" | grep -qE 'mkdir[^;&|]*\.preflight'; then
  bad "G2 block output STILL prints the sentinel mint recipe: $OUT"
else
  ok "G2 block output no longer prints the mint recipe (no approvedAtHEAD / mkdir+echo)"
fi

# G3: redirection minting bootstrap-write-approved → BLOCK.
run_bash_hook 'echo x > .preflight/gate/bootstrap-write-approved'
if [ "$RC" -eq 2 ]; then
  ok "G3 tripwire blocks redirect-mint of bootstrap-write-approved"
else bad "G3 expected BLOCK(2), got RC=$RC OUT=$OUT"; fi

# G4: write-gate-evidence parity-clean (two path forms) → BLOCK both.
run_bash_hook 'bash hooks/write-gate-evidence parity-clean'
RC1=$RC; OUT1=$OUT
run_bash_hook 'bash .claude/hooks/write-gate-evidence parity-clean'
if [ "$RC1" -eq 2 ] && [ "$RC" -eq 2 ]; then
  ok "G4 tripwire blocks 'write-gate-evidence parity-clean' (both path forms)"
else bad "G4 expected BLOCK(2)+BLOCK(2), got RC=$RC1/$RC OUT=$OUT1 / $OUT"; fi

# G5: legitimate agent evidence gates still pass.
run_bash_hook 'bash hooks/write-gate-evidence tests-pass'
if [ "$RC" -eq 0 ]; then
  ok "G5 'write-gate-evidence tests-pass' (legit agent evidence) is ALLOWED"
else bad "G5 expected ALLOW(0), got RC=$RC OUT=$OUT"; fi

# G6: read-shaped reference to the protected path passes.
run_bash_hook 'cat .preflight/gate/parity-clean'
if [ "$RC" -eq 0 ]; then
  ok "G6 read-shaped 'cat .preflight/gate/parity-clean' is ALLOWED"
else bad "G6 expected ALLOW(0), got RC=$RC OUT=$OUT"; fi

# G7: unrelated command passes (preflight-selfcheck allow-case contract).
run_bash_hook 'ls'
if [ "$RC" -eq 0 ]; then
  ok "G7 unrelated 'ls' is ALLOWED (selfcheck contract intact)"
else bad "G7 expected ALLOW(0), got RC=$RC OUT=$OUT"; fi

# G8: tee and sed -i write-shaped variants targeting parity-clean → BLOCK both.
run_bash_hook 'tee .preflight/gate/parity-clean <<< x'
RC1=$RC; OUT1=$OUT
run_bash_hook 'sed -i s/a/b/ .preflight/gate/parity-clean'
if [ "$RC1" -eq 2 ] && [ "$RC" -eq 2 ]; then
  ok "G8 tripwire blocks tee and sed -i mint variants of parity-clean"
else bad "G8 expected BLOCK(2)+BLOCK(2), got tee RC=$RC1 OUT=$OUT1 / sed RC=$RC OUT=$OUT"; fi

# G9: the read-shaped reference must NOT emit the 'line 244: A: unbound variable' warning. PRE-FIX, the
# variable-expansion grep was written `"\$[A-Za-z_]..."` which collapses to a bash ARITHMETIC expansion
# `$[...]` — under `set -u` it warned to stderr AND corrupted the pattern (silent fail-open). Assert the
# warning is gone (the [$] char-class fix).
run_bash_hook 'cat .preflight/gate/parity-clean'
if printf '%s' "$OUT" | grep -qi 'unbound variable'; then
  bad "G9 read-shaped command emitted an 'unbound variable' warning (the \$[ arithmetic-misparse at line 244): $OUT"
else
  ok "G9 no 'unbound variable' warning on a read-shaped command ([\$] char-class fix; arithmetic misparse closed)"
fi

# G10: a var-expanded write to the sentinel is BLOCKED (exit 2). NOTE: a `$VAR > sentinel` write is also
# caught by the redirection branch (a), which keys on the `>` regardless of the var-expansion branch — so
# this case stays blocked both pre- and post-fix. The line-244 fix's real, isolated proof is G9 (the
# stderr warning gone): the [$] char-class also REPAIRS the var-expansion pattern so it now matches
# (verified directly: OLD `$[A-Za-z_]` pattern -> no-match on `$VAR>sentinel`; NEW `[$]` pattern -> match),
# restoring defence-in-depth even if branch (a) were ever narrowed. G10 asserts the end-to-end block holds.
run_bash_hook '$MINT>.preflight/gate/parity-clean'
if [ "$RC" -eq 2 ]; then
  ok "G10 variable-expanded write '\$MINT>...parity-clean' is BLOCKED (exit 2)"
else bad "G10 expected BLOCK(2) for the var-expansion obfuscation, got RC=$RC OUT=$OUT"; fi

echo ""
echo "sentinel-tripwire tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
