#!/usr/bin/env bash
# Behavioral test: ANCESTRY-AWARE release-relation classification in tools/preflight-verify.sh (BLOCKER 1).
#
# THE DEFECT: the old Step-3 staleness check compared `latest-tag-SHA != installed-SHA` and returned STALE
# (exit 2) for ANY inequality — mislabeling a deliberately-pinned candidate that is NEWER than the latest
# tag (a descendant). The fix classifies by COMMIT ANCESTRY:
#   == -> CURRENT_RELEASE (0) · descendant -> PINNED_AHEAD (0) · ancestor -> STALE (2) ·
#   unrelated/unresolvable/no-tag -> DIVERGED_OR_UNKNOWN (3) · integrity/hazard -> exit 1 (precedence).
#
# ISOLATED FIXTURES ONLY — a throwaway code-forge git repo with controlled tags/ancestry + a throwaway
# consumer with a real (drift-free) install built from that repo. NO dependency on the live repo's mutable
# tags. Exit 0 = all pass.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERIFY="$ROOT/tools/preflight-verify.sh"
INSTALL="$ROOT/tools/preflight-install.sh"
[ -f "$VERIFY" ] || { echo "FAIL: verify not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required."; echo ""; echo "verify-release-relation tests: 0 passed, 0 failed (skipped)"; exit 0; }

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }
_CLEAN=(); trap 'for d in "${_CLEAN[@]}"; do rm -rf "$d" 2>/dev/null || true; done' EXIT

# ── Build an isolated "code-forge"-shaped git repo carrying the FULL shippable surface, so the real
# installer can install from it and the verifier can hash + ancestry-check against it. We seed it from the
# LIVE source tree's committed surfaces (copied as files, then committed in our throwaway repo) so the
# manifest/blob shapes are real. We then place tags at chosen commits to drive each ancestry case.
FORGE="$(mktemp -d)/forge"; mkdir -p "$FORGE"; _CLEAN+=("$(dirname "$FORGE")")
(
  cd "$FORGE"
  # core.autocrlf=input: normalize CRLF->LF on commit so the fixture's committed-object blob SHAs match the
  # canonical LF blobs the installer reads (the live Windows working tree carries CRLF; committing it with
  # autocrlf=false would record CRLF blobs whose SHAs differ from the installed LF-object files → spurious
  # drift in the fixture, not a verifier/installer defect). This mirrors recompute_skill_tree's own
  # core.autocrlf input normalization.
  git init -q; git config user.email t@t; git config user.name t; git config core.autocrlf input
  # copy the shippable surfaces from the live source working tree (HEAD-committed content is fine for fixtures)
  for s in agents skills lib hooks examples docs defaults tools; do
    [ -d "$ROOT/$s" ] && { mkdir -p "$s"; cp -r "$ROOT/$s/." "$s/" 2>/dev/null || true; }
  done
  git add -A; git commit -qm "base surface" >/dev/null
) >/dev/null 2>&1
BASE_SHA="$(git -C "$FORGE" rev-parse HEAD)"
# add two more commits on top (descendants of BASE)
( cd "$FORGE"; echo "x" > docs/_fixture_marker_1.md; git add -A; git commit -qm c1 ) >/dev/null 2>&1
MID_SHA="$(git -C "$FORGE" rev-parse HEAD)"
( cd "$FORGE"; echo "y" > docs/_fixture_marker_2.md; git add -A; git commit -qm c2 ) >/dev/null 2>&1
TIP_SHA="$(git -C "$FORGE" rev-parse HEAD)"
# a DIVERGENT branch off BASE (unrelated to MID/TIP)
( cd "$FORGE"; git checkout -q -b sidebranch "$BASE_SHA"; echo "z" > docs/_fixture_side.md; git add -A; git commit -qm side; git checkout -q master 2>/dev/null || git checkout -q main 2>/dev/null || git checkout -q "$TIP_SHA" ) >/dev/null 2>&1
SIDE_SHA="$(git -C "$FORGE" rev-parse sidebranch)"

