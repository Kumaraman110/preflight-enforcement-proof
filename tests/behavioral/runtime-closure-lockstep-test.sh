#!/usr/bin/env bash
# runtime-closure-lockstep-test.sh — the installer (tools/preflight-user.sh) and the artifact builder
# (tools/user/build-artifact.sh) each declare the runtime closure (which hooks + libs ship into a user
# install). If they DIVERGE, one path ships a file the other omits — e.g. the builder shipped an artifact
# WITHOUT hook-arbitration.sh while the installer's RUNTIME_LIBS included it, so a from-artifact install
# would carry a broken/absent arbitration lib. This is the dead-gate / dual-source bug class. This test
# asserts the two declared lists are IDENTICAL, and that every declared lib/hook actually exists in the
# tree (so neither list names a phantom file).
#
# Exit 0 = lists match and every member exists.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
INST="$REPO/tools/preflight-user.sh"
BLD="$REPO/tools/user/build-artifact.sh"
PASS=0; FAIL=0
ok(){ echo "PASS: $1"; PASS=$((PASS+1)); }
bad(){ echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }
[ -f "$INST" ] && [ -f "$BLD" ] || { bad "installer or builder missing"; echo "lockstep: 0/1"; exit 1; }

# extract a quoted assignment's value: <NAME>="..." → the ... (single logical line)
val(){ grep -m1 -E "^$1=" "$2" | sed -E "s/^$1=\"([^\"]*)\".*/\1/"; }
norm(){ printf '%s\n' "$1" | tr ' ' '\n' | grep -v '^$' | LC_ALL=C sort | tr '\n' ' '; }

I_HOOKS="$(norm "$(val RUNTIME_HOOKS "$INST")")"
B_HOOKS="$(norm "$(val HOOKS "$BLD")")"
I_LIBS="$(norm "$(val RUNTIME_LIBS "$INST")")"
B_LIBS="$(norm "$(val LIBS "$BLD")")"

[ -n "$I_HOOKS" ] && [ -n "$B_HOOKS" ] || bad "could not read HOOKS lists (I=[$I_HOOKS] B=[$B_HOOKS])"
[ -n "$I_LIBS" ] && [ -n "$B_LIBS" ] || bad "could not read LIBS lists (I=[$I_LIBS] B=[$B_LIBS])"

[ "$I_HOOKS" = "$B_HOOKS" ] && ok "runtime HOOKS lists match (installer == builder)" \
  || bad "HOOKS DIVERGE — installer:[$I_HOOKS] builder:[$B_HOOKS]"
[ "$I_LIBS" = "$B_LIBS" ] && ok "runtime LIBS lists match (installer == builder)" \
  || bad "LIBS DIVERGE — installer:[$I_LIBS] builder:[$B_LIBS]"

# every declared member must actually exist in the tree (no phantom entries)
for h in $I_HOOKS; do [ -f "$REPO/hooks/$h" ] && ok "hook exists: $h" || bad "declared hook missing from tree: hooks/$h"; done
for l in $I_LIBS;  do [ -f "$REPO/lib/$l" ]   && ok "lib exists: $l"   || bad "declared lib missing from tree: lib/$l"; done

# and hook-arbitration.sh specifically must be present in BOTH (the rc.3 regression that motivated this)
case " $I_LIBS " in *" hook-arbitration.sh "*) ok "hook-arbitration.sh in installer RUNTIME_LIBS";; *) bad "hook-arbitration.sh NOT in installer RUNTIME_LIBS";; esac
case " $B_LIBS " in *" hook-arbitration.sh "*) ok "hook-arbitration.sh in builder LIBS";;          *) bad "hook-arbitration.sh NOT in builder LIBS";; esac

echo ""
echo "runtime-closure-lockstep: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
