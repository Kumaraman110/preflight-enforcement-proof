#!/usr/bin/env bash
# tools/preflight-selfcheck.sh — hook/gate LIVENESS self-check (issue #10).
#
# THE DEFECT CLASS THIS HUNTS: the "present-but-dead checker" — a gate that
# exists on disk but never fires (observed twice in this repo: the CI parity
# gate dead under set -e, fixed in 6ac0fb5; lib/null-boundary-lint.sh returning
# 0 findings on known-bad input, fixed in 7356d08). This tool proves, on demand
# and with REAL exit codes, that each shipped PreToolUse gate hook still:
#   BLOCKS (exit 2) on crafted known-bad stdin, and
#   ALLOWS (exit 0) on crafted known-good stdin.
# A gate that fails either direction is reported DEAD: an always-0 gate is the
# classic dead checker; an always-2 gate is an over-blocker that sessions will
# route around — both are liveness failures.
#
# USAGE:
#   tools/preflight-selfcheck.sh [HOOKS_DIR]
#     HOOKS_DIR  directory containing the gate hooks (default: <repo>/hooks
#                relative to this script). The override is what makes the
#                meta-test (tests/behavioral/selfcheck-liveness-test.sh) able
#                to point this tool at a deliberately-killed copy of hooks/.
#
# OUTPUT: one line per gate —
#   ALIVE <gate> (block=2, allow=0)
#   DEAD  <gate> (block=<rc> expected 2, allow=<rc> expected 0)   [or: hook file missing]
# then a summary line.
#
# EXIT: 0 = all gates alive · 1 = at least one gate dead · 2 = usage error.
#
# GATES COVERED (block-condition source citations — read-first, not guessed):
#   pre-push-gate-check     BLOCK hooks/pre-push-gate-check:311-317 (push to a
#                           named remote != config.branch.remote, the #6b
#                           wrong-remote guard). ALLOW :225-227 (non-push
#                           command exits 0 immediately — deliberately chosen so
#                           this tool NEVER falls through to the evidence gate
#                           `exec hooks/pre-push-gate` at :341; that hook is
#                           out of scope here).
#   bootstrap-write-gate    BLOCK hooks/bootstrap-write-gate:96-106 (Write to an
#                           EXISTING CLAUDE.md with no approval sentinel at
#                           .preflight/gate/bootstrap-write-approved; blocks
#                           before any git call). ALLOW :77-79 (unprotected
#                           file passes immediately).
#   coupled-edit-gate       BLOCK hooks/coupled-edit-gate:99-116 (Edit to a file
#                           listed in an "acknowledged": false group in
#                           .preflight/gate/active-groups.json). ALLOW :69-71
#                           (file in no group passes).
#   adjudication-output-gate BLOCK hooks/adjudication-output-gate:132-137
#                           (forbidden per-finding key, e.g. the smuggled
#                           verifiedAgainstSource, in a Write to
#                           .preflight/adjudications/*.json; node validator,
#                           fail-closed wrapper :149-153). ALLOW :156 (record
#                           with only allow-listed keys and a concrete
#                           file:line citation). NOTE: the validator requires
#                           node; on a node-less machine the gate fails CLOSED
#                           by design (:95-98), so the allow case would exit 2
#                           and be reported DEAD — that report is honest (the
#                           gate over-blocks in such an environment).
#   rubric-validity-gate    BLOCK hooks/rubric-validity-gate:115-119
#                           (code-reviewer spawn with NO preflight config in
#                           cwd). ALLOW :131-143 (config.rubric resolves to an
#                           existing file).
#
# NOT COVERED (deliberately): hooks/pre-push-gate (evidence gate) and
# hooks/write-gate-evidence — under parallel development; exercising them here
# would race that work. They need their own liveness entries once stable.
#
# ── HONESTY CEILING — read before trusting a green run ───────────────────────
# This tool proves the HOOK SCRIPTS block/allow when invoked with crafted
# stdin (real invocations, real exit codes). It CANNOT prove the Claude Code
# runtime actually invokes them: hook REGISTRATION (the hooks.json merge into
# the consumer's settings.json), the run-hook.cmd Windows shim, and the
# $TOOL_INPUT stdin plumbing are a separate liveness layer this tool does not
# reach. A gate can be ALIVE here and still dead in a live session if
# registration is broken. The registration-liveness half of issue #10 remains
# OPEN — do not read "5/5 alive" as "the gates fire in sessions".
# ──────────────────────────────────────────────────────────────────────────────

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Args / usage ──────────────────────────────────────────────────────────────
if [ "$#" -gt 1 ]; then
  echo "usage: $0 [HOOKS_DIR]" >&2
  exit 2