# Install the framework from a chosen ref into a fresh throwaway consumer; echoes consumer dir.
mk_consumer() {  # $1 = ref to install (a SHA in FORGE)
  local ref="$1" cdir; cdir="$(mktemp -d)/consumer"; mkdir -p "$cdir"; _CLEAN+=("$(dirname "$cdir")")
  ( cd "$cdir"; git init -q; git config user.email t@t; git config user.name t
    echo app > app.txt; git add -A; git commit -qm init ) >/dev/null 2>&1
  ( PREFLIGHT_SKIP_RUNTIME=1 CODE_FORGE_DIR="$FORGE" bash "$INSTALL" "$cdir" "$ref" ) >/dev/null 2>&1
  printf '%s' "$cdir"
}
# run verify; sets RC + OUT
run_verify() {  # $1 = consumer dir ; $2 = code-forge dir (or "")
  OUT="$(bash "$VERIFY" "$1" "$2" 2>&1)"; RC=$?
}
# tag helper
settag() { git -C "$FORGE" tag -f "$1" "$2" >/dev/null 2>&1; }
cleartags() { git -C "$FORGE" tag -l 'v*' | while read -r t; do git -C "$FORGE" tag -d "$t" >/dev/null 2>&1; done; }

echo "════ release-relation classification (isolated fixtures; ancestry, not bare inequality) ════"

# (1) installed == latest tag  → CURRENT_RELEASE / exit 0
cleartags; settag v0.9.0 "$TIP_SHA"
C_TIP="$(mk_consumer "$TIP_SHA")"
run_verify "$C_TIP" "$FORGE"
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'CURRENT_RELEASE'; } && ok "installed==latest tag → CURRENT_RELEASE / exit 0" || bad "CURRENT_RELEASE: got rc=$RC :: $(printf '%s' "$OUT"|grep -iE 'release|=== '|tail -1)"

# (2) installed is DESCENDANT of latest tag → PINNED_AHEAD / exit 0  (THE PILOT TOPOLOGY)
cleartags; settag v0.9.0 "$BASE_SHA"           # latest tag = BASE; installed = TIP (descendant)
C_AHEAD="$(mk_consumer "$TIP_SHA")"
run_verify "$C_AHEAD" "$FORGE"
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'PINNED_AHEAD'; } && ok "installed descendant of latest tag → PINNED_AHEAD / exit 0 (pilot topology)" || bad "PINNED_AHEAD: got rc=$RC :: $(printf '%s' "$OUT"|grep -iE 'release|=== '|tail -1)"
printf '%s' "$OUT" | grep -qiE 'INTACT and NEWER|newer than the latest tagged' && ok "PINNED_AHEAD message states intact + newer than latest tag" || bad "PINNED_AHEAD message lacks intact/newer wording"

