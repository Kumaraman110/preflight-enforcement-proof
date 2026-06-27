#!/usr/bin/env bash
# Behavioral test: gh pr merge POLICY (BLOCKER 5).
#
# `gh pr merge` lands commits on the PR's BASE (protected/integration) branch of the TARGET repo — an
# outward-facing, consequential action. The decision is DERIVED FROM COMMITTED POLICY (no new config key):
#   • target repo on config.branch.forbiddenRepos       → BLOCK (explicit denylist; e.g. legacy prod).
#   • target repo != canonical slug(config.branch.remote) → BLOCK (non-canonical / wrong repo).
#   • `--admin` (override required checks / branch protection) → BLOCK (merge analogue of force-to-protected).
#   • canonical, not-forbidden, non-admin                 → CONFIRM (ask) — consequential protected-branch
#                                                           landing; a human may proceed, NEVER silent,
#                                                           NEVER a generic timeout.
#   • a get-url wedge while resolving the target          → fail CLOSED (block) — never allow on an
#                                                           unverified target.
# The merge path must use a SAFE gh execution shim and NEVER perform a real merge.
#
# Exit 0 = all pass.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENGINE="$ROOT/hooks/pre-push-gate-engine"
[ -f "$ENGINE" ] || { echo "FAIL: engine not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required."; echo ""; echo "pre-pr-merge-policy tests: 0 passed, 0 failed (skipped)"; exit 0; }

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }
_CLEAN=(); trap 'for d in "${_CLEAN[@]}"; do rm -rf "$d" 2>/dev/null || true; done' EXIT

# Build a consumer-topology repo. $1 = optional overlay JSON written to config.local.json (else none).
mkrepo() {  # $1 = canonical remote URL for 'poc' ; $2 = optional config.local.json content
  local pocurl="${1:-https://github.com/United-Airlines-Org/cyf.cpsl_core.git}" overlay="${2:-}" r
  r="$(mktemp -d)/repo"; mkdir -p "$r"; _CLEAN+=("$(dirname "$r")")
  ( cd "$r"
    git init -q; git config user.email t@t; git config user.name t
    git remote add origin https://github.com/United-Airlines-Org/CPSL.git
    git remote add poc    "$pocurl"
    mkdir -p .preflight .preflight/gate
    printf '{"branch":{"base":"AccountLookUp_POC","remote":"poc","forbiddenRemotes":["origin"],"forbiddenRepos":["United-Airlines-Org/CPSL"]}}' > .preflight/config.json
    [ -n "$overlay" ] && printf '%s' "$overlay" > .preflight/config.local.json
    echo x > f; git add -A; git commit -qm init
    git checkout -q -b feature/registerseats-bff-l3 ) >/dev/null 2>&1
  printf '%s' "$r"
}
# safe gh shim: ANY gh invocation → marker + nonzero (no network/merge ever). non-push git → real git.
SHIM="$(mktemp -d)/shim"; mkdir -p "$SHIM"; _CLEAN+=("$(dirname "$SHIM")"); MARK="$SHIM/.m"; _rg="$(command -v git)"
cat > "$SHIM/gh" <<EOF
#!/bin/sh
echo "SHIM gh \$*">>"$MARK"; exit 9
EOF
chmod +x "$SHIM/gh"
cat > "$SHIM/git" <<EOF
#!/bin/sh
case "\$*" in *push*) echo "SHIM \$*">>"$MARK"; exit 9;; esac
exec "$_rg" "\$@"
EOF
chmod +x "$SHIM/git"

run() {  # $1 = repo ; $2 = command
  : > "$MARK"
  local j; j="$(jq -n --arg c "$2" '{tool_name:"Bash",tool_input:{command:$c}}')"
  OUT="$(cd "$1" && printf '%s' "$j" | PATH="$SHIM:$PATH" CLAUDE_PROJECT_DIR="$1" timeout 90 bash "$ENGINE" 2>&1)"; RC=$?
  if [ "$RC" -eq 2 ]; then CLS=BLOCK
  elif printf '%s' "$OUT" | grep -q '"permissionDecision":"ask"'; then CLS=ASK
  elif printf '%s' "$OUT" | grep -q '"permissionDecision":"allow"'; then CLS=ALLOW
  elif [ "$RC" -eq 0 ]; then CLS="ALLOW-silent"
  else CLS="rc=$RC"; fi
  MERGED=no; [ -s "$MARK" ] && MERGED=yes   # any gh/push shim hit = a represented merge/transport attempt
  TO=no; printf '%s' "$OUT" | grep -qiE 'FAILED to reach a policy|did not reach|rc=124' && TO=yes
}
expect() {  # $1 label ; $2 expected class
  [ "$CLS" = "$2" ] && ok "$1 → $2" || bad "$1: expected $2 got $CLS :: $(printf '%s' "$OUT"|grep -ioE 'BLOCKED[^"]*|CONSEQUENTIAL MERGE[^"]*'|head -1|cut -c1-60)"
  [ "$MERGED" = no ] || bad "$1: a represented gh/merge command EXECUTED (shim marker) — gate must decide before dispatch"
  [ "$TO" = no ] || bad "$1: decision was a generic TIMEOUT, not a policy decision (principle 5)"
}

