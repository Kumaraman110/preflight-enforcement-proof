#!/usr/bin/env bash
# Behavioral PERFORMANCE-REGRESSION test: CANDIDATE-PATH SUBPROCESS BUDGET (preflight Stage 2C).
#
# WHY A SPAWN-COUNT GATE (and why it is the RIGHT slow-spawn CI gate):
#   The Stage-2B "AUTHORITATIVE PERFORMANCE INSUFFICIENT" incident was, mechanically, latency =
#   (number of external process spawns on the candidate path) × (per-spawn scan-on-exec tax on the
#   Windows/CrowdStrike host, ~0.4–3s). Wall-clock is UNMEASURABLE on that host (it thrashes: the same
#   engine run varies 5×), so a wall-time assertion is pure jitter there. The INVARIANT that actually
#   drove the 23–25s regression is the SPAWN COUNT — and that is deterministic on ANY host. This test
#   pins a CEILING on the number of taxed spawns each candidate class makes, so the ir-push-perf wall
#   test (which needs a calibrated host) is complemented by a gate that fails the moment a change
#   RE-INTRODUCES spawns on the hot path — which is exactly how the original latency crept in, and exactly
#   what Stage 2C removed. A regression that adds N spawns back would add N × tax seconds on the pilot host
#   and is caught HERE before it can ever reach a Windows run.
#
# METHOD (deterministic, host-independent): a PATH shim dir with a counting wrapper per external binary
# (git/jq/awk/find/grep/sed/cat/date/tr/cut/head/dirname/basename). Each logs its name then execs the real
# binary. Run the engine once per case with the shim FIRST on PATH; assert total spawn count <= the budget.
# The budgets are the Stage-2C MEASURED counts + a small headroom for cross-platform binary differences
# (e.g. an extra `tr`/`cut` in a slightly different jq/grep build). A budget is a CEILING, never an equality,
# so benign platform variance does not flake; a real regression (a re-added git/find/jq spawn) blows it.
#
# The evidence gate MUST still run for AUTO (it is the freshness proof) — this test does NOT assert "fewer
# than the evidence gate needs"; it asserts "no MORE than the optimized path needs". Fail-closed, evidence,
# destination, and parser semantics are covered by the OTHER suites (ir-authoritative-push, evidence-gate-
# scoping, evidence-rc-failclosed); this suite covers ONLY the spawn budget.
#
# Exit 0 = all within budget. Isolated mktemp repo, string-only remotes, no network, no consumer.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENGINE="$ROOT/hooks/pre-push-gate-engine"
[ -f "$ENGINE" ] || { echo "FAIL: engine not found ($ENGINE)" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; echo "ir-push-spawn-budget tests: 0 passed, 0 failed (skipped)"; exit 0; }

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
REALGIT="$(command -v git)"

# ── Counting shims: one wrapper per external binary, ahead on PATH. Each appends its name to $SPAWNLOG then
# execs the real binary. `git push` still records to the push MARKER (via the real git being read-only here)
# so a BLOCK/CONFIRM case can also be asserted shim-not-run if desired. We count EVERY external spawn. ──
SHIM="$T/shim"; mkdir -p "$SHIM"
SPAWNLOG="$T/spawns.log"
MARKER="$T/pushed.marker"
for b in git jq awk gawk mawk find grep sed cat date tr cut head tail dirname basename sort; do
  real="$(command -v "$b" 2>/dev/null || true)"
  if [ "$b" = git ]; then
    # git wrapper: count, then if the invocation is a `push` record the marker and DO NOT run a real push;
    # otherwise exec the real git (read-only ops the gate needs: rev-parse / remote get-url).
    cat > "$SHIM/git" <<EOF
#!/usr/bin/env bash
printf 'git\n' >> "$SPAWNLOG"
for a in "\$@"; do [ "\$a" = push ] && { echo pushed >> "$MARKER"; exit 0; }; done
exec "$REALGIT" "\$@"
EOF
    chmod +x "$SHIM/git"; continue
  fi
  [ -n "$real" ] || continue
  cat > "$SHIM/$b" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$b" >> "$SPAWNLOG"
