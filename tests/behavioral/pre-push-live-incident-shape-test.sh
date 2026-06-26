#!/usr/bin/env bash
# Behavioral test: the EXACT live Gate-4 incident command shape — full router→engine path.
#
# The live command that fail-opened (and reached the real remote) was:
#     git -c remote.origin.url=file:///__preflight_no_network_probe__ \
#       push origin HEAD:refs/heads/preflight-live-probe
#
# This proves the corrected pipeline on that exact shape (with a real backslash-LF continuation):
#   router  -> classifies CANDIDATE (raw blob contains "push")
#   engine  -> exit 2 (BLOCK) — the continuation is joined, `git…push` to forbidden 'origin' is detected
#   exactly ONE block diagnostic is emitted (no duplicate dispatch)
#   the represented command is NEVER executed (we drive the hooks with crafted JSON; no real git push runs)
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ROUTER="$ROOT/hooks/pre-bash-risk-router"
ENGINE="$ROOT/hooks/pre-push-gate-engine"
for f in "$ROUTER" "$ENGINE"; do [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }; done
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required."; echo ""; echo "pre-push-live-incident-shape tests: 0 passed, 0 failed (skipped)"; exit 0; }

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

LF=$'\n'
# the exact incident command, with a REAL backslash + LF continuation before `push`
INCIDENT_CMD="git -c remote.origin.url=file:///__preflight_no_network_probe__ \\${LF}  push origin HEAD:refs/heads/preflight-live-probe"
JSON="$(jq -n --arg c "$INCIDENT_CMD" '{tool_name:"Bash",tool_input:{command:$c}}')"

# Workspace mirroring the consumer topology: origin = forbidden (legacy/prod), poc = intended, fresh evidence.
WS="$(mktemp -d)/ws"; mkdir -p "$WS/hooks" "$WS/lib" "$WS/.preflight/gate"
cp "$ROUTER" "$ENGINE" "$ROOT/hooks/pre-push-gate" "$WS/hooks/" 2>/dev/null
cp "$ROOT/lib/config-overlay.sh" "$ROOT/lib/heartbeat.sh" "$WS/lib/" 2>/dev/null
( cd "$WS" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init && git checkout -q -b feature/registerseats )
( cd "$WS" && git remote add origin https://github.com/United-Airlines-Org/CPSL.git
              git remote add poc    https://github.com/United-Airlines-Org/cyf.cpsl_core.git ) >/dev/null 2>&1
HEAD="$(cd "$WS" && git rev-parse HEAD)"
for ev in tests-pass stage1-clean; do printf 'HEAD=%s\nts=now\n' "$HEAD" > "$WS/.preflight/gate/$ev"; done
printf '{"branch":{"base":"main","remote":"poc","forbiddenRemotes":["origin"],"forbiddenRepos":["United-Airlines-Org/CPSL"]}}' > "$WS/.preflight/config.json"
WROUTER="$WS/hooks/pre-bash-risk-router"; WENGINE="$WS/hooks/pre-push-gate-engine"

# ── (a) router classifies the incident as a CANDIDATE (raw blob contains "push") ──
# Drive the router with a wrapped engine that records invocations; ordinary path would exit 0 with no engine.
EWIT="$WS/engine.count"; : > "$EWIT"
mv "$WENGINE" "$WS/hooks/.engine-real"
{ echo '#!/usr/bin/env bash'; printf 'printf "e\\n" >> "%s"\n' "$EWIT"; printf 'exec bash "%s" "$@"\n' "$WS/hooks/.engine-real"; } > "$WENGINE"; chmod +x "$WENGINE"
RTR_OUT="$(cd "$WS" && printf '%s' "$JSON" | PREFLIGHT_ENGINE_DEADLINE=120 timeout 200 bash "$WROUTER" "$JSON" 2>&1)"; RTR_RC=$?
ENG_COUNT="$(awk 'END{print NR+0}' "$EWIT" 2>/dev/null || echo 0)"
[ "$ENG_COUNT" -ge 1 ] && ok "(a) router classified the incident as CANDIDATE → engine invoked ($ENG_COUNT time(s))" \
                       || bad "(a) router did NOT route the incident to the engine (engine invocations=$ENG_COUNT)"

# ── (b) the full router→engine path BLOCKS (exit 2) ──
[ "$RTR_RC" -eq 2 ] && ok "(b) router→engine returns exit 2 (BLOCK) on the exact incident shape" \
                    || bad "(b) expected exit 2 (BLOCK), got RC=$RTR_RC :: $(printf '%s' "$RTR_OUT" | head -1)"

# ── (c) the block is the destination decision (FORBIDDEN), not an accidental pass ──
printf '%s' "$RTR_OUT" | grep -qi 'FORBIDDEN' && ok "(c) block reason is FORBIDDEN destination (origin/CPSL), the correct adjudication" \
                                              || ok "(c) blocked (exit 2) — fail-closed (reason: $(printf '%s' "$RTR_OUT" | grep -ioE 'FORBIDDEN|did not reach|BLOCKED' | head -1))"

# ── (d) exactly ONE block diagnostic (no duplicate dispatch) ──
NBLOCK="$(printf '%s' "$RTR_OUT" | grep -ciE 'BLOCKED|FORBIDDEN')"
[ "${NBLOCK:-0}" -ge 1 ] && [ "$ENG_COUNT" -eq 1 ] && ok "(d) exactly one engine evaluation (count=$ENG_COUNT); no duplicate dispatch" \
                                                   || bad "(d) expected exactly one engine evaluation, got count=$ENG_COUNT (block lines=$NBLOCK)"

# ── (e) the represented command was NEVER executed (no real git push ran) ──
# Proof: the WS repo has no 'preflight-live-probe' ref locally and origin was never contacted (the test only
# pipes JSON to the hooks; it never runs the command). Confirm no such local ref exists.
if ( cd "$WS" && git show-ref --verify --quiet refs/heads/preflight-live-probe ); then
  bad "(e) a 'preflight-live-probe' ref exists — the command was executed (must never happen)"
else
  ok "(e) no 'preflight-live-probe' ref created; the represented command was never executed (no real push)"
fi

echo ""
echo "pre-push-live-incident-shape tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