echo "════ gh pr merge — policy-derived decisions (no generic timeout, no real merge) ════"
R="$(mkrepo)"
# CANONICAL slug = slug(branch.remote=poc) = United-Airlines-Org/cyf.cpsl_core. Use an explicit --repo for
# the CONFIRM/admin cases so we exercise the MERGE policy, not the bare-no-repo path (which resolves the cwd
# default remote 'origin' = CPSL = forbiddenRepos → BLOCK; that inverted-clone bare-default block is its own
# assertion below). canonical repo:
CANON=United-Airlines-Org/cyf.cpsl_core
# (1) requirements satisfied: canonical configured repo, no --admin → CONFIRM (consequential, human proceeds)
run "$R" "gh pr merge 12 --repo $CANON --squash";                  expect "merge canonical repo (req satisfied)" ASK
printf '%s' "$OUT" | grep -qi 'protected base branch' && ok "merge CONFIRM names the protected-base landing" || bad "merge CONFIRM lacks protected-base rationale"
# explicit --repo canonical, --merge strategy
run "$R" "gh pr merge 12 --repo $CANON --merge";                   expect "merge --repo canonical (--merge)" ASK
# (2) requirements missing is gh's own RUNTIME check — the GATE must NOT invent a universal human gate; a
#     well-formed canonical merge is CONFIRM regardless of flags (gh enforces unmet required checks at run).
run "$R" "gh pr merge 12 --repo $CANON";                           expect "canonical merge, no strategy flag (no invented gate)" ASK
# (3) protected target — the base IS protected (AccountLookUp_POC); a canonical merge → CONFIRM (never silent).
run "$R" "gh pr merge 12 --repo $CANON --rebase"
{ [ "$CLS" = ASK ]; } && ok "protected-base merge is CONFIRM, never silent-allow" || bad "protected-base merge expected ASK, got $CLS"
# (3b) bare 'gh pr merge' (no --repo) on the INVERTED clone resolves cwd default 'origin' = CPSL = FORBIDDEN
#      → BLOCK (the same inverted-clone protection as bare gh pr create). This is policy-derived, not a gate
#      invented for merge.
run "$R" "gh pr merge 12 --squash";                                expect "bare merge → resolves forbidden origin → BLOCK" BLOCK
# (4) forbidden repo (explicit) → BLOCK
run "$R" "gh pr merge 12 --repo United-Airlines-Org/CPSL --merge"; expect "merge into FORBIDDEN repo (CPSL)" BLOCK
# (5) non-canonical repo → BLOCK
run "$R" "gh pr merge 12 --repo other-org/other-repo --merge";     expect "merge into NON-CANONICAL repo" BLOCK
# (6) --admin override on the CANONICAL repo → BLOCK (so the admin check is reached, not pre-empted by the
#     forbidden/non-canonical checks).
run "$R" "gh pr merge 12 --repo $CANON --admin --merge";           expect "merge --admin (override protection)" BLOCK
printf '%s' "$OUT" | grep -qi 'admin' && ok "admin BLOCK names the override" || bad "admin BLOCK lacks --admin rationale"

echo "════ unresolved repository / wedge → fail CLOSED (never allow on an unverified target) ════"
# a git that wedges on remote get-url (so the canonical slug can't resolve) → fail-closed. Simulate via a
# git shim whose 'remote get-url' sleeps past the subprocess timeout.
WSHIM="$(mktemp -d)/wshim"; mkdir -p "$WSHIM"; _CLEAN+=("$(dirname "$WSHIM")")
cat > "$WSHIM/gh" <<EOF
#!/bin/sh
echo "SHIM gh \$*">>"$MARK"; exit 9
EOF
chmod +x "$WSHIM/gh"
cat > "$WSHIM/git" <<EOF
#!/bin/sh
case "\$*" in *"remote get-url"*) sleep 8; exit 0;; esac
exec "$_rg" "\$@"
EOF
chmod +x "$WSHIM/git"
# no --repo → must resolve origin's url (wedges) → fail closed (BLOCK), never ALLOW.
: > "$MARK"
J="$(jq -n --arg c "gh pr merge 12 --merge" '{tool_name:"Bash",tool_input:{command:$c}}')"
OUTW="$(cd "$R" && printf '%s' "$J" | PATH="$WSHIM:$PATH" CLAUDE_PROJECT_DIR="$R" timeout 90 bash "$ENGINE" 2>&1)"; RCW=$?
{ [ "$RCW" -eq 2 ] || printf '%s' "$OUTW" | grep -q '"permissionDecision":"ask"'; } \
  && ok "merge with a get-url WEDGE → fail-closed (block/confirm), never silent-allow" \
  || bad "merge with a wedge returned rc=$RCW (must fail closed, not allow): $(printf '%s' "$OUTW"|head -1|cut -c1-60)"
[ -s "$MARK" ] && bad "merge-wedge case EXECUTED a gh/merge command (shim marker)" || ok "merge-wedge case executed NO represented merge"

echo ""
echo "pre-pr-merge-policy tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
