#!/usr/bin/env bash
# Behavioral test: RUNTIME-INSTALL FULL VERIFICATION + REPOSITORY-LOCAL EXCLUSION (preflight Stage 2C.1).
#
# Two remediations proven here:
#
#  (A) preflight-verify.sh supports the BRANCH-STABLE RUNTIME-INSTALL model directly. The runtime-install
#      model has NO .preflight/installed.lock; before 2C.1 the verifier hard-FAILed ("not installed") on a
#      perfectly valid runtime install and had no way to attest it. Now the installer writes an immutable
#      per-generation RUNTIME_MANIFEST.json (source blob shas) and the verifier validates the ACTIVE runtime
#      against it. A VALID runtime install → full PASS (exit 0); a BROKEN one → FAIL (exit 1). The absence of
#      installed.lock is NEVER by itself a PASS.
#
#  (B) preflight-runtime-install.sh no longer mutates the consumer's TRACKED .gitignore. It excludes
#      .claude/settings.local.json via the repository-LOCAL, UNTRACKED .git/info/exclude instead — so a clean
#      consumer stays clean, a dirty consumer's porcelain is unchanged except approved untracked runtime
#      metadata, and repeated installs never duplicate the exclusion.
#
# Exit 0 = all assertions passed; exit 1 = at least one failed. Isolated mktemp consumers; no network.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL="$ROOT/tools/preflight-runtime-install.sh"
VERIFY="$ROOT/tools/preflight-verify.sh"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

for f in "$INSTALL" "$VERIFY"; do [ -f "$f" ] || { bad "missing $f"; echo "runtime-verify-and-exclude: ${PASS} passed, ${FAIL} failed"; exit 1; }; done
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; echo "runtime-verify-and-exclude: 0 passed, 0 failed (skipped)"; exit 0; }
git -C "$ROOT" cat-file -e HEAD:hooks/pre-bash-risk-router 2>/dev/null || { echo "SKIP: router not committed at HEAD"; echo "runtime-verify-and-exclude: 0 passed, 0 failed (skipped)"; exit 0; }

export CODE_FORGE_DIR="$ROOT"
T="$(mktemp -d)"; trap 'rm -rf "$T" 2>/dev/null || true' EXIT

# a fresh consumer worktree (no framework installed yet)
mk_consumer() {  # $1 = name ; echoes dir
  local c="$T/$1"; mkdir -p "$c"
  ( cd "$c" && git init -q && git commit -q --allow-empty -m init && git checkout -q -b feature/a ) >/dev/null 2>&1
  echo "$c"
}
active_dir() { echo "$1/.git/preflight/runtime/$(cat "$1/.git/preflight/runtime/ACTIVE")"; }

# ══════════════════════════════════════════════════════════════════════════════════════════════════════════
# (B) INSTALLER: repository-local untracked exclusion, tracked .gitignore never mutated.
# ══════════════════════════════════════════════════════════════════════════════════════════════════════════

# 1. CLEAN consumer (has a committed .gitignore) stays clean — .gitignore byte-identical after install.
C1="$(mk_consumer c1)"
printf 'node_modules/\n*.log\n' > "$C1/.gitignore"
( cd "$C1" && git add .gitignore && git commit -q -m "seed gitignore" )
GI_BEFORE="$(git -C "$C1" hash-object .gitignore)"
bash "$INSTALL" "$C1" HEAD >/dev/null 2>&1
GI_AFTER="$(git -C "$C1" hash-object .gitignore)"
[ "$GI_BEFORE" = "$GI_AFTER" ] \
  && ok "1: tracked .gitignore is BYTE-IDENTICAL after runtime install ($GI_BEFORE)" \
  || bad "1: .gitignore was MUTATED by install ($GI_BEFORE → $GI_AFTER)"

# 2. No TRACKED file shows as modified after install (porcelain has no ' M'/'M ' entries).
if git -C "$C1" status --porcelain=v1 | grep -qE '^[ MARC][MD] |^[MARC] '; then
  bad "2: install left a TRACKED modification: $(git -C "$C1" status --porcelain=v1 | grep -E '^[ MARC][MD] |^[MARC] ' | head -1)"
