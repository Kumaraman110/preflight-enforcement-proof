#!/usr/bin/env bash
# preflight-user.sh — USER-LEVEL Preflight install / verify / status / version / rollback / uninstall /
# doctor (v0.10.0-rc.1). Immutable, versioned, opt-in per repo, reversible, independently verifiable.
#
# MODEL (see docs/user-install.md). Runtime home = ${PREFLIGHT_USER_HOME:-$HOME/.claude/preflight}:
#   runtime/<commit-sha>/  immutable generation: hooks/ lib/ verifier/ protocol/ gate/ VERSION
#                          SOURCE_COMMIT RELEASE_VERSION RUNTIME_MANIFEST.json (sha256 of every artifact)
#   ACTIVE                 the live <commit-sha> (pointer)
#   PREVIOUS               the prior <commit-sha> (rollback target)
#   dispatcher.cmd         STABLE path referenced by ~/.claude/settings.json (never changes)
#   settings-backup/<ts>/  backups of ~/.claude/settings.json (or an ABSENT marker) before every edit
#
# Install sources ONLY committed git objects of a tag/sha (git archive) OR a release artifact tarball.
# It NEVER copies the working tree. Activation is an atomic pointer swap AFTER checksum validation, so a
# half-written generation can never go live. On ANY failure the prior settings + pointers are restored.
#
# Usage:
#   preflight-user.sh install  --user --ref <tag|sha> [--from-artifact <tarball>] [--source <code-forge-dir>]
#   preflight-user.sh verify   --user
#   preflight-user.sh status   --user
#   preflight-user.sh version
#   preflight-user.sh rollback --user
#   preflight-user.sh uninstall --user
#   preflight-user.sh doctor   --user
set -uo pipefail

RELEASE_VERSION="v0.10.0-rc.2"

# ── Resolvable roots (overridable for isolated testing) ──────────────────────────────────────────────────
PF_CLAUDE_HOME="${PREFLIGHT_CLAUDE_HOME:-$HOME/.claude}"
PF_USER_HOME="${PREFLIGHT_USER_HOME:-$PF_CLAUDE_HOME/preflight}"
PF_SETTINGS="$PF_CLAUDE_HOME/settings.json"
PF_RUNTIME="$PF_USER_HOME/runtime"
PF_ACTIVE="$PF_USER_HOME/ACTIVE"
PF_PREVIOUS="$PF_USER_HOME/PREVIOUS"
PF_DISPATCH="$PF_USER_HOME/dispatcher.cmd"
PF_BACKUPS="$PF_USER_HOME/settings-backup"

# The runtime closure: exactly what the user-level Bash gate needs (kept in lockstep with the engine deps).
RUNTIME_HOOKS="run-hook.cmd user-preflight-router pre-bash-risk-router pre-push-gate-engine pre-push-gate session-start"
RUNTIME_LIBS="config-overlay.sh heartbeat.sh shell-structure.sh shell-structure-lexer.awk"

# Preflight-owned hook registration marker (command identity, never position — for idempotent merge).
PF_OWN_RE='preflight/dispatcher\.cmd'

_err(){ echo "preflight-user: $*" >&2; }
_die(){ _err "$*"; exit 1; }

