#!/usr/bin/env bash
# Regression test locking in the classifier hardening from the independent trust-boundary review:
#   F-A allowlist default (unknown area → BLOCK, not AUTO)
#   F-B rename-blind (rename protected→safe → BLOCK, not AUTO)
#   F-C core.quotePath (non-ASCII protected path → BLOCK, not AUTO)
# plus the intended AUTO/CONFIRM/BLOCK mappings. No network, no secrets.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLS="$HERE/../gate/classify-tier.sh"
PASS=0; FAIL=0
ok(){ echo "PASS: $1"; PASS=$((PASS+1)); }
bad(){ echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }
command -v git >/dev/null 2>&1 || { bad "no git"; echo "classifier-hardening: $PASS passed, $FAIL failed"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
R="$TMP/repo"; git init -q "$R"
( cd "$R" && git config user.email t@t && git config user.name t && git config commit.gpgsign false
  mkdir -p app/safe app/protected app/review docs scripts
  printf 'x\n' > app/safe/a.txt; printf 'x\n' > app/protected/p.txt
  printf 'x\n' > app/review/r.txt; printf 'x\n' > docs/d.md
  git add -A && git commit -q -m base )
BASE="$( cd "$R" && git rev-parse HEAD )"

# case <name> <expected> <setup-cmds...> — runs setup on a fresh branch off BASE, classifies, resets
run(){ local name="$1" want="$2"; shift 2
  ( cd "$R" && git checkout -q -b "b-$name" "$BASE" && eval "$1" && git add -A && git commit -q -m "$name" )
  local H; H="$( cd "$R" && git rev-parse HEAD )"
  local got; got="$(bash "$CLS" "$R" "$BASE" "$H")"
  [ "$got" = "$want" ] && ok "$name → $got" || bad "$name expected $want got $got"
  ( cd "$R" && git checkout -q "$BASE" )
}

run safe-only        AUTO    'printf "y\n" >> app/safe/a.txt'
run docs-only        AUTO    'printf "y\n" >> docs/d.md'
run review           CONFIRM 'printf "y\n" >> app/review/r.txt'
run protected        BLOCK   'printf "y\n" >> app/protected/p.txt'
run gate-edit        BLOCK   'mkdir -p gate; printf "x\n" > gate/x.sh'
run unknown-area     BLOCK   'printf "d\n" >> scripts/deploy.sh'          # F-A allowlist default
run root-file        BLOCK   'printf "m\n" > Makefile'                    # F-A
run rename-protected BLOCK   'git mv app/protected/p.txt app/safe/p.txt'  # F-B rename-blind
run nonascii-prot    BLOCK   'printf "x\n" > app/protected/é.txt'         # F-C core.quotePath
run mixed-safe-prot  BLOCK   'printf "y\n" >> app/safe/a.txt; printf "y\n" >> app/protected/p.txt'
run safe-plus-hints  AUTO    'printf "y\n" >> app/safe/a.txt; mkdir -p .gate/artifacts; printf "tier=AUTO\n" > .gate/artifacts/tier.txt'  # PR hints allowed
run gate-nonartifact BLOCK   'mkdir -p .gate/evidence; printf "x\n" > .gate/evidence/x.txt'  # rest of .gate/ NOT safe

echo ""
echo "classifier-hardening: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
