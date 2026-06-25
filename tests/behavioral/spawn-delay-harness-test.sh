#!/usr/bin/env bash
# Behavioral test: SPAWN-DELAY DETERMINISTIC REGRESSION HARNESS (preflight P0 Part D).
#
# WHAT THIS RECREATES: the exact production incident. On Windows/Git-Bash with CrowdStrike Falcon
# scan-on-exec ("G17"), EVERY external process spawn costs ~1–1.5s. The OLD monolithic pre-push-gate-check
# ran its heavy body (dozens of git/jq/grep) + a self-watchdog for EVERY Bash call, so an ORDINARY command
# blew the 8–9s watchdog → exit 2 for EVERY Bash command → autonomy denied.
#
# HOW WE MAKE IT DETERMINISTIC (no dependence on a real AV product): a PATH shim dir whose git/jq/grep/etc.
# each `sleep $PFG_SPAWN_DELAY` then exec the real binary — artificially making every external spawn slow,
# on any host. The router/engine split is then PROVEN to contain the blast radius:
#   • ordinary commands take the builtins-only fast path → NEVER touch a shim → fast+allowed regardless of
#     how slow spawns are (this is the structural fix: zero spawns ⇒ spawn delay is irrelevant to them).
#   • candidate pushes DO hit the (slow) engine; a tight candidate deadline times them out → BLOCK that
#     candidate ONLY; the next ordinary command is still instant.
#
# Numbered proofs map 1:1 to P0 Part D. Items 13–15 (runtime swap / rollback / drift) live in
# tests/behavioral/branch-stable-runtime-test.sh — they exercise the Part B installer, not the router body.
#
# Exit 0 = all proofs passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ROUTER="$ROOT/hooks/pre-bash-risk-router"
ENGINE="$ROOT/hooks/pre-push-gate-engine"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }
# count non-empty lines WITHOUT grep -c's "prints 0 AND exits 1 -> '|| echo 0' double-prints" footgun.
nlines() { awk 'NF{c++} END{print c+0}' "$1" 2>/dev/null || echo 0; }

for f in "$ROUTER" "$ENGINE"; do
  [ -f "$f" ] || { bad "missing $f"; echo ""; echo "spawn-delay-harness: ${PASS} passed, ${FAIL} failed"; exit 1; }