# (3) installed is ANCESTOR of latest tag → STALE / exit 2
cleartags; settag v0.9.0 "$TIP_SHA"            # latest tag = TIP; installed = BASE (ancestor)
C_STALE="$(mk_consumer "$BASE_SHA")"
run_verify "$C_STALE" "$FORGE"
{ [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'STALE'; } && ok "installed ancestor of latest tag → STALE / exit 2" || bad "STALE: got rc=$RC :: $(printf '%s' "$OUT"|grep -iE 'release|=== '|tail -1)"

# (4) installed UNRELATED to latest tag → DIVERGED_OR_UNKNOWN / exit 3
cleartags; settag v0.9.0 "$SIDE_SHA"           # latest tag = sidebranch; installed = TIP (unrelated)
C_DIV="$(mk_consumer "$TIP_SHA")"
run_verify "$C_DIV" "$FORGE"
{ [ "$RC" -eq 3 ] && printf '%s' "$OUT" | grep -q 'DIVERGED_OR_UNKNOWN'; } && ok "installed unrelated to latest tag → DIVERGED_OR_UNKNOWN / exit 3" || bad "DIVERGED: got rc=$RC :: $(printf '%s' "$OUT"|grep -iE 'release|=== '|tail -1)"

# (5) NO tags in repo → DIVERGED_OR_UNKNOWN / exit 3
cleartags
C_NOTAG="$(mk_consumer "$TIP_SHA")"
run_verify "$C_NOTAG" "$FORGE"
{ [ "$RC" -eq 3 ] && printf '%s' "$OUT" | grep -q 'DIVERGED_OR_UNKNOWN'; } && ok "no release tags → DIVERGED_OR_UNKNOWN / exit 3" || bad "no-tag: got rc=$RC :: $(printf '%s' "$OUT"|grep -iE 'release|=== '|tail -1)"

# (6) missing/unresolvable installed object (manifest SHA not in forge) → DIVERGED_OR_UNKNOWN / exit 3
cleartags; settag v0.9.0 "$TIP_SHA"
C_BADSHA="$(mk_consumer "$TIP_SHA")"
# tamper the manifest's resolvedSha to a non-existent commit (release-relation only; artifacts still match)
jq '.resolvedSha="0000000000000000000000000000000000000000" | .pinnedRef="0000000"' "$C_BADSHA/.preflight/installed.lock" > "$C_BADSHA/.preflight/installed.lock.tmp" && mv "$C_BADSHA/.preflight/installed.lock.tmp" "$C_BADSHA/.preflight/installed.lock"
run_verify "$C_BADSHA" "$FORGE"
{ [ "$RC" -eq 3 ] && printf '%s' "$OUT" | grep -q 'DIVERGED_OR_UNKNOWN'; } && ok "unresolvable installed object → DIVERGED_OR_UNKNOWN / exit 3" || bad "unresolvable: got rc=$RC :: $(printf '%s' "$OUT"|grep -iE 'release|=== '|tail -1)"

# (7) code-forge path omitted → release SKIPPED, integrity PASS / exit 0
cleartags; settag v0.9.0 "$TIP_SHA"
C_NOFORGE="$(mk_consumer "$TIP_SHA")"
run_verify "$C_NOFORGE" ""
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qiE 'SKIPPED'; } && ok "no code-forge path → release SKIPPED, integrity PASS / exit 0" || bad "no-forge: got rc=$RC :: $(printf '%s' "$OUT"|grep -iE 'release|=== '|tail -1)"

echo "════ integrity precedence: drift / mismatch FAIL (exit 1) regardless of release relation ════"
# (8) artifact drift remains INTEGRITY_FAILURE exit 1 — even when release would be PINNED_AHEAD
cleartags; settag v0.9.0 "$BASE_SHA"
C_DRIFT="$(mk_consumer "$TIP_SHA")"
# tamper an installed agent file → blob drift
_agent="$(ls "$C_DRIFT/.claude/agents"/*.md 2>/dev/null | head -1)"
[ -n "$_agent" ] && echo "TAMPER" >> "$_agent"
run_verify "$C_DRIFT" "$FORGE"
{ [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qiE 'DRIFT|INTEGRITY_FAILURE|artifact'; } && ok "artifact drift → exit 1 (integrity), NOT hidden behind PINNED_AHEAD" || bad "drift: expected exit 1, got rc=$RC :: $(printf '%s' "$OUT"|grep -iE '=== |DRIFT'|tail -1)"

# (9) missing required artifact → INTEGRITY_FAILURE exit 1
cleartags; settag v0.9.0 "$BASE_SHA"
C_MISS="$(mk_consumer "$TIP_SHA")"
_agent2="$(ls "$C_MISS/.claude/agents"/*.md 2>/dev/null | head -1)"
[ -n "$_agent2" ] && rm -f "$_agent2"
run_verify "$C_MISS" "$FORGE"
{ [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qiE 'MISSING|DRIFT'; } && ok "missing required artifact → exit 1 (integrity)" || bad "missing-artifact: expected exit 1, got rc=$RC"

# (10) corrupt manifest (artifacts not object) → INTEGRITY_FAILURE exit 1 (precedes release relation)
cleartags; settag v0.9.0 "$TIP_SHA"
C_CORRUPT="$(mk_consumer "$TIP_SHA")"
printf '{"pinnedRef":"x","resolvedSha":"x","artifacts":"oops"}' > "$C_CORRUPT/.preflight/installed.lock"
run_verify "$C_CORRUPT" "$FORGE"
[ "$RC" -eq 1 ] && ok "corrupt manifest → exit 1 (integrity), release relation never reached" || bad "corrupt-manifest: expected exit 1, got rc=$RC"

echo ""
echo "verify-release-relation tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
