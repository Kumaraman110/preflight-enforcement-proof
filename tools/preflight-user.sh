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
# Usage (the `preflight` launcher execs this; both spellings work):
#   preflight install  --user --ref <tag|sha> [--from-artifact <tarball>] [--source <code-forge-dir>]
#   preflight init --local [--dir <repo>]   # opt THIS repo in (writes gitignored .preflight/config.json)
#   preflight status  [--dir <repo>]        # active/inactive, owner, version, policy tier, health, remote
#   preflight doctor  [--dir <repo>]        # diagnose deps, dup hooks, stale runtime, malformed config, git ctx
#   preflight verify                        # integrity of the active user runtime
#   preflight disable [--dir <repo>]        # deactivate THIS repo (reversible; keeps config as .disabled)
#   preflight version
#   preflight rollback  --user              # swap ACTIVE <-> PREVIOUS generation
#   preflight uninstall --user              # remove the user-level runtime + hook (unrelated settings kept)
#   preflight doctor --project <path>       # read-only hook-ownership report for another repo
set -uo pipefail

RELEASE_VERSION="v0.10.1"

# ── Resolvable roots (overridable for isolated testing) ──────────────────────────────────────────────────
PF_CLAUDE_HOME="${PREFLIGHT_CLAUDE_HOME:-$HOME/.claude}"
PF_USER_HOME="${PREFLIGHT_USER_HOME:-$PF_CLAUDE_HOME/preflight}"
PF_SETTINGS="$PF_CLAUDE_HOME/settings.json"
PF_RUNTIME="$PF_USER_HOME/runtime"
PF_ACTIVE="$PF_USER_HOME/ACTIVE"
PF_PREVIOUS="$PF_USER_HOME/PREVIOUS"
PF_DISPATCH="$PF_USER_HOME/dispatcher.cmd"
PF_BACKUPS="$PF_USER_HOME/settings-backup"
# Stable management-CLI copy (version-independent, like the dispatcher): the `preflight` launcher execs
# THIS file, which reads ACTIVE to resolve the versioned runtime. Updated on every install so CLI
# bugfixes propagate; the immutable, security-critical surface remains the per-generation runtime hooks.
PF_CLI="$PF_USER_HOME/cli/preflight-user.sh"
# The launcher lives on PATH. Real installs → ~/bin (or ~/.local/bin); isolated tests (a non-default
# PREFLIGHT_CLAUDE_HOME) → inside the isolated home so they never pollute the real ~/bin. Overridable.
_pf_bin_dir(){
  if [ -n "${PREFLIGHT_BIN_DIR:-}" ]; then echo "$PREFLIGHT_BIN_DIR"; return; fi
  if [ -n "${PREFLIGHT_CLAUDE_HOME:-}" ] || [ -n "${PREFLIGHT_USER_HOME:-}" ]; then echo "$PF_USER_HOME/bin"; return; fi
  if [ -d "$HOME/bin" ]; then echo "$HOME/bin"; else echo "$HOME/.local/bin"; fi
}