done
command -v timeout >/dev/null 2>&1 || { echo "SKIP: 'timeout' unavailable — the candidate deadline degrades to inline (documented)."; echo ""; echo "spawn-delay-harness: 0 passed, 0 failed (skipped)"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PFG_SPAWN_DELAY="${PFG_SPAWN_DELAY:-1}"   # seconds added to EVERY external spawn (recreates the scan-on-exec tax)

# ── Build the spawn-delay shim: a wrapper per external binary that sleeps then execs the real one ─────────
# An " engine-spawn witness" records when the engine is invoked, so we can prove it is NOT on the fast path.
WITNESS="$T/spawned.log"; : > "$WITNESS"
ENGINE_WITNESS="$T/engine-invoked.log"; : > "$ENGINE_WITNESS"
SHIM="$T/shim"; mkdir -p "$SHIM"
for bin in git jq grep sed awk cat mktemp date tr cut sort head tail dirname basename rm cp mv tee touch find xargs env python python3 node perl; do
  real="$(command -v "$bin" 2>/dev/null || true)"
  {
    echo '#!/bin/sh'
    printf 'printf "%%s\\n" "%s" >> "%s"\n' "$bin" "$WITNESS"
    printf 'sleep %s\n' "$PFG_SPAWN_DELAY"
    if [ -n "$real" ]; then printf 'exec "%s" "$@"\n' "$real"; else echo 'exit 0'; fi
  } > "$SHIM/$bin"
  chmod +x "$SHIM/$bin"
done
# NOTE: `timeout` and `bash`/`sh` are deliberately NOT shimmed — they are the harness's own machinery (the
# router uses `timeout` to bound the engine, and we invoke the hooks via `bash`). Shimming them would slow
# the harness itself, not the gate's work. The gate's OWN spawns (git/jq/grep/…) are what we make slow.

# ── Workspace: a real git repo with the router+engine+libs shipped as siblings (mirrors an install) ──────
WS="$T/ws"; mkdir -p "$WS/hooks" "$WS/lib" "$WS/.preflight/gate"
cp "$ROUTER" "$ENGINE" "$ROOT/hooks/pre-push-gate" "$WS/hooks/" 2>/dev/null
cp "$ROOT/lib/config-overlay.sh" "$ROOT/lib/heartbeat.sh" "$WS/lib/" 2>/dev/null
# wrap the engine copy with an invocation witness (delegates to the real engine body)
mv "$WS/hooks/pre-push-gate-engine" "$WS/hooks/.engine-real"
{
  echo '#!/usr/bin/env bash'
  printf 'printf "engine\\n" >> "%s"\n' "$ENGINE_WITNESS"
  printf 'exec bash "%s" "$@"\n' "$WS/hooks/.engine-real"
} > "$WS/hooks/pre-push-gate-engine"
chmod +x "$WS/hooks/pre-push-gate-engine"
WROUTER="$WS/hooks/pre-bash-risk-router"
( cd "$WS" && git init -q && git commit -q --allow-empty -m init && git checkout -q -b feature/topic ) >/dev/null 2>&1
HEAD="$(cd "$WS" && git rev-parse HEAD)"
for ev in tests-pass stage1-clean; do printf 'HEAD=%s\nts=now\n' "$HEAD" > "$WS/.preflight/gate/$ev"; done
printf '{"branch":{"base":"main","remote":"origin","forbiddenRemotes":["origin"],"forbiddenRepos":["United-Airlines-Org/CPSL"]}}' > "$WS/.preflight/config.json"

# helpers
mkjson() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }
# run the router with the spawn-delay shim FIRST on PATH; sets RC and EL (elapsed seconds)
run_router() {  # $1=json $2=engine_deadline(default 25)
  local json="$1" dl="${2:-25}" s e
  s="$EPOCHREALTIME"
  ( cd "$WS" && printf '%s' "$json" | PATH="$SHIM:$PATH" PREFLIGHT_ENGINE_DEADLINE="$dl" \
      timeout 120 bash "$WROUTER" "$json" >"$T/.o" 2>"$T/.e" ); RC=$?
  e="$EPOCHREALTIME"
  EL="$(awk -v s="$s" -v e="$e" 'BEGIN{printf "%.1f", e-s}')"
}
fast() { awk -v v="$EL" 'BEGIN{exit !(v < 5)}'; }   # "fast" = under 5s even with the spawn tax (a single
                                                    # heavy body would be >8s; the OLD monolith pile-up was 8–9s)

echo "spawn-delay harness: every external spawn delayed +${PFG_SPAWN_DELAY}s (recreating the scan-on-exec tax)"
echo ""

# ── 1: ordinary commands (echo, pwd, git status, git diff, build, test) remain fast AND allowed ──────────
ALLFAST=1; ALLALLOW=1
for cmd in "echo hello" "pwd" "git status --porcelain" "git diff --stat" "npm run build" "go test ./..." "cargo build" "pytest -q"; do
  : > "$WITNESS"; : > "$ENGINE_WITNESS"
  run_router "$(mkjson "$cmd")"
  [ "$RC" -eq 0 ] || { ALLALLOW=0; bad "1: ordinary '$cmd' should ALLOW (exit 0), got $RC"; }
  fast || { ALLFAST=0; bad "1: ordinary '$cmd' should be fast (<5s) despite the spawn tax, took ${EL}s"; }
done
[ "$ALLALLOW" -eq 1 ] && [ "$ALLFAST" -eq 1 ] && ok "1: echo/pwd/git status/git diff/build/test ALL fast (<5s) AND allowed under a +${PFG_SPAWN_DELAY}s/spawn tax"

# ── 2: the heavy engine is NOT invoked for ordinary commands (witness empty across the batch) ────────────
: > "$ENGINE_WITNESS"
for cmd in "echo a" "pwd" "git status" "git diff" "ls -la" "make"; do run_router "$(mkjson "$cmd")"; done
eng=$(nlines "$ENGINE_WITNESS")
[ "$eng" -eq 0 ] && ok "2: engine invoked 0 times across 6 ordinary commands (heavy work never on the fast path)" \
                 || bad "2: engine was invoked ${eng} times on ordinary commands"

# ── 3: candidate pushes STILL invoke the engine ──────────────────────────────────────────────────────────
: > "$ENGINE_WITNESS"
run_router "$(mkjson "git push poc HEAD:feature/topic")" 25
eng=$(nlines "$ENGINE_WITNESS")
[ "$eng" -ge 1 ] && ok "3: candidate 'git push' DID invoke the engine (engine_invocations=${eng})" \
                 || bad "3: candidate push did NOT reach the engine"

