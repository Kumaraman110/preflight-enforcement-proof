#!/usr/bin/env bash
# Behavioral test for .github/CODEOWNERS — the Model B base-owners governance path.
#
# WHAT IT CHECKS: the CODEOWNERS file exists, assigns the BASE rubrics + the governance machinery to a
# base-owner, and that team overlays are documented as team-owned (safe because overlays can only tighten).
# CRITICALLY it asserts the stub-vs-real state HONESTLY: while any @OWNER-PROVIDE-* stub remains, the file
# does NOT yet enforce (GitHub ignores CODEOWNERS lines naming a non-existent user — fails OPEN), so the
# test FLAGS the stub as a not-yet-live state rather than pretending it's governing.
#
# Proves:
#   C1 — CODEOWNERS exists at .github/CODEOWNERS.
#   C2 — the base rubrics path is owned (a base-owner line for /examples/rubrics/rubric-*.md).
#   C3 — the governance machinery (overlay-check, resolver, source-check) is base-owner-governed.
#   C4 — STUB-STATE HONESTY: if @OWNER-PROVIDE-* placeholders remain, the test reports NOT-YET-LIVE
#        (a clear, loud signal the owner must replace them) — it does NOT pass silently as if enforcing.
#        Once the owner replaces every stub with a real handle, C4 flips to "live-ready".
#   C5 — overlays are documented as team-owned (the tighten-only asymmetry is recorded).
#
# This is a STRUCTURE + HONESTY test. It does NOT (cannot) verify GitHub actually enforces CODEOWNERS —
# that needs the "require code owner review" toggle on the branch ruleset (an owner/admin action), which
# this test explicitly notes as out of its reach.
#
# Exit 0 = all structural assertions passed (C4 may report NOT-YET-LIVE without failing — the stub state
# is the EXPECTED current state, loudly surfaced). Exit 1 = a structural assertion failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CO="$ROOT/.github/CODEOWNERS"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }
note(){ echo "NOTE: $1"; }

# C1
if [ -f "$CO" ]; then ok "C1: .github/CODEOWNERS exists"; else
  bad "C1: .github/CODEOWNERS missing"; echo ""; echo "base-owners-codeowners tests: ${PASS} passed, ${FAIL} failed"; exit 1
fi

# C2 — base rubrics owned.
grep -qE '^/examples/rubrics/rubric-\*\.md[[:space:]]+@' "$CO" \
  && ok "C2: base rubrics (/examples/rubrics/rubric-*.md) have an owner line" \
  || bad "C2: no owner line for the base rubrics path"

# C3 — governance machinery base-owner-governed.
MACHINERY_OK=1
for f in rubric-overlay-check.sh rubric-resolve.sh rubric-source-check.sh; do
  grep -qE "^/lib/${f}[[:space:]]+@" "$CO" || { MACHINERY_OK=0; note "  /lib/$f has no owner line"; }
done
[ "$MACHINERY_OK" = "1" ] && ok "C3: governance machinery (overlay-check, resolver, source-check) is owner-governed" \
  || bad "C3: not all governance machinery files are owner-governed"

# C4 — STUB-STATE HONESTY (the load-bearing honesty assertion).
STUBS="$(grep -c 'OWNER-PROVIDE' "$CO" || echo 0)"
if [ "$STUBS" -gt 0 ]; then
  # Stub present → NOT YET LIVE. This is the EXPECTED current state. Assert it's surfaced loudly: the file
  # must carry the "GitHub SILENTLY IGNORES ... fails OPEN" warning so no one mistakes a stub for enforcement.
  if grep -qiE 'SILENTLY IGNORES|fails OPEN|MUST PROVIDE A REAL' "$CO"; then
    ok "C4: stub state HONESTLY surfaced — $STUBS @OWNER-PROVIDE stub(s) remain AND the file loudly warns that unreplaced stubs do NOT enforce (fails open). NOT-YET-LIVE until the owner replaces them."
    note "  ACTION FOR OWNER: replace every @OWNER-PROVIDE-* with a real GitHub handle/team, then enable 'require code owner review' on the branch ruleset."
  else
    bad "C4: stubs present but the file does NOT warn that unreplaced stubs fail open — a silent fail-open risk"
  fi
else
  # No stubs → owner has filled in real handles. Assert there's at least one real @owner reference.
  grep -qE '@[A-Za-z0-9][-A-Za-z0-9/]*' "$CO" \
    && ok "C4: no stubs remain — real owner handles present (live-ready, pending the GitHub 'require code owner review' toggle)" \
    || bad "C4: no stubs but no real @owner handle either — CODEOWNERS owns nothing"
fi

# C5 — overlays documented as team-owned (the tighten-only asymmetry recorded).
grep -qiE 'overlay.*team|team.*overlay|tighten' "$CO" \
  && ok "C5: team-overlay ownership + tighten-only asymmetry documented" \
  || bad "C5: CODEOWNERS does not document team-overlay ownership"

echo ""
echo "base-owners-codeowners tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
