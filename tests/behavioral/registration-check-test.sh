#!/usr/bin/env bash
set -uo pipefail

# registration-check-test.sh — behavioral certification for tools/preflight-registration-check.sh
# (issue #10 / gap #26, registration-liveness half).
#
# Builds fake consumers under mktemp and proves the checker DETECTS each rot mode — not just
# that it passes a healthy consumer. R2/R3/R4/R6 are the falsification half: a checker that
# greens a broken consumer is theater.
#
# Healthy-consumer construction: REPLICATED INSTALLER MERGE. preflight-install.sh Step 6
# builds a fresh consumer's settings.json as `jq -n --argjson hooks <.hooks block> '{hooks:$hooks}'`
# (and for existing settings, `.hooks = $hooks` preserving other keys). We replicate both shapes,
# sourcing .hooks from the working-tree hooks/hooks.json (the installer reads the same file from
# the pinned ref; git is out of scope for this test). Stub hook files are DERIVED from the same
# hooks.json — nothing here hardcodes the hook list (CLAUDE.md rule 5).
#
# Scenarios:
#   R1 HEALTHY              — replicated merge + all stub hook files + run-hook.cmd  -> exit 0
#   R2 MISSING-REGISTRATION — coupled-edit-gate Edit entry stripped from settings    -> exit 1, names it
#   R3 MISSING-FILE         — registration intact, hook file deleted                 -> exit 1, names it
#   R4 NO settings.json     — clobbered consumer (a: absent, b: invalid JSON)        -> exit 1, no-hooks message
#   R5 usage                — no args                                                -> exit 2
#   R6 DERIVATION pin       — custom source w/ fake hook vs consumer built from real -> fake surfaces as MISSING
#                             (proves expectations derive from the source argument, not a hardcoded list)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CHECK="${REPO_ROOT}/tools/preflight-registration-check.sh"
SRC_HOOKS="${REPO_ROOT}/hooks/hooks.json"

PASS=0
FAIL=0

assert() {  # assert <desc> <expected_exit> <actual_exit> <output> [required_substring...]
    local desc="$1" want="$2" got="$3" out="$4"; shift 4
    local ok=1
    [ "$got" -eq "$want" ] || ok=0
    local sub
    for sub in "$@"; do
        case "$out" in *"$sub"*) ;; *) ok=0; echo "  [missing substring: ${sub}]";; esac
    done
    if [ "$ok" -eq 1 ]; then
        echo "PASS: ${desc} (exit ${got})"
        PASS=$((PASS + 1))
    else
        echo "FAIL: ${desc} — wanted exit ${want}, got ${got}"
        echo "--- output ---"; echo "$out"; echo "--------------"
        FAIL=$((FAIL + 1))
    fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Hook names DERIVED from the real source (rule 5 — no hardcoded list).
HOOK_NAMES=$(jq -r '.hooks | to_entries[] | .value[].hooks[].command
    | capture("run-hook\\.cmd\"? +(?<n>[^ \"]+)") | .n' "$SRC_HOOKS" | tr -d '\r' | sort -u)

build_consumer() {  # build_consumer <dir> — replicated installer merge + stub files
    local dir="$1"
    mkdir -p "${dir}/.claude/hooks"
    # Replicates preflight-install.sh Step 6 fresh-consumer branch:
    jq -n --argjson hooks "$(jq '.hooks' "$SRC_HOOKS")" '{hooks: $hooks}' \
        > "${dir}/.claude/settings.json"
    local n
    for n in $HOOK_NAMES; do
        printf '#!/usr/bin/env bash\n# stub %s\nexit 0\n' "$n" > "${dir}/.claude/hooks/${n}"
    done
    printf '@echo off\r\nrem stub shim\r\n' > "${dir}/.claude/hooks/run-hook.cmd"
}

echo "=== registration-check behavioral test ==="
echo ""

# ── R1: HEALTHY ────────────────────────────────────────────────────────────────
R1="${TMP}/r1"; build_consumer "$R1"
OUT=$(bash "$CHECK" "$R1" "$SRC_HOOKS" 2>&1); RC=$?
assert "R1 healthy consumer passes" 0 "$RC" "$OUT" "RESULT: PASS"
# every derived hook must show REGISTERED at least once
for n in $HOOK_NAMES; do
    case "$OUT" in *"REGISTERED"*"/${n} "*) ;; *)
        echo "FAIL: R1 missing REGISTERED line for ${n}"; FAIL=$((FAIL + 1));; esac
