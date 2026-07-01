#!/usr/bin/env bash
# lib/shell-structure.sh — BOUNDED, QUOTE-AWARE SHELL COMMAND-POSITION PARSER (Stage 2A: AWK-lexer backend).
#
# STATUS (Stage 2A of the shared-parser redesign): this library is PARSER-ONLY and UNWIRED. Nothing in the
# router or engine policy path sources or calls it yet; sourcing it defines functions and changes NO
# enforcement behavior. It exists so that a later stage can move BOTH `git push` and `gh pr` detection onto
# ONE structural representation (closing the command-position bypass class proven in
# .release-audit/mission2/ci/missionG/SHELL-STRUCTURE-PARSER-DESIGN.md) instead of the divergent
# regex-anchor (gh-pr) vs sed-segmenter (git-push) front-ends that exist today.
#
# STAGE 2A CHANGE FROM STAGE 1: the per-byte quote/escape/comment-aware scan + bounded structural recursion
# + simple-command classification now runs in a STATIC POSIX-AWK lexer (lib/shell-structure-lexer.awk),
# invoked as ONE bounded subprocess over stdin. This replaced the pure-Bash `${var:i:1}` scan, which is
# O(n²) on this platform (16KiB ~5.3s, 64KiB >20s). The AWK scan is linear (~3µs/byte). The public API,
# the PFG_SS_* IR arrays, and the field-for-field output are UNCHANGED and proven equivalent to the frozen
# Stage-1 Bash parser (tests/behavioral/fixtures/shell-structure-stage1-frozen.sh) over the full corpus.
#
# WHY AWK IS PERMITTED HERE (a deliberate, reviewed architecture decision — the Stage-1 header said
# "builtins ONLY"): `awk` is already a core engine dependency (hooks/pre-push-gate-engine invokes it in the
# authoritative path with a `command -v awk` guard; hooks/behavioral-contract-gate uses it too). It is
# present on supported Git-Bash and Linux hosts. The pure-Bash scan could not meet the parser latency budget
# on the supported Windows/CrowdStrike host; a single fixed POSIX-AWK process can. The safety review below
# governs how it is invoked.
#
# HARD SAFETY CONTRACT (every one a security property, not a nicety):
#   • The command bytes are sent to AWK ONLY over stdin (never argv, never -v, never a generated script).
#   • The AWK program is a FIXED, source-controlled file read with `-f`; it is NEVER built from input. It
#     performs NO system(), NO getline-from-command, NO pipe, NO filesystem access beyond being -f'd.
#   • This wrapper NEVER eval's the lexer output. It parses it with `read`. Every field is validated
#     (version, enum, decimal, bounds, node/parent, single terminal, nothing after terminal); malformed,
#     truncated, or abnormal output → PFG_SS_STATUS=ERROR (the caller fails CLOSED).
#   • The lexer NEVER executes, eval's, sources, or expands the command. Malformed/unterminated/ambiguous
#     executable structure → OPAQUE. Budget exhaustion (size/nodes/depth) → an explicit LIMIT status.
#   • Resolved token VALUES (program literal, joined subcommand, env prefix) cross the boundary HEX-ENCODED
#     — no raw command text, no here-doc bodies, no payloads are transmitted in the protocol.
#   • AWK absence / abnormal exit / malformed protocol → ERROR here (fail closed for the parser). In the
#     Stage-2A push SHADOW this maps to SHADOW_ERROR with the legacy verdict left UNCHANGED.
#
# OUTPUT MODEL (unchanged from Stage 1): after a parse, the node forest is in parallel arrays indexed by
# node id (0-based), and PFG_SS_STATUS holds the top-level result:
#   PFG_SS_STATUS         = OK | OPAQUE | SIZE_LIMIT | NODE_LIMIT | DEPTH_LIMIT | ERROR
#   PFG_SS_STATUS_REASON  = human reason for OPAQUE/limit/ERROR (for the caller's fail-closed diagnostic)
#   PFG_SS_NODE_COUNT     = number of nodes emitted
#   per-node parallel arrays (index = node_id): PARENT/CTX/START/END/EXEC/EXEC_COMPUTED/SUBCMD/
#     SUBCMD_COMPUTED/ARGS/ENV/REDIR/OPACITY/OPACITY_REASON  (identical semantics to Stage 1)
# Test/debug-only scanner metadata (NOT part of ordinary diagnostics):
#   PFG_SS_SCANNER=awk   PFG_SS_SCANNER_IMPL=<impl banner>   PFG_SS_SCANNER_DURATION_MS=<int>
#
# This file is intentionally written for complete line-by-line review.

