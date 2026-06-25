#!/usr/bin/env bash
# Behavioral test for the .preflight/config.local.json per-clone topology overlay
# (issue #6 — the clean fix for the SessionToken inverted-remote topology that
# BLOCKED the correct push/PR every round of PR #95).
#
# Proves, mechanically:
#   O1. lib/config-overlay.sh resolves branch.remote from config.local.json
#       (overlay 'poc' over committed 'origin') — ALLOWLISTED key honored.
#   O2. an overlay trying to LOWER test.coverageBaseline is IGNORED (committed
#       96.0 wins over local 10.0) and a warning names the ignored key —
#       gate thresholds are NEVER weakened by a clone-local file.
#   O3. hooks/pre-push-gate-engine honors the overlay: `git push poc ...` (the
#       CORRECT target, blocked every round live) now passes the remote guard
#       (falls through to the evidence gate — no FORBIDDEN/non-canonical block).
#   O4. the overlay CANNOT weaken the guard: local sets forbiddenRemotes=[],
#       but push to origin (legacy prod) is STILL BLOCKED — forbidden lists are
#       read from committed config only, deliberately not overlaid.
#   O5. `gh pr create --repo <correct target>` is ALLOWED with the overlay
#       (this was live CASE-2: blocked every round).
#   O6. `gh pr create` with no --repo (resolves to origin=legacy) STILL BLOCKED.
#   O7. bootstrap-write-gate does NOT trip on writes to config.local.json
#       (basename != config.json — per design, the overlay needs no approval
#       sentinel; that's the point of a per-clone uncommitted file).
#   O8. single-source gitignore wiring: BOTH defaults/preflight-gitignore and
#       the installer's REQUIRED_IGNORES carry config.local.json (CLAUDE.md
#       rule 5 — the dual-source divergence class).
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$ROOT/hooks/pre-push-gate-engine"
WRITE_GATE="$ROOT/hooks/bootstrap-write-gate"
OVERLAY_LIB="$ROOT/lib/config-overlay.sh"

LEGACY_URL="https://github.com/United-Airlines-Org/CPSL.git"          # legacy prod (forbidden)
TARGET_URL="https://github.com/United-Airlines-Org/cyf.cpsl_core.git" # the real migration target
LEGACY_SLUG="United-Airlines-Org/CPSL"
TARGET_SLUG="United-Airlines-Org/cyf.cpsl_core"

PASS=0; FAIL=0
ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

run_hook() {
  local cmd="$1" json
  json="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"${cmd}\"}}"
  # _PFG_WATCHDOG_CHILD=1 drives the hook BODY directly, bypassing the Layer-1 self-watchdog re-exec —
  # same posture as the sibling pre-push-*-test.sh helpers. This isolates the DECISION logic (what is
  # under test) from the watchdog's 8s deadline: on a slow-subprocess-spawn host (this Windows/Git-Bash
  # box, ~1s/spawn under endpoint scan-on-exec) a NORMAL full-body run makes dozens of git/jq spawns and
  # exceeds the deadline, fail-CLOSED (rc=124->2) — which would mask the decision result behind an
  # environment artifact (observed: O4/O5 false-failed with the watchdog timeout, not a logic error).
  # The watchdog's own fail-closed behavior is covered separately by pre-push-wedge-failclosed-test.sh.
  OUT="$(printf '%s' "$json" | _PFG_WATCHDOG_CHILD=1 bash "$HOOK" 2>&1)"; RC=$?
}

# ── Build the inverted-topology repo WITH the overlay ─────────────────────────
TD="$(mktemp -d)/inverted"; mkdir -p "$TD"; ( cd "$TD"
  git init -q; git config user.email t@t; git config user.name t
  git remote add origin "$LEGACY_URL"     # origin = LEGACY PROD (forbidden)
  git remote add poc    "$TARGET_URL"     # poc    = the real target
  mkdir -p .preflight
  # The committed (wrong/inverted) config — exactly the live consumer's shape.
  cat > .preflight/config.json <<JSON
{ "branch": { "base": "AccountLookUp_POC", "remote": "origin",
              "forbiddenRemotes": ["origin"],
              "forbiddenRepos": ["${LEGACY_SLUG}"] },
  "test":   { "command": "dotnet test", "coverageBaseline": 96.0 } }
JSON
  # The per-clone overlay: corrects branch.remote (ALLOWLISTED), and ALSO tries
  # two attacks that MUST be ignored: weakening coverageBaseline and clearing
  # forbiddenRemotes.
  cat > .preflight/config.local.json <<JSON
{ "branch": { "remote": "poc", "forbiddenRemotes": [] },
  "test":   { "coverageBaseline": 10.0 } }
JSON
  echo x > f; git add -A; git commit -qm init
  git checkout -q -b feature/work
) >/dev/null 2>&1