else
  ok "2: no tracked application file is modified by the runtime install (porcelain clean of tracked changes)"
fi

# 3. The exclusion lives in .git/info/exclude (untracked), and names settings.local.json exactly once.
EXCL="$C1/.git/info/exclude"
N="$(grep -cxF '.claude/settings.local.json' "$EXCL" 2>/dev/null || echo 0)"
[ "$N" -eq 1 ] \
  && ok "3: .claude/settings.local.json excluded via .git/info/exclude (exactly 1 entry, untracked)" \
  || bad "3: expected exactly 1 exclude entry in .git/info/exclude, got $N"

# 4. Idempotence: a second install does NOT duplicate the exclude entry and does NOT touch .gitignore.
bash "$INSTALL" "$C1" HEAD >/dev/null 2>&1
N2="$(grep -cxF '.claude/settings.local.json' "$EXCL" 2>/dev/null || echo 0)"
GI_AFTER2="$(git -C "$C1" hash-object .gitignore)"
{ [ "$N2" -eq 1 ] && [ "$GI_AFTER2" = "$GI_BEFORE" ]; } \
  && ok "4: reinstall is idempotent — exclude entry not duplicated ($N2) and .gitignore still identical" \
  || bad "4: reinstall duplicated the exclude (n=$N2) or mutated .gitignore ($GI_AFTER2)"

# 5. A consumer with NO .gitignore at all does not get one created (no tracked file appears).
C2="$(mk_consumer c2)"
bash "$INSTALL" "$C2" HEAD >/dev/null 2>&1
if [ -f "$C2/.gitignore" ]; then bad "5: install CREATED a .gitignore where none existed"; else ok "5: no .gitignore created when the consumer had none (exclusion is repo-local only)"; fi

# ══════════════════════════════════════════════════════════════════════════════════════════════════════════
# (A) VERIFIER: full PASS on a valid runtime install; FAIL on each corruption class.
# ══════════════════════════════════════════════════════════════════════════════════════════════════════════

# 6. VALID runtime-only install → full preflight-verify.sh PASS (exit 0).
bash "$VERIFY" "$C1" >/dev/null 2>&1
[ $? -eq 0 ] \
  && ok "6: full preflight-verify.sh PASSES a valid runtime-only install (exit 0) — no installed.lock required" \
  || { bad "6: verify did NOT pass a valid runtime install"; bash "$VERIFY" "$C1" 2>&1 | grep -E 'FAIL|DRIFT' | head -2 >&2; }

# 7. HASH MISMATCH (tamper a runtime artifact) → FAIL.
RT="$(active_dir "$C1")"
cp "$RT/hooks/pre-push-gate-engine" "$T/eng.bak"
printf '\n# tampered\n' >> "$RT/hooks/pre-push-gate-engine"
bash "$VERIFY" "$C1" >/tmp/rv.7 2>&1; RC7=$?
{ [ "$RC7" -ne 0 ] && grep -qi 'DRIFT' /tmp/rv.7; } \
  && ok "7: verify FAILs on a tampered runtime artifact (hash mismatch → DRIFT, rc=$RC7)" \
  || bad "7: verify did not fail-closed on hash mismatch (rc=$RC7)"
cp "$T/eng.bak" "$RT/hooks/pre-push-gate-engine"

# 8. MISSING PARSER LIB → FAIL.
cp "$RT/lib/shell-structure-lexer.awk" "$T/lex.bak"
rm -f "$RT/lib/shell-structure-lexer.awk"
bash "$VERIFY" "$C1" >/tmp/rv.8 2>&1; RC8=$?
{ [ "$RC8" -ne 0 ] && grep -qiE 'parser|shell-structure-lexer|MISSING' /tmp/rv.8; } \
  && ok "8: verify FAILs when the authoritative parser lib is missing (rc=$RC8)" \
  || bad "8: verify did not fail on a missing parser lib (rc=$RC8)"
cp "$T/lex.bak" "$RT/lib/shell-structure-lexer.awk"