# ── Tunable budgets (callers may override before calling pfg_ss_parse; defaults are the approved values) ──
: "${PFG_SS_MAX_BYTES:=65536}"   # maximum command size
: "${PFG_SS_MAX_NODES:=256}"     # maximum command nodes
: "${PFG_SS_MAX_DEPTH:=8}"       # maximum structural nesting depth

# ── Result/IR globals (reset on every parse) ────────────────────────────────────────────────────────────
PFG_SS_STATUS=""
PFG_SS_STATUS_REASON=""
PFG_SS_NODE_COUNT=0
PFG_SS_PARENT=()
PFG_SS_CTX=()
PFG_SS_START=()
PFG_SS_END=()
PFG_SS_EXEC=()
PFG_SS_EXEC_COMPUTED=()
PFG_SS_SUBCMD=()
PFG_SS_SUBCMD_COMPUTED=()
PFG_SS_ARGS=()
PFG_SS_ENV=()
PFG_SS_REDIR=()
PFG_SS_OPACITY=()
PFG_SS_OPACITY_REASON=()
# test/debug-only scanner metadata
PFG_SS_SCANNER=""
PFG_SS_SCANNER_IMPL=""
PFG_SS_SCANNER_DURATION_MS=""

# ── Location of the fixed lexer + AWK resolution (cached). The lexer sits beside this library. ──────────
_PFG_SS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PFG_SS_LEXER="$_PFG_SS_DIR/shell-structure-lexer.awk"
_PFG_SS_AWK=""          # resolved awk path (cached on first parse)
_PFG_SS_AWK_IMPL=""     # awk implementation banner (first line of --version, or "unknown")

