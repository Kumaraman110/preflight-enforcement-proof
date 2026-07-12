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

# Runtime closure (kept in lockstep with tools/preflight-user.sh RUNTIME_HOOKS/LIBS).
HOOKS="run-hook.cmd user-preflight-router pre-bash-risk-router pre-push-gate-engine pre-push-gate session-start"
LIBS="config-overlay.sh heartbeat.sh shell-structure.sh shell-structure-lexer.awk"

STAGE="$(mktemp -d)/preflight-user"; mkdir -p "$STAGE/hooks" "$STAGE/lib"
for h in $HOOKS; do git -C "$SRC" show "${SHA}:hooks/${h}" > "$STAGE/hooks/${h}"; done
for l in $LIBS;  do git -C "$SRC" show "${SHA}:lib/${l}"   > "$STAGE/lib/${l}";   done
git -C "$SRC" archive "$SHA" verifier protocol 2>/dev/null | tar -x -C "$STAGE" 2>/dev/null || true
git -C "$SRC" show "${SHA}:tools/user/dispatcher.cmd" > "$STAGE/dispatcher.cmd"
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
tar -czf "$TARBALL" -C "$(dirname "$STAGE")" "$(basename "$STAGE")"
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