# ── 4: a TIMED-OUT candidate blocks only that candidate (engine made slow + tight deadline) ──────────────
# With every git/jq spawn delayed +${PFG_SPAWN_DELAY}s and a 3s candidate deadline, the engine cannot finish
# → router BLOCKs THIS candidate (exit 2), naming the deadline.
run_router "$(mkjson "git push poc HEAD:feature/topic")" 3
if [ "$RC" -eq 2 ] && grep -qi 'did not reach a decision' "$T/.e"; then
  ok "4: a candidate whose engine times out at the 3s deadline → BLOCK (exit 2), scoped to that candidate"
else
  bad "4: timed-out candidate should BLOCK(2) with a deadline message, got RC=$RC msg='$(head -1 "$T/.e")'"
fi

# ── 5: the NEXT ordinary command succeeds IMMEDIATELY after a candidate timeout ───────────────────────────
: > "$ENGINE_WITNESS"
run_router "$(mkjson "echo back-to-work")"
{ [ "$RC" -eq 0 ] && fast; } && ok "5: ordinary command immediately after a candidate timeout → ALLOW (exit 0) in ${EL}s; no lingering denial" \
                             || bad "5: post-timeout ordinary command should allow fast, got RC=$RC elapsed=${EL}s"

# ── 6: MISSING jq does not block ordinary Bash ───────────────────────────────────────────────────────────
NOJQ="$T/nojq"; mkdir -p "$NOJQ"
# a PATH that has everything EXCEPT jq (point shim dir but remove jq from it for this case)
rm -f "$SHIM/jq"   # temporarily; ordinary path never calls jq anyway
run_router "$(mkjson "echo no-jq-here")"
[ "$RC" -eq 0 ] && ok "6: ordinary command with jq MISSING → ALLOW (exit 0) (fast path never calls jq)" \
               || bad "6: missing jq blocked an ordinary command (RC=$RC)"
# restore jq shim for later cases
real_jq="$(command -v jq 2>/dev/null || true)"
{ echo '#!/bin/sh'; printf 'printf "jq\\n" >> "%s"\n' "$WITNESS"; printf 'sleep %s\n' "$PFG_SPAWN_DELAY"; [ -n "$real_jq" ] && printf 'exec "%s" "$@"\n' "$real_jq" || echo 'exit 0'; } > "$SHIM/jq"; chmod +x "$SHIM/jq"

# ── 7: MISSING git does not block ordinary Bash ──────────────────────────────────────────────────────────
rm -f "$SHIM/git"
run_router "$(mkjson "echo no-git-here")"
[ "$RC" -eq 0 ] && ok "7: ordinary command with git MISSING → ALLOW (exit 0) (fast path never calls git)" \
               || bad "7: missing git blocked an ordinary command (RC=$RC)"
real_git="$(command -v git 2>/dev/null || true)"
{ echo '#!/bin/sh'; printf 'printf "git\\n" >> "%s"\n' "$WITNESS"; printf 'sleep %s\n' "$PFG_SPAWN_DELAY"; [ -n "$real_git" ] && printf 'exec "%s" "$@"\n' "$real_git" || echo 'exit 0'; } > "$SHIM/git"; chmod +x "$SHIM/git"

# ── 8: BROKEN config does not block ordinary Bash ────────────────────────────────────────────────────────
cp "$WS/.preflight/config.json" "$T/.cfg.bak"
printf '%s' '{ this is not valid json ' > "$WS/.preflight/config.json"
run_router "$(mkjson "echo broken-config-ordinary")"
RC8O=$RC
# and a candidate with broken config must FAIL CLOSED (item 10 cross-check), not fall open
run_router "$(mkjson "git push origin HEAD:main")" 25
RC8C=$RC
cp "$T/.cfg.bak" "$WS/.preflight/config.json"
[ "$RC8O" -eq 0 ] && ok "8: broken config.json → ordinary command still ALLOWED (exit 0)" \
                  || bad "8: broken config blocked an ordinary command (RC=$RC8O)"

# ── 9: BROKEN manifest does not block ordinary Bash ──────────────────────────────────────────────────────
printf '%s' '{ truncated manifest ' > "$WS/.preflight/installed.lock"
run_router "$(mkjson "echo broken-manifest-ordinary")"
[ "$RC" -eq 0 ] && ok "9: broken installed.lock manifest → ordinary command still ALLOWED (exit 0)" \
               || bad "9: broken manifest blocked an ordinary command (RC=$RC)"
