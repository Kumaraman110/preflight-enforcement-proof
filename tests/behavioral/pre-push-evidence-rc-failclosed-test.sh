#!/usr/bin/env bash
# Behavioral test for the evidence-gate non-2 exit pass-through fail-open in pre-push-gate-check (G6).
#
# THE BUG (self-review G6): after running the sibling evidence gate (pre-push-gate), pre-push-gate-check
# remaps ONLY 124/137/>128 to a hard BLOCK (exit 2). A plain non-zero that is neither 2 nor >128 — e.g.
# 127 if `pre-push-gate` is missing/non-executable, or 1 from a `set -e` abort — is passed through VERBATIM
# via `exit "$EVIDENCE_RC"`. Under the PreToolUse protocol ONLY exit 2 blocks; exit 1/127 is NON-blocking,
# so the push then PROCEEDS UNGATED. The evidence gate is the core fail-closed surface; an unexpected exit
# from it must FAIL CLOSED, not wave the push through. (Same class as the parity 0/1/2/3 fix: any
# unexpected code must fail loudly, never be treated as pass.)
#
# THE PRINCIPLE (this fix family): an unexpected/unverifiable result from a safety gate must resolve to
# FAIL CLOSED (exit 2 = block), never a non-blocking pass-through.
#
# METHOD: copy the real hook into a temp dir alongside a STUB `pre-push-gate` that exits a chosen code, and
# drive the hook BODY-DIRECT (_PFG_WATCHDOG_CHILD=1). The hook resolves its sibling as
# "$(dirname "$0")/pre-push-gate", so the stub is what runs. (Body-direct also isolates the test from the
# Layer-1 watchdog, which on a timeout-equipped host would itself remap a 127 child to 2 — we are testing
# the BODY's own handling, which is also the no-timeout-host path.) The repo is set up to reach the
# evidence-gate call: a safe configured remote, unprotected branch, non-force push.
#
# RED->GREEN:
#   E1 — evidence gate exits 127 (missing/broken sibling):
#          RED  (pre-fix): hook exits 127 (non-blocking pass-through — the push proceeds UNGATED).
#          GREEN (post-fix): hook exits 2 (BLOCK) with a fail-closed diagnostic.
#   E2 — evidence gate exits 1 (a set -e abort):
#          RED  (pre-fix): hook exits 1 (non-blocking). GREEN (post-fix): hook exits 2.
#   E3 — regression: evidence gate exits 2 (a real evidence block) -> hook exits 2 (unchanged hard block).
#   E4 — regression: evidence gate exits 0 (evidence fresh) -> hook proceeds to the tier decision (exit 0).
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_HOOK="${SCRIPT_DIR}/../../hooks/pre-push-gate-engine"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

[ -f "$REAL_HOOK" ] || { bad "missing hook $REAL_HOOK"; echo ""; echo "pre-push-evidence-rc-failclosed tests: ${PASS} passed, ${FAIL} failed"; exit 1; }

# Build a target repo set up to REACH the evidence-gate call: safe configured remote (non-prod URL),
# unprotected branch, non-force push. Echoes the repo dir.
make_repo() {
  local d; d="$(mktemp -d)/repo"; mkdir -p "$d"
  ( cd "$d"
    git init -q; git config user.email t@t; git config user.name t
    git remote add origin "https://github.com/acme/app.git"   # safe, non-prod
    mkdir -p .preflight
    printf '{ "branch": { "base": "main", "remote": "origin", "forbiddenRemotes": [], "forbiddenRepos": [] } }\n' > .preflight/config.json
    echo x > f; git add -A; git commit -qm init
    git checkout -q -b topic-work
  ) >/dev/null 2>&1
  printf '%s' "$d"
}

# Run the real hook from a temp dir whose sibling pre-push-gate is a STUB that exits $1. Sets RC and OUT.
# $2 = the push command. Returns the hook's exit code in RC.
run_with_stub_evidence() {  # $1 = stub exit code ; $2 = repo dir
  local code="$1" repo="$2" hd
  hd="$(mktemp -d)/hookdir"; mkdir -p "$hd"
  cp "$REAL_HOOK" "$hd/pre-push-gate-engine"
  printf '#!/usr/bin/env bash\nexit %s\n' "$code" > "$hd/pre-push-gate"
  chmod +x "$hd/pre-push-gate" 2>/dev/null || true
  local json="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push origin HEAD:topic-work\"}}"
  OUT="$( cd "$repo" && printf '%s' "$json" | _PFG_WATCHDOG_CHILD=1 bash "$hd/pre-push-gate-engine" 2>&1 )"; RC=$?
}

REPO="$(make_repo)"

# ── E1 (RED->GREEN): evidence gate exits 127 -> hook must BLOCK (exit 2), not pass 127 through ──
run_with_stub_evidence 127 "$REPO"
if [ "$RC" -eq 2 ]; then
  ok "E1: evidence gate exit 127 (missing/broken sibling) -> hook BLOCKS (exit 2), not a non-blocking pass-through"
else
  bad "E1: FAIL-OPEN — evidence-gate 127 passed through as exit $RC (non-blocking under PreToolUse; pre-fix=127)"
fi

# ── E2 (RED->GREEN): evidence gate exits 1 (set -e abort) -> hook must BLOCK (exit 2) ──
run_with_stub_evidence 1 "$REPO"
if [ "$RC" -eq 2 ]; then
  ok "E2: evidence gate exit 1 (set -e abort) -> hook BLOCKS (exit 2), not a non-blocking pass-through"
else
  bad "E2: FAIL-OPEN — evidence-gate 1 passed through as exit $RC (non-blocking; pre-fix=1)"
fi

# ── E3 (regression): evidence gate exits 2 (real evidence block) -> hook exits 2 (unchanged) ──
run_with_stub_evidence 2 "$REPO"
[ "$RC" -eq 2 ] && ok "E3 regression: evidence gate exit 2 (real block) -> hook exits 2 (hard block preserved)" \
                || bad "E3 regression: evidence-gate 2 should yield hook exit 2, got $RC"

# ── E4 (regression): evidence gate exits 0 (fresh) -> hook proceeds to the tier decision (exit 0) ──
run_with_stub_evidence 0 "$REPO"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"permissionDecision"'; then
  ok "E4 regression: evidence gate exit 0 (fresh) -> hook proceeds to the tier decision (exit 0 + permissionDecision)"
else
  bad "E4 regression: evidence-gate 0 should let the hook emit a tier decision (exit 0), got RC=$RC OUT=$(printf '%s' "$OUT" | tr '\n' '|')"
fi

echo ""
echo "pre-push-evidence-rc-failclosed tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
