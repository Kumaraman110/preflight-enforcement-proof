#!/usr/bin/env bash
set -uo pipefail

# preflight-registration-check.sh — FILE-LEVEL hook-registration liveness check (issue #10 / gap #26).
#
# Proves that a consumer's .claude/settings.json actually CARRIES every hook registration from
# the single registration source (hooks/hooks.json) and that every registered hook FILE exists.
# Registration rot is silent: a skipped merge, a clobbered settings.json, a pruned hook file with
# its registration left behind (or vice versa) all degrade the framework to plain-agent behavior
# with NO error. This checker closes the file-level slice of that gap.
#
# Usage:
#   ./tools/preflight-registration-check.sh <CONSUMER_DIR> [SOURCE_HOOKS_JSON]
#     SOURCE_HOOKS_JSON defaults to <script-dir>/../hooks/hooks.json
#
# SINGLE SOURCE OF TRUTH (CLAUDE.md rule 5): the expected registration set is DERIVED from
# SOURCE_HOOKS_JSON at runtime. Nothing here hardcodes a hook name, event, or matcher.
#
# Checks, per hook entry derived from the source:
#   FORWARD  (a) consumer settings.json has a registration with the same event, same matcher,
#                and a command referencing the same hook name via run-hook.cmd
#            (b) the referenced hook file exists and is non-empty in consumer .claude/hooks/
#            (c) run-hook.cmd itself exists and is non-empty in consumer .claude/hooks/
#   REVERSE  any preflight-looking registration in the consumer (command contains run-hook.cmd)
#            that is NOT in the source is reported as EXTRA-REGISTRATION (warning, not failure —
#            consumers may legitimately add their own hooks), BUT if its hook file is MISSING
#            that IS a failure: registered-but-absent = guaranteed runtime error or silent skip.
#
# Output: one line per check —
#   REGISTERED <event>/<hook> (matcher: <m>) | MISSING-REGISTRATION <…> | FILE-OK <hook> |
#   MISSING-FILE <hook> | EXTRA-REGISTRATION <…> — then a summary.
#
# Exit codes:
#   0 — all registrations present, all hook files present
#   1 — any failure (missing registration, missing/empty hook file, missing run-hook.cmd,
#       missing/invalid settings.json, missing consumer dir — a consumer without a readable
#       settings.json has NO hooks firing: the exact silent degrade this tool hunts)
#   2 — usage error, or this checker itself cannot run (jq absent, source hooks.json
#       missing/invalid) — no verdict rendered about the consumer
#
# ── HONESTY CEILING ───────────────────────────────────────────────────────────
# FILE-LEVEL check — proves registration entries and hook files exist and agree;
# CANNOT prove Claude Code parses settings.json, that run-hook.cmd resolves bash
# correctly on this machine, or that $TOOL_INPUT plumbing works at runtime.
# Pair with tools/preflight-selfcheck.sh (script-behavior half); the
# runtime-invocation slice remains open.
# ──────────────────────────────────────────────────────────────────────────────

usage() {
    echo "Usage: preflight-registration-check.sh <CONSUMER_DIR> [SOURCE_HOOKS_JSON]" >&2
}

