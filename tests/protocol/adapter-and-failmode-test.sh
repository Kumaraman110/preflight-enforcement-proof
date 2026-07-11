#!/usr/bin/env bash
# Behavioral test: the claude-code ADAPTER (producer) + verifier failure modes.
#
# Proves Success-Contract #6 (Claude Code represented as an ADAPTER, not the platform
# core): the adapter reads the EXISTING .preflight/gate/ evidence files + a router tier
# and emits a conforming Action Intent + Evidence Bundle that the server-authoritative
# verifier independently accepts. It also proves the fail-closed behavior for the
# remaining mission cases: dependency failure (unreadable schema dir), a tampered
# adapter artifact, and a timeout/interpreter-failure simulation.
#
# The adapter writes ONLY into a throwaway mktemp gate dir — the repo's real
# .preflight/gate/ is never read or written.
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

if ! _probe_python; then
  bad "no working python3/python interpreter (fail-closed: NOT green)"
  echo ""; echo "adapter-and-failmode: ${PASS} passed, ${FAIL} failed"; exit 1
fi

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
NOW="2026-07-10T09:05:00Z"
HEAD="abc1234def5678"

# ── Set up a throwaway "consumer" with real .preflight/gate/ evidence files ───────────────────────────
CONS="$TMPROOT/consumer"; GATE="$CONS/.preflight/gate"; mkdir -p "$GATE"
cat > "$GATE/tests-pass" <<EOF
GATE=tests-pass
HEAD=$HEAD
TIMESTAMP=2026-07-10T09:00:00Z
EOF
cat > "$GATE/stage1-clean" <<EOF
GATE=stage1-clean
HEAD=$HEAD
TIMESTAMP=2026-07-10T09:00:02Z
EOF

# ── 1. ADAPTER produces conforming artifacts from the existing gate evidence ──────────────────────────
( cd "$PROTO_ROOT" && "$PF_PY" -m verifier.pfverify.adapters.claude_code_adapter \
    --repo-root "$CONS" --head "$HEAD" --branch topic --tier AUTO \
    --remote safe --refspec HEAD:topic --intent-id cc-1 \
    --evidence-root "$CONS" \
    --out-intent "$TMPROOT/i.json" --out-bundle "$TMPROOT/b.json" ) 2>/dev/null
if [ -f "$TMPROOT/i.json" ] && [ -f "$TMPROOT/b.json" ]; then
  ok "adapter emitted intent + bundle from existing .preflight/gate/ evidence"
else
  bad "adapter did not emit both artifacts"
fi

# issuer is the claude-code adapter (provenance). Path passed as ARGV (MSYS path-safe).
ISS="$("$PF_PY" -c "import json,sys;print(json.load(open(sys.argv[1],encoding='utf-8'))['issuer']['adapter'])" "$TMPROOT/b.json" 2>/dev/null)"
[ "$ISS" = "claude-code" ] && ok "adapter provenance issuer=claude-code" || bad "adapter issuer wrong: '$ISS'"

# it carried the tests-pass gate AND the push-tier evidence
TYPES="$("$PF_PY" -c "import json,sys;print(','.join(sorted(e['type'] for e in json.load(open(sys.argv[1],encoding='utf-8'))['evidence'])))" "$TMPROOT/b.json" 2>/dev/null)"
case "$TYPES" in
  *push-tier*) case "$TYPES" in *tests-pass*) ok "adapter carried tests-pass + push-tier ($TYPES)";; *) bad "adapter missing tests-pass ($TYPES)";; esac;;
  *) bad "adapter missing push-tier ($TYPES)";;
esac

# ── 2. VERIFY the adapter output → ALLOW / exit 0 (kernel-as-producer, verifier-as-core) ──────────────
OUT="$(pf_verify "$TMPROOT/i.json" "$TMPROOT/b.json" "$CONS" "$NOW")"; RC=$?
pf_assert "verify adapter output (AUTO)" "$OUT" "$RC" ALLOW 0