done
# R1b: merged-into-existing shape (installer's other branch) — extra keys present
R1B="${TMP}/r1b"; build_consumer "$R1B"
jq '. + {permissions: {allow: ["Bash(git status)"]}, "$schema": "x"}' \
    "${R1B}/.claude/settings.json" > "${R1B}/.claude/settings.json.tmp" \
    && mv "${R1B}/.claude/settings.json.tmp" "${R1B}/.claude/settings.json"
OUT=$(bash "$CHECK" "$R1B" "$SRC_HOOKS" 2>&1); RC=$?
assert "R1b healthy consumer with extra settings keys passes" 0 "$RC" "$OUT" "RESULT: PASS"

# ── R2: MISSING-REGISTRATION (coupled-edit-gate stripped from EVERY matcher it's registered under) ───
# coupled-edit-gate is registered under BOTH the Write and the Edit|MultiEdit matchers (M13 — a whole-file
# Write/MultiEdit to a coupled file must be gated, not just Edit). To genuinely test "missing registration
# detected," strip the gate from ALL hook blocks (not just one matcher) so the check sees it truly absent.
R2="${TMP}/r2"; build_consumer "$R2"
jq '(.hooks.PreToolUse[].hooks)
        |= map(select(.command | test("coupled-edit-gate") | not))' \
    "${R2}/.claude/settings.json" > "${R2}/.claude/settings.json.tmp" \
    && mv "${R2}/.claude/settings.json.tmp" "${R2}/.claude/settings.json"
OUT=$(bash "$CHECK" "$R2" "$SRC_HOOKS" 2>&1); RC=$?
assert "R2 missing registration detected" 1 "$RC" "$OUT" \
    "MISSING-REGISTRATION" "coupled-edit-gate" "RESULT: FAIL"

# ── R3: MISSING-FILE (registration present, hook file deleted) ────────────────
R3="${TMP}/r3"; build_consumer "$R3"
rm -f "${R3}/.claude/hooks/coupled-edit-gate"
OUT=$(bash "$CHECK" "$R3" "$SRC_HOOKS" 2>&1); RC=$?
assert "R3 missing hook file detected" 1 "$RC" "$OUT" \
    "MISSING-FILE" "coupled-edit-gate" "RESULT: FAIL"

# ── R4: clobbered settings.json ────────────────────────────────────────────────
R4A="${TMP}/r4a"; build_consumer "$R4A"
rm -f "${R4A}/.claude/settings.json"
OUT=$(bash "$CHECK" "$R4A" "$SRC_HOOKS" 2>&1); RC=$?
assert "R4a absent settings.json fails with no-hooks message" 1 "$RC" "$OUT" \
    "no settings.json" "NO hooks"
R4B="${TMP}/r4b"; build_consumer "$R4B"
printf 'this is not json {' > "${R4B}/.claude/settings.json"
OUT=$(bash "$CHECK" "$R4B" "$SRC_HOOKS" 2>&1); RC=$?
assert "R4b clobbered (invalid JSON) settings.json fails" 1 "$RC" "$OUT" \
    "not valid JSON" "silently dead"

# ── R5: usage error ────────────────────────────────────────────────────────────
OUT=$(bash "$CHECK" 2>&1); RC=$?
assert "R5 no args is usage error" 2 "$RC" "$OUT" "Usage:"

# ── R6: DERIVATION pin — custom source with a fake hook ───────────────────────
R6="${TMP}/r6"; build_consumer "$R6"   # consumer built from the REAL source
CUSTOM="${TMP}/custom-hooks.json"
jq '.hooks.PreToolUse += [{matcher: "Glob", hooks: [{type: "command",
        command: "\"${CLAUDE_PROJECT_DIR}/.claude/hooks/run-hook.cmd\" fake-derivation-pin-gate \"$TOOL_INPUT\"",
        timeout: 5000, async: false}]}]' "$SRC_HOOKS" > "$CUSTOM"
OUT=$(bash "$CHECK" "$R6" "$CUSTOM" 2>&1); RC=$?
assert "R6 fake hook in custom source surfaces as MISSING (derivation, not hardcode)" 1 "$RC" "$OUT" \
    "MISSING-REGISTRATION" "fake-derivation-pin-gate" "RESULT: FAIL"

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