# ── portable sha256 (sha256sum, then shasum, then python) ────────────────────────────────────────────────
_sha256(){ # $1 = file
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else _PF_PY_LOCAL="$(_py)"; "$_PF_PY_LOCAL" -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$1"
  fi
}
_py(){ for c in python3 python; do if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys;sys.exit(0 if sys.version_info[0]>=3 else 1)' >/dev/null 2>&1; then echo "$c"; return 0; fi; done; return 1; }

# ── source repo resolution for the git-object install path ───────────────────────────────────────────────
_resolve_source(){ # sets SRC_REPO ; honors --source / CODE_FORGE_DIR / this script's repo
  if [ -n "${OPT_SOURCE:-}" ]; then SRC_REPO="$OPT_SOURCE"
  elif [ -n "${CODE_FORGE_DIR:-}" ]; then SRC_REPO="$CODE_FORGE_DIR"
  else SRC_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; fi
}

# ═══════════════════════════════ INSTALL ═══════════════════════════════════════════════════════════════
cmd_install(){
  local REF="${OPT_REF:-}" ARTIFACT="${OPT_ARTIFACT:-}"
  [ -n "$REF" ] || _die "install requires --ref <tag|sha>"
  command -v jq >/dev/null 2>&1 || _die "jq is required for settings merge"
  local PY; PY="$(_py)" || _die "no working python3/python"

  # ---- Stage the generation into a temp dir from committed objects OR the artifact ----
  local STAGE_PARENT; STAGE_PARENT="$(mktemp -d)"; local STAGE="$STAGE_PARENT/gen"
  mkdir -p "$STAGE"
  local RESOLVED_SHA=""
  if [ -n "$ARTIFACT" ]; then
    [ -f "$ARTIFACT" ] || { rm -rf "$STAGE_PARENT"; _die "artifact not found: $ARTIFACT"; }
    tar -xzf "$ARTIFACT" -C "$STAGE" 2>/dev/null || { rm -rf "$STAGE_PARENT"; _die "cannot extract artifact"; }
    # a self-contained artifact carries SOURCE_COMMIT
    if [ -f "$STAGE/SOURCE_COMMIT" ]; then RESOLVED_SHA="$(tr -d ' \t\r\n' < "$STAGE/SOURCE_COMMIT")"; fi
    [ -n "$RESOLVED_SHA" ] || { rm -rf "$STAGE_PARENT"; _die "artifact missing SOURCE_COMMIT"; }
  else
    _resolve_source
    git -C "$SRC_REPO" rev-parse --git-dir >/dev/null 2>&1 || { rm -rf "$STAGE_PARENT"; _die "source '$SRC_REPO' is not a git repo"; }
    RESOLVED_SHA="$(git -C "$SRC_REPO" rev-parse --verify "${REF}^{commit}" 2>/dev/null || true)"
    [ -n "$RESOLVED_SHA" ] || { rm -rf "$STAGE_PARENT"; _die "cannot resolve ref '$REF' in $SRC_REPO"; }
    # REJECT a dirty/ambiguous source when installing from a symbolic ref that resolves to the working head
    if ! git -C "$SRC_REPO" cat-file -e "${RESOLVED_SHA}^{commit}" 2>/dev/null; then rm -rf "$STAGE_PARENT"; _die "resolved sha not a commit object"; fi
    _stage_from_git "$SRC_REPO" "$RESOLVED_SHA" "$STAGE" || { rm -rf "$STAGE_PARENT"; _die "staging from git objects failed"; }
  fi

  # ---- Record identity + write the manifest (sha256 of every staged artifact) ----
  printf '%s\n' "$RESOLVED_SHA" > "$STAGE/SOURCE_COMMIT"
  printf '%s\n' "$RELEASE_VERSION" > "$STAGE/RELEASE_VERSION"
  printf '%s\n' "$RELEASE_VERSION" > "$STAGE/VERSION"
  _write_manifest "$STAGE" "$RESOLVED_SHA" "$PY" || { rm -rf "$STAGE_PARENT"; _die "manifest write failed"; }

  # ---- Validate checksums of the staged generation BEFORE any activation ----
  _verify_manifest "$STAGE" "$PY" || { rm -rf "$STAGE_PARENT"; _die "staged generation failed checksum validation — NOT activating"; }

  mkdir -p "$PF_RUNTIME" "$PF_BACKUPS"
  local GEN_DIR="$PF_RUNTIME/$RESOLVED_SHA"

  # ---- Idempotent: identical gen present + active + registered EXACTLY ONCE + intact → no-op success.
  #      If duplicate preflight entries exist (review IF2), do NOT short-circuit — fall through so the
  #      dedup merge collapses them. ----
  if [ -d "$GEN_DIR" ] && [ -f "$PF_ACTIVE" ] && [ "$(tr -d ' \t\r\n' < "$PF_ACTIVE")" = "$RESOLVED_SHA" ] && [ "$(_registration_count)" = 1 ]; then
    if _verify_manifest "$GEN_DIR" "$PY"; then
      rm -rf "$STAGE_PARENT"
      echo "preflight-user: already installed + active at $RESOLVED_SHA ($RELEASE_VERSION) — no changes."
      return 0
    fi
  fi

  # ---- Backup current settings (or record ABSENT) BEFORE any modification ----
  local TS; TS="$($PY -c 'import time;print(time.strftime("%Y%m%dT%H%M%S"))' 2>/dev/null || echo backup)"
  local BK="$PF_BACKUPS/$TS"; mkdir -p "$BK"
  local RESTORE_KIND
  if [ -f "$PF_SETTINGS" ]; then cp "$PF_SETTINGS" "$BK/settings.json"; RESTORE_KIND="file"; else printf 'ABSENT\n' > "$BK/ABSENT"; RESTORE_KIND="absent"; fi
  # capture prior pointers for rollback-on-failure
  local PRIOR_ACTIVE=""; [ -f "$PF_ACTIVE" ] && PRIOR_ACTIVE="$(tr -d ' \t\r\n' < "$PF_ACTIVE")"
  local PRIOR_PREVIOUS=""; [ -f "$PF_PREVIOUS" ] && PRIOR_PREVIOUS="$(tr -d ' \t\r\n' < "$PF_PREVIOUS")"

  # ---- Failure trap: restore settings + pointers EXACTLY, drop the half-staged generation ----
  _install_rollback(){
    _err "install failed — restoring prior state"
    if [ "$RESTORE_KIND" = "file" ]; then cp "$BK/settings.json" "$PF_SETTINGS"; else rm -f "$PF_SETTINGS"; fi
    [ -n "$PRIOR_ACTIVE" ] && printf '%s\n' "$PRIOR_ACTIVE" > "$PF_ACTIVE" || rm -f "$PF_ACTIVE" 2>/dev/null || true
    [ -n "$PRIOR_PREVIOUS" ] && printf '%s\n' "$PRIOR_PREVIOUS" > "$PF_PREVIOUS" || rm -f "$PF_PREVIOUS" 2>/dev/null || true
    # remove the just-staged gen only if it was NOT a pre-existing active generation
    [ "$PRIOR_ACTIVE" = "$RESOLVED_SHA" ] || rm -rf "$GEN_DIR" 2>/dev/null || true
    rm -rf "$STAGE_PARENT" 2>/dev/null || true
  }
  trap '_install_rollback' ERR

  # ---- Promote the staged generation atomically (rename), then install the stable dispatcher ----
  set -e
  if [ ! -d "$GEN_DIR" ]; then
    rm -rf "$GEN_DIR.partial" 2>/dev/null || true
    cp -r "$STAGE" "$GEN_DIR.partial"
    mv "$GEN_DIR.partial" "$GEN_DIR"           # atomic promote of the immutable generation
  fi
  # stable dispatcher (idempotent overwrite — it is version-independent)
  cp "$STAGE/dispatcher.cmd" "$PF_DISPATCH" 2>/dev/null || cp "$GEN_DIR/dispatcher.cmd" "$PF_DISPATCH"
  chmod +x "$PF_DISPATCH" 2>/dev/null || true

  # ---- Pointer swap = the commit point. PREVIOUS <- old ACTIVE ; ACTIVE <- new sha ----
  if [ -n "$PRIOR_ACTIVE" ] && [ "$PRIOR_ACTIVE" != "$RESOLVED_SHA" ]; then printf '%s\n' "$PRIOR_ACTIVE" > "$PF_PREVIOUS.tmp"; mv "$PF_PREVIOUS.tmp" "$PF_PREVIOUS"; fi
  printf '%s\n' "$RESOLVED_SHA" > "$PF_ACTIVE.tmp"; mv "$PF_ACTIVE.tmp" "$PF_ACTIVE"

  # ---- Register the hook in ~/.claude/settings.json (backup-preserve-merge-dedup) ----
  _register_settings "$PY" || { false; }

  trap - ERR
  set +e
  rm -rf "$STAGE_PARENT" 2>/dev/null || true
  echo "preflight-user: installed $RELEASE_VERSION (source $RESOLVED_SHA); ACTIVE=$RESOLVED_SHA PREVIOUS=$(cat "$PF_PREVIOUS" 2>/dev/null || echo none)"
  echo "preflight-user: settings backup at $BK"
  return 0
}

# stage the runtime closure from git objects of RESOLVED_SHA into $3 (STAGE)
_stage_from_git(){ # $1 src repo  $2 sha  $3 stage
  local src="$1" sha="$2" st="$3"
  mkdir -p "$st/hooks" "$st/lib" "$st/verifier" "$st/protocol" "$st/gate"
  local h l
  for h in $RUNTIME_HOOKS; do
    git -C "$src" cat-file -e "${sha}:hooks/${h}" 2>/dev/null || { _err "missing hooks/${h} at ${sha}"; return 1; }
    git -C "$src" show "${sha}:hooks/${h}" > "$st/hooks/${h}" || return 1
  done
  for l in $RUNTIME_LIBS; do
    git -C "$src" cat-file -e "${sha}:lib/${l}" 2>/dev/null || { _err "missing lib/${l} at ${sha}"; return 1; }
    git -C "$src" show "${sha}:lib/${l}" > "$st/lib/${l}" || return 1
  done
  # verifier package (pfverify + tools) + protocol (schemas + policies) + gate scripts, if present at the ref
  git -C "$src" archive "$sha" verifier 2>/dev/null | tar -x -C "$st" 2>/dev/null || true
  git -C "$src" archive "$sha" protocol 2>/dev/null | tar -x -C "$st" 2>/dev/null || true
  # dispatcher ships WITH the generation (also copied to the stable path on activation)
  cp "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/user/dispatcher.cmd" "$st/dispatcher.cmd" 2>/dev/null \
    || git -C "$src" show "${sha}:tools/user/dispatcher.cmd" > "$st/dispatcher.cmd" 2>/dev/null || { _err "dispatcher.cmd unavailable"; return 1; }
  chmod +x "$st/hooks/"* "$st/dispatcher.cmd" 2>/dev/null || true
  return 0
}

# write RUNTIME_MANIFEST.json = sha256 of every file in the staged generation (except the manifest itself)
_write_manifest(){ # $1 stage  $2 sha  $3 py
  local st="$1" sha="$2" py="$3"
  "$py" - "$st" "$sha" "$RELEASE_VERSION" > "$st/RUNTIME_MANIFEST.json" <<'PY' || return 1
import sys, json, hashlib, os
stage, sha, ver = sys.argv[1], sys.argv[2], sys.argv[3]
arts = {}
for dp, _, fs in os.walk(stage):
    for f in fs:
        if f == "RUNTIME_MANIFEST.json": continue
        p = os.path.join(dp, f)
        rel = os.path.relpath(p, stage).replace('\\', '/')
        with open(p, 'rb') as fh:
            arts[rel] = hashlib.sha256(fh.read()).hexdigest()
json.dump({"framework":"preflight","model":"user-level-runtime","schema":1,
           "releaseVersion":ver,"sourceCommit":sha,"artifacts":dict(sorted(arts.items()))},
          sys.stdout, indent=2, sort_keys=True)
PY
  return 0
}

# verify a generation dir against its own RUNTIME_MANIFEST.json (every artifact present + sha256 matches)
_verify_manifest(){ # $1 gen dir  $2 py ; exit 0 = intact
  local gen="$1" py="$2"
  [ -f "$gen/RUNTIME_MANIFEST.json" ] || { _err "no RUNTIME_MANIFEST.json in $gen"; return 1; }
  "$py" - "$gen" <<'PY'
import sys, json, hashlib, os
gen = sys.argv[1]
mf = json.load(open(os.path.join(gen,"RUNTIME_MANIFEST.json"),encoding="utf-8"))
arts = mf.get("artifacts",{})
if not arts:
    print("manifest has no artifacts", file=sys.stderr); sys.exit(1)
bad = 0
seen = set()
for rel, want in arts.items():
    p = os.path.join(gen, rel)
    if not os.path.isfile(p):
        print(f"MISSING {rel}", file=sys.stderr); bad += 1; continue
    got = hashlib.sha256(open(p,'rb').read()).hexdigest()
    seen.add(os.path.normpath(rel))
    if got != want:
        print(f"DIGEST-MISMATCH {rel}", file=sys.stderr); bad += 1
# extra-file detection: any tracked file not in the manifest (tamper via addition)
for dp,_,fs in os.walk(gen):
    for f in fs:
        rel = os.path.relpath(os.path.join(dp,f), gen).replace('\\','/')
        if rel == "RUNTIME_MANIFEST.json": continue
        if os.path.normpath(rel) not in seen:
            print(f"UNEXPECTED {rel}", file=sys.stderr); bad += 1
sys.exit(1 if bad else 0)
PY
}

# is the Preflight user hook currently registered in settings.json?
_is_registered(){
  [ -f "$PF_SETTINGS" ] || return 1
  case "$(cat "$PF_SETTINGS" 2>/dev/null)" in *preflight/dispatcher.cmd*) return 0;; *) return 1;; esac
}
# how many Preflight-owned Bash PreToolUse entries are registered (0 if none / unparseable)?
_registration_count(){
  [ -f "$PF_SETTINGS" ] || { echo 0; return; }
  jq empty "$PF_SETTINGS" 2>/dev/null || { echo 0; return; }
  jq --arg re "$PF_OWN_RE" '[(.hooks.PreToolUse // [])[] | select(.matcher=="Bash") | (.hooks // [])[] | select((.command // "") | test($re))] | length' "$PF_SETTINGS" 2>/dev/null || echo 0
}

