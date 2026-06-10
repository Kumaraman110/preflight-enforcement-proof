#!/usr/bin/env bash
# Behavioral test for the A4 fix: tools/preflight-install.sh must resolve CODE_FORGE_DIR
# from its OWN location ($BASH_SOURCE), NOT from `git rev-parse` in the caller's cwd.
#
# RED (pre-fix): with `set -e` and CODE_FORGE_DIR unset, running the installer from a
# NON-git cwd made the line-1 command substitution exit 128 and the script died before
# doing anything — even with absolute path args.
# GREEN (post-fix): the installer resolves CODE_FORGE_DIR to the code-forge root from
# $BASH_SOURCE and proceeds past that point regardless of cwd.
#
# CRITICAL: this test MUST `unset CODE_FORGE_DIR`. If run-all-tests.sh runs with
# CODE_FORGE_DIR exported (it runs from inside code-forge), the `${VAR:-…}` short-circuit
# would let the BROKEN installer pass and the red/green would degrade to a tautology.
#
# Exit 0 = passed; exit 1 = failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="${SCRIPT_DIR}/../../tools/preflight-install.sh"
CODE_FORGE_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

if [ ! -f "$INSTALLER" ]; then bad "installer not found at $INSTALLER"; echo ""; echo "install-cwd-independence: 0 passed, 1 failed"; exit 1; fi

# A non-git scratch cwd, and a non-git consumer dir (absolute path arg).
NONGIT_CWD="$(mktemp -d)/nongit"; mkdir -p "$NONGIT_CWD"
CONSUMER="$(mktemp -d)/consumer"; mkdir -p "$CONSUMER"

# Confirm the precondition: the cwd really is NOT inside a git repo.
if git -C "$NONGIT_CWD" rev-parse --git-dir >/dev/null 2>&1; then
  bad "precondition: scratch cwd unexpectedly inside a git repo ($NONGIT_CWD) — test inconclusive"
  echo ""; echo "install-cwd-independence: ${PASS} passed, ${FAIL} failed"; exit 1
fi

# Run the installer from the non-git cwd, CODE_FORGE_DIR UNSET, absolute args. We do NOT
# want a full end-to-end install here (slow): we only need to prove it gets PAST the
# CODE_FORGE_DIR resolution instead of dying with exit 128. So we pass a BOGUS pinned ref —
# the installer resolves CODE_FORGE_DIR, prints the banner, then aborts fast at ref-resolution
# (exit 1), well before the expensive artifact copy. Capture combined output + exit code.
BOGUS_REF="___pf_no_such_ref___"
OUT="$( cd "$NONGIT_CWD" && env -u CODE_FORGE_DIR bash "$INSTALLER" "$CONSUMER" "$BOGUS_REF" 2>&1 )"
RC=$?

# Assertion 1: it must NOT die with the bare exit-128 (git-failure) signature.
if [ "$RC" -eq 128 ]; then
  bad "installer exited 128 from a non-git cwd (the A4 RED is still present)"
else
  ok "installer did NOT exit 128 from a non-git cwd (RC=$RC)"
fi

# Assertion 2: it must have resolved CODE_FORGE_DIR to the real code-forge root and printed
# it in the banner — proving $BASH_SOURCE derivation worked, not a cwd-relative lookup.
if printf '%s' "$OUT" | grep -qF "Code-forge: ${CODE_FORGE_ROOT}"; then
  ok "installer resolved CODE_FORGE_DIR to the script's repo root via \$BASH_SOURCE"
else
  bad "installer did not report the expected Code-forge root '${CODE_FORGE_ROOT}'. Output head:
$(printf '%s' "$OUT" | head -5)"
fi

# Assertion 3 (env override still honored): pass CODE_FORGE_DIR explicitly to a BOGUS non-git
# dir and confirm it now fails with the CLEAR ABORT message, not a silent 128.
BOGUS="$(mktemp -d)/not-a-repo"; mkdir -p "$BOGUS"
OUT2="$( cd "$NONGIT_CWD" && CODE_FORGE_DIR="$BOGUS" bash "$INSTALLER" "$CONSUMER" HEAD 2>&1 )"
RC2=$?
if [ "$RC2" -ne 0 ] && printf '%s' "$OUT2" | grep -qi 'not a git repository'; then
  ok "env override honored + clear ABORT (not opaque 128) when CODE_FORGE_DIR is non-git"
else
  bad "expected clear 'not a git repository' ABORT for a bogus CODE_FORGE_DIR, got RC=$RC2: $(printf '%s' "$OUT2" | head -3)"
fi

echo ""
echo "install-cwd-independence: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
