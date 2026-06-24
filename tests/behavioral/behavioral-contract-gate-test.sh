#!/usr/bin/env bash
# Behavioral test for hooks/behavioral-contract-gate — the STAGED (not-yet-wired) fail-closed mechanism
# for the "stop if no Behavioral Contract in CLAUDE.md" guard.
#
# WHY THIS TEST EXISTS — it encodes the EXACT bypass that was caught:
#   An agent, with NO '## Behavioral Contract' section in CLAUDE.md but WITH a behavior-spec.json present
#   (carrying comparison_surfaces + category_vocabulary — a machine OUTPUT, two-thirds fixed framework
#   boilerplate), declared THAT the contract and cleared the prompt-level guard it should have returned
#   BLOCKED on. This test proves: (a) the pre-fix mechanical gap was real (no WIRED hook blocks that
#   dispatch on contract grounds), and (b) the new staged hook FAILS CLOSED on it — it does NOT accept the
#   spec-output as a contract.
#
# RED -> GREEN framing for a MECHANISM:
#   RED  (BG_RED1): the bypass dispatch run through the hook WIRED today for Agent|Task spawns
#                   (rubric-validity-gate) is NOT blocked on missing-contract grounds -> the gap is open
#                   without this hook. This is the pre-fix state the bypass exploited.
#   GREEN(BG1):     the same bypass dispatch run through the NEW behavioral-contract-gate -> BLOCKED (2).
#
# Other assertions:
#   BG2 GREEN — real human-authored contract (concrete recognition pattern + non-placeholder behavior
#               list) -> ALLOWED (0). (Don't over-block legitimate contracts.)
#   BG3       — non-spec-analyst spawn (code-reviewer), even with no contract -> ALLOWED (0).
#   BG4 RED   — DRAFT contract: OPERATOR placeholder still present -> BLOCKED (2). (DRAFT == ABSENT.)
#   BG5 RED   — DRAFT contract: AUTO-DERIVED placeholder still present -> BLOCKED (2).
#   BG6 RED   — no CLAUDE.md at all -> BLOCKED (2).
#   BG7 RED   — blank recognition pattern (heading present, no content) -> BLOCKED (2).
#   BG8 RED   — namespaced 'preflight:spec-analyst' with no contract -> BLOCKED (2).
#   BG9       — WIRED: behavioral-contract-gate is registered exactly once under a PreToolUse Agent|Task
#               block in hooks/hooks.json (owner approved; fires on a real spec-analyst spawn). (Flipped
#               from the original "must be staged/absent" assertion when the owner wired the hook.)
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE="$ROOT/hooks/behavioral-contract-gate"
WIRED_AGENT_HOOK="$ROOT/hooks/rubric-validity-gate"   # the hook wired TODAY for Agent|Task spawns
HOOKS_JSON="$ROOT/hooks/hooks.json"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

if [ ! -f "$GATE" ]; then
  bad "gate not found at $GATE"; echo ""; echo "behavioral-contract-gate tests: ${PASS} passed, ${FAIL} failed"; exit 1
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# Build a temp git repo with a given CLAUDE.md body (passed on stdin) + optional behavior-spec.json.
# Returns the repo dir path.
make_repo() {
  local name="$1" with_spec="$2"
  local d="$T/$name"
  mkdir -p "$d"
  ( cd "$d" && git init -q 2>/dev/null )
  cat > "$d/CLAUDE.md"
  if [ "$with_spec" = "with-spec" ]; then
    mkdir -p "$d/.preflight/Svc"
    printf '{"service":"Svc","comparison_surfaces":["Auth / channel gate","Wire format"],"category_vocabulary":["result_code","wire_contract","wire_format","error_path","side_effect","state_transition"],"completeness_check":{"pattern":"[EWS]\\\\d{4}"}}' \
      > "$d/.preflight/Svc/behavior-spec.json"
  fi
  echo "$d"
}
make_repo_nofile() { local d="$T/$1"; mkdir -p "$d"; ( cd "$d" && git init -q 2>/dev/null ); echo "$d"; }

# Run a hook from inside a repo dir with a crafted dispatch JSON; echo the exit code.
run_hook() {
  local hook="$1" dir="$2" subagent="$3"
  ( cd "$dir" && printf '{"tool_name":"Agent","tool_input":{"subagent_type":"%s","prompt":"extract behaviors"}}' "$subagent" \
      | bash "$hook" >/dev/null 2>&1; echo $? )
}

