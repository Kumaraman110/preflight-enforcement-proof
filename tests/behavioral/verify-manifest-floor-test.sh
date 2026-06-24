#!/usr/bin/env bash
# Behavioral test for the preflight-verify.sh cluster: M11 (manifest floor) + H7 (skill content-check).
#
# THE TWO FINDINGS (FRAMEWORK-SCRUTINY-FINDINGS + MEDIUM-FIXES-DESIGN.md Cluster B), both in
# tools/preflight-verify.sh, composed as ONE fail-closed pass:
#   M11 (false-green, silent-absence): verify reported "Integrity: PASS" exit 0 on a degenerate manifest
#       with ZERO framework files on disk — all-empty artifacts.*={} (CHECKED_COUNT=0), artifacts.agents=null
#       (swallowed jq error in the procsub), artifacts absent, or artifacts a non-object. "Nothing checked"
#       read as "everything matched". FIX (3 seams): (1) a manifest-shape + mandatory-surface floor (assert
#       .artifacts is an object and {agents,skills} are each a non-empty object); (2) a CHECKED_COUNT==0
#       backstop before the final PASS; (3) type-classify the optional surfaces (absent->skip, object->iterate,
#       else->FAIL).
#   H7 (false-green): skills are the only invocable surface, but verify only tested [ -f SKILL.md ] and
#       printed OK — the manifest tree-SHA was NEVER compared. A tampered SKILL.md, an added sibling, or a
#       deleted SKILL.md (a non-DRIFT WARN) all passed. FIX: recompute the installed skill's tree sha
#       (isolated throwaway git repo, core.autocrlf=input to match the committed objects) and compare to the
#       manifest's stored tree sha; any mismatch/missing = DRIFT (exit 1), incrementing CHECKED_COUNT.
#
# COMPOSITION: M11's floor runs FIRST; if it FAILs, H7's per-skill compare never runs (a null/empty skills
# object can't be content-checked). THE JOINT GUARD: a fully-populated, UNTAMPERED real install -> exit 0
# PASS after BOTH fixes (proves the floor + the content-check don't false-block a legitimate install).
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERIFY="$ROOT/tools/preflight-verify.sh"
INSTALL="$ROOT/tools/preflight-install.sh"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

