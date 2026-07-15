#!/usr/bin/env bash
# Behavioral regression for the v0.10.0 CLI-version-lag defect (fixed in v0.10.1).
#
# ROOT DEFECT (v0.10.0): the published user artifact carried only the runtime closure — NOT the
# management CLI (tools/preflight-user.sh). build-artifact.sh never packed it, and cmd_install only
# sourced a fresh CLI on the git-object path. So a from-artifact install/upgrade swapped the runtime
# generation but had NO CLI to stage; the stable on-PATH `preflight` command stayed at the previously
# installed version while the runtime moved. `preflight version` reported the runtime as v0.10.0 while
# the CLI label lagged at v0.10.0-rc.4.
#
# GREEN CONTRACT (v0.10.1): the CLI ships INSIDE every generation (cli/preflight-user.sh, covered by
# RUNTIME_MANIFEST.json + ARTIFACT_MANIFEST.json + SBOM), and the stable on-PATH CLI is SYNCED FROM THE
# ACTIVE GENERATION on install AND rollback. This test proves, end to end, in isolated HOME dirs:
#   1. the built artifact CONTAINS the CLI (tarball + ARTIFACT_MANIFEST + SBOM);
#   2. artifact-only FRESH install syncs the stable CLI to the active generation;
#   3. artifact-only UPGRADE (driven by a v0.10.1+ CLI) over a prior generation re-syncs the CLI;
#   4. an interrupted CLI staging (mid-transaction failure) rolls BOTH runtime and CLI back;
#   5. verify DETECTS a CLI/runtime mismatch (drift) and a re-install REPAIRS it;
#   6. rollback restores BOTH runtime and CLI (bundled<->bundled);
#   7. the install is self-contained: it keeps working after the source checkout is deleted.
#
# Exit 0 = passed; exit 1 = failed. Fully isolated: never touches the real ~/.claude or ~/bin.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_REPO="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CLI_SRC="${SRC_REPO}/tools/preflight-user.sh"
BUILD="${SRC_REPO}/tools/user/build-artifact.sh"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }
trailer(){ echo ""; echo "artifact-cli-packaging: ${PASS} passed, ${FAIL} failed"; [ "$FAIL" -eq 0 ]; }

command -v git >/dev/null 2>&1 || { bad "git required"; trailer; exit $?; }
command -v jq  >/dev/null 2>&1 || { bad "jq required";  trailer; exit $?; }
command -v tar >/dev/null 2>&1 || { bad "tar required"; trailer; exit $?; }
[ -f "$CLI_SRC" ] || { bad "CLI source missing at $CLI_SRC"; trailer; exit $?; }
[ -f "$BUILD" ]   || { bad "build-artifact.sh missing at $BUILD"; trailer; exit $?; }

# All scratch normalized to forward slashes (cygwin resolves \ and / identically; / is JSON/argv safe).
ROOT="$(mktemp -d)"; ROOT="${ROOT//\\//}"
OUT="$ROOT/out"; mkdir -p "$OUT"
HEADSHA="$(git -C "$SRC_REPO" rev-parse HEAD)"

# ── Build the primary artifact from committed HEAD objects (never the working tree). ────────────────
if ! bash "$BUILD" "$HEADSHA" v0.10.1-pkgtest "$OUT" "$SRC_REPO" >"$OUT/build.log" 2>&1; then
  bad "build-artifact.sh failed: $(tail -3 "$OUT/build.log")"; trailer; exit $?
fi
ART="$OUT/preflight-user-v0.10.1-pkgtest.tar.gz"
[ -f "$ART" ] || { bad "artifact not produced"; trailer; exit $?; }

# ── 1. artifact CONTAINS the CLI (tarball + ARTIFACT_MANIFEST + SBOM) ────────────────────────────────
# List members to a file first: `tar | grep -q` would SIGPIPE tar (grep -q closes the pipe on match) and
# pipefail would then misreport a present file as missing. Read the archive via stdin (`-f -` implied by the
# redirect) so a drive-qualified path (D:/a/... on the Windows runner) is not parsed as a tar remote host:path.
tar -tz < "$ART" > "$OUT/members.txt" 2>/dev/null || true
if grep -qE '(^|\./|/)cli/preflight-user\.sh$' "$OUT/members.txt"; then
  ok "artifact tarball bundles cli/preflight-user.sh"