exec "$real" "\$@"
EOF
  chmod +x "$SHIM/$b"
done

# ── Fixture: isolated repo, safe+forbidden remotes, opted-in config, fresh evidence at HEAD. ──
WS="$T/ws"; mkdir -p "$WS/.preflight/gate"
( cd "$WS" && "$REALGIT" init -q && "$REALGIT" commit -q --allow-empty -m init && "$REALGIT" checkout -q -b feature/topic ) >/dev/null 2>&1
WSH="$(cd "$WS" && "$REALGIT" rev-parse HEAD)"
for ev in tests-pass stage1-clean; do printf 'HEAD=%s\nts=now\n' "$WSH" > "$WS/.preflight/gate/$ev"; done
printf '{"branch":{"base":"main","remote":"safe","safeRemotes":["safe"],"forbiddenRemotes":["evil"],"forbiddenRepos":["org/prod-repo"]}}' > "$WS/.preflight/config.json"
( cd "$WS" && "$REALGIT" remote add safe "https://example.com/org/safe-repo.git" && "$REALGIT" remote add evil "https://example.com/org/evil.git" ) 2>/dev/null

count_spawns() {  # $1 = command → sets SPAWNS, RC, EXECD
  : > "$SPAWNLOG"; : > "$MARKER"
  local js; js="$(printf '%s' "$1" | jq -Rs '{tool_name:"Bash",tool_input:{command:.}}')"
  ( cd "$WS" && printf '%s' "$js" | PATH="$SHIM:$PATH" CLAUDE_PROJECT_DIR="$WS" bash "$ENGINE" >/dev/null 2>&1 ); RC=$?
  SPAWNS="$(awk 'END{print NR+0}' "$SPAWNLOG")"
  EXECD=0; [ -s "$MARKER" ] && EXECD=1
}

# budget check: label, command, ceiling, expected-rc (optional; '' = don't assert rc)
budget() {  # $1 label  $2 cmd  $3 ceiling  $4 expect_rc
  count_spawns "$2"
  echo "  EVIDENCE case='$1' spawns=$SPAWNS ceiling=$3 rc=$RC execd=$EXECD"
  if [ -n "$4" ] && [ "$RC" != "$4" ]; then bad "$1: expected rc=$4 got rc=$RC (wrong verdict, not a budget pass)"; return; fi
  if [ "$SPAWNS" -le "$3" ]; then ok "$1: $SPAWNS spawns <= $3 budget"
  else bad "$1: $SPAWNS spawns EXCEEDS the $3 budget — a candidate-path subprocess REGRESSION (each re-added spawn is ~0.4–3s on the Windows/CrowdStrike host; this is how the 23–25s Stage-2B latency crept in)"; fi
}

# 16 KiB safe command (linear parser: must NOT add spawns vs a short safe push).
_big() { awk -v k="$1" 'BEGIN{s="git push safe HEAD:topic # "; while(length(s)<k) s=s "padpadpadpadpadp "; printf "%s", substr(s,1,k)}'; }

echo "════ Stage-2C candidate-path subprocess budget (host-independent regression gate) ════"
# Stage-2C MEASURED counts (this repo, optimized): safe-AUTO 20, canonical-CONFIRM 11, forbidden-BLOCK 7,
# two-safe 98, 16KiB 20. Budgets = measured + headroom for cross-platform binary variance. A budget breach
# means a spawn was RE-ADDED to the hot path (the regression class). See PERF comments at the top.
budget "1 safe AUTO push"        "git push safe HEAD:topic"                              26  0
budget "2 canonical CONFIRM"     "git push safe HEAD:main"                               16  0
budget "3 forbidden BLOCK"       "git push evil HEAD:topic"                              12  2
budget "4 16KiB safe push"       "$(_big 16384)"                                         26  0
budget "5 two-safe (multi-node)" "git push safe HEAD:topic; git push safe HEAD:other"   112  0

echo ""
echo "ir-push-spawn-budget tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