for f in "$VERIFY" "$INSTALL"; do
  [ -f "$f" ] || { bad "missing $f"; echo ""; echo "verify-manifest-floor tests: ${PASS} passed, ${FAIL} failed"; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required for this test"; echo ""; echo "verify-manifest-floor tests: ${PASS} passed, ${FAIL} failed"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# v <consumer-dir> -> sets RC and OUT (verify stdout+stderr). Verify takes no code-forge arg (skip staleness).
v() { OUT="$(bash "$VERIFY" "$1" 2>&1)"; RC=$?; }
# has_pass / no_pass — assert the "Integrity: PASS" attestation is / is not printed (the false-green line).
has_pass() { printf '%s' "$OUT" | grep -q "Integrity: PASS"; }

# ── Build ONE authentic consumer via the real installer (the GREEN / no-false-positive fixture). ──
REAL="$TMP/real"; mkdir -p "$REAL"
( cd "$REAL" && git init -q ) >/dev/null 2>&1
if ! bash "$INSTALL" "$REAL" HEAD >/dev/null 2>&1; then
  bad "could not install a real consumer fixture (installer failed)"; echo ""; echo "verify-manifest-floor tests: ${PASS} passed, ${FAIL} failed"; exit 1
fi
MAN="$REAL/.preflight/installed.lock"

# Helper: clone the real consumer to a fresh dir so each mutation is isolated.
clone_real() { local d="$TMP/$1"; cp -r "$REAL" "$d"; echo "$d"; }
# Helper: write a crafted manifest into a zero-files consumer.
mk_manifest() { local d="$TMP/$1"; mkdir -p "$d/.preflight" "$d/.claude"; printf '%s' "$2" > "$d/.preflight/installed.lock"; echo "$d"; }

echo "════════ JOINT GUARD — a fully-populated, untampered real install must PASS (exit 0) ════════"
v "$REAL"
{ [ "$RC" -eq 0 ] && has_pass; } && ok "JOINT GUARD: untampered real install -> exit 0 PASS (floor + content-check do not false-block)" \
                                 || bad "JOINT GUARD: real install should PASS(0), got RC=$RC OUT=$(printf '%s' "$OUT" | tr '\n' '|' | tail -c 200)"

echo "════════ M11 — degenerate manifest + ZERO files on disk must FAIL (exit 1), no PASS line ════════"
EMPTY=$(mk_manifest m11_empty '{"pinnedRef":"HEAD","resolvedSha":"deadbeef","installedAt":"x","artifacts":{"agents":{},"skills":{},"lib":{},"hooks":{},"examples":{},"docs":{},"defaults":{}}}')
v "$EMPTY"; { [ "$RC" -eq 1 ] && ! has_pass; } && ok "M11 all-empty artifacts.*={} -> FAIL exit 1, NO 'Integrity: PASS'" \
                                              || bad "M11 all-empty: expected FAIL(1)+no-PASS, got RC=$RC pass=$(has_pass && echo y || echo n)"
NULLAG=$(mk_manifest m11_null '{"pinnedRef":"HEAD","resolvedSha":"d","installedAt":"x","artifacts":{"agents":null,"skills":{},"lib":{},"hooks":{},"examples":{},"docs":{},"defaults":{}}}')
v "$NULLAG"; { [ "$RC" -eq 1 ] && ! has_pass; } && ok "M11 artifacts.agents=null -> FAIL exit 1 (mandatory-surface type check)" \
                                               || bad "M11 agents=null: expected FAIL(1)+no-PASS, got RC=$RC"
PARTIAL=$(mk_manifest m11_partial '{"pinnedRef":"HEAD","resolvedSha":"d","installedAt":"x","artifacts":{"agents":{"code-reviewer.md":"abc"}}}')
v "$PARTIAL"; { [ "$RC" -eq 1 ] && ! has_pass; } && ok "M11 only agents present, skills MISSING -> FAIL exit 1 (mandatory floor)" \
                                                 || bad "M11 partial: expected FAIL(1)+no-PASS, got RC=$RC"
NOART=$(mk_manifest m11_noart '{"pinnedRef":"HEAD","resolvedSha":"d","installedAt":"x"}')
v "$NOART"; { [ "$RC" -eq 1 ] && ! has_pass; } && ok "M11 artifacts key ABSENT -> FAIL exit 1 (shape check)" \
                                              || bad "M11 artifacts-absent: expected FAIL(1)+no-PASS, got RC=$RC"
NONOBJ=$(mk_manifest m11_nonobj '{"pinnedRef":"HEAD","resolvedSha":"d","installedAt":"x","artifacts":"oops"}')
v "$NONOBJ"; { [ "$RC" -eq 1 ] && ! has_pass; } && ok "M11 artifacts non-object (\"oops\") -> FAIL exit 1 (shape check)" \
                                               || bad "M11 non-object: expected FAIL(1)+no-PASS, got RC=$RC"

echo "──── M11 seam-3: a real install with a NULL optional surface must FAIL ────"
NULLOPT=$(clone_real m11_nullopt)
jq '.artifacts.lib = null' "$NULLOPT/.preflight/installed.lock" > "$NULLOPT/.preflight/installed.lock.tmp" && mv "$NULLOPT/.preflight/installed.lock.tmp" "$NULLOPT/.preflight/installed.lock"
v "$NULLOPT"; [ "$RC" -eq 1 ] && ok "M11 seam-3: a NULL optional surface (lib=null) on a real install -> FAIL exit 1 (not silently skipped)" \
                             || bad "M11 seam-3: lib=null should FAIL(1), got RC=$RC"

echo "──── M11 NO-FALSE-POSITIVE ────"
# Legacy manifest: agents+skills present (real, matching on disk), optional surfaces ABSENT (not null).
LEGACY=$(clone_real m11_legacy)
jq 'del(.artifacts.lib, .artifacts.hooks, .artifacts.examples, .artifacts.docs, .artifacts.defaults)' "$LEGACY/.preflight/installed.lock" > "$LEGACY/.preflight/installed.lock.tmp" && mv "$LEGACY/.preflight/installed.lock.tmp" "$LEGACY/.preflight/installed.lock"
v "$LEGACY"; { [ "$RC" -eq 0 ] && has_pass; } && ok "M11-NFP legacy manifest (agents+skills present, optional keys ABSENT) -> PASS exit 0 (sanctioned legacy path preserved)" \
                                              || bad "M11-NFP legacy: expected PASS(0), got RC=$RC OUT=$(printf '%s' "$OUT" | tr '\n' '|' | tail -c 200)"
# Malformed JSON manifest -> must FAIL (pin the already-safe path).
BADJSON=$(mk_manifest m11_badjson '{not valid json')
v "$BADJSON"; [ "$RC" -ne 0 ] && ok "M11 malformed-JSON manifest -> FAIL (non-zero; already-safe path pinned)" \
                              || bad "M11 malformed JSON: expected non-zero, got RC=$RC"

echo "════════ H7 — skill content-check (manifest tree-SHA compared, not just [ -f SKILL.md ]) ════════"
# Tamper a SKILL.md on a real install -> DRIFT (was a silent OK+PASS).
TAMPER=$(clone_real h7_tamper)
echo "TAMPERED CONTENT — arbitrary attacker payload" >> "$TAMPER/.claude/skills/migrate/SKILL.md"
v "$TAMPER"; { [ "$RC" -eq 1 ] && ! has_pass && printf '%s' "$OUT" | grep -qi 'DRIFT.*migrate'; } \
  && ok "H7 tampered SKILL.md -> DRIFT exit 1 (was 'OK ... PASS' — the false-green)" \
  || bad "H7 tamper: expected DRIFT(1) naming migrate, got RC=$RC pass=$(has_pass && echo y || echo n)"
# Delete a SKILL.md -> DRIFT (was a non-incrementing WARN).
DELSKILL=$(clone_real h7_delskill)
rm -f "$DELSKILL/.claude/skills/migrate/SKILL.md"
v "$DELSKILL"; { [ "$RC" -eq 1 ] && ! has_pass; } && ok "H7 deleted SKILL.md -> DRIFT exit 1 (was a non-blocking WARN)" \
                                                  || bad "H7 delete: expected DRIFT(1), got RC=$RC pass=$(has_pass && echo y || echo n)"
# Add a junk sibling into a skill dir -> DRIFT (tree sha changes).
ADDSIB=$(clone_real h7_addsib)
echo "junk" > "$ADDSIB/.claude/skills/migrate/INJECTED.md"
v "$ADDSIB"; { [ "$RC" -eq 1 ] && ! has_pass; } && ok "H7 added junk sibling in a skill dir -> DRIFT exit 1 (subtree sha changed)" \
                                               || bad "H7 add-sibling: expected DRIFT(1), got RC=$RC pass=$(has_pass && echo y || echo n)"
# Delete a whole skill dir -> DRIFT (already handled pre-fix, must stay).
DELDIR=$(clone_real h7_deldir)
rm -rf "$DELDIR/.claude/skills/migrate"
v "$DELDIR"; [ "$RC" -eq 1 ] && ok "H7 deleted skill DIR -> DRIFT exit 1 (regression baseline kept)" \
                            || bad "H7 delete-dir: expected DRIFT(1), got RC=$RC"
echo "──── H7 NO-FALSE-POSITIVE ────"
# An UNTAMPERED real install's skills must verify clean (this is also the JOINT GUARD, re-asserted post-H7).
v "$REAL"; { [ "$RC" -eq 0 ] && has_pass && printf '%s' "$OUT" | grep -qE 'OK: migrate/'; } \
  && ok "H7-NFP untampered real skills -> OK, exit 0 PASS (content-check matches the manifest tree sha)" \
  || bad "H7-NFP: untampered real install should PASS with OK skills, got RC=$RC OUT=$(printf '%s' "$OUT" | grep -i migrate | head -1)"

echo ""
echo "verify-manifest-floor tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