else
  bad "artifact tarball is MISSING cli/preflight-user.sh (the v0.10.0 defect)"
fi
if jq -e '.members["cli/preflight-user.sh"].sha256' "$OUT/ARTIFACT_MANIFEST.json" >/dev/null 2>&1; then
  ok "ARTIFACT_MANIFEST.json records the CLI (sha256)"
else
  bad "ARTIFACT_MANIFEST.json does not list cli/preflight-user.sh"
fi
if jq -e '.components[] | select(.name=="preflight-user-cli")' "$OUT/SBOM.json" >/dev/null 2>&1; then
  ok "SBOM.json lists the CLI as a component"
else
  bad "SBOM.json does not list the CLI component"
fi

# ── isolated-install harness: run the CLI against a private HOME/bin ─────────────────────────────────
# $1 = home tag ; remaining args = install/verify/rollback argv for the CLI to run.
gen_cli(){ local h="$1"; echo "$ROOT/$h/.claude/preflight/runtime/$(cat "$ROOT/$h/.claude/preflight/ACTIVE" 2>/dev/null)/cli/preflight-user.sh"; }
onpath_cli(){ echo "$ROOT/$1/.claude/preflight/cli/preflight-user.sh"; }
active(){ cat "$ROOT/$1/.claude/preflight/ACTIVE" 2>/dev/null; }
# run the branch CLI (the fixed installer) with an isolated environment
run_cli(){ # $1 home  rest: argv
  local h="$1"; shift
  PREFLIGHT_CLAUDE_HOME="$ROOT/$h/.claude" PREFLIGHT_BIN_DIR="$ROOT/$h/bin" \
    bash "$CLI_SRC" "$@"
}
# run whatever CLI is INSTALLED on-PATH in home $1 (proves lockstep through the real launcher chain)
run_installed(){ local h="$1"; shift
  PREFLIGHT_CLAUDE_HOME="$ROOT/$h/.claude" PREFLIGHT_BIN_DIR="$ROOT/$h/bin" \
    bash "$ROOT/$h/bin/preflight" "$@"
}
mkhome(){ mkdir -p "$ROOT/$1/.claude" "$ROOT/$1/bin"; }

# ── 2. artifact-only FRESH install syncs the CLI to the active generation ────────────────────────────
mkhome fresh
if run_cli fresh install --user --ref v0.10.1-pkgtest --from-artifact "$ART" >"$OUT/fresh.log" 2>&1; then
  a="$(active fresh)"
  if [ -n "$a" ] && [ -f "$(onpath_cli fresh)" ] && cmp -s "$(onpath_cli fresh)" "$(gen_cli fresh)"; then
    ok "artifact-only FRESH install: on-PATH CLI is byte-identical to the active generation's CLI"
  else
    bad "artifact-only FRESH install did NOT sync the CLI (drift or missing)"
  fi
else
  bad "artifact-only FRESH install failed: $(tail -3 "$OUT/fresh.log")"
fi

# ── 5. verify DETECTS a CLI/runtime mismatch, and a re-install REPAIRS it ─────────────────────────────
# Corrupt the on-PATH CLI to simulate the v0.10.0 stale-CLI end state, then assert verify FAILs.
if [ -f "$(onpath_cli fresh)" ]; then
  sed 's/^RELEASE_VERSION=.*/RELEASE_VERSION="v0.10.0-rc.4"/' "$(onpath_cli fresh)" > "$(onpath_cli fresh).x" \
    && mv "$(onpath_cli fresh).x" "$(onpath_cli fresh)"
  if run_installed fresh verify >"$OUT/verify-drift.log" 2>&1; then
    bad "verify PASSED despite an injected CLI/runtime mismatch (drift not detected)"
  else
    if grep -q "CLI/runtime MISMATCH" "$OUT/verify-drift.log"; then
      ok "verify FAILS and reports a CLI/runtime MISMATCH on injected drift"
    else
      bad "verify failed but did not report the CLI/runtime mismatch: $(tail -2 "$OUT/verify-drift.log")"
    fi
  fi
  # re-install the SAME artifact must REPAIR the stale CLI (must not short-circuit as a no-op)
  if run_cli fresh install --user --ref v0.10.1-pkgtest --from-artifact "$ART" >"$OUT/repair.log" 2>&1 \
     && cmp -s "$(onpath_cli fresh)" "$(gen_cli fresh)"; then
    ok "re-install REPAIRS a stale CLI (short-circuit requires lockstep)"
  else
    bad "re-install did not repair the stale CLI: $(tail -3 "$OUT/repair.log")"
  fi
