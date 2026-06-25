#!/usr/bin/env bash
# Behavioral regression for the CPSL repository-target incident — against the INSTALLED artifact.
#
# THE INCIDENT: on an inverted migration clone (origin = legacy production United-Airlines-Org/CPSL,
# the intended target = a DIFFERENT remote 'poc' → United-Airlines-Org/cyf.cpsl_core), the executing
# pre-push/PR gate interpreted branch.remote=origin as canonical and emitted guidance that recommended
# the CPSL repository. Root cause was consumer-side configuration/installed-artifact drift, NOT a source
# defect — the shipped source blocks every incident shape WHEN the consumer config carries
# forbiddenRemotes:[origin] + forbiddenRepos:[United-Airlines-Org/CPSL] + branch.remote=poc.
#
# This test differs from pre-push-remote-guard-test.sh in three ways the incident demands:
#   1. It installs the framework into a temp consumer via tools/preflight-install.sh and exercises the
#      INSTALLED .claude/hooks/pre-push-gate-check — NOT only the source hook (Phase-4 requirement #10:
#      "the final test operates against the installed artifact"). A stale/drifted install is the actual
#      failure surface; testing only the source hook would not have caught it.
#   2. It proves DESTINATION-IDENTITY (not remote-name) is authoritative: a differently-NAMED remote whose
#      URL resolves to the CPSL slug, and a direct CPSL URL with no remote name, both HARD BLOCK.
#   3. It proves the install→verify→tamper→reinstall lifecycle: a fresh install verifies clean; a tampered
#      installed hook is detected as DRIFT by preflight-verify.sh (exit 1); reinstall restores it.
#
# Remote NAMES are aliases; repository IDENTITY (the resolved owner/repo slug) is what the guard forbids.
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.
#
# NOTE on the G17 spawn-tax (this Windows/Git-Bash host): the hook makes dozens of git/jq spawns and the
# full Layer-1 self-watchdog body can exceed its 8s deadline on a slow-spawn host, fail-CLOSED (rc=124→2).
# To isolate the DECISION logic (the thing under test) from the watchdog timer — exactly as the sibling
# pre-push tests do — we drive the installed hook body directly with _PFG_WATCHDOG_CHILD=1.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL="$ROOT/tools/preflight-install.sh"
VERIFY="$ROOT/tools/preflight-verify.sh"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }
fin() { echo ""; echo "pre-push-installed-cpsl-incident tests: ${PASS} passed, ${FAIL} failed"; [ "$FAIL" -eq 0 ]; }