# ── 3. ADAPTER honesty: a CONFIRM tier from the router → REQUIRE_APPROVAL (not silently allowed) ──────
( cd "$PROTO_ROOT" && "$PF_PY" -m verifier.pfverify.adapters.claude_code_adapter \
    --repo-root "$CONS" --head "$HEAD" --branch main --tier CONFIRM \
    --remote safe --refspec HEAD:main --intent-id cc-2 \
    --evidence-root "$CONS" \
    --out-intent "$TMPROOT/i2.json" --out-bundle "$TMPROOT/b2.json" ) 2>/dev/null
OUT="$(pf_verify "$TMPROOT/i2.json" "$TMPROOT/b2.json" "$CONS" "$NOW")"; RC=$?
pf_assert "verify adapter output (CONFIRM tier)" "$OUT" "$RC" REQUIRE_APPROVAL 10

# ── 4. TAMPER an adapter artifact after production → BLOCK hash.mismatch ───────────────────────────────
# Edit the gate file the adapter hashed, then re-verify with the ORIGINAL bundle.
printf 'GATE=tests-pass\nHEAD=%s\nTIMESTAMP=2026-07-10T09:00:00Z\nINJECTED=evil\n' "$HEAD" > "$GATE/tests-pass"
OUT="$(pf_verify "$TMPROOT/i.json" "$TMPROOT/b.json" "$CONS" "$NOW")"; RC=$?
pf_assert "tampered adapter artifact" "$OUT" "$RC" BLOCK 20
pf_assert_violation "tampered adapter code" "$OUT" "hash.mismatch"

# ── 5. DEPENDENCY FAILURE — point --schema-dir at a nonexistent dir → BLOCK dependency.unavailable ────
OUT="$( cd "$PROTO_ROOT" && "$PF_PY" -m verifier.pfverify --intent "$TMPROOT/i.json" --bundle "$TMPROOT/b.json" \
        --policy "$POLICY" --evidence-root "$CONS" --now "$NOW" --schema-dir "$TMPROOT/nope" 2>/dev/null )"; RC=$?
pf_assert "dependency-missing-schema-dir" "$OUT" "$RC" BLOCK 20
pf_assert_violation "dependency schema code" "$OUT" "dependency.unavailable"

# ── 6. TIMEOUT / dependency-runtime failure — verifier under a 0s timeout is killed → NON-zero, NOT 0 ─
# A killed verifier must NEVER present as ALLOW(0). We wrap it in `timeout` with an impossibly short
# budget; the SIGTERM/kill yields rc 124/137 — a fail-closed non-allow for the shell caller. (If `timeout`
# is unavailable on the host, self-note and skip — this is an env capability, not a product regression.)
if command -v timeout >/dev/null 2>&1; then
  ( cd "$PROTO_ROOT" && timeout -s KILL 0.001 "$PF_PY" -m verifier.pfverify --intent "$TMPROOT/i.json" \
      --bundle "$TMPROOT/b.json" --policy "$POLICY" --evidence-root "$CONS" --now "$NOW" >/dev/null 2>&1 )
  RC=$?
  if [ "$RC" -ne 0 ]; then
    ok "timeout-killed verifier is non-ALLOW (rc=$RC, never 0)"
  else
    bad "timeout-killed verifier returned 0 (fail-OPEN!)"
  fi
else
  ok "timeout unavailable on host — case self-noted skip (env capability, not a regression)"
fi

# ── 7. Router/hook SOURCE untouched by the adapter — the adapter only READS gate outputs ──────────────
# Assert the adapter module contains no write to hooks/ or lib/ (static guard on the producer boundary).
if grep -Eq "open\([^)]*hooks/|open\([^)]*/lib/|subprocess" "$PROTO_ROOT/verifier/pfverify/adapters/claude_code_adapter.py"; then
  bad "adapter appears to write kernel source or shell out — producer boundary violated"
else
  ok "adapter does not write kernel source / shell out (producer boundary intact)"
fi

echo ""
echo "adapter-and-failmode: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