cd "$TD"

# ── O1/O2: the lib resolver ───────────────────────────────────────────────────
if [ -f "$OVERLAY_LIB" ]; then
  V="$(bash "$OVERLAY_LIB" branch.remote 2>/dev/null)"
  if [ "$V" = "poc" ]; then
    ok "O1: overlay branch.remote=poc honored by lib/config-overlay.sh"
  else bad "O1: expected 'poc', got '$V'"; fi

  ERR="$(bash "$OVERLAY_LIB" test.coverageBaseline 2>&1 >/dev/null)"
  V="$(bash "$OVERLAY_LIB" test.coverageBaseline 2>/dev/null)"
  if [ "$V" = "96.0" ] || [ "$V" = "96" ]; then
    ok "O2a: overlay attempt to lower test.coverageBaseline IGNORED (committed 96.0 wins)"
  else bad "O2a: expected committed 96.0, got '$V' (local 10.0 must NOT win)"; fi
  if printf '%s' "$ERR" | grep -qi "ignor"; then
    ok "O2b: ignored non-allowlisted local key is surfaced as a warning"
  else bad "O2b: no warning emitted for ignored local key. stderr: $ERR"; fi
else
  bad "O1: lib/config-overlay.sh does not exist"
  bad "O2a: lib/config-overlay.sh does not exist"
  bad "O2b: lib/config-overlay.sh does not exist"
fi

# ── O3: the CORRECT push is no longer caught by the remote guard ─────────────
run_hook 'git push poc HEAD:AccountLookUp_POC'
if printf '%s' "$OUT" | grep -qiE 'FORBIDDEN|non-canonical|configured remote'; then
  bad "O3: correct 'git push poc' still caught by the remote guard: $OUT"
else
  ok "O3: correct 'git push poc' passes the remote guard (falls through to evidence gate)"
fi

# ── O4: the overlay cannot weaken the guard ──────────────────────────────────
# local forbiddenRemotes=[] must be IGNORED: origin (legacy) stays forbidden.
run_hook 'git push origin HEAD:AccountLookUp_POC'
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qi 'FORBIDDEN'; then
  ok "O4: push to legacy 'origin' STILL BLOCKED — local cannot clear forbiddenRemotes"
else bad "O4: expected BLOCK(2)+FORBIDDEN, got RC=$RC OUT=$OUT"; fi

# ── O5: pr-create to the CORRECT repo is allowed ──────────────────────────────
run_hook "gh pr create --repo ${TARGET_SLUG} --base AccountLookUp_POC"
if [ "$RC" -eq 0 ]; then
  ok "O5: 'gh pr create --repo <correct target>' ALLOWED with the overlay (was blocked live)"
else bad "O5: expected ALLOW(0), got RC=$RC OUT=$OUT"; fi

# ── O6: pr-create resolving to legacy origin is still blocked ─────────────────
run_hook 'gh pr create --base AccountLookUp_POC'
if [ "$RC" -eq 2 ]; then
  ok "O6: 'gh pr create' (no --repo → legacy origin) STILL BLOCKED"
else bad "O6: expected BLOCK(2), got RC=$RC OUT=$OUT"; fi

# ── O7: bootstrap-write-gate does not trip on the overlay file ────────────────
WG_JSON="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TD/.preflight/config.local.json\",\"content\":\"{}\"}}"
printf '%s' "$WG_JSON" | bash "$WRITE_GATE" >/dev/null 2>&1; WG_RC=$?
if [ "$WG_RC" -eq 0 ]; then
  ok "O7: bootstrap-write-gate allows writes to config.local.json (no sentinel needed)"
else bad "O7: write-gate blocked config.local.json write (RC=$WG_RC) — overlay must be writable per-clone"; fi

# ── O8: single-source gitignore wiring (both surfaces) ────────────────────────
if grep -q '^config\.local\.json' "$ROOT/defaults/preflight-gitignore" 2>/dev/null; then
  ok "O8a: defaults/preflight-gitignore ignores config.local.json"
else bad "O8a: defaults/preflight-gitignore missing config.local.json"; fi
if grep -q 'config\.local\.json' "$ROOT/tools/preflight-install.sh" 2>/dev/null; then
  ok "O8b: installer REQUIRED_IGNORES carries config.local.json"
else bad "O8b: tools/preflight-install.sh REQUIRED_IGNORES missing config.local.json"; fi

echo ""
echo "config-local-overlay tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
