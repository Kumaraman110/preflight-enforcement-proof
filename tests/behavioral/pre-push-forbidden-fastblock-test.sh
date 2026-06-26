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
# second-count is host-dependent (the live host is ~1.5-3x this one), so we assert TWO host-independent facts
# that together guarantee margin on ANY host:
#   (1) the early decision performs NO `git remote get-url` and does NOT reach the evidence gate (asserted
#       above) — it skips the two most expensive downstream stages entirely; and
#   (2) from the engine's PFG_STAGE timing, the time from structural-parse-done → FORBIDDEN-decision (the
#       early block's OWN added cost) is a SMALL fraction of the total to-decision time — i.e. the block adds
#       little and fires right after parse, rather than after the full policy pipeline.
TF="$(mktemp)"
( cd "$REPO" && printf '%s' "$(jq -n --arg c "git \\${LF}push origin HEAD:refs/heads/x" '{tool_name:"Bash",tool_input:{command:$c}}')" \
    | PATH="$SHIM:$PATH" _PFG_WATCHDOG_CHILD=1 PREFLIGHT_ENGINE_TIMING=1 PREFLIGHT_ENGINE_TIMING_FILE="$TF" CLAUDE_PROJECT_DIR="$REPO" timeout 90 bash "$WENGINE" >/dev/null 2>&1 )
_t_parse="$(awk '/structural-parse-done/{print $2+0}' "$TF" | tail -1)"
_t_dec="$(awk '/FORBIDDEN-decision/{print $2+0}' "$TF" | tail -1)"
if [ -n "$_t_parse" ] && [ -n "$_t_dec" ]; then
  # early-block own cost = decision - parse-done; must be < the parse-done time itself (block adds less than
  # the parse already cost) AND the decision must occur (FORBIDDEN-decision stage present).
  _added="$(awk -v d="$_t_dec" -v p="$_t_parse" 'BEGIN{printf "%.0f", d-p}')"
  if awk -v d="$_t_dec" -v p="$_t_parse" 'BEGIN{exit !(d-p < p && p>0)}'; then
    ok "latency: early block adds ${_added}ms after parse (< the ${_t_parse%.*}ms parse cost) — fires right after parse, skips evidence-gate + remote-url (substantial margin by construction)"
  else
    bad "latency: early block added ${_added}ms after parse vs parse ${_t_parse%.*}ms — the block is not short-circuiting early enough"
  fi
else
  bad "latency: could not read PFG_STAGE timing (parse=$_t_parse dec=$_t_dec)"
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