# The runtime closure: exactly what the user-level Bash gate needs (kept in lockstep with the engine deps).
RUNTIME_HOOKS="run-hook.cmd user-preflight-router pre-bash-risk-router pre-push-gate-engine pre-push-gate session-start"
RUNTIME_LIBS="config-overlay.sh heartbeat.sh shell-structure.sh shell-structure-lexer.awk hook-arbitration.sh"

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
  # The version STAMPED into this generation. For a git-object install it is the CLI's compiled constant;
  # for a from-artifact install it is the artifact's OWN staged RELEASE_VERSION — the artifact is the source
  # of truth for what it contains (same trust already given to SOURCE_COMMIT), so a correctly-built v0.10.0
  # artifact must NOT be re-stamped with the installer's compiled constant (review P1: that made every
  # from-artifact install self-report as whatever the CLI literal happened to be, diverging from the
  # artifact's own SBOM/manifest). Defaults to the compiled constant; overridden below for the artifact path.
  local GEN_VERSION="$RELEASE_VERSION"
  if [ -n "$ARTIFACT" ]; then
    [ -f "$ARTIFACT" ] || { rm -rf "$STAGE_PARENT"; _die "artifact not found: $ARTIFACT"; }
    tar -xzf "$ARTIFACT" -C "$STAGE" 2>/dev/null || { rm -rf "$STAGE_PARENT"; _die "cannot extract artifact"; }
    # a self-contained artifact carries SOURCE_COMMIT
    if [ -f "$STAGE/SOURCE_COMMIT" ]; then RESOLVED_SHA="$(tr -d ' \t\r\n' < "$STAGE/SOURCE_COMMIT")"; fi
    [ -n "$RESOLVED_SHA" ] || { rm -rf "$STAGE_PARENT"; _die "artifact missing SOURCE_COMMIT"; }
    # trust the artifact's own version (it was built for a specific release; the installer must not relabel it)
    if [ -f "$STAGE/RELEASE_VERSION" ]; then
      local _art_ver; _art_ver="$(tr -d ' \t\r\n' < "$STAGE/RELEASE_VERSION")"
      case "$_art_ver" in v[0-9]*) GEN_VERSION="$_art_ver" ;; esac
    fi
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
  printf '%s\n' "$GEN_VERSION" > "$STAGE/RELEASE_VERSION"
  printf '%s\n' "$GEN_VERSION" > "$STAGE/VERSION"
  _write_manifest "$STAGE" "$RESOLVED_SHA" "$GEN_VERSION" "$PY" || { rm -rf "$STAGE_PARENT"; _die "manifest write failed"; }

  # ---- Validate checksums of the staged generation BEFORE any activation ----
  _verify_manifest "$STAGE" "$PY" || { rm -rf "$STAGE_PARENT"; _die "staged generation failed checksum validation — NOT activating"; }

  mkdir -p "$PF_RUNTIME" "$PF_BACKUPS"
  local GEN_DIR="$PF_RUNTIME/$RESOLVED_SHA"

  # ---- Idempotent: identical gen present + active + registered EXACTLY ONCE + intact → no-op success.
  #      If duplicate preflight entries exist (review IF2), do NOT short-circuit — fall through so the
  #      dedup merge collapses them. ----
  # v0.10.1: also require the stable on-PATH CLI to already be in lockstep with this generation's bundled
  # CLI — otherwise a re-install of the SAME ref (the natural repair for a stale CLI) would short-circuit
  # and never re-sync. If the CLI drifts (or the gen predates the bundle), fall through to the full path.
  if [ -d "$GEN_DIR" ] && [ -f "$PF_ACTIVE" ] && [ "$(tr -d ' \t\r\n' < "$PF_ACTIVE")" = "$RESOLVED_SHA" ] && [ "$(_registration_count)" = 1 ]; then
    if _verify_manifest "$GEN_DIR" "$PY" && [ -f "$GEN_DIR/cli/preflight-user.sh" ] && [ -f "$PF_CLI" ] && cmp -s "$GEN_DIR/cli/preflight-user.sh" "$PF_CLI"; then
      rm -rf "$STAGE_PARENT"
      echo "preflight-user: already installed + active at $RESOLVED_SHA ($GEN_VERSION), CLI in lockstep — no changes."
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
  # v0.10.1: back up the current stable CLI bytes so the rollback can restore the CLI in lockstep with the
  # pointer restore — otherwise a failure AFTER _sync_stable_cli (e.g. in _register_settings) would leave the
  # NEW CLI live against the RESTORED old ACTIVE runtime: exactly the version-mismatch this release closes.
  local CLI_RESTORE="none"
  if [ -f "$PF_CLI" ]; then cp "$PF_CLI" "$BK/cli-preflight-user.sh"; CLI_RESTORE="file"; fi

  # ---- Failure trap: restore settings + pointers + CLI EXACTLY, drop the half-staged generation ----
  _install_rollback(){
    _err "install failed — restoring prior state"
    if [ "$RESTORE_KIND" = "file" ]; then cp "$BK/settings.json" "$PF_SETTINGS"; else rm -f "$PF_SETTINGS"; fi
    [ -n "$PRIOR_ACTIVE" ] && printf '%s\n' "$PRIOR_ACTIVE" > "$PF_ACTIVE" || rm -f "$PF_ACTIVE" 2>/dev/null || true
    [ -n "$PRIOR_PREVIOUS" ] && printf '%s\n' "$PRIOR_PREVIOUS" > "$PF_PREVIOUS" || rm -f "$PF_PREVIOUS" 2>/dev/null || true
    # restore the stable CLI bytes (if we had a prior CLI); if this was a fresh install there was none → remove
    if [ "$CLI_RESTORE" = "file" ]; then cp "$BK/cli-preflight-user.sh" "$PF_CLI" 2>/dev/null || true; chmod +x "$PF_CLI" 2>/dev/null || true
    else rm -f "$PF_CLI" 2>/dev/null || true; fi
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

  # stable management CLI (synced FROM the just-promoted immutable generation) + the on-PATH launcher.
  # v0.10.1: the CLI travels inside the generation (cli/preflight-user.sh, staged by _stage_from_git for a
  # git install and carried in the artifact for a from-artifact install), so BOTH install paths sync the
  # same source and an upgrade always moves the CLI in lockstep with the runtime. This sync is part of the
  # ATOMIC transaction: a failure here trips the ERR trap and rolls back settings + pointers + the staged
  # generation, so the runtime and CLI can never be left half-swapped (the CLI-version-lag defect class).
  _sync_stable_cli "$GEN_DIR" || { _err "CLI sync from generation failed — rolling back"; false; }
  _install_launcher || _err "warning: on-PATH launcher write incomplete (CLI + runtime are installed and active)"

  # ---- Pointer swap = the commit point. PREVIOUS <- old ACTIVE ; ACTIVE <- new sha ----
  if [ -n "$PRIOR_ACTIVE" ] && [ "$PRIOR_ACTIVE" != "$RESOLVED_SHA" ]; then printf '%s\n' "$PRIOR_ACTIVE" > "$PF_PREVIOUS.tmp"; mv "$PF_PREVIOUS.tmp" "$PF_PREVIOUS"; fi
  printf '%s\n' "$RESOLVED_SHA" > "$PF_ACTIVE.tmp"; mv "$PF_ACTIVE.tmp" "$PF_ACTIVE"

  # ---- Register the hook in ~/.claude/settings.json (backup-preserve-merge-dedup) ----
  _register_settings "$PY" || { false; }

  trap - ERR
  set +e
  rm -rf "$STAGE_PARENT" 2>/dev/null || true
  echo "preflight-user: installed $GEN_VERSION (source $RESOLVED_SHA); ACTIVE=$RESOLVED_SHA PREVIOUS=$(cat "$PF_PREVIOUS" 2>/dev/null || echo none)"
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
  # v0.10.1: the management CLI ships WITH the generation (cli/preflight-user.sh). It is covered by the
  # generation manifest and is the single source the stable on-PATH CLI is synced from — so an upgrade
  # (git OR artifact) always moves the CLI in lockstep with the runtime (fixes the v0.10.0 CLI-version lag).
  mkdir -p "$st/cli"
  git -C "$src" cat-file -e "${sha}:tools/preflight-user.sh" 2>/dev/null || { _err "tools/preflight-user.sh missing at ${sha}"; return 1; }
  git -C "$src" show "${sha}:tools/preflight-user.sh" > "$st/cli/preflight-user.sh" || return 1
  chmod +x "$st/cli/preflight-user.sh" 2>/dev/null || true
  chmod +x "$st/hooks/"* "$st/dispatcher.cmd" 2>/dev/null || true
  return 0
}