else
  bad "cannot run drift/repair checks — fresh install produced no on-PATH CLI"
fi

# ── 3. artifact-only UPGRADE (driven by the fixed CLI) over a prior generation re-syncs the CLI ──────
# Build a SECOND artifact with a distinct CLI version marker from a throwaway commit, upgrade to it,
# and confirm the on-PATH CLI moves to the new generation's CLI.
WT="$ROOT/wt-genB"
if git -C "$SRC_REPO" worktree add -q --detach "$WT" "$HEADSHA" 2>>"$OUT/wt.log"; then
  sed -i 's/^RELEASE_VERSION="v0\.10\.[0-9].*"/RELEASE_VERSION="v0.10.1-genB"/' "$WT/tools/preflight-user.sh"
  git -C "$WT" add tools/preflight-user.sh >/dev/null 2>&1
  git -C "$WT" -c user.name=t -c user.email=t@t commit -q -m "test-only genB CLI marker" >/dev/null 2>&1
  GENB_SHA="$(git -C "$WT" rev-parse HEAD)"
  if bash "$BUILD" "$GENB_SHA" v0.10.1-genB "$OUT/b" "$WT" >"$OUT/buildb.log" 2>&1; then
    ART_B="$OUT/b/preflight-user-v0.10.1-genB.tar.gz"
    # upgrade the 'fresh' home to genB, DRIVEN BY THE FIXED CLI (go-forward correctness)
    if run_cli fresh install --user --ref v0.10.1-genB --from-artifact "$ART_B" >"$OUT/upgrade.log" 2>&1; then
      if grep -q 'v0.10.1-genB' "$(onpath_cli fresh)" && cmp -s "$(onpath_cli fresh)" "$(gen_cli fresh)"; then
        ok "artifact-only UPGRADE re-syncs the on-PATH CLI to the NEW generation's CLI"
      else
        bad "after upgrade the on-PATH CLI did not move to genB"
      fi
      # ── 6. rollback restores BOTH runtime and CLI (genB -> prior bundled gen) ──────────────────────
      PREV="$(cat "$ROOT/fresh/.claude/preflight/PREVIOUS" 2>/dev/null)"
      # the pre-upgrade generation's own bundled CLI bytes — rollback must restore exactly these.
      PREV_CLI="$ROOT/fresh/.claude/preflight/runtime/$PREV/cli/preflight-user.sh"
      if run_installed fresh rollback --user >"$OUT/rollback.log" 2>&1; then
        # lockstep = the on-PATH CLI is byte-identical to the NOW-active generation's bundled CLI, and that
        # is the PREVIOUS generation's CLI (NOT the genB CLI). Compare bytes, not a --ref label string.
        if [ "$(active fresh)" = "$PREV" ] && cmp -s "$(onpath_cli fresh)" "$(gen_cli fresh)" \
           && cmp -s "$(onpath_cli fresh)" "$PREV_CLI" && ! grep -q 'v0.10.1-genB' "$(onpath_cli fresh)"; then
          ok "rollback restores BOTH runtime (ACTIVE=$PREV) AND the CLI to that generation"
        else
          bad "rollback did not restore both runtime and CLI in lockstep"
        fi
      else
        bad "rollback failed: $(tail -3 "$OUT/rollback.log")"
      fi
    else
      bad "artifact-only upgrade to genB failed: $(tail -3 "$OUT/upgrade.log")"
    fi
  else
    bad "could not build genB artifact: $(tail -3 "$OUT/buildb.log")"
  fi
  git -C "$SRC_REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true
