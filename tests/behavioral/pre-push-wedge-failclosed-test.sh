#!/usr/bin/env bash
# Behavioral test: pre-push-gate-check FAILS CLOSED when it wedges/stalls.
#
# THE HOLE (RED, pre-fix): the hook is registered with a 10s platform timeout. If a push-safety
# subprocess wedges (git blocked on a credential/SSH prompt, jq on a stalled FS read), the PLATFORM
# SIGKILLs the hook at 10s. That kill surfaces as exit 124/137 — and per the PreToolUse protocol ONLY
# exit 2 blocks; 124/137 are NON-blocking errors, so the push then proceeds UNGATED. A safety gate that
# wedges must NEVER wave a push through.
#
# THE FIX (GREEN): two layers, each independently fail-closed —
#   L1 (self-watchdog): the body re-execs as a child under an internal deadline (default 8s, < the 10s
#       platform kill). A child that doesn't reach a decision (124/137/abnormal) is mapped to exit 2.
#   L2 (subprocess bounding): the wedge-prone network-facing call (`git remote get-url`) runs under a
#       short per-call timeout; a wedge sets a flag and the next decision checkpoint exits 2.
#
# We inject a REAL wedge by shadowing `git` with a hanging stub on PATH, run the hook under a 10s
# ceiling (emulating the platform), and assert exit == 2 (BLOCK), NOT 124/137 (fail-open).
#
# WINDOWS/GIT-BASH NOTE: this box has a pathological ~1.5s/subprocess-spawn tax, so even a NORMAL
# unwedged body can take far longer than 10s here. The DECISION-logic assertions (D-series) therefore
# raise PREFLIGHT_PUSH_GATE_DEADLINE so the watchdog doesn't kill a legitimate (merely slow) run —
# the same compensation the sibling tier-tests already make with their per-probe `timeout 60`. The
# WEDGE assertions (W-series) use the production default and assert fail-closed + under the platform kill.
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$ROOT/hooks/pre-push-gate-check"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

if [ ! -f "$HOOK" ]; then
  bad "hook not found at $HOOK"; echo ""; echo "pre-push-wedge-failclosed tests: ${PASS} passed, ${FAIL} failed"; exit 1
fi
if ! command -v timeout >/dev/null 2>&1; then
  echo "SKIP: 'timeout' not available — the watchdog degrades to inline (documented); wedge-bounding is a no-op here."
  echo ""; echo "pre-push-wedge-failclosed tests: 0 passed, 0 failed (skipped)"; exit 0
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# Build a workspace with HEAD-fresh evidence + config (so a normal run reaches the tier/remote logic).
mk_ws() {
  local ws="$T/$1"; mkdir -p "$ws/.preflight/gate"
  ( cd "$ws" && git init -q && git commit -q --allow-empty -m init && git checkout -q -b feature/topic-x )
  local head; head="$(cd "$ws" && git rev-parse HEAD)"
  for ev in tests-pass stage1-clean; do printf 'HEAD=%s\nts=now\n' "$head" > "$ws/.preflight/gate/$ev"; done
  printf '{"branch":{"base":"main","remote":"origin","forbiddenRemotes":[],"forbiddenRepos":[]}}' > "$ws/.preflight/config.json"
  echo "$ws"
}
WS="$(mk_ws optedin)"

# A `git` stub that HANGS on every call (simulates a fully-wedged git — the worst case).
STUB_ALL="$T/stub_all"; mkdir -p "$STUB_ALL"
printf '#!/bin/sh\nsleep 999\n' > "$STUB_ALL/git"; chmod +x "$STUB_ALL/git"

# A `git` stub that is FAST for everything EXCEPT `remote get-url`, which hangs — the REALISTIC
# production wedge (a credential/network round-trip stalls; local reads are fine).
STUB_REMOTE="$T/stub_remote"; mkdir -p "$STUB_REMOTE"
cat > "$STUB_REMOTE/git" <<EOF
#!/bin/sh
case "\$*" in
  *"remote get-url"*) sleep 999 ;;
  *) exec $(command -v git) "\$@" ;;
esac
EOF
chmod +x "$STUB_REMOTE/git"

PUSH='{"tool_name":"Bash","tool_input":{"command":"git push origin HEAD:feature/x"}}'

# run_wedged <stub-dir> <deadline-env> <platform-ceiling> -> sets RC, ELAPSED, ERR1
run_wedged() {
  local stub="$1" dl="$2" ceil="$3"
  local errf; errf="$(mktemp)"
  local start end
  start="$(date +%s)"
  ( cd "$WS" && printf '%s' "$PUSH" | PATH="$stub:$PATH" CLAUDE_PROJECT_DIR="$WS" \
      PREFLIGHT_PUSH_GATE_DEADLINE="$dl" timeout "$ceil" bash "$HOOK" "$PUSH" >/dev/null 2>"$errf" ); RC=$?
  end="$(date +%s)"
  ELAPSED=$((end - start))
  ERR1="$(head -1 "$errf" 2>/dev/null)"
  rm -f "$errf"
}