# write RUNTIME_MANIFEST.json = sha256 of every file in the staged generation (except the manifest itself)
_write_manifest(){ # $1 stage  $2 sha  $3 version  $4 py
  local st="$1" sha="$2" ver="$3" py="$4"
  "$py" - "$st" "$sha" "$ver" > "$st/RUNTIME_MANIFEST.json" <<'PY' || return 1
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

# how many Preflight-owned Bash PreToolUse entries are FUNCTIONALLY registered (0 if none / unparseable)?
# This is the single source of truth for "is the hook registered" — a matcher-aware structured check, NOT
# a substring scan (a substring like "preflight/dispatcher.cmd" in a note/comment is NOT a live hook).
_registration_count(){
  [ -f "$PF_SETTINGS" ] || { echo 0; return; }
  jq empty "$PF_SETTINGS" 2>/dev/null || { echo 0; return; }
  jq --arg re "$PF_OWN_RE" '[(.hooks.PreToolUse // [])[] | select(.matcher=="Bash") | (.hooks // [])[] | select((.command // "") | test($re))] | length' "$PF_SETTINGS" 2>/dev/null || echo 0
}
# is the Preflight user hook FUNCTIONALLY registered? Keyed to the structured count (review F2): a decoy
# substring in a comment/customField must NEVER read as registered (that let verify/doctor falsely PASS).
_is_registered(){
  [ "$(_registration_count)" -ge 1 ] 2>/dev/null
}

# register (or refresh) the PreToolUse Bash hook, preserving all other settings, dedup by command identity
_register_settings(){ # $1 py
  local py="$1"
  local disp_fwd; disp_fwd="$(printf '%s' "$PF_DISPATCH" | sed 's#\\#/#g')"
  local cmd="\"${disp_fwd}\" user-preflight-router"
  local block; block="$(jq -n --arg cmd "$cmd" '{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:$cmd,timeout:60000}]}]}')" || return 1
  local merged
  # An EMPTY / whitespace-only / non-OBJECT settings.json is NOT a mergeable object. `jq empty` passes on
  # empty input and on a bare scalar/array, and merging into it yields empty output (a lone newline) with
  # NO hook registered — yet the old code declared success (review F1: a silent dead-gate + false success).
  # Treat "not a JSON object" as a FRESH install (write the {hooks:$blk} block); only a NON-EMPTY,
  # PARSEABLE, OBJECT settings.json is merged into. An existing object that is not valid JSON is fail-closed.
  local is_mergeable_object="no"
  if [ -f "$PF_SETTINGS" ] && [ -s "$PF_SETTINGS" ]; then
    if ! jq -e 'type=="object"' "$PF_SETTINGS" >/dev/null 2>&1; then
      # present, non-empty, but not a JSON object (invalid JSON, or a top-level array/scalar/empty-after-ws)
      if jq empty "$PF_SETTINGS" 2>/dev/null; then
        # valid JSON but not an object (array/scalar) OR whitespace-only → cannot merge; a non-empty
        # array/scalar could hold user intent, so refuse rather than silently discard it.
        if jq -e '. == null' "$PF_SETTINGS" >/dev/null 2>&1 || [ -z "$(tr -d ' \t\r\n' < "$PF_SETTINGS")" ]; then
          is_mergeable_object="no"   # null / whitespace-only → safe to treat as fresh
        else
          _err "existing $PF_SETTINGS is valid JSON but not an object (top-level $(jq -r 'type' "$PF_SETTINGS" 2>/dev/null)) — refusing to overwrite it. Fix or move it, then re-install."
          return 1
        fi
      else
        # FAIL-CLOSED (review IF1): unparseable settings.json must NOT be overwritten (would drop user keys).
        _err "existing $PF_SETTINGS is not valid JSON — refusing to overwrite it. Fix or move it, then re-install."
        return 1
      fi
    else
      is_mergeable_object="yes"
    fi
  fi
  if [ "$is_mergeable_object" = "yes" ]; then
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
  # The merged result MUST be a non-empty object; guard against an empty/degenerate merge before writing.
  printf '%s' "$merged" | jq -e 'type=="object"' >/dev/null 2>&1 || { _err "settings merge produced no object — aborting"; return 1; }
  printf '%s\n' "$merged" > "$PF_SETTINGS.tmp" || return 1
  jq empty "$PF_SETTINGS.tmp" 2>/dev/null || { rm -f "$PF_SETTINGS.tmp"; return 1; }
  mv "$PF_SETTINGS.tmp" "$PF_SETTINGS" || return 1
  # POST-CONDITION (review F1): after writing, the hook MUST be functionally registered. If not, the merge
  # silently failed — fail the install rather than report a false success with a dead gate.
  [ "$(_registration_count)" -ge 1 ] || { _err "post-merge registration check failed — the Preflight hook is not present in $PF_SETTINGS after merge"; return 1; }
  return 0
}

# ═══════════════════════════════ CLI + LAUNCHER ════════════════════════════════════════════════════════
# v0.10.1 model: the management CLI ships INSIDE each immutable generation (runtime/<sha>/cli/preflight-user.sh,
# covered by RUNTIME_MANIFEST.json). The stable on-PATH copy at $PF_CLI is SYNCED FROM THE ACTIVE GENERATION on
# every install AND every rollback — so `preflight version` can never lag the runtime again (the v0.10.0 defect:
# a from-artifact upgrade swapped the runtime but had no CLI to stage, leaving the old CLI in place). The sync
# is ATOMIC (stage a temp beside $PF_CLI, then mv) and, during install, FATAL (rolled back with the runtime);
# the on-PATH launcher write stays best-effort (version-independent UX, not the governing surface).
#
# _sync_stable_cli <gen-dir>: copy the generation's bundled CLI to $PF_CLI atomically. Returns non-zero on any
# failure so the caller can decide (install → fatal+rollback; rollback → warn). NEVER cp a file onto itself.
_sync_stable_cli(){ # $1 = generation dir
  local gen="$1"; local cli_src="$gen/cli/preflight-user.sh"
  [ -f "$cli_src" ] || { _err "generation $gen has no bundled cli/preflight-user.sh"; return 1; }
  mkdir -p "$(dirname "$PF_CLI")" || return 1
  local src_abs dst_abs
  src_abs="$(cd "$(dirname "$cli_src")" 2>/dev/null && pwd)/$(basename "$cli_src")"
  dst_abs="$(cd "$(dirname "$PF_CLI")" 2>/dev/null && pwd)/$(basename "$PF_CLI")"
  if [ "$src_abs" = "$dst_abs" ]; then chmod +x "$PF_CLI" 2>/dev/null || true; return 0; fi
  local tmp="$PF_CLI.stage.$$"
  cp "$cli_src" "$tmp" 2>/dev/null || { _err "failed to stage CLI from $cli_src"; rm -f "$tmp" 2>/dev/null; return 1; }
  chmod +x "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$PF_CLI" 2>/dev/null || { _err "failed to activate staged CLI"; rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}

# _install_launcher: write the thin `preflight` launcher (+ Windows .cmd) on PATH. Best-effort UX; the launcher
# path never changes across upgrades — it hard-codes ONLY the stable $PF_CLI path, so upgrades never rewrite it.
_install_launcher(){
  local bindir launcher
  bindir="$(_pf_bin_dir)"; mkdir -p "$bindir" || return 1
  launcher="$bindir/preflight"
  # Thin polyglot launcher: on Git-Bash/Unix it execs the stable CLI with bash; it forwards all args and
  # stdin. It hard-codes ONLY the stable CLI path (never a versioned one), so upgrades need not rewrite it.
  cat > "$launcher" <<LAUNCH
#!/usr/bin/env bash
# preflight — user launcher (installed by preflight-user.sh). Execs the stable management CLI, which
# resolves the ACTIVE immutable runtime generation. This launcher path is stable across upgrades.
PF_CLI="${PF_CLI}"
if [ ! -f "\$PF_CLI" ]; then echo "preflight: management CLI missing at \$PF_CLI — reinstall preflight" >&2; exit 1; fi
exec bash "\$PF_CLI" "\$@"
LAUNCH
  chmod +x "$launcher" 2>/dev/null || true
  # Windows companion: a preflight.cmd so `preflight` works from cmd.exe/PowerShell too (best-effort).
  if [ -n "${WINDIR:-}${SystemRoot:-}" ] || case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) true;; *) false;; esac; then
    local cli_win; cli_win="$(printf '%s' "$PF_CLI" | sed 's#/#\\#g')"
    cat > "$bindir/preflight.cmd" <<WINCMD
@echo off
where bash >nul 2>&1 && (bash "%~dp0preflight" %* & exit /b !errorlevel!)
echo preflight: bash not found on PATH 1>&2
exit /b 1
WINCMD
  fi
  echo "preflight-user: launcher at $launcher  (CLI at $PF_CLI)"
  # PATH hint if the bindir is not currently on PATH.
  case ":$PATH:" in *":$bindir:"*) : ;; *) echo "preflight-user: NOTE add '$bindir' to your PATH to run 'preflight' directly";; esac
  return 0
}