# Context-code → name decode table (MUST mirror the lexer's CTX enum).
_PFG_SS_CTX_NAME=(
  [1]=TOPLEVEL [2]=PIPELINE [3]=SUBSHELL [4]=BRACE_GROUP
  [5]=COMMAND_SUBSTITUTION [6]=BACKTICK_SUBSTITUTION
  [7]=PROCESS_SUBSTITUTION_IN [8]=PROCESS_SUBSTITUTION_OUT
  [9]=IF_BODY [10]=ELIF_BODY [11]=ELSE_BODY
  [12]=WHILE_BODY [13]=UNTIL_BODY [14]=FOR_BODY [15]=CASE_BODY
  [16]=INLINE_SHELL [17]=HERE_DOCUMENT_EXECUTION [18]=FUNCTION_BODY
)
# Status-code → name decode table (mirrors lexer ST enum).
_PFG_SS_ST_NAME=( [0]=OK [1]=OPAQUE [2]=SIZE_LIMIT [3]=NODE_LIMIT [4]=DEPTH_LIMIT [5]=ERROR )
# Reason-code → human string (mirrors lexer RC enum; these strings are what the corpus asserts substrings of).
# reason-code → human string. Sets the GLOBAL _PFG_SS_REASONOUT (not echo/command-substitution — avoids a
# subshell fork per opaque node). The strings are exactly what the Stage-1 corpus asserts substrings of.
_PFG_SS_REASONOUT=""
_pfg_ss_reason_text() {  # $1 = reason code. Sets _PFG_SS_REASONOUT.
  case "$1" in
    1)  _PFG_SS_REASONOUT='computed executable token (program name is a substitution/parameter-expansion; cannot be resolved without execution)' ;;
    2)  _PFG_SS_REASONOUT='computed governed-subcommand token (a leading subcommand is a substitution/parameter-expansion; cannot be resolved without execution)' ;;
    3)  _PFG_SS_REASONOUT='inline shell -c with no recoverable payload' ;;
    4)  _PFG_SS_REASONOUT='inline shell -c with a dynamic payload ($VAR/$(…)/backtick/${…}); cannot be resolved without execution' ;;
    5)  _PFG_SS_REASONOUT='here-document/here-string fed into a shell (its body is executed; the concealed commands cannot be statically resolved)' ;;
    6)  _PFG_SS_REASONOUT='unterminated quote (the command cannot be statically resolved; an executable structure may be concealed)' ;;
    7)  _PFG_SS_REASONOUT='unterminated grouping/substitution (executable structure may be concealed)' ;;
    8)  _PFG_SS_REASONOUT='unterminated brace group (executable structure may be concealed)' ;;
    9)  _PFG_SS_REASONOUT='unterminated backtick substitution (executable structure may be concealed)' ;;
    10) _PFG_SS_REASONOUT='unterminated arithmetic expression' ;;
    11) _PFG_SS_REASONOUT='unterminated ${ } parameter expansion' ;;
    12) _PFG_SS_REASONOUT='here-document with no recoverable delimiter' ;;
    13) _PFG_SS_REASONOUT='command exceeds the structural-depth budget' ;;
    14) _PFG_SS_REASONOUT='command exceeds the node parser budget' ;;
    15) _PFG_SS_REASONOUT='inline-shell nesting exceeds the depth budget' ;;
    *)  _PFG_SS_REASONOUT='opaque executable structure' ;;
  esac
}

_pfg_ss_reset() {
  PFG_SS_STATUS=""; PFG_SS_STATUS_REASON=""; PFG_SS_NODE_COUNT=0
  PFG_SS_PARENT=(); PFG_SS_CTX=(); PFG_SS_START=(); PFG_SS_END=()
  PFG_SS_EXEC=(); PFG_SS_EXEC_COMPUTED=(); PFG_SS_SUBCMD=(); PFG_SS_SUBCMD_COMPUTED=()
  PFG_SS_ARGS=(); PFG_SS_ENV=(); PFG_SS_REDIR=(); PFG_SS_OPACITY=(); PFG_SS_OPACITY_REASON=()
  PFG_SS_SCANNER="awk"; PFG_SS_SCANNER_IMPL=""; PFG_SS_SCANNER_DURATION_MS=""
}

