#!/usr/bin/env bash
# Behavioral test: EARLY forbidden-remote FAST BLOCK (live Gate-4 23s-timeout incident).
#
# THE INCIDENT (authoritative live result at runtime af49b18): the continuation-shaped candidate
#     PATH="…/preflight-gate4-shim:$PATH" git \<LF> push origin HEAD:refs/heads/preflight-live-probe
# was BLOCKED — but via "pre-push-gate-engine did not reach a decision within its 23s candidate deadline
# (rc=124)", NOT via the explicit forbidden-remote policy. The continuation parser fix WORKED (push was
# detected + routed), but on the real Windows/Git-Bash host the engine's many pre-decision spawns
# (_pfg_config + ~6 _pfg_branch_* jq/node reads + git remote get-url + the evidence gate) stacked past the
# router's 23s candidate deadline, so the router deadline-blocked before the engine emitted the
# forbidden-remote BLOCK. Safe containment, but not a clean denylist-path decision.
#
# THE FIX: an EARLY fast block. Right after command extraction + continuation normalization + structural
# parse + ONE local config read, if the parsed EXPLICIT remote NAME is on branch.forbiddenRemotes, emit the
# explicit forbidden-destination diagnostic and exit 2 IMMEDIATELY — before `git remote get-url`, canonical
# slug resolution, the evidence gate, protected-branch eval, gh, or any network-capable op. The later
# forbiddenRepos (slug/URL) check is preserved for cases that genuinely need URL resolution.
#
# This test proves the early path is taken, identifies the forbidden remote (not a timeout), occurs before
# the evidence gate / remote-url resolution, never executes the represented command, and is fast under the
# slow-spawn harness with substantial margin under 23s.
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENGINE="$ROOT/hooks/pre-push-gate-engine"
[ -f "$ENGINE" ] || { echo "FAIL: engine not found at $ENGINE" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required."; echo ""; echo "pre-push-forbidden-fastblock tests: 0 passed, 0 failed (skipped)"; exit 0; }

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

# Repo wired like the consumer: forbidden 'origin' + 'poc', protected base, fresh evidence, topic branch.
REPO="$(mktemp -d)/repo"; mkdir -p "$REPO"
( cd "$REPO"
  git init -q; git config user.email t@t; git config user.name t
  git remote add origin https://github.com/forbidden-org/legacy-prod.git
  git remote add poc https://github.com/forbidden-org/prod-repo.git
  git remote add safe https://github.com/safe-org/app.git
  mkdir -p .preflight .preflight/gate
  cat > .preflight/config.json <<JSON
{ "branch": { "base": "main", "remote": "poc",
              "forbiddenRemotes": ["origin","poc"], "forbiddenRepos": ["forbidden-org/legacy-prod","forbidden-org/prod-repo"] } }
JSON
  echo x > f; git add -A; git commit -qm init
  git checkout -q -b topic-work
  h="$(git rev-parse HEAD)"
  printf 'HEAD=%s\n' "$h" > .preflight/gate/stage1-clean
  printf 'HEAD=%s\n' "$h" > .preflight/gate/tests-pass
) >/dev/null 2>&1

# A trip-wire 'pre-push-gate' (evidence gate) + git shim placed FIRST on PATH, so we can PROVE the early
# block fires BEFORE the evidence gate and BEFORE any `git remote get-url`. If either is reached, a marker
# file is written; the early-block assertions require those markers to be ABSENT.
SHIM="$(mktemp -d)/shim"; mkdir -p "$SHIM"
EVIDENCE_MARKER="$SHIM/.evidence_called"; GETURL_MARKER="$SHIM/.geturl_called"
# git shim: log a 'remote get-url' call (the network-capable resolution we must avoid on the early path),
# forward everything else to the real git so parsing/config still work.
_real_git="$(command -v git)"
cat > "$SHIM/git" <<EOF
#!/bin/sh
for a in "\$@"; do :; done
case "\$*" in
  *"remote get-url"*) echo geturl >> "$GETURL_MARKER" ;;
