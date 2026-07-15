#!/usr/bin/env bash
# build-artifact.sh — build the self-contained user-level release artifact from COMMITTED git objects
# of a ref (never the working tree). Produces:
#   <out>/preflight-user-<version>.tar.gz            the self-contained runtime closure + SOURCE_COMMIT
#   <out>/preflight-user-<version>.tar.gz.sha256     the checksum
#   <out>/ARTIFACT_MANIFEST.json                     name/size/sha256 of the artifact + its members
#   <out>/SBOM.json                                  minimal provenance (source repo/commit/version/deps)
#
# The artifact deliberately EXCLUDES non-product material (.release-audit/, tests/, goal-state, logs).
# Usage: build-artifact.sh <ref> <version> <out-dir> [<source-repo>]
set -euo pipefail
REF="${1:?ref}"; VER="${2:?version}"; OUT="${3:?out dir}"; SRC="${4:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
git -C "$SRC" rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repo: $SRC" >&2; exit 1; }
SHA="$(git -C "$SRC" rev-parse --verify "${REF}^{commit}")" || { echo "cannot resolve $REF" >&2; exit 1; }
PY=""; for c in python3 python; do command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys;sys.exit(0 if sys.version_info[0]>=3 else 1)' >/dev/null 2>&1 && { PY="$c"; break; }; done
[ -n "$PY" ] || { echo "no python" >&2; exit 1; }
mkdir -p "$OUT"

# POSIX-form scratch: TMPDIR may be a drive-qualified backslash path (Windows shell / CI RUNNER_TEMP=D:\a\_temp),
# and a backslash STAGE passed to `tar -C` fails on cygwin ("C\:\\... Cannot open"). cygpath -u normalizes it
# to /c/... (a naive sed corrupts the drive letter); no cygpath (real POSIX) → mktemp is already clean.
_mktemp_d(){ local d; d="$(mktemp -d)" || return 1; if command -v cygpath >/dev/null 2>&1; then cygpath -u "$d" 2>/dev/null || printf '%s\n' "$d"; else printf '%s\n' "$d"; fi; }

# Runtime closure (kept in lockstep with tools/preflight-user.sh RUNTIME_HOOKS/LIBS).
HOOKS="run-hook.cmd user-preflight-router pre-bash-risk-router pre-push-gate-engine pre-push-gate session-start"
# MUST stay in lockstep with tools/preflight-user.sh RUNTIME_LIBS — a lib missing here ships a broken
# artifact (e.g. hook-arbitration.sh absent → the user router can't classify ownership).
LIBS="config-overlay.sh heartbeat.sh shell-structure.sh shell-structure-lexer.awk hook-arbitration.sh"

STAGE="$(_mktemp_d)/preflight-user"; mkdir -p "$STAGE/hooks" "$STAGE/lib" "$STAGE/cli"
for h in $HOOKS; do git -C "$SRC" show "${SHA}:hooks/${h}" > "$STAGE/hooks/${h}"; done
for l in $LIBS;  do git -C "$SRC" show "${SHA}:lib/${l}"   > "$STAGE/lib/${l}";   done
git -C "$SRC" archive "$SHA" verifier protocol 2>/dev/null | tar -x -C "$STAGE" 2>/dev/null || true
git -C "$SRC" show "${SHA}:tools/user/dispatcher.cmd" > "$STAGE/dispatcher.cmd"
# v0.10.1: BUNDLE the management CLI inside the artifact (cli/preflight-user.sh). Before this, the artifact
# carried only the runtime closure, so a from-artifact install/upgrade had no CLI to stage — the on-PATH
# `preflight` command stayed at the OLD version while the runtime swapped (the v0.10.0 missing-CLI defect).
# The CLI now travels WITH the generation, is covered by RUNTIME_MANIFEST.json + ARTIFACT_MANIFEST.json
# (both walk the stage), and the installer syncs the stable on-PATH CLI from it. A missing CLI is fatal.
git -C "$SRC" cat-file -e "${SHA}:tools/preflight-user.sh" 2>/dev/null || { echo "FATAL: tools/preflight-user.sh missing at $SHA — cannot build artifact without the CLI" >&2; exit 1; }
git -C "$SRC" show "${SHA}:tools/preflight-user.sh" > "$STAGE/cli/preflight-user.sh"
chmod +x "$STAGE/cli/preflight-user.sh" 2>/dev/null || true
printf '%s\n' "$SHA" > "$STAGE/SOURCE_COMMIT"
printf '%s\n' "$VER" > "$STAGE/RELEASE_VERSION"
printf '%s\n' "$VER" > "$STAGE/VERSION"