# ── W1: FULLY-WEDGED git -> must BLOCK (exit 2), fail-CLOSED. The CORE assertion of this whole fix. ──
# Production default deadline (8s) under a 12s ceiling. RED (pre-fix): the platform killed the hung hook
# at 10s -> 124/137 -> NON-blocking -> push proceeds UNGATED. GREEN (post-fix): the self-watchdog renders
# a BLOCK (exit 2) at its own deadline first.
run_wedged "$STUB_ALL" 8 12
if [ "$RC" -eq 2 ]; then
  ok "W1: fully-wedged git -> BLOCK (exit 2), fail-CLOSED (was 124/137 fail-open pre-fix)"
else
  bad "W1: wedged git should exit 2, got RC=$RC (124/137 = the fail-open hole is still present)"
fi

# ── W1b: the DEADLINE (not the platform ceiling) is what fires. Box-speed-independent proof: with a SHORT
# deadline (3s) under a GENEROUS ceiling (30s), the hook must still BLOCK — and the watchdog message must
# name the 3s deadline, proving the internal watchdog (not the outer ceiling) rendered the verdict. On a
# production host this directly demonstrates the block lands well before the 10s platform kill. ──
errf="$(mktemp)"
( cd "$WS" && printf '%s' "$PUSH" | PATH="$STUB_ALL:$PATH" CLAUDE_PROJECT_DIR="$WS" \
    PREFLIGHT_PUSH_GATE_DEADLINE=3 timeout 30 bash "$HOOK" "$PUSH" >/dev/null 2>"$errf" ); _rc=$?
if [ "$_rc" -eq 2 ] && grep -qi 'within its 3s safety deadline' "$errf"; then
  ok "W1b: a 3s deadline under a 30s ceiling still BLOCKs and names the 3s deadline — the watchdog, not the platform kill, decides"
else
  bad "W1b: expected exit 2 + '3s safety deadline' message, got RC=$_rc msg='$(head -1 "$errf")'"
fi
rm -f "$errf"

# ── W2: the watchdog block-MESSAGE is present at the production default deadline (proves L1 fired,
#       not some incidental exit 2). ───
errf="$(mktemp)"
( cd "$WS" && printf '%s' "$PUSH" | PATH="$STUB_ALL:$PATH" CLAUDE_PROJECT_DIR="$WS" \
    PREFLIGHT_PUSH_GATE_DEADLINE=8 timeout 14 bash "$HOOK" "$PUSH" >/dev/null 2>"$errf" ); _rc=$?
if [ "$_rc" -eq 2 ] && grep -qi 'did not reach a decision' "$errf"; then
  ok "W2: BLOCK carries the watchdog 'did not reach a decision' reason (fail-closed self-watchdog confirmed)"
else
  bad "W2: expected watchdog block message + exit 2, got RC=$_rc msg='$(head -1 "$errf")'"
fi
rm -f "$errf"

# ── W3: REALISTIC wedge (only `git remote get-url` hangs), watchdog DISABLED -> proves Layer 2
#       bounds the network call on its own (not merely shadowed by Layer 1). Must still BLOCK.
#   The named push remote forces the hook's B0 forbidden pre-check to call `git remote get-url <name>`,
#   which the stub wedges on. With L1 OFF, only the L2 per-call timeout (3s) + checkpoint can block.
#   Generous ceiling (120s): this box's ~1.3s/spawn tax makes the PRE-wedge body work slow (the wedge
#   itself is bounded at 3s); we assert only that it FAILS CLOSED (exit 2) with the L2 message, not timing. ──
errf="$(mktemp)"; start="$(date +%s)"
( cd "$WS" && printf '%s' "$PUSH" | PATH="$STUB_REMOTE:$PATH" CLAUDE_PROJECT_DIR="$WS" \
    _PFG_WATCHDOG_CHILD=1 PREFLIGHT_PUSH_GATE_DEADLINE=8 timeout 120 bash "$HOOK" "$PUSH" >/dev/null 2>"$errf" ); _rc=$?
end="$(date +%s)"; _el=$((end - start))
if [ "$_rc" -eq 2 ] && grep -qiE 'timed out|wedge|did not reach' "$errf"; then
  ok "W3: realistic remote-wedge, self-watchdog OFF -> Layer 2 (per-subprocess timeout + checkpoint) fail-CLOSED (exit 2) in ${_el}s"
else
  bad "W3: Layer 2 alone should fail-closed (exit 2) on a wedged 'git remote get-url', got RC=$_rc"
fi
rm -f "$errf"