if [ $# -lt 1 ]; then
    usage
    exit 2
fi

CONSUMER_DIR="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_HOOKS_JSON="${2:-${SCRIPT_DIR}/../hooks/hooks.json}"

# ── Preconditions of the checker itself (exit 2 — no verdict, honest not silent) ──
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not found on PATH — cannot run registration check." >&2
    echo "       (Refusing to guess: a JSON check without a JSON parser would be theater.)" >&2
    exit 2
fi

if [ ! -f "$SOURCE_HOOKS_JSON" ]; then
    echo "ERROR: source hooks.json not found: ${SOURCE_HOOKS_JSON}" >&2
    echo "       Cannot derive the expected registration set — no verdict rendered." >&2
    exit 2
fi

if ! jq empty "$SOURCE_HOOKS_JSON" 2>/dev/null; then
    echo "ERROR: source hooks.json is not valid JSON: ${SOURCE_HOOKS_JSON}" >&2
    exit 2
fi

echo "=== Preflight Registration Check (file-level) ==="
echo "Consumer: ${CONSUMER_DIR}"
echo "Source:   ${SOURCE_HOOKS_JSON}"
echo ""

FAILURES=0
WARNINGS=0
REGISTERED=0

# ── Consumer-side failures are exit 1 (a verdict: hooks will not fire) ────────
if [ ! -d "$CONSUMER_DIR" ]; then
    echo "FAIL: consumer directory does not exist: ${CONSUMER_DIR}"
    echo "No consumer => no settings.json => NO preflight hooks will fire."
    exit 1
fi
CONSUMER_DIR="$(cd "$CONSUMER_DIR" && pwd)"
SETTINGS="${CONSUMER_DIR}/.claude/settings.json"
HOOKS_DIR="${CONSUMER_DIR}/.claude/hooks"

if [ ! -f "$SETTINGS" ]; then
    echo "FAIL: no settings.json at ${SETTINGS}"
    echo "Without it Claude Code registers NO hooks — every preflight gate is silently dead"
    echo "and the framework degrades to plain-agent behavior with no error. Re-run"
    echo "tools/preflight-install.sh to restore the merged hooks block."
    exit 1
fi

if ! jq empty "$SETTINGS" 2>/dev/null; then
    echo "FAIL: ${SETTINGS} is not valid JSON (clobbered?)."
    echo "Claude Code will not load hooks from an unparseable settings.json — every"
    echo "preflight gate is silently dead. Restore or re-install."
    exit 1
fi

# ── Derive the EXPECTED set from the source (event ␟ matcher ␟ hook-name) ─────
# \u001f (unit separator) as field delimiter: matchers may contain '|' and tabs
# are IFS-whitespace (empty matcher fields would collapse).
EXTRACT='.hooks // {} | to_entries[] | .key as $event
  | .value[]? | (.matcher // "") as $matcher
  | .hooks[]? | (.command // "") as $cmd
  | select($cmd | test("run-hook\\.cmd"))
  | ($cmd | capture("run-hook\\.cmd\"? +(?<name>[^ \"]+)") | .name) as $name
  | [$event, $matcher, $name] | join("\u001f")'

# tr -d '\r': MSYS jq emits CRLF; without this the last field (hook name) carries a stray \r.
EXPECTED_LINES=$(jq -r "$EXTRACT" "$SOURCE_HOOKS_JSON" | tr -d '\r')
if [ -z "$EXPECTED_LINES" ]; then
    echo "ERROR: derived ZERO hook registrations from ${SOURCE_HOOKS_JSON} — source is empty" >&2
    echo "       or its command shape changed (expected: run-hook.cmd <hook-name> …)." >&2
    exit 2
fi

CONSUMER_LINES=$(jq -r "$EXTRACT" "$SETTINGS" | tr -d '\r')

# Index consumer registrations + collect every referenced hook name.
declare -A CONSUMER_REG=()
declare -A CONSUMER_NAMES=()
while IFS=$'\x1f' read -r event matcher name; do
    [ -n "${name:-}" ] || continue
    CONSUMER_REG["${event}"$'\x1f'"${matcher}"$'\x1f'"${name}"]=1
    CONSUMER_NAMES["$name"]=1
done <<< "$CONSUMER_LINES"

# ── FORWARD: every source registration must exist in the consumer ─────────────
declare -A EXPECTED_REG=()
declare -A EXPECTED_NAMES=()
echo "--- Registrations (source -> consumer settings.json) ---"
while IFS=$'\x1f' read -r event matcher name; do
    [ -n "${name:-}" ] || continue
    key="${event}"$'\x1f'"${matcher}"$'\x1f'"${name}"
    EXPECTED_REG["$key"]=1
    EXPECTED_NAMES["$name"]=1
    label="${event}/${name} (matcher: '${matcher}')"
    if [ -n "${CONSUMER_REG[$key]:-}" ]; then
        echo "REGISTERED            ${label}"
        REGISTERED=$((REGISTERED + 1))
    else
        echo "MISSING-REGISTRATION  ${label} — in source but NOT in consumer settings.json: this gate will NEVER fire"
        FAILURES=$((FAILURES + 1))
    fi
done <<< "$EXPECTED_LINES"
echo ""

# ── REVERSE: preflight-looking registrations in consumer not in source ────────
echo "--- Reverse (consumer registrations not in source) ---"
EXTRA=0
for key in "${!CONSUMER_REG[@]}"; do
    if [ -z "${EXPECTED_REG[$key]:-}" ]; then
        IFS=$'\x1f' read -r event matcher name <<< "$key"
        echo "EXTRA-REGISTRATION    ${event}/${name} (matcher: '${matcher}') — not in source (warning only; consumers may add their own hooks)"
        WARNINGS=$((WARNINGS + 1))
        EXTRA=$((EXTRA + 1))
    fi
done
[ "$EXTRA" -eq 0 ] && echo "(none)"
echo ""

# ── Hook FILES: every referenced hook (expected ∪ consumer-registered) ────────
# A registered-but-absent file is a FAILURE regardless of direction:
# guaranteed runtime error or silent skip.
echo "--- Hook files (consumer .claude/hooks/) ---"
declare -A ALL_NAMES=()
for n in "${!EXPECTED_NAMES[@]}"; do ALL_NAMES["$n"]=1; done
for n in "${!CONSUMER_NAMES[@]}"; do ALL_NAMES["$n"]=1; done

for name in $(printf '%s\n' "${!ALL_NAMES[@]}" | sort); do
    f="${HOOKS_DIR}/${name}"
    if [ -s "$f" ]; then
        echo "FILE-OK               ${name}"
    elif [ -f "$f" ]; then
        echo "MISSING-FILE          ${name} — exists but is EMPTY in ${HOOKS_DIR}: registered-but-hollow, runtime no-op"
        FAILURES=$((FAILURES + 1))
    else
        echo "MISSING-FILE          ${name} — registered but absent from ${HOOKS_DIR}: guaranteed runtime error or silent skip"
        FAILURES=$((FAILURES + 1))
    fi
done

# run-hook.cmd: the shim every registration's command goes through.
if [ -s "${HOOKS_DIR}/run-hook.cmd" ]; then
    echo "FILE-OK               run-hook.cmd"
else
    echo "MISSING-FILE          run-hook.cmd — every registered command routes through this shim; without it NO hook runs"
    FAILURES=$((FAILURES + 1))
fi
echo ""

# ── Summary ────────────────────────────────────────────────────────────────────
echo "=== Summary ==="
echo "Registered: ${REGISTERED}  Failures: ${FAILURES}  Warnings: ${WARNINGS}"
echo ""
echo "CEILING: FILE-LEVEL check — proves registration entries and hook files exist and"
echo "agree; CANNOT prove Claude Code parses settings.json, that run-hook.cmd resolves"
echo "bash correctly on this machine, or that \$TOOL_INPUT plumbing works at runtime."
echo "Pair with tools/preflight-selfcheck.sh (script-behavior half); the"
echo "runtime-invocation slice remains open."
echo ""

if [ "$FAILURES" -gt 0 ]; then
    echo "RESULT: FAIL (${FAILURES} failure(s))"
    exit 1
fi
echo "RESULT: PASS"
exit 0