# Per-artifact runtime manifest (sha256 of every member).
"$PY" - "$STAGE" "$SHA" "$VER" > "$STAGE/RUNTIME_MANIFEST.json" <<'PY'
import sys,json,hashlib,os
st,sha,ver=sys.argv[1],sys.argv[2],sys.argv[3]; arts={}
for dp,_,fs in os.walk(st):
    for f in fs:
        if f=="RUNTIME_MANIFEST.json": continue
        p=os.path.join(dp,f); rel=os.path.relpath(p,st).replace('\\','/')
        arts[rel]=hashlib.sha256(open(p,'rb').read()).hexdigest()
json.dump({"framework":"preflight","model":"user-level-runtime","schema":1,"releaseVersion":ver,
           "sourceCommit":sha,"artifacts":dict(sorted(arts.items()))},sys.stdout,indent=2,sort_keys=True)
PY

TARBALL="$OUT/preflight-user-${VER}.tar.gz"
# Pack the CONTENTS flat (SOURCE_COMMIT at the tar root) so `install --from-artifact` extracts a
# self-contained generation directly, with no wrapper subdir. Write via `-f -` + shell redirection rather
# than `-f "$TARBALL"`: on Windows the OUT path can be drive-qualified (e.g. D:/a/...), and cygwin GNU tar
# parses the `D:` as a REMOTE host:path and fails with "Cannot connect to D:". Redirection sidesteps it
# entirely (the shell opens the file; tar sees only a stream) and is portable across GNU/BSD/cygwin tar.
tar -cz -C "$STAGE" . > "$TARBALL"
# checksum
if command -v sha256sum >/dev/null 2>&1; then ( cd "$OUT" && sha256sum "$(basename "$TARBALL")" > "$(basename "$TARBALL").sha256" )
else ( cd "$OUT" && shasum -a 256 "$(basename "$TARBALL")" > "$(basename "$TARBALL").sha256" ); fi

# artifact manifest + SBOM
"$PY" - "$TARBALL" "$OUT" "$SHA" "$VER" "$STAGE" <<'PY'
import sys,json,hashlib,os,time
tb,out,sha,ver,stage=sys.argv[1:6]
def h(p): return hashlib.sha256(open(p,'rb').read()).hexdigest()
members={}
for dp,_,fs in os.walk(stage):
    for f in fs:
        p=os.path.join(dp,f); rel=os.path.relpath(p,stage).replace('\\','/'); members[rel]={"size":os.path.getsize(p),"sha256":h(p)}
json.dump({"artifact":os.path.basename(tb),"size":os.path.getsize(tb),"sha256":h(tb),
           "releaseVersion":ver,"sourceCommit":sha,"members":dict(sorted(members.items()))},
          open(os.path.join(out,"ARTIFACT_MANIFEST.json"),"w"),indent=2,sort_keys=True)
json.dump({"bomFormat":"CycloneDX-min","specVersion":"1.5","metadata":{
            "component":{"type":"application","name":"preflight-user","version":ver},
            "properties":[{"name":"sourceRepo","value":"preflight"},{"name":"sourceCommit","value":sha}]},
           "components":[
             {"type":"application","name":"preflight-user-runtime","version":ver},
             {"type":"application","name":"preflight-user-cli","version":ver,
              "properties":[{"name":"path","value":"cli/preflight-user.sh"}]},
             {"type":"library","name":"bash"},{"type":"library","name":"git"},
             {"type":"library","name":"jq"},{"type":"library","name":"python3"}],
           "note":"stdlib-only Python; no third-party pip dependencies"},
          open(os.path.join(out,"SBOM.json"),"w"),indent=2,sort_keys=True)
PY
rm -rf "$(dirname "$STAGE")"
echo "artifact:  $TARBALL"
echo "sha256:    $(cat "$TARBALL.sha256")"
echo "manifest:  $OUT/ARTIFACT_MANIFEST.json"
echo "sbom:      $OUT/SBOM.json"
echo "source:    $SHA  version: $VER"