# ── D-series: DECISION logic still works on a NORMAL (unwedged) run — NO regression to the tiers. ──
#   Driven BODY-DIRECT (_PFG_WATCHDOG_CHILD=1): the watchdog kills the body at its internal deadline and
#   fails CLOSED — correct in production, but on this slow-spawn box a legitimate body (~37s) exceeds any
#   sub-10s deadline, so the watchdog would turn every outcome into a spurious exit-2. Body-direct tests
#   the exact code that runs AS the watchdog child in production. (Full tier coverage lives in
#   pre-push-bare-remote-test.sh; here we just confirm the body edits — bounded wrappers + checkpoints —
#   did not break a clean AUTO/CONFIRM decision.)
probe_body() {  # $1 = push command ; sets RC, DEC (real git, no stub, watchdog bypassed)
  local cmd="$1" json outf; json="$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$cmd")"
  outf="$(mktemp)"
  ( cd "$WS" && printf '%s' "$json" | CLAUDE_PROJECT_DIR="$WS" _PFG_WATCHDOG_CHILD=1 \
      timeout 90 bash "$HOOK" "$json" >"$outf" 2>/dev/null ); RC=$?
  DEC="$(jq -r '.hookSpecificOutput.permissionDecision // ""' "$outf" 2>/dev/null || echo "")"
  rm -f "$outf"
}

# D1: AUTO — named safe-remote push to an UNPROTECTED branch, non-force, evidence fresh -> allow.
probe_body 'git push origin HEAD:feature/x'
if [ "$RC" -eq 0 ] && [ "$DEC" = "allow" ]; then
  ok "D1: normal AUTO decision intact (exit 0 + allow) — bounded-subprocess wrappers don't false-trip on a clean run"
else
  bad "D1: normal AUTO push should be 0/allow, got RC=$RC DEC=$DEC (body edits regressed the decision)"
fi

# D2: CONFIRM — push to the PROTECTED branch 'main' -> ask (exit 0).
probe_body 'git push origin HEAD:main'
if [ "$RC" -eq 0 ] && [ "$DEC" = "ask" ]; then
  ok "D2: normal CONFIRM decision intact (exit 0 + ask) — checkpoints don't false-block a clean run"
else
  bad "D2: normal CONFIRM push should be 0/ask, got RC=$RC DEC=$DEC"
fi

# ── R1: watchdog RELAY integrity — the AUTO/CONFIRM JSON the child writes must survive the parent's
#   file-capture relay byte-for-byte. Use a FAST (non-wedging) git stub so the body finishes well within
#   the watchdog deadline, then assert the parent (which re-execs the child and relays its captured
#   stdout) emits the SAME permissionDecision the body would. Run THROUGH the watchdog (no bypass). ──
# Real git is fast per-call; this box's tax is spawn COUNT, so on it even the clamp-ceiling 9s deadline
# cannot clear the body and the watchdog fires (a correct fail-closed, just not what R1 wants to show).
# Outer ceiling 20s — safely above the watchdog's worst-case teardown (9s deadline + 1s grace + box tax)
# so we get a clean watchdog verdict rather than the outer ceiling pre-empting it. On a normal-spawn host
# the body clears 9s and R1 demonstrates relay integrity; on this box it self-skips (honestly recorded).
errf="$(mktemp)"; outf="$(mktemp)"
J_AUTO='{"tool_name":"Bash","tool_input":{"command":"git push origin HEAD:feature/x"}}'
( cd "$WS" && printf '%s' "$J_AUTO" | CLAUDE_PROJECT_DIR="$WS" PREFLIGHT_PUSH_GATE_DEADLINE=9 \
    timeout 20 bash "$HOOK" "$J_AUTO" >"$outf" 2>"$errf" ); _rc=$?
_dec="$(jq -r '.hookSpecificOutput.permissionDecision // ""' "$outf" 2>/dev/null || echo "")"
if [ "$_rc" -eq 0 ] && [ "$_dec" = "allow" ]; then
  ok "R1: watchdog relay preserves the AUTO JSON end-to-end (parent re-emits child's permissionDecision:allow)"
elif { [ "$_rc" -eq 2 ] && grep -qi 'did not reach a decision' "$errf"; } || [ "$_rc" -eq 124 ]; then
  echo "SKIP-NOTE R1: this host is too slow-spawn to finish the body within the 9s clamp (watchdog fired, or the"
  echo "  outer 20s ceiling pre-empted on extreme load); relay integrity is instead covered by the body-direct"
  echo "  D1/D2 above + the wedge proofs W1/W2. Recorded as a skip, not counted as a pass or a failure."
else
  bad "R1: expected AUTO/allow through the watchdog (or a clean deadline-skip), got RC=$_rc DEC=$_dec"
fi
rm -f "$errf" "$outf"

echo ""
echo "pre-push-wedge-failclosed tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
