#!/usr/bin/env bash
# Behavioral test for the coupled-edit-gate matcher registration (M13).
#
# THE BUG (FRAMEWORK-SCRUTINY-FINDINGS M13): coupled-edit-gate was registered ONLY under the `Edit` matcher
# in hooks.json, so a whole-file `Write` (or a MultiEdit) to a coupled file in an unacknowledged group was
# NEVER routed to the gate — the "mechanical enforcement of read-ALL-before-fixing-ANY" had a Write-tool
# bypass. The gate BODY already handles the Write shape (it reads only tool_input.file_path, which Write
# carries; it never touches old_string/new_string), so the gap was purely the matcher registration.
#
# THE FIX: register coupled-edit-gate under BOTH the `Write` matcher and an `Edit|MultiEdit` matcher (mirror
# bootstrap-write-gate / adjudication-output-gate, already under both Write and Edit). Plus a fix-and-close
# SKILL.md honesty note that the Bash-shell mutation seam (sed -i / tee / >) remains ungated.
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOKS_JSON="$ROOT/hooks/hooks.json"
GATE="$ROOT/hooks/coupled-edit-gate"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

for f in "$HOOKS_JSON" "$GATE"; do
  [ -f "$f" ] || { bad "missing $f"; echo ""; echo "coupled-edit-matcher tests: ${PASS} passed, ${FAIL} failed"; exit 1; }
done

# ── Registration assertions (the M13 core) — coupled-edit-gate under Write AND Edit(|MultiEdit) ──
if command -v jq &>/dev/null; then
  MATCHERS=$(jq -r '.hooks.PreToolUse[] | select(.hooks[].command | contains("coupled-edit-gate")) | .matcher' "$HOOKS_JSON")
  echo "$MATCHERS" | grep -qx "Write" \
    && ok "M13: coupled-edit-gate registered under the Write matcher (was Edit-only)" \
    || bad "M13: coupled-edit-gate NOT registered under Write — matchers seen: $(echo "$MATCHERS" | tr '\n' ' ')"
  if echo "$MATCHERS" | grep -qE '(^|\|)Edit(\||$)'; then
    ok "M13: coupled-edit-gate still registered under an Edit matcher (regression baseline kept)"
  else
    bad "M13: coupled-edit-gate lost its Edit registration — matchers: $(echo "$MATCHERS" | tr '\n' ' ')"
  fi
  # MultiEdit coverage (the in-place mutation tool referenced by adjudication-output-gate).
  echo "$MATCHERS" | grep -q "MultiEdit" \
    && ok "M13: coupled-edit-gate covers MultiEdit (matcher includes MultiEdit)" \
    || bad "M13: coupled-edit-gate does not cover MultiEdit — matchers: $(echo "$MATCHERS" | tr '\n' ' ')"
  # hooks.json stays valid JSON (the merge into consumer settings.json depends on it).
  jq empty "$HOOKS_JSON" >/dev/null 2>&1 && ok "M13: hooks.json is still valid JSON after the matcher change" \
                                          || bad "M13: hooks.json is no longer valid JSON"
else
  bad "M13: jq unavailable — cannot assert matcher registration"
fi

# ── Behavioral: a WRITE to a coupled file in an unacknowledged group is BLOCKED by the gate body ──
WS="$(mktemp -d)/repo"; mkdir -p "$WS/.preflight/gate"
( cd "$WS" && git init -q ) >/dev/null 2>&1
write_rc() {  # $1 = file_path; drive the gate with a WRITE-shape tool_input (file_path + content, no old/new_string)
  ( cd "$WS" && printf '%s' "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$1\",\"content\":\"whole file rewrite\"}}" | bash "$GATE" >/dev/null 2>&1; echo $? )
}
printf '[{"files":["Services/TokenProvider.cs"],"findings":["x"],"acknowledged":false}]' > "$WS/.preflight/gate/active-groups.json"
[ "$(write_rc "$WS/Services/TokenProvider.cs")" = 2 ] \
  && ok "M13: a WRITE (abs path) to a coupled file in an unacked group -> BLOCK exit 2 (gate handles the Write shape)" \
  || bad "M13: Write to a coupled file should BLOCK"
[ "$(write_rc "Services/TokenProvider.cs")" = 2 ] \
  && ok "M13: a WRITE (relative) to a coupled file in an unacked group -> BLOCK exit 2" \
  || bad "M13: Write (relative) to a coupled file should BLOCK"
# NO-FALSE-POSITIVE: Write to an unrelated file -> ALLOW.
[ "$(write_rc "$WS/Other/Unrelated.cs")" = 0 ] \
  && ok "M13-NFP: a WRITE to an unrelated (non-grouped) file -> ALLOW exit 0" \
  || bad "M13-NFP: Write to an unrelated file should ALLOW"
# NO-FALSE-POSITIVE: Write to a coupled file in an ACKNOWLEDGED group -> ALLOW.
printf '[{"files":["Services/TokenProvider.cs"],"findings":["x"],"acknowledged":true}]' > "$WS/.preflight/gate/active-groups.json"
[ "$(write_rc "Services/TokenProvider.cs")" = 0 ] \
  && ok "M13-NFP: a WRITE to a coupled file in an ACKNOWLEDGED group -> ALLOW exit 0" \
  || bad "M13-NFP: Write to a coupled file in an acked group should ALLOW"

# ── Honesty label: the SKILL.md Bash-seam note is present (the residual is labeled, not silent) ──
SKILL="$ROOT/skills/fix-and-close/SKILL.md"
if [ -f "$SKILL" ] && grep -qiE 'Bash-shell mutation|sed -i.*tee.*>|NOT intercepted' "$SKILL"; then
  ok "M13: fix-and-close SKILL.md carries the Bash-seam honesty note (residual labeled)"
else
  bad "M13: fix-and-close SKILL.md missing the Bash-seam honesty note"
fi

echo ""
echo "coupled-edit-matcher tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
