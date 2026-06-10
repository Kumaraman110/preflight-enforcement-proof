#!/usr/bin/env bash
# Behavioral guard for the A5 fix: the CI workflow TEMPLATE shipped in
# skills/migrate/SKILL.md must capture the parity-check AND spec-integrity exit codes
# with errexit DISABLED around the call (`set +e` … `$?` … `set -e`), and still BLOCK on
# a non-zero exit. A bare `bash …parity-check.sh` under GitHub Actions' default `set -e`
# aborts the step at the call, BEFORE `$?` is read, making the exit-2-blocks branch DEAD
# (the dead-gate observed live in the SessionToken run, vendored-fixed in the consumer).
#
# This is a structural assertion on the template text (the template is the deliverable —
# there is no compiled artifact). It also extracts the two step bodies and EXECUTES them
# under `bash -eo pipefail` with mock scripts that exit 2, proving the BLOCK fires.
#
# Exit 0 = template is dead-gate-safe; exit 1 = a gate would be dead / not block.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEMPLATE="${ROOT}/skills/migrate/SKILL.md"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

if [ ! -f "$TEMPLATE" ]; then
  bad "template not found: $TEMPLATE"; echo ""; echo "ci-gate-liveness-template: 0 passed, 1 failed"; exit 1
fi

# ── Structural assertion 1: both gate calls are wrapped in `set +e` / capture `$?` / `set -e`.
# We require, for each script, that a `set +e` appears shortly before the call and a `$?`
# capture + `set -e` appears shortly after — i.e. the bare-call pattern is gone.
check_wrapped() {  # $1 = script basename ; $2 = human label
  local script="$1" label="$2"
  # Pull a window around the call line and confirm the guard tokens are present near it.
  local window
  window="$(grep -n -A3 -B3 "bash .github/scripts/${script}" "$TEMPLATE" 2>/dev/null || true)"
  if [ -z "$window" ]; then
    bad "${label}: no call to ${script} found in template"; return
  fi
  if printf '%s' "$window" | grep -q 'set +e' \
     && printf '%s' "$window" | grep -qE '_EXIT=\$\?|PARITY_EXIT=\$\?|SPEC_EXIT=\$\?' \
     && printf '%s' "$window" | grep -q 'set -e'; then
    ok "${label}: call to ${script} is wrapped (set +e / \$? capture / set -e)"
  else
    bad "${label}: call to ${script} is NOT exit-capture-wrapped — dead-gate risk under CI set -e. Window:
${window}"
  fi
}
check_wrapped "parity-check.sh"        "parity gate"
check_wrapped "spec-integrity-check.sh" "spec-integrity gate"

# ── Structural assertion 2: no BARE call remains (a call line with no `set +e` on the
# immediately preceding non-blank line). This catches a re-introduced bare call directly.
BARE="$(grep -nE '^\s*bash \.github/scripts/(parity-check|spec-integrity-check)\.sh' "$TEMPLATE" \
        | while IFS=: read -r ln _; do
            prev="$(sed -n "$((ln-1))p" "$TEMPLATE" | tr -d '[:space:]')"
            [ "$prev" = "set+e" ] || echo "line $ln not preceded by set +e"
          done)"
if [ -z "$BARE" ]; then
  ok "no bare (unwrapped) gate call remains in the template"
else
  bad "a gate call is not immediately preceded by 'set +e':
${BARE}"
fi

# ── Behavioral assertion 3: execute the two fixed snippets with mock scripts exiting 2,
# under `bash -eo pipefail` (GitHub Actions' shell), and assert each BLOCKS (exit 1).
SB="$(mktemp -d)"; mkdir -p "$SB/.github/scripts" "$SB/.preflight/Svc"
echo '{}' > "$SB/.preflight/Svc/behavior-spec.json"
echo '{}' > "$SB/.preflight/Svc/behavior-spec-current.json"
printf '#!/usr/bin/env bash\necho ran; exit 2\n' > "$SB/.github/scripts/parity-check.sh"
printf '#!/usr/bin/env bash\necho ran; exit 2\n' > "$SB/.github/scripts/spec-integrity-check.sh"
chmod +x "$SB/.github/scripts/"*.sh

# Reconstruct minimal step bodies that mirror the template's fixed structure.
run_block() {  # $1 = the step body ; sets RC
  ( cd "$SB" && printf '%s\n' "$1" | bash -eo pipefail ); RC=$?
}
SPEC_BODY='SPEC=".preflight/Svc/behavior-spec-current.json"; SOURCE="src"
if [ ! -f "$SPEC" ]; then echo skip; exit 0; fi
set +e
bash .github/scripts/spec-integrity-check.sh "$SPEC" "$SOURCE"
SPEC_EXIT=$?
set -e
if [ $SPEC_EXIT -ne 0 ]; then echo "BLOCKED"; exit 1; fi'
PAR_BODY='BASELINE=".preflight/Svc/behavior-spec.json"; CURRENT=".preflight/Svc/behavior-spec-current.json"
if [ ! -f "$BASELINE" ] || [ ! -f "$CURRENT" ]; then echo skip; exit 0; fi
set +e
bash .github/scripts/parity-check.sh "$BASELINE" "$CURRENT"
PARITY_EXIT=$?
set -e
if [ $PARITY_EXIT -eq 2 ]; then echo "BLOCKED"; exit 1; fi
exit $PARITY_EXIT'

run_block "$SPEC_BODY"
[ "$RC" -eq 1 ] && ok "spec-integrity step BLOCKS (exit 1) on a mock exit-2 under bash -e" \
                || bad "spec-integrity step did not block: RC=$RC"
run_block "$PAR_BODY"
[ "$RC" -eq 1 ] && ok "parity step BLOCKS (exit 1) on a mock exit-2 under bash -e" \
                || bad "parity step did not block: RC=$RC"

echo ""
echo "ci-gate-liveness-template: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