# ═══════════════════════════════ REPO / OPT-IN HELPERS (init/disable/status) ═══════════════════════════
# Resolve the repo root at/above a directory (read-only, bounded). Echoes the root or the input dir.
_pf_repo_root(){  # $1 = start dir
  local d="$1" i=0
  while [ -n "$d" ] && [ "$i" -lt 40 ]; do
    if [ -e "$d/.git" ] || [ -f "$d/.preflight/config.json" ] || [ -f "$d/.cpsl/config.json" ] || [ -f "$d/.forge.json" ]; then echo "$d"; return 0; fi
    local p; p="$(dirname "$d")"; [ "$p" = "$d" ] && break; d="$p"; i=$((i+1))
  done
  echo "$1"; return 1
}
# The opt-in config path for a repo root (active form), and its disabled sibling.
_pf_active_config(){ echo "$1/.preflight/config.json"; }
_pf_disabled_config(){ echo "$1/.preflight/config.json.disabled"; }
# Ensure a line is present in .git/info/exclude so Preflight-owned local config stays UNTRACKED without
# touching the tracked .gitignore. Returns a STATUS the caller reports HONESTLY (review D3: the old version
# swallowed every failure and the caller unconditionally claimed success, so a read-only exclude / a non-git
# dir printed "ensured" while .preflight/ was actually committable). Contract:
#   0 = the pattern is now present in .git/info/exclude (or already was)
#   3 = not a git repo (nothing to exclude into — .git/info/exclude does not apply)
#   4 = git repo but the exclude write FAILED (dir uncreatable or file not writable) — caller must warn
_pf_exclude_local(){  # $1 = repo root ; $2 = pattern (e.g. /.preflight/)
  local root="$1" pat="$2" gd exf
  # Use the COMMON git dir, NOT --git-dir (review P1): Git reads info/exclude ONLY from the common dir. In a
  # LINKED WORKTREE `--git-dir` returns .git/worktrees/<name>/, so writing info/exclude there has NO effect —
  # .preflight/ stays committable while init falsely claims "untracked". --git-common-dir is the .git that
  # Git actually consults, and equals --git-dir in a normal (non-worktree) repo. This project is itself
  # developed in linked worktrees (code-forge-rdg), so the worktree case is the common case here.
  gd="$(cd "$root" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null)" || return 3
  [ -n "$gd" ] || return 3
  # --git-common-dir may return a path relative to the worktree's cwd; resolve to absolute.
  case "$gd" in
    /*|[A-Za-z]:*) : ;;
    *) gd="$(cd "$root" 2>/dev/null && cd "$gd" 2>/dev/null && pwd)" || gd="$root/$gd" ;;
  esac
  exf="$gd/info/exclude"
  [ -f "$exf" ] && grep -qxF "$pat" "$exf" 2>/dev/null && return 0   # already excluded
  mkdir -p "$gd/info" 2>/dev/null || return 4
  printf '%s\n' "$pat" >> "$exf" 2>/dev/null || return 4
  # confirm it actually landed (a silent partial write / RO fs must not read as success)
  grep -qxF "$pat" "$exf" 2>/dev/null || return 4
  return 0
}
# Emit the honest exclude-status line for init, given _pf_exclude_local's return code and the repo root.
_pf_report_exclude(){  # $1 = rc from _pf_exclude_local ; $2 = repo root
  case "$1" in
    0) echo "  exclude:  '/.preflight/' is in .git/info/exclude (untracked — no tracked file changed)" ;;
    3) echo "  exclude:  (not a git repo — no .git/info/exclude; .preflight/ is not tracked because there is no index here)" ;;
    4) echo "  WARNING:  could NOT write .git/info/exclude (read-only?). .preflight/ is NOT excluded — do NOT 'git add' it, or add '/.preflight/' to your ignore rules manually." ;;
  esac
}

# ═══════════════════════════════ INIT --local ══════════════════════════════════════════════════════════
# Activate Preflight in the CURRENT repo by writing a Preflight-owned, gitignored opt-in config. Creates
# ONLY .preflight/ (config + local exclude). Reports exactly what changed. No tracked change is made.
cmd_init_local(){
  local start="${OPT_DIR:-$PWD}" root cfg dis created="" reactivated="no"
  root="$(_pf_repo_root "$start")"
  cfg="$(_pf_active_config "$root")"; dis="$(_pf_disabled_config "$root")"
  local exrc
  echo "preflight init --local"
  echo "  repo:     $root"
  if [ -f "$cfg" ]; then
    echo "  config:   already present at $cfg (repo already opted in) — no change"
    # An orphaned .disabled alongside an active config is stale — note it so the user isn't misled into
    # thinking `disable` would restore THAT one (review D1 init-side: don't leave it silently orphaned).
    [ -f "$dis" ] && echo "  note:     a stale $dis also exists (a prior disabled config). The ACTIVE config above governs; the .disabled copy is ignored."
    _pf_exclude_local "$root" "/.preflight/"; exrc=$?
    _pf_report_exclude "$exrc" "$root"
    echo "  status:   ACTIVE"
    return 0
  fi
  mkdir -p "$root/.preflight" || _die "cannot create $root/.preflight"
  if [ -f "$dis" ]; then
    mv "$dis" "$cfg" || _die "cannot re-activate $cfg"; reactivated="yes"
    echo "  config:   re-activated $cfg (was disabled)"
  else
    # Minimal, self-documented opt-in config. Ships a safe generic default; the user edits branch.remote etc.
    cat > "$cfg" <<'CFG'
{
  "_note": "Preflight opt-in config (LOCAL, gitignored). Its PRESENCE activates Preflight for this repo.",
  "mode": "generic",
  "branch": {
    "base": "main",
    "remote": "origin",
    "_comment_remote": "VERIFY 'remote' is your intended push target (NOT a prod/legacy repo) before pushing.",
    "forbiddenRemotes": [],
    "forbiddenRepos": [],
    "safeRemotes": []
  }
}
CFG
    created="yes"
    echo "  config:   created $cfg  (mode=generic, base=main, remote=origin)"
  fi
  _pf_exclude_local "$root" "/.preflight/"; exrc=$?
  _pf_report_exclude "$exrc" "$root"
  echo "  owner:    $(_pf_owner_for_repo "$root")"
  echo "  status:   ACTIVE"
  echo ""
  echo "  Tip: verify 'branch.remote' in $cfg before your first push. Run 'preflight status' to confirm."
  return 0
}

# ═══════════════════════════════ DISABLE ═══════════════════════════════════════════════════════════════
# Deactivate Preflight in the current repo WITHOUT deleting the config: rename config.json → .disabled so the
# router fast-exits (repo no longer opted in). `preflight init --local` re-activates it. Reversible, local.
cmd_disable(){
  local start="${OPT_DIR:-$PWD}" root cfg dis
  root="$(_pf_repo_root "$start")"
  cfg="$(_pf_active_config "$root")"; dis="$(_pf_disabled_config "$root")"
  echo "preflight disable"
  echo "  repo:     $root"
  if [ ! -f "$cfg" ]; then
    if [ -f "$dis" ]; then echo "  status:   already INACTIVE (config disabled at $dis)"; return 0; fi
    echo "  status:   INACTIVE (no opt-in config present) — nothing to disable"; return 0
  fi
  # COLLISION GUARD (review D1): never clobber an existing .disabled — that silently destroys a prior saved
  # config. If the default .disabled slot is taken, move to a unique timestamped sibling instead.
  local target="$dis"
  if [ -e "$dis" ]; then
    local ts; ts="$(_py 2>/dev/null && "$(_py)" -c 'import time;print(time.strftime("%Y%m%dT%H%M%S"))' 2>/dev/null)"; [ -n "$ts" ] || ts="prev"
    target="${dis}.${ts}"
    # extremely unlikely, but guarantee uniqueness
    local i=1; while [ -e "$target" ]; do target="${dis}.${ts}.${i}"; i=$((i+1)); done
    echo "  note:     $dis already exists (a prior disabled config) — preserving it; this one goes to $(basename "$target")"
  fi
  mv "$cfg" "$target" || _die "cannot disable $cfg"
  echo "  config:   $cfg → $target (preserved; re-enable with 'preflight init --local')"
  echo "  status:   INACTIVE (router now fast-exits for this repo)"
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
  # version: the ACTIVE generation must record a well-formed RELEASE_VERSION (self-consistency). It need
  # NOT equal the CLI's compiled-in RELEASE_VERSION — after a legitimate ROLLBACK the active generation is
  # an OLDER version (e.g. rc.1) while the CLI is newer (rc.2); that is a VALID state, not an integrity
  # failure (v0.10.0-rc.2 fix). Integrity is manifest + registration + dispatcher (checked above). We
  # report the active version, and note when it differs from the CLI (informational, non-failing).
  local ver=""; [ -f "$gen/RELEASE_VERSION" ] && ver="$(tr -d ' \t\r\n' < "$gen/RELEASE_VERSION")"
  case "$ver" in
    v[0-9]*) if [ "$ver" = "$RELEASE_VERSION" ]; then echo "OK version $ver"; else echo "OK version $ver (active generation differs from CLI $RELEASE_VERSION — expected after a rollback)"; fi ;;
    *) _err "active generation has no valid RELEASE_VERSION"; rc=1 ;;
  esac
  # v0.10.1: CLI / runtime lockstep. The stable on-PATH CLI ($PF_CLI) MUST be byte-identical to the ACTIVE
  # generation's bundled cli/preflight-user.sh — that is the invariant a from-artifact upgrade violated in
  # v0.10.0 (runtime swapped, CLI stale). If the generation bundles a CLI and it drifts from $PF_CLI, that is
  # a real integrity fault (FAIL). A generation predating the bundle (no cli/, e.g. an older rolled-back gen)
  # is exempted with a note — its runtime still governs; there is simply nothing to compare against.
  if [ -f "$gen/cli/preflight-user.sh" ]; then
    if [ -f "$PF_CLI" ] && cmp -s "$gen/cli/preflight-user.sh" "$PF_CLI"; then
      echo "OK CLI in lockstep with active generation"
    else
      _err "CLI/runtime MISMATCH: on-PATH CLI ($PF_CLI) differs from the active generation's bundled CLI — run 'preflight install --user --ref <ACTIVE>' or 'rollback' to re-sync"; rc=1
    fi
  else
    echo "OK (active generation predates the bundled CLI — CLI lockstep check skipped)"
  fi
  [ "$rc" = 0 ] && echo "VERIFY: PASS" || echo "VERIFY: FAIL"
  return $rc
}

# ═══════════════════════════════ STATUS / VERSION ══════════════════════════════════════════════════════
# Locate + source lib/hook-arbitration.sh (dev tree, installed .claude/lib, or the ACTIVE runtime gen).
_pf_load_arbitration(){
  local here arb sha
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for arb in "$here/../lib/hook-arbitration.sh" "$here/../.claude/lib/hook-arbitration.sh"; do
    [ -f "$arb" ] && { . "$arb"; return 0; }
  done
  [ -f "$PF_ACTIVE" ] && sha="$(tr -d ' \t\r\n' < "$PF_ACTIVE" 2>/dev/null)"
  if [ -n "${sha:-}" ] && [ -f "$PF_RUNTIME/$sha/lib/hook-arbitration.sh" ]; then . "$PF_RUNTIME/$sha/lib/hook-arbitration.sh"; return 0; fi
  return 1
}
# Effective owner (USER|PROJECT|AMBIGUOUS|NONE) for a repo root, via the SINGLE shared arbitration rule.
_pf_owner_for_repo(){  # $1 = repo root
  local root="$1" cfg="no" c
  for c in "$root/.preflight/config.json" "$root/.cpsl/config.json" "$root/.forge.json"; do [ -f "$c" ] && { cfg="yes"; break; }; done
  [ "$cfg" = yes ] || { echo "NONE"; return 0; }
  if _pf_load_arbitration; then pfa_classify_owner "$root" "$PF_DISPATCH"; echo "$PFA_OWNER"; else echo "USER"; fi
}
# Policy tier + push posture derived from the repo's opt-in config (honest, config-derived; not a claim of
# server-side enforcement). Echoes a one-line summary.
_pf_policy_summary(){  # $1 = repo root
  local root="$1" cfg="" c mode="generic" safe=0 forb=0
  for c in "$root/.preflight/config.json" "$root/.cpsl/config.json" "$root/.forge.json"; do [ -f "$c" ] && { cfg="$c"; break; }; done
  [ -n "$cfg" ] || { echo "n/a (repo not opted in)"; return 0; }
  if command -v jq >/dev/null 2>&1 && jq empty "$cfg" >/dev/null 2>&1; then
    mode="$(jq -r '.mode // "generic"' "$cfg" 2>/dev/null)"
    safe="$(jq -r '((.branch.safeRemotes // []) | length)' "$cfg" 2>/dev/null || echo 0)"
    forb="$(jq -r '(((.branch.forbiddenRemotes // []) + (.branch.forbiddenRepos // [])) | length)' "$cfg" 2>/dev/null || echo 0)"
  fi
  local tier="AUTO/CONFIRM/BLOCK (reversibility-tiered)"
  [ "${safe:-0}" -gt 0 ] 2>/dev/null && tier="STRICT — AUTO restricted to safeRemotes allowlist"
  echo "mode=$mode; push-gate=$tier; denylist entries=$forb (agent Bash-tool guard, fail-open by design; not server-side)"
}
# Is remote (CI-side) enforcement configured for this repo? Detects the remote-gate collector workflow or a
# protocol policy present in the repo. HONEST: local install is advisory/agent-side; remote is the authority.
_pf_remote_enforcement(){  # $1 = repo root
  local root="$1"
  if [ -f "$root/.github/workflows/preflight-remote-gate-collect.yaml" ] || [ -f "$root/.github/workflows/preflight-remote-gate.yaml" ]; then
    echo "configured (remote-gate workflow present) — this is the authoritative required-check"; return 0
  fi
  echo "not configured (local agent-side advisory gate only; no server-side required-check)"
}
# One-line runtime-health check (no heavy verify): ACTIVE resolves + gen dir + router present + registered.
_pf_runtime_health(){
  local sha
  [ -f "$PF_ACTIVE" ] || { echo "INACTIVE (no user runtime installed)"; return 0; }
  sha="$(tr -d ' \t\r\n' < "$PF_ACTIVE" 2>/dev/null)"
  case "$sha" in *[!0-9a-fA-F]*|"") echo "UNHEALTHY (ACTIVE not a valid sha)"; return 0;; esac
  [ -d "$PF_RUNTIME/$sha" ] || { echo "UNHEALTHY (ACTIVE generation dir missing)"; return 0; }
  [ -f "$PF_DISPATCH" ] || { echo "UNHEALTHY (stable dispatcher missing)"; return 0; }
  [ -f "$PF_RUNTIME/$sha/hooks/user-preflight-router" ] || { echo "UNHEALTHY (router missing from active gen)"; return 0; }
  if _is_registered; then echo "HEALTHY (installed, registered, router present)"; else echo "STAGED (installed but NOT registered in settings.json)"; fi
}

cmd_status(){
  local start="${OPT_DIR:-$PWD}" root owner active_sha ver health
  root="$(_pf_repo_root "$start")"
  owner="$(_pf_owner_for_repo "$root")"
  [ -f "$PF_ACTIVE" ] && active_sha="$(tr -d ' \t\r\n' < "$PF_ACTIVE" 2>/dev/null)"
  [ -n "${active_sha:-}" ] && [ -f "$PF_RUNTIME/$active_sha/RELEASE_VERSION" ] && ver="$(tr -d ' \t\r\n' < "$PF_RUNTIME/$active_sha/RELEASE_VERSION")"
  health="$(_pf_runtime_health)"
  # Does a HEALTHY, registered user runtime actually exist to enforce the decision here? (review D2: config
  # presence ALONE must NOT read as "governed" — a fail-closed guard must never tell a user they are
  # protected when nothing is installed/registered to gate a push. "governed" requires BOTH opt-in AND a
  # live runtime that owns this repo.) A PROJECT owner is enforced by the project runtime, so it also counts.
  local runtime_live="no"
  case "$health" in HEALTHY*) runtime_live="yes" ;; esac

  echo "preflight status"
  # ── this repo ──
  echo "  repo:              $root"
  if [ "$owner" = "NONE" ]; then
    echo "  active here:       NO — this repo has NOT opted in (run: preflight init --local)"
  elif [ "$owner" = "PROJECT" ]; then
    echo "  active here:       YES — a PROJECT-level runtime governs this repo"
  elif [ "$runtime_live" = "yes" ]; then
    echo "  active here:       YES — Preflight governs this repo (opted in + healthy user runtime)"
  else
    echo "  active here:       OPTED IN, but NOT ENFORCED — no healthy/registered user runtime is installed to gate pushes here (run: preflight install --user; then preflight doctor)"
  fi
  echo "  ownership:         $owner$( [ "$owner" = NONE ] && echo '  (no governing runtime)')"
  echo "  policy:            $(_pf_policy_summary "$root")"
  echo "  remote enforcement:$(printf ' %s' "$(_pf_remote_enforcement "$root")")"
  # ── the user-level install ──
  echo "  --- user install ---"
  echo "  version:           ${ver:-（none active)}"
  echo "  runtime health:    $health"
  echo "  ACTIVE:            $( [ -f "$PF_ACTIVE" ] && cat "$PF_ACTIVE" || echo '(none)')"
  echo "  PREVIOUS:          $( [ -f "$PF_PREVIOUS" ] && cat "$PF_PREVIOUS" || echo '(none)')"
  echo "  registered (user): $( _is_registered && echo yes || echo no)"
  if [ -d "$PF_RUNTIME" ]; then echo "  generations:       $(find "$PF_RUNTIME" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"; fi
  echo "  settings:          $PF_SETTINGS $( [ -f "$PF_SETTINGS" ] && echo '(present)' || echo '(absent)')"
  return 0
}
# version: report what is ACTUALLY governing (the ACTIVE generation), not just the CLI's compiled constant.
cmd_version(){
  local sha ver
  [ -f "$PF_ACTIVE" ] && sha="$(tr -d ' \t\r\n' < "$PF_ACTIVE" 2>/dev/null)"
  if [ -n "${sha:-}" ] && [ -f "$PF_RUNTIME/$sha/RELEASE_VERSION" ]; then
    ver="$(tr -d ' \t\r\n' < "$PF_RUNTIME/$sha/RELEASE_VERSION")"
    if [ "$ver" = "$RELEASE_VERSION" ]; then echo "$ver"
    else echo "$ver (active runtime; CLI $RELEASE_VERSION)"; fi
  else
    echo "$RELEASE_VERSION (CLI; no active runtime)"
  fi
}

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
  # v0.10.1: re-sync the stable on-PATH CLI from the now-active generation so `preflight version` reports the
  # rolled-back version, not the version that happened to be installed last. The generation was manifest-
  # verified above, so its bundled cli/ is trusted. A generation predating the bundled-CLI change (no cli/)
  # keeps the current CLI (best-effort) — the runtime, which governs, is still correctly rolled back.
  if [ -f "$gen/cli/preflight-user.sh" ]; then
    _sync_stable_cli "$gen" || _err "warning: CLI re-sync after rollback incomplete (runtime IS rolled back to $prev)"
  else
    _err "note: generation $prev predates the bundled CLI (v0.10.1) — leaving the current management CLI in place"
  fi
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
# Resolve the active user-runtime version + commit (READ-ONLY). Echoes "version|commit" or "none|none".
_doctor_user_gen(){
  local sha ver="unknown"
  [ -r "$PF_ACTIVE" ] || { echo "none|none"; return 0; }
  sha="$(tr -d ' \t\r\n' < "$PF_ACTIVE" 2>/dev/null)"
  [ -n "$sha" ] || { echo "none|none"; return 0; }
  local rv="$PF_RUNTIME/$sha/RELEASE_VERSION"
  [ -r "$rv" ] && ver="$(tr -d ' \t\r\n' < "$rv" 2>/dev/null)"
  echo "${ver}|${sha}"
}

# READ-ONLY hook-ownership report for a project path. Never writes; never mutates the target repo.
# Effective owner is derived from the SINGLE shared rule (lib/hook-arbitration.sh) — no second source.
cmd_doctor_project(){
  local proj="$1"
  echo "preflight hook-arbitration doctor  (READ-ONLY)"
  echo "  project:  $proj"
  if [ ! -d "$proj" ]; then echo "  ERROR: not a directory"; return 1; fi

  # ---- user side ----
  local ug uver usha; ug="$(_doctor_user_gen)"; uver="${ug%%|*}"; usha="${ug##*|}"
  if [ "$usha" = "none" ]; then
    echo "  user runtime:    NOT INSTALLED (no ACTIVE generation)"
  else
    echo "  user runtime:    version $uver  commit $usha"
    # Use the FUNCTIONAL (structured, matcher-aware) registration check — not a substring scan that a decoy
    # comment could satisfy (review F2). Single source of truth: _is_registered → _registration_count.
    if _is_registered; then echo "  user registration: PRESENT in $PF_SETTINGS (PreToolUse Bash → dispatcher.cmd)"
    else echo "  user registration: ABSENT from $PF_SETTINGS (user runtime staged but not registered)"; fi
  fi

  # ---- find the repo root at/above the given path (read-only) ----
  local root="" d="$proj" i=0
  while [ -n "$d" ] && [ "$i" -lt 40 ]; do
    if [ -e "$d/.git" ] || [ -f "$d/.preflight/config.json" ] || [ -f "$d/.cpsl/config.json" ] || [ -f "$d/.forge.json" ]; then root="$d"; break; fi
    local p; p="$(dirname "$d")"; [ "$p" = "$d" ] && break; d="$p"; i=$((i+1))
  done
  [ -n "$root" ] || root="$proj"
  echo "  repo root:       $root"

  # opt-in status
  local optin="no"
  for c in "$root/.preflight/config.json" "$root/.cpsl/config.json" "$root/.forge.json"; do
    [ -f "$c" ] && { optin="yes"; echo "  opt-in config:   $c"; break; }
  done
  [ "$optin" = "yes" ] || echo "  opt-in config:   NONE (repo not opted in → user router exits immediately; effective owner NONE)"

  # ---- effective owner via the SHARED rule ----
  local arb; arb="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/hook-arbitration.sh"
  [ -f "$arb" ] || arb="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../.claude/lib/hook-arbitration.sh"
  # in an installed user runtime the lib is under runtime/<sha>/lib
  [ -f "$arb" ] || arb="$PF_RUNTIME/$usha/lib/hook-arbitration.sh"
  if [ ! -f "$arb" ]; then echo "  ERROR: hook-arbitration.sh not found (cannot classify owner)"; return 1; fi
  # shellcheck source=/dev/null
  . "$arb"

  if [ "$optin" != "yes" ]; then
    echo "  EFFECTIVE OWNER: NONE (not opted in)"
    echo "  duplicate risk:  no"
    echo "  remediation:     none — the repo is not governed by Preflight."
    return 0
  fi

  pfa_classify_owner "$root" "$PF_DISPATCH"
  echo "  project registrations found:"
  if [ -n "$PFA_PROJECT_CMDS" ]; then
    printf '%s' "$PFA_PROJECT_CMDS" | while IFS= read -r line; do [ -n "$line" ] && echo "    - $line"; done
  else
    echo "    (none)"
  fi
  # project runtime pinned ref if a project install manifest exists (read-only, best-effort). Prefer a jq
  # read of resolvedSha/pinnedRef; fall back to a scrubbed grep. Never dumps a raw JSON fragment.
  local pver="n/a"
  if [ -r "$root/.preflight/installed.lock" ]; then
    if command -v jq >/dev/null 2>&1 && jq empty "$root/.preflight/installed.lock" >/dev/null 2>&1; then
      pver="$(jq -r '(.resolvedSha // .pinnedRef // .ref // .version // "n/a")' "$root/.preflight/installed.lock" 2>/dev/null)"
    else
      pver="$(grep -m1 -oE '"(resolvedSha|pinnedRef|ref|version)"[[:space:]]*:[[:space:]]*"[^"]*"' "$root/.preflight/installed.lock" 2>/dev/null | tr -d '\r' | head -c 120)"
    fi
    [ -n "$pver" ] || pver="n/a"
  fi
  echo "  project runtime: $pver"
  echo "  EFFECTIVE OWNER: $PFA_OWNER"
  echo "  duplicate risk:  $PFA_DUP_RISK$([ "$PFA_STALE" = yes ] && echo ' (stale project registration)')"
  echo "  reason:          $PFA_REASON"
  case "$PFA_OWNER" in
    PROJECT)   echo "  remediation:     none — the project runtime owns this repo; the user router yields (writes nothing)." ;;
    USER)      if [ "$PFA_DUP_RISK" = yes ]; then
                 echo "  remediation:     remove the user-runtime reference from the project settings file (the user-level install already governs this repo; the project entry only re-invokes the same runtime)."
               else
                 echo "  remediation:     none — user runtime owns this repo (no project install present)."
               fi ;;
    AMBIGUOUS) echo "  remediation:     $([ "$PFA_STALE" = yes ] && echo 'reinstall the project runtime or remove the stale project registration' || echo 'fix or remove the malformed project settings file'); the user runtime is owning the decision safely in the meantime." ;;
  esac
  return 0
}

# Diagnose the CURRENT repo for the five classes the goal requires: duplicate hooks, stale runtime,
# malformed config, missing dependencies, unsupported Git contexts. Prints findings + EXACT remediation.
# READ-ONLY. Returns the count of problems found (0 = clean) via the global _PF_DOCTOR_PROBLEMS.
_PF_DOCTOR_PROBLEMS=0
_pf_doctor_diagnose_repo(){  # $1 = start dir
  local root; root="$(_pf_repo_root "$1")"
  echo "  --- repo diagnostics ($root) ---"

  # (a) unsupported Git context: bare repo, detached/rebase/merge in progress, worktree edge, or non-repo.
  local gd="" inside
  inside="$(cd "$root" 2>/dev/null && git rev-parse --is-inside-work-tree 2>/dev/null)" || inside=""
  if [ "$inside" != "true" ]; then
    if (cd "$root" 2>/dev/null && git rev-parse --is-bare-repository 2>/dev/null | grep -q true); then
      echo "  git context:      BARE repository — push-gating is designed for work-tree clones."
      echo "                    FIX: run Preflight from a normal (non-bare) clone."
      _PF_DOCTOR_PROBLEMS=$((_PF_DOCTOR_PROBLEMS+1))
    else
      echo "  git context:      NOT a git work tree — the push gate has nothing to govern here (OK if intended)."
    fi
  else
    gd="$(cd "$root" && git rev-parse --git-dir 2>/dev/null)"
    local state="clean"
    [ -d "$root/$gd/rebase-merge" ] || [ -d "$root/$gd/rebase-apply" ] && state="rebase-in-progress"
    [ -f "$root/$gd/MERGE_HEAD" ] && state="merge-in-progress"
    echo "  git context:      work tree OK (git-dir=$gd; state=$state)"
  fi

  # (b) opt-in config present + parseable (malformed config).
  local cfg="" c
  for c in "$root/.preflight/config.json" "$root/.cpsl/config.json" "$root/.forge.json"; do [ -f "$c" ] && { cfg="$c"; break; }; done
  if [ -z "$cfg" ]; then
    if [ -f "$root/.preflight/config.json.disabled" ]; then
      echo "  opt-in config:    DISABLED ($root/.preflight/config.json.disabled)"
      echo "                    FIX: run 'preflight init --local' to re-enable."
    else
      echo "  opt-in config:    none — repo not opted in (run 'preflight init --local' to activate)."
    fi
  else
    if command -v jq >/dev/null 2>&1; then
      if jq empty "$cfg" >/dev/null 2>&1; then echo "  opt-in config:    $cfg (valid JSON)"
      else echo "  opt-in config:    MALFORMED — $cfg is not valid JSON."; echo "                    FIX: correct the JSON or 'preflight disable' then 'preflight init --local'."; _PF_DOCTOR_PROBLEMS=$((_PF_DOCTOR_PROBLEMS+1)); fi
    else echo "  opt-in config:    $cfg (present; install jq to validate)"; fi
    # config.local overlay malformed?
    if [ -f "$root/.preflight/config.local.json" ] && command -v jq >/dev/null 2>&1 && ! jq empty "$root/.preflight/config.local.json" >/dev/null 2>&1; then
      echo "  local overlay:    MALFORMED — .preflight/config.local.json is not valid JSON."
      echo "                    FIX: correct or remove it."; _PF_DOCTOR_PROBLEMS=$((_PF_DOCTOR_PROBLEMS+1))
    fi
  fi

  # (c) ownership + duplicate hooks + stale project runtime, via the SHARED arbitration rule.
  if [ -n "$cfg" ] && _pf_load_arbitration; then
    pfa_classify_owner "$root" "$PF_DISPATCH"
    echo "  effective owner:  $PFA_OWNER"
    if [ "$PFA_DUP_RISK" = yes ]; then
      echo "  duplicate hooks:  YES — a project settings entry re-invokes the SAME user runtime (double-exec risk)."
      echo "                    FIX: remove the user-runtime reference from the project settings file"
      echo "                         (the user-level install already governs this repo)."
      _PF_DOCTOR_PROBLEMS=$((_PF_DOCTOR_PROBLEMS+1))
    else
      echo "  duplicate hooks:  none detected"
    fi
    if [ "$PFA_STALE" = yes ]; then
      echo "  stale runtime:    YES — a project registration points at a missing/empty hook file."
      echo "                    FIX: reinstall the project runtime, or remove the stale registration."
      _PF_DOCTOR_PROBLEMS=$((_PF_DOCTOR_PROBLEMS+1))
    else
      echo "  stale runtime:    none detected"
    fi
  fi
}

cmd_doctor(){
  # doctor --project <path> → the read-only hook-arbitration report (does not require --user).
  if [ -n "${OPT_PROJECT:-}" ]; then cmd_doctor_project "$OPT_PROJECT"; return $?; fi
  _PF_DOCTOR_PROBLEMS=0
  echo "preflight doctor"
  echo "  --- dependencies ---"
  local py; py="$(_py)" && echo "  python:   $py OK" || { echo "  python:   MISSING — install Python 3 (needed for manifest/checksum)."; _PF_DOCTOR_PROBLEMS=$((_PF_DOCTOR_PROBLEMS+1)); }
  command -v jq >/dev/null 2>&1 && echo "  jq:       $(jq --version)" || { echo "  jq:       MISSING — install jq (needed for settings merge + config validation)."; _PF_DOCTOR_PROBLEMS=$((_PF_DOCTOR_PROBLEMS+1)); }
  command -v git >/dev/null 2>&1 && echo "  git:      $(git --version)" || { echo "  git:      MISSING — install git."; _PF_DOCTOR_PROBLEMS=$((_PF_DOCTOR_PROBLEMS+1)); }
  command -v timeout >/dev/null 2>&1 && echo "  timeout:  OK (candidate-path deadline enforced)" || echo "  timeout:  MISSING — engine runs unbounded on this host (degrades gracefully; install coreutils for the deadline)."
  echo "  claude:   $(claude --version 2>/dev/null || echo 'not on PATH (Claude Code hooks inactive until installed)')"
  # user-runtime health
  echo "  --- user runtime ---"
  echo "  health:   $(_pf_runtime_health)"
  # repo-specific diagnostics
  _pf_doctor_diagnose_repo "${OPT_DIR:-$PWD}"
  echo "  --- integrity ---"
  cmd_verify || true
  echo ""
  if [ "$_PF_DOCTOR_PROBLEMS" -eq 0 ]; then echo "doctor: no problems detected"; else echo "doctor: $_PF_DOCTOR_PROBLEMS problem(s) detected — see FIX lines above"; fi
  return 0
}

# ═══════════════════════════════ arg parse ═════════════════════════════════════════════════════════════
SUB="${1:-}"; shift 2>/dev/null || true
OPT_REF=""; OPT_ARTIFACT=""; OPT_SOURCE=""; OPT_USER=0; OPT_PROJECT=""; OPT_LOCAL=0; OPT_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --user) OPT_USER=1; shift;;
    --local) OPT_LOCAL=1; shift;;
    --dir) OPT_DIR="${2:-}"; shift 2;;
    --ref) OPT_REF="${2:-}"; shift 2;;
    --from-artifact) OPT_ARTIFACT="${2:-}"; shift 2;;
    --source) OPT_SOURCE="${2:-}"; shift 2;;
    --project) OPT_PROJECT="${2:-}"; shift 2;;
    *) _err "unknown arg: $1"; shift;;
  esac
done

_usage(){ cat <<'USAGE'
preflight — usable governance CLI (user-level install)

  preflight init --local [--dir R]   opt this repo in (writes gitignored .preflight/config.json; no tracked change)
  preflight status  [--dir R]        active/inactive · owner (USER/PROJECT) · version · policy tier · health · remote
  preflight doctor  [--dir R]        diagnose deps, duplicate hooks, stale runtime, malformed config, git context
  preflight verify                   integrity of the active user runtime (manifest + registration + dispatcher)
  preflight disable [--dir R]        deactivate this repo (reversible; keeps config as .disabled)
  preflight version                  the governing runtime version
  preflight rollback  --user         swap ACTIVE <-> PREVIOUS generation
  preflight uninstall --user         remove the user runtime + hook (unrelated settings preserved)
  preflight install   --user --ref <tag|sha> [--from-artifact T] [--source DIR]
  preflight doctor    --project P    read-only hook-ownership report for another repo
USAGE
}

case "$SUB" in
  install)   [ "$OPT_USER" = 1 ] || _die "install requires --user"; cmd_install;;
  init)      [ "$OPT_LOCAL" = 1 ] || _die "init requires --local (only local activation is supported)"; cmd_init_local;;
  disable)   cmd_disable;;
  verify)    cmd_verify;;
  status)    cmd_status;;
  version)   cmd_version;;
  rollback)  [ "$OPT_USER" = 1 ] || _die "rollback requires --user"; cmd_rollback;;
  uninstall) [ "$OPT_USER" = 1 ] || _die "uninstall requires --user"; cmd_uninstall;;
  doctor)    cmd_doctor;;
  ""|-h|--help|help) _usage;;
  *) _die "unknown subcommand: $SUB (run 'preflight --help')";;
esac