fi
HOOKS_DIR_RAW="${1:-$SCRIPT_DIR/../hooks}"
if [ ! -d "$HOOKS_DIR_RAW" ]; then
  echo "usage error: HOOKS_DIR '$HOOKS_DIR_RAW' is not a directory" >&2
  exit 2
fi
HOOKS_DIR="$(cd "$HOOKS_DIR_RAW" && pwd)" || { echo "usage error: cannot resolve '$HOOKS_DIR_RAW'" >&2; exit 2; }

# ── Temp workspaces (cleaned on exit) ─────────────────────────────────────────
WORK="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

ALIVE_N=0
DEAD_N=0

# run a gate: cd into $2, pipe $3 to the hook $1, return its exit code.
# pipefail is dropped inside the subshell so the pipeline status is exactly the
# HOOK's exit code (a stub that exits without reading stdin must read as its
# own code, not a printf SIGPIPE).
run_gate() {  # $1=gate-file  $2=workdir  $3=stdin-json
  ( set +o pipefail; cd "$2" && printf '%s' "$3" | bash "$HOOKS_DIR/$1" ) >/dev/null 2>&1
}

check_gate() {  # $1=gate  $2=block-wd  $3=block-json  $4=allow-wd  $5=allow-json
  local gate="$1" brc arc
  if [ ! -f "$HOOKS_DIR/$gate" ]; then
    echo "DEAD $gate (hook file missing from $HOOKS_DIR)"
    DEAD_N=$((DEAD_N+1))
    return 0
  fi
  run_gate "$gate" "$2" "$3"; brc=$?
  run_gate "$gate" "$4" "$5"; arc=$?
  if [ "$brc" -eq 2 ] && [ "$arc" -eq 0 ]; then
    echo "ALIVE $gate (block=2, allow=0)"
    ALIVE_N=$((ALIVE_N+1))
  else
    echo "DEAD $gate (block=$brc expected 2, allow=$arc expected 0)"
    DEAD_N=$((DEAD_N+1))
  fi
  return 0
}

echo "preflight gate liveness self-check"
echo "hooks dir: $HOOKS_DIR"
echo ""

# ══ 1. pre-push-gate-check ════════════════════════════════════════════════════
# Workspace: a git repo (init only — no commits needed; `git init` anchors
# `git rev-parse --show-toplevel` to THIS dir so config resolution cannot walk up
# to an enclosing repo) with .preflight/config.json setting branch.remote=poc and
# branch.forbiddenRemotes=[origin].
# BLOCK: `git push origin ...` — 'origin' is on branch.forbiddenRemotes → an
#        UNAMBIGUOUS hard BLOCK (exit 2). NOTE: a wrong-remote NAME that is merely
#        != the configured remote is now a CONFIRM/ask (a human may deliberately
#        push elsewhere), NOT a hard block — so the liveness probe uses a FORBIDDEN
#        remote, whose builtins-fast-path exit-2 block is the gate's unambiguous
#        fail-closed signal and does not depend on the sibling evidence gate being
#        runnable in this bare probe workspace.
# ALLOW: `ls` — neither a push nor a pr-create → immediate exit 0, never reaching
#        the evidence gate.
PP_WS="$WORK/prepush"
mkdir -p "$PP_WS/.preflight"
git init -q "$PP_WS" >/dev/null 2>&1 || true
printf '%s\n' '{ "branch": { "base": "main", "remote": "poc", "forbiddenRemotes": ["origin"] } }' > "$PP_WS/.preflight/config.json"
check_gate "pre-push-gate-check" \
  "$PP_WS" '{"tool_name":"Bash","tool_input":{"command":"git push origin HEAD:feature/work"}}' \
  "$PP_WS" '{"tool_name":"Bash","tool_input":{"command":"ls"}}'