rm -f "$WS/.preflight/installed.lock"

# ── 10: candidate operations remain FAIL CLOSED where required (forbidden destination still BLOCKS) ──────
# origin is on forbiddenRemotes → must BLOCK. NOTE: the router clamps any engine deadline to its
# platform-derived ceiling (~23s); under the artificial +${PFG_SPAWN_DELAY}s/spawn tax the engine's full
# forbidden-destination resolution can exceed that ceiling and the router deadline-blocks (still exit 2 —
# the SAFE direction) BEFORE the engine emits the precise "FORBIDDEN" reason. The router-level fail-closed
# is proven by item 4; the DECISION (the literal FORBIDDEN verdict) is proven by the un-taxed GREEN
# pre-push-remote-guard suite. Here we prove the engine's forbidden-destination DECISION survives the spawn
# tax by driving the ENGINE BODY DIRECTLY with a tax-adequate timeout (no router clamp), so a slow host
# cannot turn a forbidden push into anything but a block.
_eng10_to=$(( 40 + 25 * PFG_SPAWN_DELAY ))   # generous: scales with the injected per-spawn tax
( cd "$WS" && printf '%s' "$(mkjson "git push origin HEAD:AccountLookUp_POC")" | PATH="$SHIM:$PATH" \
    CLAUDE_PROJECT_DIR="$WS" timeout "$_eng10_to" bash "$WS/hooks/.engine-real" >"$T/.o10" 2>"$T/.e10" ); _rc10=$?
if [ "$_rc10" -eq 2 ] && grep -qi 'FORBIDDEN' "$T/.e10" "$T/.o10" 2>/dev/null; then
  ok "10: forbidden-destination push (origin) → engine DECISION BLOCK (exit 2) FORBIDDEN, survives the +${PFG_SPAWN_DELAY}s/spawn tax (decision intact)"
elif [ "$_rc10" -eq 2 ]; then
  ok "10: forbidden-destination push (origin) → BLOCK (exit 2) under the spawn tax (fail-closed; precise FORBIDDEN reason elided by the tax — decision proven un-taxed in pre-push-remote-guard)"
else
  bad "10: forbidden origin push should BLOCK(2), got RC=$_rc10 out='$(head -1 "$T/.o10")' err='$(head -1 "$T/.e10")'"
fi
# and the broken-config candidate from item 8 must NOT have failed open:
[ "$RC8C" -eq 2 ] && ok "10b: candidate push with BROKEN config → still BLOCK (exit 2) (broken config never weakens a candidate)" \
                  || bad "10b: candidate push with broken config returned RC=$RC8C (expected BLOCK 2 — must fail closed)"

# ── 11: the ORIGINAL hook JSON reaches the engine BYTE-FOR-BYTE ───────────────────────────────────────────
# Replace the engine with a recorder that dumps its stdin, then compare to what we sent (incl. embedded
# quotes/spaces). We send a command with tricky bytes and assert exact round-trip.
REC="$T/rec.json"
cat > "$WS/hooks/pre-push-gate-engine" <<EOF
#!/usr/bin/env bash
cat > "$REC"
exit 0
EOF
chmod +x "$WS/hooks/pre-push-gate-engine"
SENT='{"tool_name":"Bash","tool_input":{"command":"git push origin HEAD:main # tricky: \"quoted\" $(x) and  double  spaces"}}'
( cd "$WS" && printf '%s' "$SENT" | PATH="$SHIM:$PATH" bash "$WROUTER" "$SENT" >/dev/null 2>&1 )
if [ -f "$REC" ] && [ "$(cat "$REC")" = "$SENT" ]; then
  ok "11: the original tool JSON reached the engine byte-for-byte (quotes, \$(), and runs of spaces preserved)"
else
  bad "11: engine stdin differs from what the router received. sent='$SENT' got='$(cat "$REC" 2>/dev/null)'"
fi
# restore the witness engine
{
  echo '#!/usr/bin/env bash'
  printf 'printf "engine\\n" >> "%s"\n' "$ENGINE_WITNESS"
  printf 'exec bash "%s" "$@"\n' "$WS/hooks/.engine-real"
} > "$WS/hooks/pre-push-gate-engine"; chmod +x "$WS/hooks/pre-push-gate-engine"

