#!/usr/bin/env bash
# cli-usability-test.sh — the v0.10.0 usable-CLI surface (init --local / disable / status / doctor / launcher).
#
# Proves a NEW user can operate Preflight with simple commands and that the two hard invariants hold:
#   • `init --local` makes NO tracked change (writes only .preflight/ + a .git/info/exclude line);
#   • `disable` deactivates a repo REVERSIBLY (router fast-exits) and `init --local` re-enables it.
# Plus: the launcher is installed on PATH and execs the stable CLI; status is repo-aware (active/inactive,
# ownership, version, policy tier, health, remote-enforcement); doctor diagnoses a malformed config with a FIX.
#
# Every case runs against an ISOLATED temp HOME + temp bin dir — it NEVER touches the real ~/.claude or ~/bin.
# Exit 0 = all passed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CLI="$REPO/tools/preflight-user.sh"
REF="${PF_TEST_REF:-HEAD}"

PASS=0; FAIL=0
ok(){ echo "PASS: $1"; PASS=$((PASS+1)); }
bad(){ echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }
command -v git >/dev/null 2>&1 || { bad "no git"; echo "cli-usability: $PASS passed, $FAIL failed"; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq unavailable (install needs it)"; echo "cli-usability: 0 passed, 0 failed"; exit 0; }

RESOLVED="$(git -C "$REPO" rev-parse --verify "${REF}^{commit}" 2>/dev/null || echo HEAD)"

# ── Isolated user install with an isolated launcher bin dir ───────────────────────────────────────────
TH="$(mktemp -d)"
export PREFLIGHT_CLAUDE_HOME="$TH/.claude"
export PREFLIGHT_USER_HOME="$PREFLIGHT_CLAUDE_HOME/preflight"
export PREFLIGHT_BIN_DIR="$TH/bin"
mkdir -p "$PREFLIGHT_CLAUDE_HOME" "$PREFLIGHT_BIN_DIR"
trap 'rm -rf "$TH" 2>/dev/null || true' EXIT

bash "$CLI" install --user --ref "$RESOLVED" --source "$REPO" >/dev/null 2>&1 || { bad "install failed"; echo "cli-usability: $PASS passed, $FAIL failed"; exit 1; }
LAUNCH="$PREFLIGHT_BIN_DIR/preflight"
PF(){ bash "$LAUNCH" "$@"; }   # drive the CLI through the installed launcher (proves it works)

# ── 1. launcher installed + execs the stable CLI (version prints) ─────────────────────────────────────
[ -f "$LAUNCH" ] && ok "1 launcher installed at $LAUNCH" || bad "1 launcher not installed"
PF version 2>/dev/null | grep -qE '^v0\.' && ok "2 launcher execs CLI (version prints a vX.Y.Z)" || bad "2 launcher version failed"

# ── 3. a clean repo starts INACTIVE ───────────────────────────────────────────────────────────────────
# NOTE: capture status output to a variable BEFORE grepping. Piping `PF | grep -q` directly is unsafe under
# `set -o pipefail`: grep -q short-circuits on the first match and closes the pipe, so the producer gets
# SIGPIPE (141) and pipefail propagates that non-zero — the assertion would fail even on a correct match.
R="$(mktemp -d)/proj"; mkdir -p "$R"; ( cd "$R" && git init -q && git config user.email t@t && git config user.name t && echo hi > app.txt && git add app.txt && git commit -qm init )
S3="$(PF status --dir "$R" 2>/dev/null)"
echo "$S3" | grep -q 'active here:.*NO' && ok "3 status before init = INACTIVE" || bad "3 status before init not INACTIVE"

# ── 4. init --local activates AND makes NO tracked change ─────────────────────────────────────────────
PF init --local --dir "$R" >/dev/null 2>&1
[ -f "$R/.preflight/config.json" ] && ok "4a init created .preflight/config.json" || bad "4a config not created"
DIRTY="$(git -C "$R" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
[ "$DIRTY" = "0" ] && ok "4b init made NO tracked change (porcelain empty)" || bad "4b init dirtied the work tree ($DIRTY entries)"
grep -qxF '/.preflight/' "$R/.git/info/exclude" 2>/dev/null && ok "4c /.preflight/ added to .git/info/exclude" || bad "4c exclude not written"

# ── 5. status after init = ACTIVE + USER owner + policy tier + health ─────────────────────────────────
OUT="$(PF status --dir "$R" 2>/dev/null)"
echo "$OUT" | grep -q 'active here:.*YES'        && ok "5a status after init = ACTIVE" || bad "5a not ACTIVE"
echo "$OUT" | grep -qE 'ownership:.*USER'         && ok "5b ownership = USER"           || bad "5b ownership not USER"
echo "$OUT" | grep -qE 'policy:.*AUTO/CONFIRM/BLOCK|policy:.*STRICT' && ok "5c policy tier shown" || bad "5c policy tier missing"
echo "$OUT" | grep -qE 'runtime health:.*HEALTHY' && ok "5d runtime health = HEALTHY"   || bad "5d health not HEALTHY"
echo "$OUT" | grep -qi 'remote enforcement'       && ok "5e remote-enforcement line present" || bad "5e remote line missing"

# ── 6. doctor: clean repo → no problems ───────────────────────────────────────────────────────────────
PF doctor --dir "$R" 2>/dev/null | grep -q 'doctor: no problems detected' && ok "6 doctor clean on a healthy repo" || bad "6 doctor not clean"

# ── 7. doctor: malformed config → flagged with a FIX ──────────────────────────────────────────────────
printf '{ this is not json' > "$R/.preflight/config.json"
DOUT="$(PF doctor --dir "$R" 2>/dev/null)"
echo "$DOUT" | grep -qi 'MALFORMED' && ok "7a doctor flags malformed config" || bad "7a malformed not flagged"
echo "$DOUT" | grep -qi 'FIX:'      && ok "7b doctor prints a remediation FIX" || bad "7b no FIX line"
# restore a valid config for the disable test
printf '{"mode":"generic"}' > "$R/.preflight/config.json"

# ── 8. disable → INACTIVE + reversible; config preserved as .disabled ─────────────────────────────────
PF disable --dir "$R" >/dev/null 2>&1
[ -f "$R/.preflight/config.json.disabled" ] && [ ! -f "$R/.preflight/config.json" ] && ok "8a disable → config renamed to .disabled" || bad "8a disable did not rename"
S8="$(PF status --dir "$R" 2>/dev/null)"
echo "$S8" | grep -q 'active here:.*NO' && ok "8b status after disable = INACTIVE" || bad "8b not INACTIVE after disable"

# ── 9. router actually FAST-EXITS (exit 0) for the disabled repo (behavioral, through the dispatcher) ──
DISP="$PREFLIGHT_USER_HOME/dispatcher.cmd"
rc="$(printf '{"tool_name":"Bash","tool_input":{"command":"git push origin main"},"cwd":"%s"}' "$R" | bash "$DISP" user-preflight-router >/dev/null 2>&1; echo $?)"
[ "$rc" = "0" ] && ok "9 disabled repo: router fast-exits a push candidate (exit 0, not gated)" || bad "9 disabled repo still gated (rc=$rc)"

# ── 10. re-enable via init --local (idempotent reactivation), still no tracked change ─────────────────
PF init --local --dir "$R" >/dev/null 2>&1
[ -f "$R/.preflight/config.json" ] && ok "10a init --local re-activated the disabled repo" || bad "10a re-activate failed"
DIRTY2="$(git -C "$R" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
[ "$DIRTY2" = "0" ] && ok "10b re-activation still made NO tracked change" || bad "10b re-activation dirtied the tree ($DIRTY2)"

# ── 11. init --local is idempotent (a second call on an active repo is a no-op success) ───────────────
S11="$(PF init --local --dir "$R" 2>/dev/null)"
echo "$S11" | grep -qi 'already present\|already opted in' && ok "11 init --local idempotent (no-op on active repo)" || bad "11 init not idempotent"

echo ""
echo "cli-usability: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