else
  bad "could not create genB worktree: $(tail -2 "$OUT/wt.log")"
fi

# ── 4. interrupted CLI staging rolls BOTH runtime and CLI back (atomic transaction) ──────────────────
# Force a failure AFTER the CLI sync by making settings.json an unmergeable non-object; _register_settings
# fails-closed, the ERR trap must restore the prior CLI bytes + pointers (no half-swap).
mkhome interrupt
# first, a clean install so there is a prior CLI + ACTIVE to restore
if run_cli interrupt install --user --ref v0.10.1-pkgtest --from-artifact "$ART" >"$OUT/int1.log" 2>&1; then
  before_active="$(active interrupt)"; before_cli_sha="$(sha256sum "$(onpath_cli interrupt)" | cut -d' ' -f1)"
  # poison settings.json with a top-level JSON array → _register_settings refuses (fail-closed) → ERR trap
  printf '[1,2,3]\n' > "$ROOT/interrupt/.claude/settings.json"
  # build a genB-like DIFFERENT artifact to force a real generation+CLI swap attempt
  if [ -n "${ART_B:-}" ] && [ -f "${ART_B:-/nonexistent}" ]; then
    run_cli interrupt install --user --ref v0.10.1-genB --from-artifact "$ART_B" >"$OUT/int2.log" 2>&1
    rc=$?
    after_active="$(active interrupt)"; after_cli_sha="$(sha256sum "$(onpath_cli interrupt)" 2>/dev/null | cut -d' ' -f1)"
    if [ "$rc" -ne 0 ] && [ "$after_active" = "$before_active" ] && [ "$after_cli_sha" = "$before_cli_sha" ]; then
      ok "interrupted install rolls BOTH runtime pointer AND CLI back to the prior generation"
    else
      bad "interrupted install left a half-swap (rc=$rc active:$before_active->$after_active cli-changed:$([ "$after_cli_sha" != "$before_cli_sha" ] && echo yes || echo no))"
    fi
  else
    bad "genB artifact unavailable for the interrupt test"
  fi
else
  bad "interrupt-test baseline install failed: $(tail -3 "$OUT/int1.log")"
fi

# ── 7. self-contained: works after the SOURCE checkout is gone ───────────────────────────────────────
# Copy the artifact + its bundled CLI into a NON-git dir, install from there, delete it, and confirm the
# installed CLI still runs verify GREEN with no source repo present.
mkhome selfcontained
THROW="$ROOT/throwaway"; mkdir -p "$THROW"
cp "$ART" "$THROW/art.tar.gz"
tar -xz -C "$THROW" < "$ART" >/dev/null 2>&1     # extracts ./cli/preflight-user.sh (stdin: drive-path safe)
if [ -f "$THROW/cli/preflight-user.sh" ]; then
  PREFLIGHT_CLAUDE_HOME="$ROOT/selfcontained/.claude" PREFLIGHT_BIN_DIR="$ROOT/selfcontained/bin" \
    bash "$THROW/cli/preflight-user.sh" install --user --ref v0.10.1-pkgtest --from-artifact "$THROW/art.tar.gz" >"$OUT/sc.log" 2>&1
  rm -rf "$THROW"   # obliterate the source
  if run_installed selfcontained verify >"$OUT/sc-verify.log" 2>&1 && grep -q "VERIFY: PASS" "$OUT/sc-verify.log"; then
    ok "installed CLI + runtime remain functional (verify PASS) after the source checkout is deleted"
  else
    bad "install not self-contained after source deletion: $(tail -3 "$OUT/sc-verify.log")"
  fi
else
  bad "could not extract the bundled CLI from the artifact for the self-contained test"
fi

# ── cleanup ──────────────────────────────────────────────────────────────────────────────────────────
rm -rf "$ROOT" 2>/dev/null || true
git -C "$SRC_REPO" worktree prune >/dev/null 2>&1 || true

trailer