[ -f "$INSTALL" ] || { bad "missing installer $INSTALL"; fin; exit $?; }
[ -f "$VERIFY" ]  || { bad "missing verifier $VERIFY"; fin; exit $?; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git required"; fin; exit 0; }

LEGACY_URL="https://github.com/United-Airlines-Org/CPSL.git"          # forbidden / legacy prod
TARGET_URL="https://github.com/United-Airlines-Org/cyf.cpsl_core.git" # the intended migration target
LEGACY_SLUG="United-Airlines-Org/CPSL"
TARGET_SLUG="United-Airlines-Org/cyf.cpsl_core"

# ── Build an inverted-topology consumer and INSTALL the framework into it ──────
CONS="$(mktemp -d)/consumer"; mkdir -p "$CONS"
(
  cd "$CONS"
  git init -q; git config user.email t@t; git config user.name t
  git remote add origin "$LEGACY_URL"     # origin = LEGACY PROD (forbidden) — the inversion
  git remote add poc    "$TARGET_URL"     # poc    = the intended target
  git remote add cpsl_alias "$LEGACY_URL" # a differently-NAMED remote that resolves to CPSL
  echo x > f; git add -A; git commit -qm init
  git checkout -q -b AccountLookUp_POC
) >/dev/null 2>&1

# Install the framework from HEAD (reads committed git objects). Slow on this host (spawn tax) but bounded.
if ! bash "$INSTALL" "$CONS" HEAD >/tmp/.cpsl_install.out 2>&1; then
  bad "preflight-install.sh failed (see /tmp/.cpsl_install.out): $(tail -1 /tmp/.cpsl_install.out)"
  fin; exit $?
fi
HOOK="$CONS/.claude/hooks/pre-push-gate-check"
[ -f "$HOOK" ] || { bad "installed hook missing at $HOOK after install"; fin; exit $?; }

# The CONSUMER's clone-local correct config: branch.remote=poc, forbid origin + the CPSL slug.
# (This is the configuration whose ABSENCE/incorrectness was the incident's root cause. We write it as the
#  committed config.json here; on a real clone whose committed topology differs, it belongs in the
#  gitignored .preflight/config.local.json — covered by config-local-overlay-test.sh.)
mkdir -p "$CONS/.preflight"
cat > "$CONS/.preflight/config.json" <<JSON
{ "branch": { "base": "main", "remote": "poc",
              "forbiddenRemotes": ["origin", "cpsl_alias"],
              "forbiddenRepos": ["${LEGACY_SLUG}"] } }
JSON

# run_installed <command> → sets RC, OUT. DECISION-LOGIC probe (P0 split): the installed
# pre-push-gate-check is now a thin SHIM that execs the router, which runs the engine under a
# platform-derived candidate DEADLINE (~23s). On a slow scan-on-exec host the engine's full
# forbidden-resolution can exceed that deadline, so going through the shim/router would BLOCK via the
# DEADLINE (still exit 2, fail-closed) rather than emit the precise FORBIDDEN verdict this test asserts.
# To probe the DECISION (as the old _PFG_WATCHDOG_CHILD=1 did for the monolith), drive the installed ENGINE
# body DIRECTLY with a generous timeout when it exists; fall back to the shim for older installs. Either way
# RC/OUT reflect the real adjudication, isolated from the router's wall-clock deadline.
ENGINE_HOOK="$CONS/.claude/hooks/pre-push-gate-engine"
_run_to="${PREFLIGHT_CPSL_PROBE_TIMEOUT:-220}"
run_installed() {
  local cmd="$1" json target
  json="$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$cmd")"
  if [ -f "$ENGINE_HOOK" ]; then target="$ENGINE_HOOK"; else target="$HOOK"; fi
  if command -v timeout >/dev/null 2>&1; then
    OUT="$(cd "$CONS" && printf '%s' "$json" | _PFG_WATCHDOG_CHILD=1 CLAUDE_PROJECT_DIR="$CONS" timeout "$_run_to" bash "$target" 2>&1)"; RC=$?
  else
    OUT="$(cd "$CONS" && printf '%s' "$json" | _PFG_WATCHDOG_CHILD=1 CLAUDE_PROJECT_DIR="$CONS" bash "$target" 2>&1)"; RC=$?
  fi
}
# Dangerous steering = a line (other than the echoed blocked command) that RECOMMENDS using origin/CPSL.
steers() { printf '%s' "$1" | grep -vE "^BLOCKED: '?(gh pr create|git push)" \
            | grep -qiE "use '?(origin|cpsl)|push to (origin|cpsl)|target (origin|the canonical|cpsl)|retry against|recommend"; }

STEER=0

echo "════════ CPSL incident — against the INSTALLED artifact ($HOOK) ════════"

# 1. Explicit SAFE PR repo succeeds.
run_installed "gh pr create --repo ${TARGET_SLUG} --base AccountLookUp_POC"
steers "$OUT" && STEER=1
[ "$RC" -eq 0 ] && ok "1. gh pr create --repo <cyf.cpsl_core> (safe) -> ALLOW exit 0" \
               || bad "1. safe PR: expected exit 0, got $RC ($OUT)"