# register (or refresh) the PreToolUse Bash hook, preserving all other settings, dedup by command identity
_register_settings(){ # $1 py
  local py="$1"
  local disp_fwd; disp_fwd="$(printf '%s' "$PF_DISPATCH" | sed 's#\\#/#g')"
  local cmd="\"${disp_fwd}\" user-preflight-router"
  local block; block="$(jq -n --arg cmd "$cmd" '{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:$cmd,timeout:35000}]}]}')" || return 1
  local merged
  if [ -f "$PF_SETTINGS" ]; then
    # FAIL-CLOSED (review IF1): an existing but UNPARSEABLE settings.json must NOT be overwritten
    # (that would silently drop the user's unrelated keys). Abort and let the failure trap restore.
    if ! jq empty "$PF_SETTINGS" 2>/dev/null; then
      _err "existing $PF_SETTINGS is not valid JSON — refusing to overwrite it. Fix or move it, then re-install."
      return 1
    fi
    merged="$(jq --argjson blk "$block" --arg re "$PF_OWN_RE" '
      .hooks = (.hooks // {})
      | .hooks.PreToolUse = (
          (((.hooks.PreToolUse // [])
             | map(select(
                 (.matcher=="Bash" and ([ (.hooks // [])[] | select((.command // "") | test($re)) ] | length) >= 1) | not
               ))))
          + $blk.PreToolUse )
    ' "$PF_SETTINGS")" || return 1
  else
    merged="$(jq -n --argjson blk "$block" '{hooks:$blk}')" || return 1
  fi
  printf '%s\n' "$merged" > "$PF_SETTINGS.tmp" || return 1
  jq empty "$PF_SETTINGS.tmp" 2>/dev/null || { rm -f "$PF_SETTINGS.tmp"; return 1; }
  mv "$PF_SETTINGS.tmp" "$PF_SETTINGS" || return 1
  return 0
}

# ═══════════════════════════════ VERIFY ════════════════════════════════════════════════════════════════
cmd_verify(){
  local py; py="$(_py)" || _die "no python"
  local rc=0
  [ -f "$PF_ACTIVE" ] || { _err "no ACTIVE pointer"; return 1; }
  local sha; sha="$(tr -d ' \t\r\n' < "$PF_ACTIVE")"
  case "$sha" in *[!0-9a-fA-F]*|"") _err "ACTIVE is not a valid sha"; return 1;; esac
  local gen="$PF_RUNTIME/$sha"
  [ -d "$gen" ] || { _err "ACTIVE generation dir missing: $gen"; return 1; }
  if _verify_manifest "$gen" "$py"; then echo "OK manifest intact ($sha)"; else _err "manifest verification FAILED"; rc=1; fi
  # dispatcher resolves to the active generation
  [ -f "$PF_DISPATCH" ] || { _err "stable dispatcher missing"; rc=1; }
  [ -f "$gen/hooks/user-preflight-router" ] || { _err "active generation missing user-preflight-router"; rc=1; }
  # registered in settings
  if _is_registered; then echo "OK hook registered in settings.json"; else _err "hook NOT registered in settings.json"; rc=1; fi
  # version consistency
  local ver=""; [ -f "$gen/RELEASE_VERSION" ] && ver="$(tr -d ' \t\r\n' < "$gen/RELEASE_VERSION")"
  [ "$ver" = "$RELEASE_VERSION" ] && echo "OK version $ver" || { _err "version mismatch: gen=$ver cli=$RELEASE_VERSION"; rc=1; }
  [ "$rc" = 0 ] && echo "VERIFY: PASS" || echo "VERIFY: FAIL"
  return $rc
}

# ═══════════════════════════════ STATUS / VERSION ══════════════════════════════════════════════════════
cmd_status(){
  echo "preflight user-level status"
  echo "  user home:   $PF_USER_HOME"
  echo "  settings:    $PF_SETTINGS $( [ -f "$PF_SETTINGS" ] && echo '(present)' || echo '(absent)')"
  echo "  ACTIVE:      $( [ -f "$PF_ACTIVE" ] && cat "$PF_ACTIVE" || echo '(none)')"
  echo "  PREVIOUS:    $( [ -f "$PF_PREVIOUS" ] && cat "$PF_PREVIOUS" || echo '(none)')"
  echo "  registered:  $( _is_registered && echo yes || echo no)"
  if [ -d "$PF_RUNTIME" ]; then echo "  generations: $(find "$PF_RUNTIME" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"; fi
  local sha; [ -f "$PF_ACTIVE" ] && sha="$(tr -d ' \t\r\n' < "$PF_ACTIVE")"
  [ -n "${sha:-}" ] && [ -f "$PF_RUNTIME/$sha/RELEASE_VERSION" ] && echo "  version:     $(cat "$PF_RUNTIME/$sha/RELEASE_VERSION")"
  return 0
}
cmd_version(){ echo "$RELEASE_VERSION"; }

# ═══════════════════════════════ ROLLBACK ══════════════════════════════════════════════════════════════
cmd_rollback(){
  local py; py="$(_py)" || _die "no python"
  [ -f "$PF_PREVIOUS" ] || _die "no PREVIOUS generation to roll back to"
  local prev; prev="$(tr -d ' \t\r\n' < "$PF_PREVIOUS")"
  case "$prev" in *[!0-9a-fA-F]*|"") _die "PREVIOUS is not a valid sha";; esac
  local gen="$PF_RUNTIME/$prev"
  [ -d "$gen" ] || _die "PREVIOUS generation dir missing: $gen"
  _verify_manifest "$gen" "$py" || _die "PREVIOUS generation failed integrity check — refusing rollback"
  local cur=""; [ -f "$PF_ACTIVE" ] && cur="$(tr -d ' \t\r\n' < "$PF_ACTIVE")"
  # swap: ACTIVE <- prev ; PREVIOUS <- cur (so a second rollback returns)
  printf '%s\n' "$prev" > "$PF_ACTIVE.tmp"; mv "$PF_ACTIVE.tmp" "$PF_ACTIVE"
  [ -n "$cur" ] && { printf '%s\n' "$cur" > "$PF_PREVIOUS.tmp"; mv "$PF_PREVIOUS.tmp" "$PF_PREVIOUS"; }
  echo "preflight-user: rolled back → ACTIVE=$prev (was $cur)"
  return 0
}

# ═══════════════════════════════ UNINSTALL ═════════════════════════════════════════════════════════════
cmd_uninstall(){
  local py; py="$(_py)" || _die "no python"
  # remove ONLY the Preflight-owned hook entry from settings.json; preserve everything else
  if [ -f "$PF_SETTINGS" ] && jq empty "$PF_SETTINGS" 2>/dev/null; then
    local cleaned; cleaned="$(jq --arg re "$PF_OWN_RE" '
      if (.hooks.PreToolUse) then
        .hooks.PreToolUse = ((.hooks.PreToolUse // [])
          | map(select(
              (.matcher=="Bash" and ([ (.hooks // [])[] | select((.command // "") | test($re)) ] | length) >= 1) | not
            )))
        | (if (.hooks.PreToolUse | length)==0 then .hooks |= del(.PreToolUse) else . end)
        | (if (.hooks | length)==0 then del(.hooks) else . end)
      else . end
    ' "$PF_SETTINGS")" || _die "settings edit failed"
    printf '%s\n' "$cleaned" > "$PF_SETTINGS.tmp"
    jq empty "$PF_SETTINGS.tmp" 2>/dev/null || { rm -f "$PF_SETTINGS.tmp"; _die "produced invalid settings"; }
    # v0.10.0-rc.2: EXACT-BYTES restore. If the surgically-cleaned result is SEMANTICALLY identical to the
    # oldest pre-install backup (i.e. the user made no other change since install), restore that backup's
    # EXACT bytes rather than the jq-reserialized form — so uninstall restores the prior settings *exactly*
    # (byte-for-byte), not merely equivalently. Falls back to the cleaned form when they differ (preserving
    # any post-install user edits) or when no file backup exists.
    local firstbk; firstbk="$(find "$PF_BACKUPS" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | LC_ALL=C sort | head -1)"
    if [ -n "$firstbk" ] && [ -f "$firstbk/settings.json" ] \
       && [ "$(jq -S . "$PF_SETTINGS.tmp" 2>/dev/null)" = "$(jq -S . "$firstbk/settings.json" 2>/dev/null)" ]; then
      cp "$firstbk/settings.json" "$PF_SETTINGS"; rm -f "$PF_SETTINGS.tmp"
      echo "preflight-user: restored settings.json byte-for-byte from the pre-install backup"
    elif [ "$(jq -S . "$PF_SETTINGS.tmp")" = "{}" ] && _originally_absent; then
      # settings.json is now empty AND install created it → restore ABSENT (remove the file).
      rm -f "$PF_SETTINGS.tmp" "$PF_SETTINGS"; echo "preflight-user: removed settings.json (was created by install)"
    else
      mv "$PF_SETTINGS.tmp" "$PF_SETTINGS"; echo "preflight-user: removed the Preflight hook; preserved post-install settings changes"
    fi
  fi
  # remove ONLY Preflight-owned data
  rm -rf "$PF_USER_HOME"
  echo "preflight-user: uninstalled (removed $PF_USER_HOME + Preflight hook entry; unrelated settings preserved)"
  return 0
}
# did the OLDEST backup record ABSENT (i.e. install created settings.json)?
_originally_absent(){
  local first; first="$(find "$PF_BACKUPS" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | LC_ALL=C sort | head -1)"
  [ -n "$first" ] && [ -f "$first/ABSENT" ]
}

# ═══════════════════════════════ DOCTOR ════════════════════════════════════════════════════════════════
cmd_doctor(){
  echo "preflight user-level doctor"
  local py; py="$(_py)" && echo "  python:   $py OK" || echo "  python:   MISSING (fatal)"
  command -v jq >/dev/null 2>&1 && echo "  jq:       $(jq --version)" || echo "  jq:       MISSING (settings merge needs it)"
  command -v git >/dev/null 2>&1 && echo "  git:      $(git --version)" || echo "  git:      MISSING"
  echo "  claude:   $(claude --version 2>/dev/null || echo 'not on PATH')"
  cmd_status
  echo "  --- integrity ---"
  cmd_verify || true
  return 0
}

# ═══════════════════════════════ arg parse ═════════════════════════════════════════════════════════════
SUB="${1:-}"; shift 2>/dev/null || true
OPT_REF=""; OPT_ARTIFACT=""; OPT_SOURCE=""; OPT_USER=0
while [ $# -gt 0 ]; do
  case "$1" in
    --user) OPT_USER=1; shift;;
    --ref) OPT_REF="${2:-}"; shift 2;;
    --from-artifact) OPT_ARTIFACT="${2:-}"; shift 2;;
    --source) OPT_SOURCE="${2:-}"; shift 2;;
    *) _err "unknown arg: $1"; shift;;
  esac
done

case "$SUB" in
  install)   [ "$OPT_USER" = 1 ] || _die "install requires --user"; cmd_install;;
  verify)    cmd_verify;;
  status)    cmd_status;;
  version)   cmd_version;;
  rollback)  [ "$OPT_USER" = 1 ] || _die "rollback requires --user"; cmd_rollback;;
  uninstall) [ "$OPT_USER" = 1 ] || _die "uninstall requires --user"; cmd_uninstall;;
  doctor)    cmd_doctor;;
  ""|-h|--help|help) echo "usage: preflight-user.sh {install|verify|status|version|rollback|uninstall|doctor} [--user] [--ref R] [--from-artifact T] [--source DIR]";;
  *) _die "unknown subcommand: $SUB";;
esac
