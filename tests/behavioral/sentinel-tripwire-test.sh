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
  json="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"${cmd}\"}}"
  OUT="$(printf '%s' "$json" | bash "$HOOK" 2>&1)"; RC=$?
}

# ── Workspace: temp dir with an EXISTING CLAUDE.md (no sentinel) ──────────────
TMP="$(mktemp -d)"
echo existing-content > "$TMP/CLAUDE.md"
cd "$TMP"

# G1 + G2: Write to existing CLAUDE.md → block, and block output is de-steered.
WJSON="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/CLAUDE.md\",\"content\":\"x\"}}"
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

echo ""
echo "sentinel-tripwire tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
