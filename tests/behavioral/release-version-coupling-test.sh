#!/usr/bin/env bash
# release-version-coupling-test.sh — the compiled RELEASE_VERSION must not drift from what is being released
# (adversarial-review P1 durable guard). The installer stamps every git-object install with the compiled
# constant tools/preflight-user.sh:RELEASE_VERSION; if a release is cut without bumping it, the installed
# runtime self-reports the WRONG version across `preflight version`, `verify`, and RUNTIME_MANIFEST — and
# diverges from the artifact's own SBOM/manifest. This test couples the constant to the CHANGELOG's top
# entry (the single source of "what version is current") so an un-bumped constant fails CI before it ships.
#
# It also asserts the constant is a well-formed vX.Y.Z[-pre] string. Exit 0 = coupled + well-formed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CLI="$ROOT/tools/preflight-user.sh"
CHANGELOG="$ROOT/CHANGELOG.md"
PASS=0; FAIL=0
ok(){ echo "PASS: $1"; PASS=$((PASS+1)); }
bad(){ echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }
[ -f "$CLI" ] || { bad "installer missing"; echo "release-version-coupling: 0/1"; exit 1; }

# compiled constant
CONST="$(grep -m1 -E '^RELEASE_VERSION=' "$CLI" | sed -E 's/^RELEASE_VERSION="?([^"]*)"?.*/\1/')"
# well-formed vX.Y.Z with an optional -rc.N / -beta.N / etc. suffix
case "$CONST" in
  v[0-9]*.[0-9]*.[0-9]*) ok "RELEASE_VERSION is well-formed ($CONST)" ;;
  *) bad "RELEASE_VERSION is not a well-formed vX.Y.Z[-pre] string: '$CONST'" ;;
esac

# CHANGELOG top version entry (first `## vX.Y.Z...` line)
if [ -f "$CHANGELOG" ]; then
  CL="$(grep -m1 -E '^## v[0-9]' "$CHANGELOG" | sed -E 's/^## (v[0-9][^ ]*).*/\1/')"
  if [ -z "$CL" ]; then bad "no '## vX.Y.Z' entry found in CHANGELOG.md"
  elif [ "$CONST" = "$CL" ]; then ok "RELEASE_VERSION ($CONST) == CHANGELOG top entry ($CL)"
  else bad "VERSION DRIFT: RELEASE_VERSION='$CONST' but CHANGELOG top entry is '$CL'. Bump the constant AND the CHANGELOG together when cutting a release (an un-bumped constant makes every install self-report the wrong version)."
  fi
else
  bad "CHANGELOG.md not found"
fi

# The builder takes VER as an arg (does not hardcode a version) — assert it stays that way so the artifact's
# version is caller-supplied (the release script passes the tag), never a second hardcoded literal to drift.
BLD="$ROOT/tools/user/build-artifact.sh"
if [ -f "$BLD" ]; then
  if grep -qE 'VER="?\$\{?2' "$BLD" || grep -qE 'VER="\$\{2' "$BLD" || grep -qE '^REF=.*VER=' "$BLD"; then
    ok "build-artifact.sh takes the version as an argument (no hardcoded release literal)"
  else
    # tolerant: just assert there is no hardcoded vX.Y.Z release literal assigned to VER
    if grep -qE 'VER=("?v[0-9]+\.[0-9]+\.[0-9]+)' "$BLD"; then
      bad "build-artifact.sh hardcodes a version literal in VER= (should be the \$2 argument)"
    else
      ok "build-artifact.sh has no hardcoded version literal"
    fi
  fi
fi

echo ""
echo "release-version-coupling: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