# 9. MALFORMED RUNTIME_MANIFEST.json → FAIL.
cp "$RT/RUNTIME_MANIFEST.json" "$T/man.bak"
printf '{ not json' > "$RT/RUNTIME_MANIFEST.json"
bash "$VERIFY" "$C1" >/tmp/rv.9 2>&1; RC9=$?
{ [ "$RC9" -ne 0 ] && grep -qi 'RUNTIME_MANIFEST' /tmp/rv.9; } \
  && ok "9: verify FAILs on a malformed runtime manifest (rc=$RC9)" \
  || bad "9: verify did not fail on a malformed manifest (rc=$RC9)"

# 10. METADATA MISMATCH (manifest resolvedSha != ACTIVE) → FAIL.
jq '.resolvedSha="0000000000000000000000000000000000000000"' "$T/man.bak" > "$RT/RUNTIME_MANIFEST.json"
bash "$VERIFY" "$C1" >/tmp/rv.10 2>&1; RC10=$?
{ [ "$RC10" -ne 0 ] && grep -qi 'mismatch' /tmp/rv.10; } \
  && ok "10: verify FAILs when manifest resolvedSha != ACTIVE (metadata mismatch, rc=$RC10)" \
  || bad "10: verify did not fail on metadata mismatch (rc=$RC10)"
cp "$T/man.bak" "$RT/RUNTIME_MANIFEST.json"

# 11. INVALID PREVIOUS (points at a non-materialized generation) → FAIL.
PREVMARK="$C1/.git/preflight/runtime/PREVIOUS"
cp "$PREVMARK" "$T/prev.bak" 2>/dev/null || true
printf '%s' "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" > "$PREVMARK"
bash "$VERIFY" "$C1" >/tmp/rv.11 2>&1; RC11=$?
{ [ "$RC11" -ne 0 ] && grep -qi 'PREVIOUS' /tmp/rv.11; } \
  && ok "11: verify FAILs when PREVIOUS points at a non-materialized generation (rollback impossible, rc=$RC11)" \
  || bad "11: verify did not fail on invalid PREVIOUS (rc=$RC11)"
if [ -f "$T/prev.bak" ]; then cp "$T/prev.bak" "$PREVMARK"; else rm -f "$PREVMARK"; fi

# 12. DUPLICATE registration (tracked settings.json ALSO registers a preflight Bash gate) → FAIL.
mkdir -p "$C1/.claude"
cat > "$C1/.claude/settings.json" <<'EOF'
{ "hooks": { "PreToolUse": [ {"matcher":"Bash","hooks":[{"type":"command","command":"\"x/run-hook.cmd\" pre-bash-risk-router \"$TOOL_INPUT\"","timeout":10000}]} ] } }
EOF
bash "$VERIFY" "$C1" >/tmp/rv.12 2>&1; RC12=$?
{ [ "$RC12" -ne 0 ] && grep -qi 'DUPLICATE' /tmp/rv.12; } \
  && ok "12: verify FAILs on a duplicate tracked+local Bash registration (branch-swap hazard, rc=$RC12)" \
  || bad "12: verify did not fail on duplicate registration (rc=$RC12)"
rm -f "$C1/.claude/settings.json"

# 13. ABSENT artifact manifest AND absent runtime (genuine not-installed) → FAIL (never a silent PASS).
C3="$(mk_consumer c3)"
bash "$VERIFY" "$C3" >/tmp/rv.13 2>&1; RC13=$?
{ [ "$RC13" -ne 0 ] && grep -qi 'not installed' /tmp/rv.13; } \
  && ok "13: verify FAILs when NEITHER model is installed (absent manifest + absent runtime, rc=$RC13)" \
  || bad "13: verify did not fail on a genuinely un-installed consumer (rc=$RC13)"

# 14. After restoring C1, it PASSES again (proves the mutations above were the sole cause of each FAIL).
bash "$VERIFY" "$C1" >/dev/null 2>&1
[ $? -eq 0 ] \
  && ok "14: verify PASSES again after all corruptions are restored (fail causes were exactly the injected faults)" \
  || bad "14: verify still failing after restore — a corruption was not cleanly reverted"

echo ""
echo "runtime-verify-and-exclude: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