# ══ 2. bootstrap-write-gate ═══════════════════════════════════════════════════
# Workspace: a dir containing an EXISTING CLAUDE.md and no approval sentinel.
# BLOCK: Write targeting that existing CLAUDE.md → sentinel check fails
#        (hooks/bootstrap-write-gate:96-106; fires before any git call, so no
#        repo is needed).
# ALLOW: Write to an unrelated file (notes.txt) → not protected → exit 0
#        (:77-79).
BOOT_WS="$WORK/bootstrap"
mkdir -p "$BOOT_WS"
printf '%s\n' '# existing build contract' > "$BOOT_WS/CLAUDE.md"
# Build the probe JSON with jq (PRODUCT FIX): $BOOT_WS is a real filesystem path, and on Windows/Git-Bash/
# MSYS/cygwin `mktemp -d` (the $WORK base) returns a BACKSLASH path (e.g. C:\Users\...\Temp\... or D:\a\...).
# Raw-interpolated, those backslashes make the probe stdin INVALID JSON, so the gate's `jq -r
# .tool_input.file_path` extraction returns empty → the gate exits 0 → this selfcheck FALSELY reports
# bootstrap-write-gate as DEAD on every Windows user's machine (block=0 expected 2). jq -n --arg escapes any
# path. (The other four gate probes use forward-slash relative literals / path-free commands, so only this
# one embedded a mktemp path and was affected.)
BOOT_BLOCK_JSON="$(jq -n --arg fp "$BOOT_WS/CLAUDE.md" '{tool_name:"Write",tool_input:{file_path:$fp,content:"# clobbered"}}')"
BOOT_ALLOW_JSON="$(jq -n --arg fp "$BOOT_WS/notes.txt" '{tool_name:"Write",tool_input:{file_path:$fp,content:"hello"}}')"
check_gate "bootstrap-write-gate" \
  "$BOOT_WS" "$BOOT_BLOCK_JSON" \
  "$BOOT_WS" "$BOOT_ALLOW_JSON"

# ══ 3. coupled-edit-gate ══════════════════════════════════════════════════════
# Workspace: .preflight/gate/active-groups.json with ONE unacknowledged group
# coupling src/Payment.cs + src/PaymentValidator.cs.
# BLOCK: Edit to src/Payment.cs — member of an "acknowledged": false group
#        (hooks/coupled-edit-gate:99-116; jq path compares normalized full
#        paths, so file_path must equal the listed entry).
# ALLOW: Edit to src/Unrelated.cs — basename not in the groups file → exit 0
#        (:69-71).
CPL_WS="$WORK/coupled"
mkdir -p "$CPL_WS/.preflight/gate"
printf '%s\n' '[{"files":["src/Payment.cs","src/PaymentValidator.cs"],"findings":["F1: coupled null-contract change"],"acknowledged":false}]' \
  > "$CPL_WS/.preflight/gate/active-groups.json"
check_gate "coupled-edit-gate" \
  "$CPL_WS" '{"tool_name":"Edit","tool_input":{"file_path":"src/Payment.cs","old_string":"a","new_string":"b"}}' \
  "$CPL_WS" '{"tool_name":"Edit","tool_input":{"file_path":"src/Unrelated.cs","old_string":"a","new_string":"b"}}'