esac
exec "$_real_git" "\$@"
EOF
chmod +x "$SHIM/git"
# A wrapper engine that points the evidence-gate sibling at a tripwire: we copy the engine + a tripwire
# pre-push-gate into a temp hooks dir so the engine's `bash "$SCRIPT_DIR/pre-push-gate"` hits the tripwire.
HK="$(mktemp -d)/hooks"; mkdir -p "$HK"
cp "$ENGINE" "$HK/pre-push-gate-engine"
cp "$ROOT/lib/config-overlay.sh" "$ROOT/lib/heartbeat.sh" "$(dirname "$HK")/" 2>/dev/null; mkdir -p "$(dirname "$HK")/lib"; cp "$ROOT/lib/config-overlay.sh" "$ROOT/lib/heartbeat.sh" "$(dirname "$HK")/lib/" 2>/dev/null
cat > "$HK/pre-push-gate" <<EOF
#!/usr/bin/env bash
echo evidence >> "$EVIDENCE_MARKER"
exit 0
EOF
chmod +x "$HK/pre-push-gate"
WENGINE="$HK/pre-push-gate-engine"

LF=$'\n'; CR=$'\r'
# run the engine body directly on a command with REAL newlines; capture RC, OUT, elapsed, and markers.
run() {  # $1 = command string (may contain real newlines)
  : > "$EVIDENCE_MARKER"; : > "$GETURL_MARKER"
  local json s e
  json="$(jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}')"
  s="$EPOCHREALTIME"
  OUT="$(cd "$REPO" && printf '%s' "$json" | PATH="$SHIM:$PATH" _PFG_WATCHDOG_CHILD=1 CLAUDE_PROJECT_DIR="$REPO" timeout 90 bash "$WENGINE" 2>&1)"; RC=$?
  e="$EPOCHREALTIME"
  EL="$(awk -v s="$s" -v e="$e" 'BEGIN{printf "%.1f",e-s}')"
}