# ─── The bypass fixture: NO contract section, but a behavior-spec.json IS present ───
BYPASS_BODY=$'# My Service Repo\n\nThis project has no Behavioral Contract section. Just prose.\n\n## Architecture\nSome description.\n'
BYPASS_REPO="$(printf '%s' "$BYPASS_BODY" | make_repo bypass with-spec)"

# RED1 (pre-fix gap): the WIRED Agent|Task hook does NOT block this dispatch on contract grounds.
RC="$(run_hook "$WIRED_AGENT_HOOK" "$BYPASS_REPO" spec-analyst)"
[ "$RC" = "0" ] && ok "BG_RED1 (pre-fix gap): wired Agent|Task hook does NOT block the bypass dispatch (rc=0) — the mechanical gap the bypass exploited is real" \
                || bad "BG_RED1: expected the wired hook to allow (0) so the gap is demonstrated, got $RC"

# GREEN1: the NEW gate BLOCKS the exact bypass — does NOT accept the behavior-spec.json as the contract.
RC="$(run_hook "$GATE" "$BYPASS_REPO" spec-analyst)"
[ "$RC" = "2" ] && ok "BG1 GREEN: behavioral-contract-gate BLOCKS the bypass (no ## Behavioral Contract + behavior-spec.json present) -> exit 2" \
                || bad "BG1: THE BYPASS STILL PASSES — expected BLOCK (2), got $RC. Spec-output was accepted as contract."

# Confirm the block message does NOT accept the spec as contract (names it as OUTPUT, not the contract).
MSG="$( ( cd "$BYPASS_REPO" && printf '{"tool_name":"Agent","tool_input":{"subagent_type":"spec-analyst"}}' | bash "$GATE" 2>&1 || true ) )"
if printf '%s' "$MSG" | grep -qi 'behavior-spec.json'; then
  ok "BG1b: block message explicitly addresses behavior-spec.json (rejects the OUTPUT-as-contract substitution)"
else
  bad "BG1b: block message should name behavior-spec.json as a rejected (OUTPUT) source"
fi

# BG2 GREEN: a real, human-authored, non-placeholder contract -> ALLOWED.
REAL_BODY=$'# My Service Repo\n\n## Behavioral Contract\n\n### Recognition pattern\n[EWS]\\d{4}\n\n### Behavior categories\n- result_code\n- wire_contract\n\n### Observable behavior list\n| W0011 | identifier present but Version empty/whitespace | 400 |\n| E0001 | channel authorization fails | 401 |\n'
REAL_REPO="$(printf '%s' "$REAL_BODY" | make_repo real no-spec)"
RC="$(run_hook "$GATE" "$REAL_REPO" spec-analyst)"
[ "$RC" = "0" ] && ok "BG2 GREEN: real authored contract (concrete recognition pattern + behavior list) -> ALLOWED (0)" \
                || bad "BG2: legitimate contract should be ALLOWED (0), got $RC — over-blocking"

# BG3: non-spec-analyst spawn -> ALLOWED even though this repo has no contract.
RC="$(run_hook "$GATE" "$BYPASS_REPO" code-reviewer)"
[ "$RC" = "0" ] && ok "BG3: non-spec-analyst spawn (code-reviewer) -> ALLOWED (0); gate only acts on spec-analyst" \
                || bad "BG3: non-spec-analyst spawn should be ALLOWED (0), got $RC"

# BG4 RED: DRAFT — OPERATOR placeholder present.
DRAFT_OP_BODY=$'# Repo\n\n## Behavioral Contract\n\n### Recognition pattern\n<!-- OPERATOR: COMPLETE if blank -->\n\n### Behavior categories\n- result_code\n'
DRAFT_OP_REPO="$(printf '%s' "$DRAFT_OP_BODY" | make_repo draftop no-spec)"
RC="$(run_hook "$GATE" "$DRAFT_OP_REPO" spec-analyst)"
[ "$RC" = "2" ] && ok "BG4 RED: DRAFT contract (OPERATOR placeholder) -> BLOCKED (2); DRAFT == ABSENT" \
                || bad "BG4: DRAFT/OPERATOR contract should be BLOCKED (2), got $RC"