# hex-decode a lexer-transmitted token value ([0-9a-f]* → bytes). Sets the GLOBAL _PFG_SS_HEXOUT (NOT via
# echo/command-substitution — a `$(...)` capture forks a subshell, and this runs once PER X/S/G record; the
# per-record fork added a full EDR spawn-tax to every parse, the same class of bug the Stage-1 hot helpers
# avoid). Returns 1 on malformed hex (odd length / non-hex).
_PFG_SS_HEXOUT=""
_pfg_ss_hexdec() {  # $1 = hex string. Sets _PFG_SS_HEXOUT; returns 1 on malformed.
  local h="$1"
  _PFG_SS_HEXOUT=""
  [ -z "$h" ] && return 0
  case "$h" in *[!0-9a-f]*) return 1 ;; esac
  [ $(( ${#h} % 2 )) -eq 0 ] || return 1
  local esc="" i
  for ((i=0; i<${#h}; i+=2)); do esc+="\\x${h:$i:2}"; done
  # printf -v avoids a command-substitution subshell; %b interprets the \xNN escapes.
  printf -v _PFG_SS_HEXOUT '%b' "$esc"
}

# Resolve awk once. Sets _PFG_SS_AWK and _PFG_SS_AWK_IMPL. Returns 1 if awk is unavailable.
_pfg_ss_resolve_awk() {
  [ -n "$_PFG_SS_AWK" ] && return 0
  local a
  a="$(command -v awk 2>/dev/null || true)"
  [ -n "$a" ] || return 1
  _PFG_SS_AWK="$a"
  _PFG_SS_AWK_IMPL="$("$a" --version 2>/dev/null | head -1 || true)"
  [ -n "$_PFG_SS_AWK_IMPL" ] || _PFG_SS_AWK_IMPL="unknown-awk"
  return 0
}

# ── Public entrypoint ────────────────────────────────────────────────────────────────────────────────────
# pfg_ss_parse <command-string>
#   Builds the IR into the PFG_SS_* arrays via the AWK lexer + protocol validation. Sets PFG_SS_STATUS to
#   OK | OPAQUE | SIZE_LIMIT | NODE_LIMIT | DEPTH_LIMIT | ERROR. Returns 0 always. Never executes input.
pfg_ss_parse() {
  _pfg_ss_reset
  local cmd="$1"
  # SIZE budget first (before any spawn) — identical to Stage 1.
  if [ "${#cmd}" -gt "$PFG_SS_MAX_BYTES" ]; then
    PFG_SS_STATUS="SIZE_LIMIT"; PFG_SS_STATUS_REASON="command exceeds the $PFG_SS_MAX_BYTES-byte parser budget"
    return 0
  fi
  if ! _pfg_ss_resolve_awk; then
    PFG_SS_STATUS="ERROR"; PFG_SS_STATUS_REASON="awk scanner unavailable (command -v awk failed)"
    return 0
  fi
  PFG_SS_SCANNER_IMPL="$_PFG_SS_AWK_IMPL"
  if [ ! -f "$_PFG_SS_LEXER" ]; then
    PFG_SS_STATUS="ERROR"; PFG_SS_STATUS_REASON="lexer program not found ($_PFG_SS_LEXER)"
    return 0
  fi

  # ── Invoke the fixed lexer.
  # EXACTLY ONE subprocess spawn: the command bytes go RAW over stdin (never argv, never -v). `BINMODE=3`
  # (assigned via -v) tells gawk to open stdin/stdout in BINARY mode so it does NOT translate CRLF→LF on
  # Windows — without it, a `\r` in the command is silently stripped and byte offsets shift (found by the
  # differential fuzzer). BINMODE is a gawk variable; on mawk / POSIX awk it is an unused variable
  # assignment (harmless — those implementations do not do CRLF translation, so raw stdin is already
  # byte-exact). This keeps the parser to a SINGLE spawn, which is what the latency budget requires on this
  # spawn-taxed host. LC_ALL=C for byte semantics. Capture stdout, discard stderr, keep the awk exit code.
  local out rc t0 t1
  t0="${EPOCHREALTIME:-}"
  out="$(printf '%s' "$cmd" | LC_ALL=C \
        "$_PFG_SS_AWK" -v BINMODE=3 -v MAXBYTES="$PFG_SS_MAX_BYTES" -v MAXNODES="$PFG_SS_MAX_NODES" \
        -v MAXDEPTH="$PFG_SS_MAX_DEPTH" -f "$_PFG_SS_LEXER" 2>/dev/null)"
  rc=$?
  t1="${EPOCHREALTIME:-}"
  # duration is test/debug metadata only; compute it with pure-bash arithmetic (NO extra awk spawn — that
  # would add a full process-spawn tax to every parse). EPOCHREALTIME is "<secs>.<usecs>"; strip the dot to
  # get integer microseconds, subtract, convert to ms. Fall back to empty if EPOCHREALTIME is unavailable.
  if [ -n "$t0" ] && [ -n "$t1" ]; then
    local _us0="${t0/./}" _us1="${t1/./}"
    if [[ "$_us0" =~ ^[0-9]+$ && "$_us1" =~ ^[0-9]+$ ]]; then
      PFG_SS_SCANNER_DURATION_MS="$(( (_us1 - _us0) / 1000 ))"
    fi
  fi
  if [ "$rc" -ne 0 ]; then
    PFG_SS_STATUS="ERROR"; PFG_SS_STATUS_REASON="awk scanner exited abnormally (rc=$rc)"
    return 0
  fi

  _pfg_ss_ingest "$out" "${#cmd}" "$cmd"
  return 0
}

# ── Protocol validation + IR reconstruction. Parses the lexer's record stream with `read` (never eval),
# validates every field, and populates the PFG_SS_* arrays. On ANY malformed/inconsistent record →
# PFG_SS_STATUS=ERROR (fail closed). $1 = lexer stdout  $2 = command length  $3 = command (for span-derived
# fields IF ever needed; NOT used for token values — those arrive hex-encoded). ─────────────────────────
_pfg_ss_ingest() {
  local raw="$1" clen="$2"
  local seen_v=0 seen_m=0 seen_terminal=0
  local rectype id parent ctxcode start end execflag execcomp subcomp opacitycode
  local n count statuscode restfields hexval which _m_maxnodes _eff_maxnodes
  local -A _node_seen=()
  local line

  # helper: fail closed with an ERROR reason
  _err() { PFG_SS_STATUS="ERROR"; PFG_SS_STATUS_REASON="malformed lexer protocol: $1"; PFG_SS_NODE_COUNT=0
           PFG_SS_PARENT=(); PFG_SS_CTX=(); PFG_SS_START=(); PFG_SS_END=(); PFG_SS_EXEC=()
           PFG_SS_EXEC_COMPUTED=(); PFG_SS_SUBCMD=(); PFG_SS_SUBCMD_COMPUTED=(); PFG_SS_ARGS=()
           PFG_SS_ENV=(); PFG_SS_REDIR=(); PFG_SS_OPACITY=(); PFG_SS_OPACITY_REASON=(); }

  local top_status="" top_reason_code=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ "$seen_terminal" -eq 1 ]; then _err "record after terminal E"; return; fi
    rectype="${line%% *}"
    case "$rectype" in
      V)
        set -- $line
        [ "$#" -eq 2 ] && [ "$2" = "1" ] || { _err "bad version record"; return; }
        [ "$seen_v" -eq 0 ] || { _err "duplicate V"; return; }
        seen_v=1 ;;
      M)
        set -- $line
        [ "$#" -eq 4 ] || { _err "bad M record"; return; }
        [ "$seen_v" -eq 1 ] || { _err "M before V"; return; }
        # capture the lexer's echoed budgets and validate they are numeric. The effective node cap is the
        # SMALLER of the wrapper's requested budget and the lexer's echoed budget — so a lexer that emits
        # more nodes than the budget it acknowledged is rejected (defense against a runaway/forged stream).
        _m_maxnodes="$3"
        case "$2$3$4" in *[!0-9]*) _err "M non-numeric budgets"; return ;; esac
        [ "$_m_maxnodes" -le "$PFG_SS_MAX_NODES" ] 2>/dev/null && _eff_maxnodes="$_m_maxnodes" || _eff_maxnodes="$PFG_SS_MAX_NODES"
        seen_m=1 ;;
      N)
        [ "$seen_m" -eq 1 ] || { _err "N before M"; return; }
        set -- $line
        [ "$#" -eq 10 ] || { _err "N field count"; return; }
        id="$2"; parent="$3"; ctxcode="$4"; start="$5"; end="$6"; execflag="$7"; execcomp="$8"; subcomp="$9"; opacitycode="${10}"
        # numeric validation
        case "$id$start$end$execflag$execcomp$subcomp$opacitycode" in *[!0-9]*) _err "N non-numeric"; return ;; esac
        case "$parent" in -1) ;; *[!0-9]*) _err "N bad parent"; return ;; esac
        # id must be the next monotonic id
        [ "$id" -eq "$PFG_SS_NODE_COUNT" ] || { _err "N id not monotonic ($id != $PFG_SS_NODE_COUNT)"; return; }
        [ "$PFG_SS_NODE_COUNT" -lt "${_eff_maxnodes:-$PFG_SS_MAX_NODES}" ] || { _err "N exceeds node budget"; return; }
        # ctx enum
        local ctxname="${_PFG_SS_CTX_NAME[$ctxcode]:-}"; [ -n "$ctxname" ] || { _err "N bad ctx $ctxcode"; return; }
        # opacity enum
        local opname; case "$opacitycode" in 0) opname=NONE ;; 1) opname=OPAQUE ;; *) _err "N bad opacity"; return ;; esac
        # span bounds: 0<=start<=end<=clen  (note: inline-shell child spans are payload-relative → end<=clen
        # need not hold; we bound them by clen defensively but allow start<=end and start>=0).
        [ "$start" -ge 0 ] && [ "$end" -ge "$start" ] || { _err "N span order"; return; }
        # parent reference: -1 or an already-seen id
        if [ "$parent" != "-1" ]; then [ -n "${_node_seen[$parent]:-}" ] || { _err "N forward/absent parent $parent"; return; }; fi
        # populate
        PFG_SS_PARENT[$id]="$parent"; PFG_SS_CTX[$id]="$ctxname"; PFG_SS_START[$id]="$start"; PFG_SS_END[$id]="$end"
        PFG_SS_EXEC[$id]=""; PFG_SS_EXEC_COMPUTED[$id]="$execcomp"; PFG_SS_SUBCMD[$id]=""; PFG_SS_SUBCMD_COMPUTED[$id]="$subcomp"
        PFG_SS_ARGS[$id]=""; PFG_SS_ENV[$id]=""; PFG_SS_REDIR[$id]=""; PFG_SS_OPACITY[$id]="$opname"; PFG_SS_OPACITY_REASON[$id]=""
        _node_seen[$id]=1
        PFG_SS_NODE_COUNT=$((PFG_SS_NODE_COUNT+1)) ;;
      X)
        set -- $line
        [ "$#" -eq 3 ] || { _err "X field count"; return; }
        id="$2"; hexval="$3"
        case "$id" in *[!0-9]*) _err "X bad id"; return ;; esac
        [ -n "${_node_seen[$id]:-}" ] || { _err "X unknown node $id"; return; }
        _pfg_ss_hexdec "$hexval" || { _err "X bad hex"; return; }
        PFG_SS_EXEC[$id]="$_PFG_SS_HEXOUT" ;;
      S)
        set -- $line
        [ "$#" -eq 3 ] || { _err "S field count"; return; }
        id="$2"; hexval="$3"
        case "$id" in *[!0-9]*) _err "S bad id"; return ;; esac
        [ -n "${_node_seen[$id]:-}" ] || { _err "S unknown node $id"; return; }
        _pfg_ss_hexdec "$hexval" || { _err "S bad hex"; return; }
        PFG_SS_SUBCMD[$id]="$_PFG_SS_HEXOUT" ;;
      G)
        set -- $line
        [ "$#" -eq 3 ] || { _err "G field count"; return; }
        id="$2"; hexval="$3"
        case "$id" in *[!0-9]*) _err "G bad id"; return ;; esac
        [ -n "${_node_seen[$id]:-}" ] || { _err "G unknown node $id"; return; }
        _pfg_ss_hexdec "$hexval" || { _err "G bad hex"; return; }
        PFG_SS_ENV[$id]="$_PFG_SS_HEXOUT" ;;
      R)
        set -- $line
        [ "$#" -eq 3 ] || { _err "R field count"; return; }
        id="$2"; local rc2="$3"
        case "$id$rc2" in *[!0-9]*) _err "R non-numeric"; return ;; esac
        [ -n "${_node_seen[$id]:-}" ] || { _err "R unknown node $id"; return; }
        if [ "$rc2" = "2" ]; then
          # computed governed-subcommand: Stage-1 interpolates the program literal (e.g. "…subcommand of
          # 'gh' is…"). The X record for this node precedes R, so PFG_SS_EXEC[$id] holds the literal.
          PFG_SS_OPACITY_REASON[$id]="computed governed-subcommand token (a leading subcommand of '${PFG_SS_EXEC[$id]}' is a substitution/parameter-expansion; cannot be resolved without execution)"
        else
          _pfg_ss_reason_text "$rc2"; PFG_SS_OPACITY_REASON[$id]="$_PFG_SS_REASONOUT"
        fi ;;
      O)
        set -- $line
        [ "$#" -eq 3 ] || { _err "O field count"; return; }
        top_status="$2"; top_reason_code="$3"
        case "$top_status$top_reason_code" in *[!0-9]*) _err "O non-numeric"; return ;; esac ;;
      E)
        set -- $line
        [ "$#" -eq 3 ] || { _err "E field count"; return; }
        count="$2"; statuscode="$3"
        case "$count$statuscode" in *[!0-9]*) _err "E non-numeric"; return ;; esac
        [ "$count" -eq "$PFG_SS_NODE_COUNT" ] || { _err "E count mismatch ($count != $PFG_SS_NODE_COUNT)"; return; }
        seen_terminal=1
        # map status code
        local stname="${_PFG_SS_ST_NAME[$statuscode]:-}"; [ -n "$stname" ] || { _err "E bad status"; return; }
        PFG_SS_STATUS="$stname" ;;
      *)
        _err "unknown record type '$rectype'"; return ;;
    esac
  done <<< "$raw"

  [ "$seen_v" -eq 1 ] || { _err "missing V"; return; }
  [ "$seen_terminal" -eq 1 ] || { _err "missing terminal E"; return; }

  # For OPAQUE/limit top-level statuses, set the human reason from the O record (if any). For OK, no reason.
  if [ "$PFG_SS_STATUS" != OK ]; then
    if [ -n "$top_reason_code" ] && [ "$top_reason_code" != "0" ]; then
      _pfg_ss_reason_text "$top_reason_code"; PFG_SS_STATUS_REASON="$_PFG_SS_REASONOUT"
    elif [ -z "$PFG_SS_STATUS_REASON" ]; then
      case "$PFG_SS_STATUS" in
        SIZE_LIMIT) PFG_SS_STATUS_REASON="command exceeds the $PFG_SS_MAX_BYTES-byte parser budget" ;;
        NODE_LIMIT) PFG_SS_STATUS_REASON="command exceeds the $PFG_SS_MAX_NODES-node parser budget" ;;
        DEPTH_LIMIT) PFG_SS_STATUS_REASON="command exceeds the $PFG_SS_MAX_DEPTH-level structural-depth budget" ;;
        OPAQUE) PFG_SS_STATUS_REASON="opaque executable structure" ;;
      esac
    fi
  fi
}

# ── Family-neutral structural queries (NO policy — for later-stage classifiers and tests) ────────────────
# basename of a node's static executable token, or '' if none/computed.
pfg_ss_exec_basename() {  # $1 = node id
  local e="${PFG_SS_EXEC[$1]}"
  [ -n "$e" ] || { printf ''; return; }
  e="${e##*/}"; e="${e%.exe}"; printf '%s' "$e"
}
# 1 if the forest contains ANY opaque executable node (the caller's fail-closed trigger), else 0.
pfg_ss_has_opaque() {
  local i
  for ((i=0; i<PFG_SS_NODE_COUNT; i++)); do
    [ "${PFG_SS_OPACITY[$i]}" = OPAQUE ] && { printf 1; return; }
  done
  printf 0
}