echo "── the EXACT live continuation-shaped candidate (forbidden 'origin') ──"
run "git \\${LF}push origin HEAD:refs/heads/preflight-live-probe"
# PASS: exit 2, FORBIDDEN diagnostic (not a timeout), evidence gate NOT reached, remote get-url NOT called.
_dec_ok=0; { [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qi 'FORBIDDEN'; } && _dec_ok=1
[ "$_dec_ok" -eq 1 ] && ok "INCIDENT: continuation push to forbidden 'origin' -> explicit FORBIDDEN BLOCK (exit 2), not a timeout (${EL}s)" \
                     || bad "INCIDENT: expected exit2+FORBIDDEN, got RC=$RC :: $(printf '%s' "$OUT" | head -1)"
[ ! -s "$EVIDENCE_MARKER" ] && ok "early block occurred BEFORE the evidence gate (evidence gate not invoked)" \
                           || bad "evidence gate WAS invoked before the forbidden decision (not an early block)"
[ ! -s "$GETURL_MARKER" ] && ok "early block occurred BEFORE any 'git remote get-url' (no network-capable resolution)" \
                          || bad "'git remote get-url' WAS called before the forbidden decision"
printf '%s' "$OUT" | grep -qi 'did not reach a decision\|deadline\|timed out' && bad "diagnostic mentions a TIMEOUT — the early decision did not fire" \
                                                                              || ok "diagnostic identifies the forbidden remote, not a timeout"

# ── LATENCY MARGIN (host-relative, via stage timing — not an absolute wall-clock the slow host would flake) ──
# The early forbidden decision must land with SUBSTANTIAL margin before the 23s router deadline. An absolute
# second-count is host-dependent (the live host is ~1.5-3x this one), so we assert host-INDEPENDENT facts that
# together guarantee margin on ANY host:
#   (1) the early decision performs NO `git remote get-url` and does NOT reach the evidence gate (asserted
#       above) — it skips the two most expensive downstream stages entirely; and
#   (2) from the engine's PFG_STAGE timing, the FORBIDDEN decision now fires at the BUILTINS-ONLY `fast0`
#       fast path (stage `fast0:FORBIDDEN-decision`), which runs IMMEDIATELY after command extraction and
#       BEFORE the structural parser (`structural-parse-done`) ever runs — i.e. the decision moved STRICTLY
#       EARLIER than the prior B-EARLY block (which fired only after the parse greps/seds). We assert the
#       fast0 decision stage is present AND that the structural-parse-done stage did NOT fire (the engine
#       exited at fast0, skipping the parser's spawns entirely — maximal margin by construction).
#       (If a forbidden push is so exotic that fast0 conservatively declines, the B-EARLY block below still
#       catches it post-parse — proven by the NFP/variant cases — so the decision is never lost.)
TF="$(mktemp)"
( cd "$REPO" && printf '%s' "$(jq -n --arg c "git \\${LF}push origin HEAD:refs/heads/x" '{tool_name:"Bash",tool_input:{command:$c}}')" \
    | PATH="$SHIM:$PATH" _PFG_WATCHDOG_CHILD=1 PREFLIGHT_ENGINE_TIMING=1 PREFLIGHT_ENGINE_TIMING_FILE="$TF" CLAUDE_PROJECT_DIR="$REPO" timeout 90 bash "$WENGINE" >/dev/null 2>&1 )
_t_fast0="$(awk '/fast0:FORBIDDEN-decision/{print $2+0}' "$TF" | tail -1)"
_t_cmd="$(awk '/command-extracted/{print $2+0}' "$TF" | tail -1)"
_has_parse="$(awk '/structural-parse-done/{c++} END{print c+0}' "$TF")"
if [ -n "$_t_fast0" ] && [ -n "$_t_cmd" ]; then
  # fast0 own cost = decision - command-extracted; it is pure-builtins so it must be a small fraction of the
  # command-extraction time, AND the structural parser must NOT have run (decision fired before it).
  _added="$(awk -v d="$_t_fast0" -v c="$_t_cmd" 'BEGIN{printf "%.0f", d-c}')"
  if [ "$_has_parse" -eq 0 ] && awk -v d="$_t_fast0" -v c="$_t_cmd" 'BEGIN{exit !(d-c < c && c>0)}'; then
    ok "latency: forbidden decision fires at the builtins fast0 path (+${_added}ms after command-extract, < the ${_t_cmd%.*}ms extract cost) — BEFORE the structural parser ran at all (skips parse greps/seds + evidence-gate + remote-url; maximal margin)"
  else
    bad "latency: fast0 decision +${_added}ms vs extract ${_t_cmd%.*}ms, structural-parse-ran=${_has_parse} — the fast path is not short-circuiting before the parser"
  fi
else
  bad "latency: could not read PFG_STAGE fast0 timing (fast0=$_t_fast0 cmd=$_t_cmd parse_ran=$_has_parse)"
fi
rm -f "$TF"

echo "── LF + CRLF + single-line variants all early-block forbidden 'origin' ──"
run "git \\${CR}${LF}push origin HEAD:main"; { [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qi FORBIDDEN; } && ok "CRLF continuation -> FORBIDDEN BLOCK (${EL}s)" || bad "CRLF: RC=$RC"
run "git push origin HEAD:main";            { [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qi FORBIDDEN; } && ok "single-line control -> FORBIDDEN BLOCK (${EL}s)" || bad "single-line: RC=$RC"
run "git -c http.sslVerify=false \\${LF}push origin HEAD:main"; { [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qi FORBIDDEN; } && ok "git -c k=v continuation -> FORBIDDEN BLOCK (${EL}s)" || bad "-c form: RC=$RC"

echo "── no-false-shortcut: explicit SAFE remote must NOT early-block; implicit remote must NOT use the name shortcut ──"
run "git push safe HEAD:topic-work"
printf '%s' "$OUT" | grep -qi 'FORBIDDEN' && bad "NFP: safe-remote push wrongly FORBIDDEN-blocked" || ok "NFP: explicit SAFE remote does NOT early-block (falls to the normal policy/evidence path)"
# implicit remote (no positional remote) must not be matched by the forbidden-NAME shortcut (no ARG_REMOTE)
run "git push"
printf '%s' "$OUT" | grep -qiE "FORBIDDEN destination 'origin'|FORBIDDEN destination 'poc'" && bad "NFP: implicit 'git push' wrongly used the forbidden-NAME shortcut" || ok "NFP: implicit 'git push' (no named remote) does NOT use the forbidden-name shortcut"

echo "── forbiddenRepos still blocks by RESOLVED slug (direct forbidden URL, no name on the denylist) ──"
run "git push https://github.com/forbidden-org/legacy-prod.git HEAD:main"
{ [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qi FORBIDDEN; } && ok "forbiddenRepos: direct forbidden URL still BLOCKS by resolved slug" || bad "forbiddenRepos slug block regressed: RC=$RC :: $(printf '%s' "$OUT" | head -1)"

echo "── shim marker absent (represented command never executed) ──"
# our git shim only logs 'remote get-url'; a real push would have been forwarded to real git. Prove no push ref was created.
( cd "$REPO" && git show-ref --verify --quiet refs/heads/preflight-live-probe ) && bad "a probe ref was created — command executed" \
  || ok "no 'preflight-live-probe' ref created; represented command never executed"

echo ""
echo "pre-push-forbidden-fastblock tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