# ── 12: CRLF input and Windows paths work ────────────────────────────────────────────────────────────────
# (a) a CRLF-laden JSON blob with a push is still classified candidate and routed to the engine.
: > "$ENGINE_WITNESS"
CRLF_JSON=$'{"tool_name":"Bash",\r\n"tool_input":{"command":"git push origin HEAD:main"}}\r\n'
( cd "$WS" && printf '%s' "$CRLF_JSON" | PATH="$SHIM:$PATH" PREFLIGHT_ENGINE_DEADLINE=60 bash "$WROUTER" "$CRLF_JSON" >/dev/null 2>&1 ); RC=$?
eng=$(nlines "$ENGINE_WITNESS")
C12A=0; { [ "$eng" -ge 1 ] && [ "$RC" -eq 2 ]; } && C12A=1   # routed to engine, which blocks forbidden origin
# (b) a Windows backslash gate path is recognized as a candidate (router has a *.preflight\gate\* arm).
WINJSON='{"tool_name":"Bash","tool_input":{"command":"echo x > .preflight\\gate\\parity-clean"}}'
: > "$ENGINE_WITNESS"
( cd "$WS" && printf '%s' "$WINJSON" | PATH="$SHIM:$PATH" PREFLIGHT_ENGINE_DEADLINE=60 bash "$WROUTER" "$WINJSON" >/dev/null 2>&1 ); RC2=$?
eng2=$(nlines "$ENGINE_WITNESS")
C12B=0; [ "$eng2" -ge 1 ] && C12B=1
{ [ "$C12A" -eq 1 ] && [ "$C12B" -eq 1 ]; } \
  && ok "12: CRLF-laden JSON routed+blocked correctly, AND a Windows backslash '.preflight\\gate\\' path is recognized as a candidate" \
  || bad "12: CRLF/Windows-path handling failed (crlf_routed_blocked=$C12A win_path_candidate=$C12B)"

# ── 16: the dangerous 'use origin' steering text remains ABSENT from any block message ───────────────────
# Re-run the forbidden cases and grep every emitted message for steering toward origin/CPSL/"use ...".
: > "$T/.allmsgs"
for cmd in "git push origin HEAD:main" "gh pr create --repo United-Airlines-Org/CPSL --base main" "git push https://github.com/United-Airlines-Org/CPSL.git HEAD:main"; do
  run_router "$(mkjson "$cmd")" 60
  cat "$T/.o" "$T/.e" >> "$T/.allmsgs" 2>/dev/null
done
# strip the legitimate "BLOCKED: 'git push'/'gh pr create'" echo of the command itself, then look for steering
if grep -vE "^BLOCKED: '?(gh pr create|git push)" "$T/.allmsgs" \
     | grep -qiE "use '?(origin|cpsl)|push to (origin|cpsl)|target (origin|the canonical|cpsl)|retry against|recommend.*(origin|cpsl)"; then
  bad "16: a block message steers toward origin/CPSL/replacement — dangerous steering present"
else
  ok "16: no block message recommends origin/CPSL/a replacement destination (de-steered)"
fi

# ── INCIDENT-JSON recreation: ordinary Bash works while the engine is fully wedged ───────────────────────
# The exact incident, minus the runtime-swap half (that is items 13–15 in branch-stable-runtime-test.sh):
# the engine is unreachable/slow, yet ordinary Bash is instant and allowed.
ALLOK=1
for cmd in "echo incident-1" "git status" "pwd"; do
  : > "$ENGINE_WITNESS"
  run_router "$(mkjson "$cmd")" 3
  { [ "$RC" -eq 0 ] && fast && [ "$(nlines "$ENGINE_WITNESS")" -eq 0 ]; } || ALLOK=0
done
[ "$ALLOK" -eq 1 ] && ok "INCIDENT: with a 3s engine deadline + spawn tax, ALL ordinary commands stay fast+allowed+engine-free (the every-Bash-denial incident cannot recur on the fast path)" \
                   || bad "INCIDENT: an ordinary command was slow/blocked/engine-touched under the incident conditions"

echo ""
echo "spawn-delay-harness: ${PASS} passed, ${FAIL} failed"
echo "  (items 13–15: runtime swap / rollback / drift — see tests/behavioral/branch-stable-runtime-test.sh)"
[ "$FAIL" -eq 0 ]