# BG5 RED: DRAFT — AUTO-DERIVED placeholder present.
DRAFT_AD_BODY=$'# Repo\n\n## Behavioral Contract\n\n### Recognition pattern\n<!-- AUTO-DERIVED -- VERIFY: bootstrap proposes [EWS]\\d{4} -->\n[EWS]\\d{4}\n\n### Behavior categories\n- result_code\n'
DRAFT_AD_REPO="$(printf '%s' "$DRAFT_AD_BODY" | make_repo draftad no-spec)"
RC="$(run_hook "$GATE" "$DRAFT_AD_REPO" spec-analyst)"
[ "$RC" = "2" ] && ok "BG5 RED: DRAFT contract (AUTO-DERIVED placeholder) -> BLOCKED (2)" \
                || bad "BG5: AUTO-DERIVED DRAFT contract should be BLOCKED (2), got $RC"

# BG6 RED: no CLAUDE.md at all.
NOFILE_REPO="$(make_repo_nofile nofile)"
RC="$(run_hook "$GATE" "$NOFILE_REPO" spec-analyst)"
[ "$RC" = "2" ] && ok "BG6 RED: no CLAUDE.md -> BLOCKED (2)" \
                || bad "BG6: missing CLAUDE.md should be BLOCKED (2), got $RC"

# BG7 RED: recognition-pattern heading present but blank (no concrete pattern).
BLANK_BODY=$'# Repo\n\n## Behavioral Contract\n\n### Recognition pattern\n\n### Behavior categories\n- result_code\n\n### Observable behavior list\n| W0011 | x | 400 |\n'
BLANK_REPO="$(printf '%s' "$BLANK_BODY" | make_repo blankrec no-spec)"
RC="$(run_hook "$GATE" "$BLANK_REPO" spec-analyst)"
[ "$RC" = "2" ] && ok "BG7 RED: blank recognition pattern -> BLOCKED (2); boilerplate alone does not satisfy" \
                || bad "BG7: blank recognition pattern should be BLOCKED (2), got $RC"

# BG8 RED: namespaced subagent_type, no contract.
RC="$(run_hook "$GATE" "$BYPASS_REPO" preflight:spec-analyst)"
[ "$RC" = "2" ] && ok "BG8 RED: namespaced 'preflight:spec-analyst' with no contract -> BLOCKED (2)" \
                || bad "BG8: namespaced spec-analyst should be BLOCKED (2), got $RC"

# BG9: WIRED — the gate is now registered in hooks.json (owner approved the hook point). It must appear
# EXACTLY ONCE, under a PreToolUse "Agent|Task" matcher block (same dispatch seam as rubric-validity-gate),
# so it fires on a real spec-analyst spawn. (This assertion was flipped from "must be ABSENT/staged" when
# the owner wired the hook — see the wiring commit.)
if [ ! -f "$HOOKS_JSON" ]; then
  bad "BG9: hooks.json not found at $HOOKS_JSON"
else
  BC_COUNT="$(grep -c 'behavioral-contract-gate' "$HOOKS_JSON")"
  # Confirm it lives under an Agent|Task PreToolUse block (jq if available; else a structural grep).
  UNDER_AGENT_TASK=0
  if command -v jq &>/dev/null; then
    jq -e '.hooks.PreToolUse[] | select(.matcher=="Agent|Task") | .hooks[] | select(.command|test("behavioral-contract-gate"))' \
      "$HOOKS_JSON" >/dev/null 2>&1 && UNDER_AGENT_TASK=1
  else
    # Fallback: the gate is registered and an "Agent|Task" matcher exists in the file.
    grep -q '"Agent|Task"' "$HOOKS_JSON" && UNDER_AGENT_TASK=1
  fi
  if [ "$BC_COUNT" -eq 1 ] && [ "$UNDER_AGENT_TASK" -eq 1 ]; then
    ok "BG9: behavioral-contract-gate is WIRED exactly once under a PreToolUse Agent|Task block (owner-approved; fires on a real spec-analyst spawn)"
  else
    bad "BG9: expected behavioral-contract-gate registered exactly once (got $BC_COUNT) under an Agent|Task PreToolUse block (under_agent_task=$UNDER_AGENT_TASK)"
  fi
fi

echo ""
echo "behavioral-contract-gate tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