# ══ 4. adjudication-output-gate ═══════════════════════════════════════════════
# No filesystem setup needed — the gate validates the Write payload itself.
# BLOCK: record entry smuggling the forbidden key verifiedAgainstSource (the
#        1A correctness-attestation disease) → validator rejects
#        (hooks/adjudication-output-gate:132-137, wrapper :149-153). The bare
#        prose citedEvidence would independently trip :139-145.
# ALLOW: record with only allow-listed keys and a concrete file:line citation
#        ("Legacy/PaymentService.cs:42" matches the CITES regex :125) → exit 0
#        (:156). Requires node (present-by-contract); without node the gate
#        fails closed and this allow case honestly reports DEAD/over-block.
ADJ_WS="$WORK/adjudication"
mkdir -p "$ADJ_WS"
check_gate "adjudication-output-gate" \
  "$ADJ_WS" '{"tool_name":"Write","tool_input":{"file_path":".preflight/adjudications/pr-9.json","content":"{\"adjudications\":[{\"commentId\":\"c1\",\"parentVerdict\":\"DEFENDED\",\"citedEvidence\":\"reviewed it, looks fine\",\"verifiedAgainstSource\":true}]}"}}' \
  "$ADJ_WS" '{"tool_name":"Write","tool_input":{"file_path":".preflight/adjudications/pr-9.json","content":"{\"adjudications\":[{\"commentId\":\"c1\",\"parentVerdict\":\"DEFENDED\",\"citedEvidence\":\"Legacy/PaymentService.cs:42\"}]}"}}'

# ══ 5. rubric-validity-gate ═══════════════════════════════════════════════════
# BLOCK workspace: a config with a CONFIGURED-BUT-BROKEN rubric path (points at a file that does not
#        exist) → the gate BLOCKs (a review against a phantom rubric is worse than none). This is the
#        gate's fail-closed signal that SURVIVES the G2 zero-config base-rubric fallback: an ABSENT
#        rubric now falls back to the shipped base (day-0 useful, exit 0), but a CONFIGURED path that
#        does not resolve still exit-2 blocks — that is the liveness signal, and it does not depend on
#        the base rubric being reachable from this probe workspace.
# ALLOW workspace: .preflight/config.json with "rubric": "rubric.md" and the rubric file present →
#        all paths resolve → exit 0.
RUB_BLOCK_WS="$WORK/rubric-broken"
RUB_ALLOW_WS="$WORK/rubric-ok"
mkdir -p "$RUB_BLOCK_WS/.preflight" "$RUB_ALLOW_WS/.preflight"
printf '%s\n' '{ "rubric": "does-not-exist-phantom.md" }' > "$RUB_BLOCK_WS/.preflight/config.json"
printf '%s\n' '{ "rubric": "rubric.md" }' > "$RUB_ALLOW_WS/.preflight/config.json"
printf '%s\n' '# review rubric' > "$RUB_ALLOW_WS/rubric.md"
RUB_JSON='{"tool_name":"Agent","tool_input":{"subagent_type":"code-reviewer","prompt":"review the diff"}}'
check_gate "rubric-validity-gate" \
  "$RUB_BLOCK_WS" "$RUB_JSON" \
  "$RUB_ALLOW_WS" "$RUB_JSON"

# ── Summary ───────────────────────────────────────────────────────────────────
TOTAL=$((ALIVE_N + DEAD_N))
echo ""
echo "SUMMARY: $ALIVE_N alive, $DEAD_N dead (of $TOTAL gates)"
echo "CEILING: this proves hook-script behavior on crafted stdin only. It does NOT prove"
echo "  the Claude Code runtime invokes these hooks. The FILE-LEVEL registration half is"
echo "  covered by tools/preflight-registration-check.sh (settings.json carries every"
echo "  hooks.json entry + hook files exist); the runtime-invocation slice (settings.json"
echo "  parsing, run-hook.cmd shim, \$TOOL_INPUT plumbing) remains open — issue #10."

[ "$DEAD_N" -eq 0 ] && exit 0 || exit 1