# 2. Explicit FORBIDDEN PR repo hard blocks.
run_installed "gh pr create --repo ${LEGACY_SLUG} --base AccountLookUp_POC"
steers "$OUT" && STEER=1
{ [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qi 'FORBIDDEN'; } \
  && ok "2. gh pr create --repo <CPSL> (forbidden) -> BLOCK exit 2" \
  || bad "2. forbidden PR: expected BLOCK(2)+FORBIDDEN, got $RC ($OUT)"

# 3. Implicit PR resolution to legacy origin blocks.
run_installed "gh pr create --base AccountLookUp_POC"
steers "$OUT" && STEER=1
[ "$RC" -eq 2 ] && ok "3. gh pr create (no --repo → origin=CPSL) -> BLOCK exit 2" \
               || bad "3. implicit-origin PR: expected BLOCK(2), got $RC ($OUT)"

# 4. Correct 'poc' push PASSES the destination guard (a later evidence gate may still block — that is OK).
run_installed "git push poc HEAD:AccountLookUp_POC"
if printf '%s' "$OUT" | grep -qiE 'FORBIDDEN|non-canonical|configured remote'; then
  bad "4. git push poc: wrongly caught by the destination guard ($OUT)"
else
  ok "4. git push poc (intended target) passes the destination guard (falls through to evidence gate)"
fi

# 5. Legacy 'origin' push hard blocks as forbidden.
run_installed "git push origin HEAD:AccountLookUp_POC"
steers "$OUT" && STEER=1
{ [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qi 'FORBIDDEN'; } \
  && ok "5. git push origin (legacy CPSL) -> BLOCK exit 2 (FORBIDDEN)" \
  || bad "5. origin push: expected BLOCK(2)+FORBIDDEN, got $RC ($OUT)"

# 6a. A remote ALIAS (different name) whose URL resolves to the CPSL slug hard blocks (identity, not name).
run_installed "git push cpsl_alias HEAD:AccountLookUp_POC"
steers "$OUT" && STEER=1
{ [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qi 'FORBIDDEN'; } \
  && ok "6a. git push cpsl_alias (alias → CPSL.git) -> BLOCK exit 2 (resolved-slug identity, not the name)" \
  || bad "6a. alias push: expected BLOCK(2)+FORBIDDEN, got $RC ($OUT)"

# 6b. A direct CPSL URL (no remote name at all) hard blocks.
run_installed "git push ${LEGACY_URL} HEAD:AccountLookUp_POC"
steers "$OUT" && STEER=1
{ [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qi 'FORBIDDEN'; } \
  && ok "6b. git push <direct CPSL URL> -> BLOCK exit 2 (FORBIDDEN)" \
  || bad "6b. direct-URL push: expected BLOCK(2)+FORBIDDEN, got $RC ($OUT)"

# 7. No block message contained dangerous steering toward origin/CPSL.
[ "$STEER" -eq 0 ] && ok "7. no block message recommended origin/CPSL (de-steered across all cases)" \
                   || bad "7. a block message recommended the forbidden remote/repo (dangerous steering)"

echo "──── install lifecycle (drift detection + reinstall restoration) ────"

# 8. A fresh install verifies clean — OR is STALE (a newer tag exists). Both are NON-drift: exit 0 or 2.
#    A drift/missing-manifest failure (exit 1) here would be the defect. (config.json we added is not a
#    manifest-tracked artifact, so it does not register as drift.)
bash "$VERIFY" "$CONS" >/tmp/.cpsl_verify1.out 2>&1; V1=$?
{ [ "$V1" -eq 0 ] || [ "$V1" -eq 2 ]; } \
  && ok "8. fresh install verifies clean (exit $V1: 0=PASS / 2=STALE-newer-tag; not a drift FAIL)" \
  || bad "8. fresh install: expected verify exit 0 or 2, got $V1 ($(tail -1 /tmp/.cpsl_verify1.out))"

# 9. Tamper the installed hook → verifier detects DRIFT (exit 1) → reinstall restores it (verify clean again).
printf '\n# TAMPER: simulated drift\n' >> "$HOOK"
bash "$VERIFY" "$CONS" >/tmp/.cpsl_verify2.out 2>&1; V2=$?
TAMPER_CAUGHT=0
{ [ "$V2" -eq 1 ] && grep -qi 'drift' /tmp/.cpsl_verify2.out; } && TAMPER_CAUGHT=1
[ "$TAMPER_CAUGHT" -eq 1 ] \
  && ok "9a. tampered installed hook detected as DRIFT by preflight-verify.sh (exit 1)" \
  || bad "9a. tamper: expected verify drift exit 1, got $V2 ($(grep -i drift /tmp/.cpsl_verify2.out | head -1))"

# Reinstall restores the intended hook (byte-identical to the source blob) and the overlay lib.
if bash "$INSTALL" "$CONS" HEAD >/tmp/.cpsl_reinstall.out 2>&1; then
  SRC_BLOB="$(git -C "$ROOT" rev-parse HEAD:hooks/pre-push-gate-check 2>/dev/null)"
  NEW_BLOB="$(git hash-object "$HOOK" 2>/dev/null)"
  OVL="$CONS/.claude/lib/config-overlay.sh"
  { [ "$SRC_BLOB" = "$NEW_BLOB" ] && [ -f "$OVL" ]; } \
    && ok "9b. reinstall restored pre-push-gate-check (byte-identical to source) + config-overlay.sh" \
    || bad "9b. reinstall: hook blob src=$SRC_BLOB new=$NEW_BLOB overlay=$([ -f "$OVL" ] && echo present || echo MISSING)"
else
  bad "9b. reinstall failed: $(tail -1 /tmp/.cpsl_reinstall.out)"
fi

# 10. Re-confirm the RESTORED installed artifact still blocks the forbidden push (operates on installed, not source).
mkdir -p "$CONS/.preflight"
cat > "$CONS/.preflight/config.json" <<JSON
{ "branch": { "base": "main", "remote": "poc",
              "forbiddenRemotes": ["origin", "cpsl_alias"],
              "forbiddenRepos": ["${LEGACY_SLUG}"] } }
JSON
run_installed "git push origin HEAD:AccountLookUp_POC"
{ [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qi 'FORBIDDEN'; } \
  && ok "10. RESTORED installed hook still BLOCKs the forbidden origin→CPSL push (exit 2)" \
  || bad "10. restored hook: expected BLOCK(2)+FORBIDDEN, got $RC ($OUT)"

fin; exit $?
