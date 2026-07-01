#!/usr/bin/env bash
# lib/shell-structure.sh — BOUNDED, QUOTE-AWARE, BUILTINS-ONLY SHELL COMMAND-POSITION PARSER.
#
# STATUS (Stage 1 of the shared-parser redesign): this library is PARSER-ONLY and UNWIRED. Nothing in the
# router or engine policy path sources or calls it yet; sourcing it defines functions and changes NO
# enforcement behavior. It exists so that a later stage can move BOTH `git push` and `gh pr` detection onto
# ONE structural representation (closing the command-position bypass class proven in
# .release-audit/mission2/ci/missionG/SHELL-STRUCTURE-PARSER-DESIGN.md) instead of the divergent
# regex-anchor (gh-pr) vs sed-segmenter (git-push) front-ends that exist today.
#
# WHAT IT DOES: given one raw Bash command string, it produces a BOUNDED FOREST of command-position nodes
# (the IR), identifying every statically-recoverable executable command position and every AMBIGUOUS
# executable position (computed program/subcommand token, malformed/unterminated structure, here-doc into a
# shell, budget exhaustion) which it marks OPAQUE. It is FAMILY-NEUTRAL: it exposes structural facts
# (executable basename, leading argument tokens, computed-token flags, child contexts) but implements NO
# git-push / gh-pr / evidence / forbidden / canonical / --admin / confirm POLICY — those stay in the engine.
#
# HARD SAFETY CONTRACT (every one of these is a security property, not a nicety):
#   • Bash BUILTINS ONLY. No sed / grep / awk / python / node / external parser. No subprocess at all.
#   • NEVER executes, eval's, sources, or `bash`-parses the input. NEVER interpolates a variable from the
#     input. NEVER expands a command substitution. NEVER touches the filesystem, git config, or network.
#   • Quote-, escape-, and comment-aware single-pass character scan; recursion is depth-bounded.
#   • Malformed / unterminated / ambiguous-executable structure → OPAQUE (the caller fails CLOSED).
#   • Budget exhaustion (size / nodes / depth) → an explicit LIMIT result, NEVER a truncated "success".
#
# OUTPUT MODEL (Bash arrays — no JSON, no external serializer in the production parser; a test adapter
# serializes for assertions). After a successful or opaque parse, the node forest is in parallel arrays
# indexed by node id (0-based), and PFG_SS_STATUS holds the top-level result:
#   PFG_SS_STATUS         = OK | OPAQUE | SIZE_LIMIT | NODE_LIMIT | DEPTH_LIMIT | ERROR
#   PFG_SS_STATUS_REASON  = human reason for OPAQUE/limit/ERROR (for the caller's fail-closed diagnostic)
#   PFG_SS_NODE_COUNT     = number of nodes emitted
#   per-node parallel arrays (index = node_id):
#     PFG_SS_PARENT[i]        parent node id, or -1 for a root
#     PFG_SS_CTX[i]           execution context (SIMPLE/LIST/PIPELINE/SUBSHELL/BRACE_GROUP/…)
#     PFG_SS_START[i]         source start offset (byte index into the original command)
#     PFG_SS_END[i]           source end offset (exclusive)
#     PFG_SS_EXEC[i]          statically-known executable token (basename-resolvable), or '' if none/computed
#     PFG_SS_EXEC_COMPUTED[i] 1 if the executable token is computed (substitution/param-expansion/concat)
#     PFG_SS_SUBCMD[i]        space-joined leading argument tokens that are STATICALLY known (e.g. "pr merge")
#     PFG_SS_SUBCMD_COMPUTED[i] 1 if a leading (governed-subcommand-position) token is computed
#     PFG_SS_ARGS[i]          space-joined remaining statically-known argument tokens (diagnostic; may elide)
#     PFG_SS_ENV[i]           space-joined VAR=val environment-assignment prefixes
#     PFG_SS_REDIR[i]         space-joined redirection operators/targets seen (diagnostic)
#     PFG_SS_OPACITY[i]       NONE | OPAQUE
#     PFG_SS_OPACITY_REASON[i] reason string when OPAQUE
#
# A node is emitted for every COMMAND POSITION (a place where, when the surrounding command runs, a program
# is invoked). Literal text (single-quoted strings, comments, here-doc DATA, arithmetic, quoted mentions)
# emits NO node. An ambiguous executable position (computed program/subcommand, unterminated/ malformed
# structure that could conceal a command, here-doc fed to a shell) emits an OPAQUE node.
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

# Internal scan state.
_PFG_SS_S=""          # the command string under scan
_PFG_SS_N=0           # length
_PFG_SS_ABORT=""      # set to a LIMIT/ERROR status to abort the whole parse

_pfg_ss_reset() {
  PFG_SS_STATUS=""; PFG_SS_STATUS_REASON=""; PFG_SS_NODE_COUNT=0
  PFG_SS_PARENT=(); PFG_SS_CTX=(); PFG_SS_START=(); PFG_SS_END=()
  PFG_SS_EXEC=(); PFG_SS_EXEC_COMPUTED=(); PFG_SS_SUBCMD=(); PFG_SS_SUBCMD_COMPUTED=()
  PFG_SS_ARGS=(); PFG_SS_ENV=(); PFG_SS_REDIR=(); PFG_SS_OPACITY=(); PFG_SS_OPACITY_REASON=()
  _PFG_SS_ABORT=""
}

# Emit a node. Sets the new node id in the GLOBAL _PFG_SS_LAST_ID (NOT via echo/command-substitution — a
# `$(...)` capture would run this in a SUBSHELL and silently discard the array writes, a fatal correctness
# bug for an array-based IR). Enforces the NODE budget: on overflow it sets the abort flag without emitting.
_PFG_SS_LAST_ID=-1
_pfg_ss_emit() {  # $1 parent  $2 ctx  $3 start  $4 end  $5 exec  $6 exec_computed  $7 subcmd  $8 subcmd_computed  $9 env  $10 opacity  $11 reason
  if [ "$PFG_SS_NODE_COUNT" -ge "$PFG_SS_MAX_NODES" ]; then
    _PFG_SS_ABORT="NODE_LIMIT"; PFG_SS_STATUS_REASON="command exceeds the $PFG_SS_MAX_NODES-node parser budget"
    _PFG_SS_LAST_ID=-1
    return 0
  fi
  local i="$PFG_SS_NODE_COUNT"
  PFG_SS_PARENT[i]="$1"; PFG_SS_CTX[i]="$2"; PFG_SS_START[i]="$3"; PFG_SS_END[i]="$4"
  PFG_SS_EXEC[i]="$5"; PFG_SS_EXEC_COMPUTED[i]="$6"; PFG_SS_SUBCMD[i]="$7"; PFG_SS_SUBCMD_COMPUTED[i]="$8"
  PFG_SS_ENV[i]="$9"; PFG_SS_ARGS[i]=""; PFG_SS_REDIR[i]=""
  PFG_SS_OPACITY[i]="${10}"; PFG_SS_OPACITY_REASON[i]="${11}"
  PFG_SS_NODE_COUNT=$((PFG_SS_NODE_COUNT+1))
  _PFG_SS_LAST_ID="$i"
}

# ── Token classification (does a token contain a LIVE substitution / parameter expansion → computed?) ────
# A token is COMPUTED iff (outside single quotes) it contains $(, `, or ${ / $NAME — i.e. its value cannot
# be known without expansion. We DO NOT expand it. Single-quoted spans inside the token are literal.
# This is a per-token check used only AFTER word-splitting has produced whole tokens; it is conservative
# (any doubt → computed) and never executes anything.
# PERFORMANCE: these hot helpers set a GLOBAL result var instead of echoing — they are called once per
# token (and the keyword peek once per word-start char), so a `$(...)` command-substitution fork per call
# made even a 50-char command take seconds (measured). No fork: O(n) scan, sub-10ms short commands.
_PFG_SS_R_COMPUTED=0   # set by _pfg_ss_token_is_computed: 1 = computed, 0 = static
_pfg_ss_token_is_computed() {  # $1 = raw token. Sets _PFG_SS_R_COMPUTED.
  local t="$1" i=0 n=${#1} c nx n2 st=NORMAL
  _PFG_SS_R_COMPUTED=0
  while [ "$i" -lt "$n" ]; do
    c="${t:$i:1}"; nx="${t:$((i+1)):1}"; n2="${t:$((i+2)):1}"
    if [ "$st" = NORMAL ]; then
      case "$c" in
        '\') i=$((i+2)); continue ;;                 # escaped char → literal
        "'") st=SQ; i=$((i+1)); continue ;;
        '"') st=DQ; i=$((i+1)); continue ;;
        '`') _PFG_SS_R_COMPUTED=1; return ;;          # backtick command substitution in a token → computed
        '$') case "$nx" in
               '(') [ "$n2" = '(' ] || { _PFG_SS_R_COMPUTED=1; return; } ;;   # $( → computed; $(( arithmetic → value
               '{') _PFG_SS_R_COMPUTED=1; return ;;                           # ${...} parameter expansion → computed
               [A-Za-z_]) _PFG_SS_R_COMPUTED=1; return ;;                     # $NAME variable → computed
             esac ;;
      esac
    elif [ "$st" = SQ ]; then
      case "$c" in "'") st=NORMAL ;; esac
    elif [ "$st" = DQ ]; then
      case "$c" in
        '\') i=$((i+2)); continue ;;
        '"') st=NORMAL ;;
        '`') _PFG_SS_R_COMPUTED=1; return ;;
        '$') case "$nx" in
               '(') [ "$n2" = '(' ] || { _PFG_SS_R_COMPUTED=1; return; } ;;
               '{') _PFG_SS_R_COMPUTED=1; return ;;
               [A-Za-z_]) _PFG_SS_R_COMPUTED=1; return ;;
             esac ;;
      esac
    fi
    i=$((i+1))
  done
}
# Is this STATIC program basename one whose leading-argument (subcommand) position is structurally
# significant for a governed family? (gh, git — Phase-6-allowed family-neutral basename facts; NOT policy.)
# A computed token in the subcommand position of such a program is opaque; for any other program a computed
# later argument is an ordinary value and must not false-block (e.g. `echo "$(date)"`).
_pfg_ss_subcmd_governed_basename() {  # $1 = static (unquoted) program token. return 0 if governed-subcommand program.
  local b="${1##*/}"; b="${b%.exe}"
  case "$b" in gh|git) return 0 ;; *) return 1 ;; esac
}

# Strip ONE level of surrounding quotes from a statically-literal token, for basename matching. Only used
# when the token is NOT computed. `'gh'` → gh, `"git"` → git, gh → gh. Conservative: if mixed/!static,
# the computed check already caught it. Builtins only.
_PFG_SS_R_LIT=""   # set by _pfg_ss_unquote: the literal (unquoted) value
_pfg_ss_unquote() {  # $1 = token (known non-computed). Sets _PFG_SS_R_LIT.
  local t="$1" out="" i=0 n=${#1} c st=NORMAL
  while [ "$i" -lt "$n" ]; do
    c="${t:$i:1}"
    if [ "$st" = NORMAL ]; then
      case "$c" in
        '\') out+="${t:$((i+1)):1}"; i=$((i+2)); continue ;;
        "'") st=SQ; i=$((i+1)); continue ;;
        '"') st=DQ; i=$((i+1)); continue ;;
        *) out+="$c" ;;
      esac
    elif [ "$st" = SQ ]; then
      case "$c" in "'") st=NORMAL ;; *) out+="$c" ;; esac
    elif [ "$st" = DQ ]; then
      case "$c" in '\') out+="${t:$((i+1)):1}"; i=$((i+2)); continue ;; '"') st=NORMAL ;; *) out+="$c" ;; esac
    fi
    i=$((i+1))
  done
  _PFG_SS_R_LIT="$out"
}

# QUOTE-AWARE TOKENIZER. Splits a simple-command text into tokens on UNQUOTED whitespace, keeping a
# single- or double-quoted span (and its enclosed whitespace) as part of ONE token, and keeping a $(…) /
# `…` / ${…} substitution span intact within a token. Builtins only; NEVER expands/executes. Sets the
# positional parameters of the CALLER is not possible across functions, so it fills the global array
# _PFG_SS_TOK[]. (We cannot use `set -- $raw`: that splits on whitespace INSIDE quotes, which fatally
# truncated an inline `-c 'gh pr merge …'` payload to the single token `'gh`.)
_PFG_SS_TOK=()
_pfg_ss_tokenize() {  # $1 = simple-command text. Fills _PFG_SS_TOK[].
  local s="$1" n=${#1} i=0 c nx cur="" have=0 st=NORMAL depthp=0
  _PFG_SS_TOK=()
  while [ "$i" -lt "$n" ]; do
    c="${s:$i:1}"; nx="${s:$((i+1)):1}"
    if [ "$st" = NORMAL ]; then
      case "$c" in
        ' '|$'\t'|$'\n')
          if [ "$have" = 1 ]; then _PFG_SS_TOK+=("$cur"); cur=""; have=0; fi
          i=$((i+1)); continue ;;
        '\') cur+="$c$nx"; have=1; i=$((i+2)); continue ;;
        "'") cur+="$c"; have=1; st=SQ; i=$((i+1)); continue ;;
        '"') cur+="$c"; have=1; st=DQ; i=$((i+1)); continue ;;
        '`') cur+="$c"; have=1; st=BT; i=$((i+1)); continue ;;
        '$')
          cur+="$c"; have=1
          if [ "$nx" = '(' ]; then cur+="$nx"; i=$((i+2)); st=CS; depthp=1; continue; fi
          if [ "$nx" = '{' ]; then cur+="$nx"; i=$((i+2)); st=PE; depthp=1; continue; fi
          i=$((i+1)); continue ;;
        *) cur+="$c"; have=1; i=$((i+1)); continue ;;
      esac
    elif [ "$st" = SQ ]; then
      cur+="$c"; case "$c" in "'") st=NORMAL ;; esac; i=$((i+1)); continue
    elif [ "$st" = DQ ]; then
      case "$c" in '\') cur+="$c$nx"; i=$((i+2)); continue ;; '"') cur+="$c"; st=NORMAL; i=$((i+1)); continue ;; *) cur+="$c"; i=$((i+1)); continue ;; esac
    elif [ "$st" = BT ]; then
      case "$c" in '\') cur+="$c$nx"; i=$((i+2)); continue ;; '`') cur+="$c"; st=NORMAL; i=$((i+1)); continue ;; *) cur+="$c"; i=$((i+1)); continue ;; esac
    elif [ "$st" = CS ]; then   # inside $( … ) — track nested ( )
      cur+="$c"; case "$c" in '(') depthp=$((depthp+1)) ;; ')') depthp=$((depthp-1)); [ "$depthp" -eq 0 ] && st=NORMAL ;; esac; i=$((i+1)); continue
    elif [ "$st" = PE ]; then   # inside ${ … } — track nested { }
      cur+="$c"; case "$c" in '{') depthp=$((depthp+1)) ;; '}') depthp=$((depthp-1)); [ "$depthp" -eq 0 ] && st=NORMAL ;; esac; i=$((i+1)); continue
    fi
  done
  [ "$have" = 1 ] && _PFG_SS_TOK+=("$cur")
}

# ── Simple-command analyzer: given the raw text of ONE simple command (no unquoted separators/operators),
# peel env-assignments + command/exec/env/builtin prefixes, then classify the program token + leading
# argument tokens. Emits ONE node under $parent in context $ctx. Builtins only; quote-aware tokenization.
_pfg_ss_analyze_simple() {  # $1 parent  $2 ctx  $3 start  $4 end  $5 raw-text  $6 depth(optional)
  local parent="$1" ctx="$2" start="$3" end="$4" raw="$5" depth="${6:-0}"
  # quote-aware tokenize (keeps quoted spans + substitutions intact); then drive a positional vector.
  _pfg_ss_tokenize "$raw"
  set -- "${_PFG_SS_TOK[@]}"
  local env_pfx="" prog="" prog_computed=0
  # Peel leading env-assignments (NAME=val, NAME not computed) and command/exec/env/builtin prefixes.
  while [ "$#" -gt 0 ]; do
    case "$1" in
      [A-Za-z_]*=*)
        # an env-assignment prefix ONLY if the NAME part is a clean identifier (else it's an arg like a=b passed to echo)
        local nm="${1%%=*}"
        case "$nm" in *[!A-Za-z0-9_]*) break ;; esac
        env_pfx="${env_pfx:+$env_pfx }$1"; shift; continue ;;
      command|builtin|exec) shift; continue ;;
      env)
        shift
        # env [-i] [-u NAME] [VAR=val]... cmd : peel its own option/assignment run.
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -i|--ignore-environment) shift ;;
            -u) shift; [ "$#" -gt 0 ] && shift ;;
            -*) shift ;;
            [A-Za-z_]*=*) local enm="${1%%=*}"; case "$enm" in *[!A-Za-z0-9_]*) break ;; esac; env_pfx="${env_pfx:+$env_pfx }$1"; shift ;;
            *) break ;;
          esac
        done
        continue ;;
      *) break ;;
    esac
  done
  if [ "$#" -eq 0 ]; then
    # env-only / assignment-only (e.g. `FOO=bar`) — a command position with no program. Not governed; emit
    # a SIMPLE node with empty exec so the forest is complete, but it is benign (no executable).
    _pfg_ss_emit "$parent" "$ctx" "$start" "$end" "" 0 "" 0 "$env_pfx" NONE "" >/dev/null
    return
  fi
  prog="$1"; shift
  _pfg_ss_token_is_computed "$prog"
  if [ "$_PFG_SS_R_COMPUTED" = 1 ]; then
    # computed program token → OPAQUE executable (fixed policy 1). Do NOT expand.
    _pfg_ss_emit "$parent" "$ctx" "$start" "$end" "" 1 "" 0 "$env_pfx" OPAQUE "computed executable token (program name is a substitution/parameter-expansion; cannot be resolved without execution)"
    return
  fi
  _pfg_ss_unquote "$prog"; local prog_lit="$_PFG_SS_R_LIT"
  # ── INLINE SHELL: `bash|sh|dash|zsh [opts] -c <payload>` — the payload is a NEW command context. Recover
  # a statically-literal payload and recurse it (INLINE_SHELL); a dynamic/non-literal payload → OPAQUE. This
  # mirrors the engine's existing inline-`-c` posture but produces IR nodes instead of an immediate verdict.
  local _base="${prog_lit##*/}"; _base="${_base%.exe}"
  case "$_base" in
    bash|sh|dash|zsh|ksh)
      # scan the remaining tokens for a -c / --command flag and the following literal payload.
      local _found_c=0 _payload="" _payload_tok=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --command|-c) _found_c=1; shift; _payload_tok="${1:-}"; break ;;
          -*c) local _mid="${1#-}"; _mid="${_mid%c}"; case "$_mid" in *[!lixeufmnBHT]*) ;; *) _found_c=1; shift; _payload_tok="${1:-}"; break ;; esac; shift ;;
          -*) shift ;;
          *) break ;;   # a script-FILE positional, not inline -c → handled as a plain shell node below
        esac
      done
      if [ "$_found_c" = 1 ]; then
        if [ -z "$_payload_tok" ]; then
          _pfg_ss_emit "$parent" INLINE_SHELL "$start" "$end" "$_base" 0 "-c" 0 "$env_pfx" OPAQUE \
            "inline shell -c with no recoverable payload" >/dev/null
          return
        fi
        _pfg_ss_token_is_computed "$_payload_tok"
        if [ "$_PFG_SS_R_COMPUTED" = 1 ]; then
          _pfg_ss_emit "$parent" INLINE_SHELL "$start" "$end" "$_base" 0 "-c" 0 "$env_pfx" OPAQUE \
            "inline shell -c with a dynamic payload (\$VAR/\$(…)/backtick/\${…}); cannot be resolved without execution"
          return
        fi
        _pfg_ss_unquote "$_payload_tok"; _payload="$_PFG_SS_R_LIT"
        # emit the inline-shell node, then recurse its payload as a child command context (depth-bounded).
        _pfg_ss_emit "$parent" INLINE_SHELL "$start" "$end" "$_base" 0 "-c" 0 "$env_pfx" NONE ""
        local _iid="$_PFG_SS_LAST_ID"
        [ -n "$_PFG_SS_ABORT" ] && return
        if [ "$((depth+1))" -gt "$PFG_SS_MAX_DEPTH" ]; then
          _PFG_SS_ABORT="DEPTH_LIMIT"; PFG_SS_STATUS_REASON="inline-shell nesting exceeds the $PFG_SS_MAX_DEPTH-level depth budget"
          return
        fi
        # recurse the payload in its own sub-scan (it is a fresh command string). Save/restore the scan
        # globals so the inner parse over a DIFFERENT string does not corrupt the outer scan position.
        local _save_s="$_PFG_SS_S" _save_n="$_PFG_SS_N"
        _PFG_SS_S="$_payload"; _PFG_SS_N="${#_payload}"
        _pfg_ss_scan "$_iid" INLINE_SHELL 0 "${#_payload}" "$((depth+1))"
        _PFG_SS_S="$_save_s"; _PFG_SS_N="$_save_n"
        return
      fi
      ;;
  esac
  local subcmd="" subcmd_computed=0 opacity=NONE reason=""
  # Leading-argument (subcommand) analysis ONLY matters for a program whose subcommand position is
  # structurally governed (gh/git). For any other program, later arguments — including a `$(…)` value like
  # `echo "$(date)"` — are ordinary data and must NOT flag the node (that was the false-positive class).
  if _pfg_ss_subcmd_governed_basename "$prog_lit"; then
    local sub1="" sub2="" a1="$1" a2="$2"
    if [ -n "$a1" ]; then
      _pfg_ss_token_is_computed "$a1"
      if [ "$_PFG_SS_R_COMPUTED" = 1 ]; then subcmd_computed=1; else _pfg_ss_unquote "$a1"; sub1="$_PFG_SS_R_LIT"; fi
    fi
    if [ "$subcmd_computed" = 0 ] && [ -n "$a2" ]; then
      _pfg_ss_token_is_computed "$a2"
      if [ "$_PFG_SS_R_COMPUTED" = 1 ]; then subcmd_computed=1; else _pfg_ss_unquote "$a2"; sub2="$_PFG_SS_R_LIT"; fi
    fi
    subcmd="$sub1"; [ -n "$sub2" ] && subcmd="$sub1 $sub2"
    if [ "$subcmd_computed" = 1 ]; then
      # A computed token in the governed-subcommand position → OPAQUE (fixed policy 2). We still record the
      # static program basename so a family classifier can see "gh with a computed subcommand" and BLOCK.
      opacity=OPAQUE; reason="computed governed-subcommand token (a leading subcommand of '$prog_lit' is a substitution/parameter-expansion; cannot be resolved without execution)"
    fi
  fi
  _pfg_ss_emit "$parent" "$ctx" "$start" "$end" "$prog_lit" 0 "$subcmd" "$subcmd_computed" "$env_pfx" "$opacity" "$reason" >/dev/null
}

# ── Core recursive scanner. Scans S[lo..hi) in execution-context $ctx under parent node $parent, at depth
# $depth. Splits the region into simple-command POSITIONS on the separators/operators it can see at this
# level, recurses into grouping/substitution/control bodies, and analyzes each leaf simple command.
# Sets _PFG_SS_ABORT on a budget breach. Builtins only; single linear pass with bounded recursion.
_pfg_ss_scan() {  # $1 parent  $2 ctx  $3 lo  $4 hi  $5 depth
  [ -n "$_PFG_SS_ABORT" ] && return 0
  local parent="$1" ctx="$2" lo="$3" hi="$4" depth="$5"
  if [ "$depth" -gt "$PFG_SS_MAX_DEPTH" ]; then
    _PFG_SS_ABORT="DEPTH_LIMIT"; PFG_SS_STATUS_REASON="command exceeds the $PFG_SS_MAX_DEPTH-level structural-depth budget"
    return 0
  fi
  local i="$lo" c nx nn st=NORMAL
  local seg_start="$lo"       # start of the current simple-command position
  local cmdpos=1 wordstart=1  # cmdpos: a bare '(' / keyword here starts a structure; wordstart: '#' here is a comment
  local seg_has_content=0
  # Helper: finalize the current segment [seg_start, end) as a simple command if it has content.
  _pfg_ss_flush() {  # $1 = end offset
    local s="$seg_start" e="$1"
    # trim: skip if the slice is only whitespace
    local slice="${_PFG_SS_S:$s:$((e-s))}"
    case "$slice" in *[!$' \t\n']*) ;; *) seg_start="$e"; seg_has_content=0; return ;; esac
    _pfg_ss_analyze_simple "$parent" "$ctx" "$s" "$e" "$slice" "$depth"
    seg_start="$e"; seg_has_content=0
  }
  while [ "$i" -lt "$hi" ]; do
    [ -n "$_PFG_SS_ABORT" ] && return 0
    c="${_PFG_SS_S:$i:1}"; nx="${_PFG_SS_S:$((i+1)):1}"; nn="${_PFG_SS_S:$((i+2)):1}"
    if [ "$st" = NORMAL ]; then
      case "$c" in
        '\') i=$((i+2)); cmdpos=0; wordstart=0; seg_has_content=1; continue ;;
        "'") st=SQ; i=$((i+1)); cmdpos=0; wordstart=0; seg_has_content=1; continue ;;
        '"') st=DQ; i=$((i+1)); cmdpos=0; wordstart=0; seg_has_content=1; continue ;;
        '#') if [ "$wordstart" = 1 ]; then
               # comment to end of line — emit current segment, then skip the comment.
               _pfg_ss_flush "$i"
               while [ "$i" -lt "$hi" ] && [ "${_PFG_SS_S:$i:1}" != $'\n' ]; do i=$((i+1)); done
               seg_start="$i"; continue
             fi
             i=$((i+1)); cmdpos=0; wordstart=0; seg_has_content=1; continue ;;
        ';'|'&')
          # list separator (also `;;` in case, `&` background). Flush the segment, reset to command position.
          _pfg_ss_flush "$i"
          # consume a second ';' for ';;'
          if [ "$c" = ';' ] && [ "$nx" = ';' ]; then i=$((i+1)); fi
          i=$((i+1)); seg_start="$i"; cmdpos=1; wordstart=1; continue ;;
        '|')
          # pipeline (or ||). Each pipeline stage is its own command position.
          _pfg_ss_flush "$i"
          if [ "$nx" = '|' ]; then i=$((i+1)); fi    # || is a list-OR; same: next is a command position
          i=$((i+1)); seg_start="$i"; cmdpos=1; wordstart=1; continue ;;
        '&')  # handled with ';' above; this arm unreachable but kept for clarity
          i=$((i+1)); continue ;;
        '`')
          # backtick command substitution — live in NORMAL. Recurse its body as a CMDSUBST position.
          _pfg_ss_recurse_delim "$parent" BACKTICK_SUBSTITUTION "$i" '`' "$depth" || return 0
          i="$_PFG_SS_DELIM_END"; cmdpos=0; wordstart=0; seg_has_content=1; continue ;;
        '$')
          if [ "$nx" = '(' ]; then
            if [ "$nn" = '(' ]; then
              # $(( arithmetic )) — NOT a command position. Skip to matching )).
              _pfg_ss_skip_arith "$((i+1))" || return 0
              i="$_PFG_SS_DELIM_END"; cmdpos=0; wordstart=0; seg_has_content=1; continue
            fi
            # $( command substitution ) — live; recurse body.
            _pfg_ss_recurse_paren "$parent" COMMAND_SUBSTITUTION "$((i+2))" "$depth" || return 0
            i="$_PFG_SS_DELIM_END"; cmdpos=0; wordstart=0; seg_has_content=1; continue
          fi
          # ${...} parameter expansion or $NAME — data here (the token-level computed check handles it when
          # this position is a program/subcommand). Skip a ${...} block so an inner ) doesn't confuse us.
          if [ "$nx" = '{' ]; then
            _pfg_ss_skip_braceparam "$((i+2))" || return 0
            i="$_PFG_SS_DELIM_END"; cmdpos=0; wordstart=0; seg_has_content=1; continue
          fi
          i=$((i+1)); cmdpos=0; wordstart=0; seg_has_content=1; continue ;;
        '('|'{')
          if [ "$c" = '(' ] && [ "$nx" = '(' ]; then
            # (( arithmetic )) — not a command position.
            _pfg_ss_skip_arith "$i" || return 0
            i="$_PFG_SS_DELIM_END"; cmdpos=0; wordstart=0; seg_has_content=1; continue
          fi
          if [ "$cmdpos" = 1 ]; then
            # a subshell ( … ) or brace group { … ; } in command position → recurse the body.
            local subctx=SUBSHELL close=')'
            if [ "$c" = '{' ]; then subctx=BRACE_GROUP; close='}'; fi
            _pfg_ss_flush "$i"   # nothing before it in this segment
            if [ "$c" = '(' ]; then
              _pfg_ss_recurse_paren "$parent" "$subctx" "$((i+1))" "$depth" || return 0
            else
              _pfg_ss_recurse_brace "$parent" "$subctx" "$((i+1))" "$depth" || return 0
            fi
            i="$_PFG_SS_DELIM_END"; seg_start="$i"; cmdpos=0; wordstart=0; continue
          fi
          # a '(' in ARGUMENT position. In real bash this is usually a syntax error (NOEXEC) EXCEPT the
          # process-substitution forms <( ) and >( ), which are handled by the '<'/'>' arms below. A bare
          # arg-position '(' that is not part of <(/>( is treated as literal text (no node) — but to stay
          # safe against an exotic executable shape we mark the enclosing segment opacity via a sentinel:
          # here we conservatively treat it as literal (matches real-bash NOEXEC for `echo foo ( x )`).
          i=$((i+1)); cmdpos=0; wordstart=0; seg_has_content=1; continue ;;
        '<'|'>')
          if [ "$nx" = '(' ]; then
            # process substitution <( … ) / >( … ) — its body runs as a child process. Recurse.
            local pctx=PROCESS_SUBSTITUTION_IN; [ "$c" = '>' ] && pctx=PROCESS_SUBSTITUTION_OUT
            _pfg_ss_recurse_paren "$parent" "$pctx" "$((i+2))" "$depth" || return 0
            i="$_PFG_SS_DELIM_END"; cmdpos=0; wordstart=0; seg_has_content=1; continue
          fi
          # ordinary redirection or here-doc/here-string.
          if [ "$c" = '<' ] && [ "$nx" = '<' ]; then
            # here-document (<<, <<-) or here-string (<<<). Determine the consuming program of THIS segment:
            # if it is a shell/eval, the here-doc body is EXECUTED → OPAQUE (fixed policy 4). Otherwise the
            # body is DATA (fixed policy 3) → literal. We cannot fully parse the body region here without a
            # heredoc-delimiter scan; conservatively: flush the segment first to learn its program, then
            # decide. For Stage 1 we mark the segment's node opacity through a dedicated heredoc handler.
            _pfg_ss_handle_heredoc "$parent" "$ctx" "$seg_start" "$i" "$nn" "$depth" || return 0
            i="$_PFG_SS_DELIM_END"; seg_start="$i"; cmdpos=1; wordstart=1; continue
          fi
          # simple redirection operator: skip it and (optionally) its target token; stays in same command.
          i=$((i+1)); cmdpos=0; wordstart=0; seg_has_content=1; continue ;;
        ' '|$'\t')
          i=$((i+1)); wordstart=1; seg_has_content=$seg_has_content; continue ;;
        $'\n')
          _pfg_ss_flush "$i"; i=$((i+1)); seg_start="$i"; cmdpos=1; wordstart=1; continue ;;
        ')')
          # a bare ')' in command position inside a CASE body is a pattern-label terminator (`pattern)`):
          # the text before it (the pattern) is NOT a command; the commands follow until `;;`. Drop the
          # pattern (do not analyze it) and reset to a command position. Elsewhere a top-level bare ')' is
          # stray (we treat it as a separator, harmless). `;;` is handled by the ';' arm (double-consume).
          seg_start="$((i+1))"; i=$((i+1)); cmdpos=1; wordstart=1; seg_has_content=0; continue ;;
        *)
          # an ordinary word char. Check for a structural KEYWORD at a command position (wordstart && cmdpos).
          if [ "$cmdpos" = 1 ] && [ "$wordstart" = 1 ]; then
            _pfg_ss_peek_keyword "$i" "$hi"; local kw="$_PFG_SS_R_KW"
            if [ -n "$kw" ]; then
              _pfg_ss_flush "$i"
              case "$kw" in
                for)
                  # `for NAME in WORDS; do` (or `for ((c-style)); do`). The head (NAME, in, WORDS) is NOT a
                  # command — skip to the `do` body introducer. WORDS could contain a substitution; we skip
                  # statically to `do` at a command position (a `do` keyword at wordstart). If no `do` is
                  # found the construct is malformed → leave for the trailing flush (benign / no governed op).
                  i=$((i+3))   # past 'for'
                  local _seen_do=0
                  while [ "$i" -lt "$hi" ]; do
                    _pfg_ss_peek_keyword "$i" "$hi"
                    if [ "$_PFG_SS_R_KW" = do ]; then i=$((i+2)); _seen_do=1; break; fi
                    # skip quotes/substitutions in the head so their internals don't confuse us
                    case "${_PFG_SS_S:$i:1}" in
                      "'") i=$((i+1)); while [ "$i" -lt "$hi" ] && [ "${_PFG_SS_S:$i:1}" != "'" ]; do i=$((i+1)); done ;;
                      '"') i=$((i+1)); while [ "$i" -lt "$hi" ] && [ "${_PFG_SS_S:$i:1}" != '"' ]; do [ "${_PFG_SS_S:$i:1}" = '\' ] && i=$((i+1)); i=$((i+1)); done ;;
                    esac
                    i=$((i+1))
                  done
                  seg_start="$i"; cmdpos=1; wordstart=1; ctx=FOR_BODY; continue ;;
                case)
                  # `case WORD in` … `pattern) cmds ;;` … `esac`. Skip the head (`case WORD in`) to just past
                  # `in`, then scan the body normally — the ')' arm above drops each pattern label and `;;`
                  # (via the ';' double-consume) resets to a command position. Set CASE_BODY context.
                  i=$((i+4))   # past 'case'
                  local _seen_in=0
                  while [ "$i" -lt "$hi" ]; do
                    _pfg_ss_peek_keyword "$i" "$hi"
                    if [ "$_PFG_SS_R_KW" = in ]; then i=$((i+2)); _seen_in=1; break; fi
                    case "${_PFG_SS_S:$i:1}" in
                      "'") i=$((i+1)); while [ "$i" -lt "$hi" ] && [ "${_PFG_SS_S:$i:1}" != "'" ]; do i=$((i+1)); done ;;
                      '"') i=$((i+1)); while [ "$i" -lt "$hi" ] && [ "${_PFG_SS_S:$i:1}" != '"' ]; do [ "${_PFG_SS_S:$i:1}" = '\' ] && i=$((i+1)); i=$((i+1)); done ;;
                    esac
                    i=$((i+1))
                  done
                  seg_start="$i"; cmdpos=1; wordstart=1; ctx=CASE_BODY; continue ;;
                in|esac|fi|done|then|do)
                  # body introducers / closers with no head to skip: advance past, stay at command position.
                  i=$((i + ${#kw})); seg_start="$i"; cmdpos=1; wordstart=1
                  local _c; _c="$(_pfg_ss_keyword_ctx "$kw")"; [ -n "$_c" ] && ctx="$_c"
                  continue ;;
                *)
                  # if/elif/else/while/until/function: their CONDITION/LIST is itself a command position.
                  i=$((i + ${#kw})); seg_start="$i"; cmdpos=1; wordstart=1
                  local _c; _c="$(_pfg_ss_keyword_ctx "$kw")"; [ -n "$_c" ] && ctx="$_c"
                  continue ;;
              esac
            fi
          fi
          i=$((i+1)); cmdpos=0; wordstart=0; seg_has_content=1; continue ;;
      esac
    elif [ "$st" = SQ ]; then
      case "$c" in "'") st=NORMAL ;; esac; i=$((i+1)); continue
    elif [ "$st" = DQ ]; then
      case "$c" in
        '\') i=$((i+2)); continue ;;
        '"') st=NORMAL; i=$((i+1)); continue ;;
        '`')
          _pfg_ss_recurse_delim "$parent" BACKTICK_SUBSTITUTION "$i" '`' "$depth" || return 0
          i="$_PFG_SS_DELIM_END"; continue ;;
        '$')
          if [ "$nx" = '(' ]; then
            if [ "$nn" = '(' ]; then _pfg_ss_skip_arith "$((i+1))" || return 0; i="$_PFG_SS_DELIM_END"; continue; fi
            _pfg_ss_recurse_paren "$parent" COMMAND_SUBSTITUTION "$((i+2))" "$depth" || return 0
            i="$_PFG_SS_DELIM_END"; continue
          fi
          i=$((i+1)); continue ;;
        *) i=$((i+1)); continue ;;
      esac
    fi
  done
  # end of region — flush any trailing segment, then check for unterminated quote.
  if [ "$st" = SQ ] || [ "$st" = DQ ]; then
    _PFG_SS_ABORT="OPAQUE"; PFG_SS_STATUS_REASON="unterminated quote (the command cannot be statically resolved; an executable structure may be concealed)"
    return 0
  fi
  _pfg_ss_flush "$hi"
  return 0
}

# Peek whether S[i..] begins with a structural keyword followed by a word boundary. Sets _PFG_SS_R_KW.
# PERFORMANCE: dispatch on the FIRST character so we only test the (few) keywords that can start with it,
# instead of slicing the string against all 16 keywords on every word-start char.
_PFG_SS_R_KW=""
_pfg_ss_peek_keyword() {  # $1 = i  $2 = hi. Sets _PFG_SS_R_KW.
  local i="$1" hi="$2" kw c0 cands
  _PFG_SS_R_KW=""
  c0="${_PFG_SS_S:$i:1}"
  case "$c0" in
    i) cands="if in" ;;
    t) cands="then" ;;
    e) cands="elif else esac" ;;
    f) cands="fi for function" ;;
    w) cands="while" ;;
    u) cands="until" ;;
    d) cands="do done" ;;
    c) cands="case" ;;
    *) return ;;
  esac
  for kw in $cands; do
    local len=${#kw}
    if [ "$((i+len))" -le "$hi" ] && [ "${_PFG_SS_S:$i:$len}" = "$kw" ]; then
      local after="${_PFG_SS_S:$((i+len)):1}"
      case "$after" in ''|' '|$'\t'|$'\n'|';'|'&'|'|'|'(') _PFG_SS_R_KW="$kw"; return ;; esac
    fi
  done
}
# Map a keyword to the execution context tag its following body should carry.
_pfg_ss_keyword_ctx() {  # $1 = keyword
  case "$1" in
    if) printf 'IF_BODY' ;;
    then) printf 'IF_BODY' ;;
    elif) printf 'ELIF_BODY' ;;
    else) printf 'ELSE_BODY' ;;
    while) printf 'WHILE_BODY' ;;
    until) printf 'UNTIL_BODY' ;;
    for) printf 'FOR_BODY' ;;
    do) printf '' ;;        # `do` keeps the loop body context already set by while/until/for
    case) printf 'CASE_BODY' ;;
    in) printf '' ;;
    function) printf 'FUNCTION_BODY' ;;
    fi|done|esac) printf '' ;;
    *) printf '' ;;
  esac
}

# Recurse a parenthesized body starting at offset $3 (first body char after '('). Honors nested () and
# inner quotes. Emits the body's command positions under a NEW node representing the group. Sets
# _PFG_SS_DELIM_END to the offset just past the matching ')'.
_pfg_ss_recurse_paren() {  # $1 parent  $2 ctx  $3 bodystart  $4 depth
  local parent="$1" ctx="$2" bstart="$3" depth="$4"
  local j="$bstart" n="$_PFG_SS_N" depthp=1 st=NORMAL c nx
  while [ "$j" -lt "$n" ]; do
    c="${_PFG_SS_S:$j:1}"; nx="${_PFG_SS_S:$((j+1)):1}"
    if [ "$st" = NORMAL ]; then
      case "$c" in
        '\') j=$((j+2)); continue ;;
        "'") st=SQ ;; '"') st=DQ ;;
        '`') # skip an inner backtick span so its ) doesn't miscount
          j=$((j+1)); while [ "$j" -lt "$n" ] && [ "${_PFG_SS_S:$j:1}" != '`' ]; do [ "${_PFG_SS_S:$j:1}" = '\' ] && j=$((j+1)); j=$((j+1)); done ;;
        '(') depthp=$((depthp+1)) ;;
        ')') depthp=$((depthp-1)); if [ "$depthp" -eq 0 ]; then break; fi ;;
      esac
    elif [ "$st" = SQ ]; then case "$c" in "'") st=NORMAL ;; esac
    elif [ "$st" = DQ ]; then case "$c" in '\') j=$((j+2)); continue ;; '"') st=NORMAL ;; esac
    fi
    j=$((j+1))
  done
  if [ "$j" -ge "$n" ] && [ "$depthp" -ne 0 ]; then
    _PFG_SS_ABORT="OPAQUE"; PFG_SS_STATUS_REASON="unterminated '${ctx}' grouping/substitution (executable structure may be concealed)"
    _PFG_SS_DELIM_END="$n"; return 1
  fi
  # emit a node for the group itself, then scan its body under it.
  _pfg_ss_emit "$parent" "$ctx" "$bstart" "$j" "" 0 "" 0 "" NONE ""
  local gid="$_PFG_SS_LAST_ID"
  [ -n "$_PFG_SS_ABORT" ] && { _PFG_SS_DELIM_END=$((j+1)); return 1; }
  _pfg_ss_scan "$gid" "$ctx" "$bstart" "$j" "$((depth+1))"
  _PFG_SS_DELIM_END=$((j+1))
  [ -n "$_PFG_SS_ABORT" ] && return 1
  return 0
}

# Recurse a brace-group body starting after '{'. Closes at the matching '}'. Like _pfg_ss_recurse_paren but
# brace-balanced (and braces don't nest via the same char in arithmetic here since we skip $(( )) elsewhere).
_pfg_ss_recurse_brace() {  # $1 parent  $2 ctx  $3 bodystart  $4 depth
  local parent="$1" ctx="$2" bstart="$3" depth="$4"
  local j="$bstart" n="$_PFG_SS_N" depthb=1 st=NORMAL c nx
  while [ "$j" -lt "$n" ]; do
    c="${_PFG_SS_S:$j:1}"; nx="${_PFG_SS_S:$((j+1)):1}"
    if [ "$st" = NORMAL ]; then
      case "$c" in
        '\') j=$((j+2)); continue ;;
        "'") st=SQ ;; '"') st=DQ ;;
        '`') j=$((j+1)); while [ "$j" -lt "$n" ] && [ "${_PFG_SS_S:$j:1}" != '`' ]; do [ "${_PFG_SS_S:$j:1}" = '\' ] && j=$((j+1)); j=$((j+1)); done ;;
        '$') if [ "$nx" = '{' ]; then j=$((j+1)); fi ;;   # ${...} — let the brace below not miscount: skip the $
        '{') depthb=$((depthb+1)) ;;
        '}') depthb=$((depthb-1)); if [ "$depthb" -eq 0 ]; then break; fi ;;
      esac
    elif [ "$st" = SQ ]; then case "$c" in "'") st=NORMAL ;; esac
    elif [ "$st" = DQ ]; then case "$c" in '\') j=$((j+2)); continue ;; '"') st=NORMAL ;; esac
    fi
    j=$((j+1))
  done
  if [ "$j" -ge "$n" ] && [ "$depthb" -ne 0 ]; then
    _PFG_SS_ABORT="OPAQUE"; PFG_SS_STATUS_REASON="unterminated brace group (executable structure may be concealed)"
    _PFG_SS_DELIM_END="$n"; return 1
  fi
  _pfg_ss_emit "$parent" "$ctx" "$bstart" "$j" "" 0 "" 0 "" NONE ""
  local gid="$_PFG_SS_LAST_ID"
  [ -n "$_PFG_SS_ABORT" ] && { _PFG_SS_DELIM_END=$((j+1)); return 1; }
  _pfg_ss_scan "$gid" "$ctx" "$bstart" "$j" "$((depth+1))"
  _PFG_SS_DELIM_END=$((j+1))
  [ -n "$_PFG_SS_ABORT" ] && return 1
  return 0
}

# Recurse a backtick-delimited body. $3 = offset of the OPENING backtick. Closes at the next unescaped `.
_pfg_ss_recurse_delim() {  # $1 parent  $2 ctx  $3 openpos  $4 closechar  $5 depth
  local parent="$1" ctx="$2" open="$3" close="$4" depth="$5"
  local bstart=$((open+1)) j=$((open+1)) n="$_PFG_SS_N" c
  while [ "$j" -lt "$n" ]; do
    c="${_PFG_SS_S:$j:1}"
    case "$c" in '\') j=$((j+2)); continue ;; "$close") break ;; esac
    j=$((j+1))
  done
  if [ "$j" -ge "$n" ]; then
    _PFG_SS_ABORT="OPAQUE"; PFG_SS_STATUS_REASON="unterminated backtick substitution (executable structure may be concealed)"
    _PFG_SS_DELIM_END="$n"; return 1
  fi
  _pfg_ss_emit "$parent" "$ctx" "$bstart" "$j" "" 0 "" 0 "" NONE ""
  local gid="$_PFG_SS_LAST_ID"
  [ -n "$_PFG_SS_ABORT" ] && { _PFG_SS_DELIM_END=$((j+1)); return 1; }
  _pfg_ss_scan "$gid" "$ctx" "$bstart" "$j" "$((depth+1))"
  _PFG_SS_DELIM_END=$((j+1))
  [ -n "$_PFG_SS_ABORT" ] && return 1
  return 0
}

# Skip an arithmetic region: $1 = offset of the first '(' of a (( or $(( . Sets _PFG_SS_DELIM_END past )).
_pfg_ss_skip_arith() {  # $1 = offset of first '('
  local j="$1" n="$_PFG_SS_N" depth=0 c
  while [ "$j" -lt "$n" ]; do
    c="${_PFG_SS_S:$j:1}"
    case "$c" in
      '(') depth=$((depth+1)) ;;
      ')') depth=$((depth-1)); if [ "$depth" -eq 0 ]; then _PFG_SS_DELIM_END=$((j+1)); return 0; fi ;;
    esac
    j=$((j+1))
  done
  _PFG_SS_ABORT="OPAQUE"; PFG_SS_STATUS_REASON="unterminated arithmetic expression"; _PFG_SS_DELIM_END="$n"; return 1
}

# Skip a ${...} parameter expansion: $1 = offset just after the '{'. Sets _PFG_SS_DELIM_END past '}'.
_pfg_ss_skip_braceparam() {  # $1 = offset after '{'
  local j="$1" n="$_PFG_SS_N" depth=1 c
  while [ "$j" -lt "$n" ]; do
    c="${_PFG_SS_S:$j:1}"
    case "$c" in
      '\') j=$((j+2)); continue ;;
      '{') depth=$((depth+1)) ;;
      '}') depth=$((depth-1)); if [ "$depth" -eq 0 ]; then _PFG_SS_DELIM_END=$((j+1)); return 0; fi ;;
    esac
    j=$((j+1))
  done
  _PFG_SS_ABORT="OPAQUE"; PFG_SS_STATUS_REASON="unterminated \${ } parameter expansion"; _PFG_SS_DELIM_END="$n"; return 1
}

# Handle a here-doc / here-string at offset $5(==nn marker, '<' for <<<) in segment [$3,$4). For Stage 1:
# determine the segment's program; if it is a shell/eval → OPAQUE (executable here-doc, fixed policy 4);
# otherwise the body is DATA (fixed policy 3) → emit the simple command normally and skip the body region.
# Sets _PFG_SS_DELIM_END to a safe continue offset.
_pfg_ss_handle_heredoc() {  # $1 parent  $2 ctx  $3 seg_start  $4 op_pos  $5 third_char  $6 depth
  local parent="$1" ctx="$2" s="$3" oppos="$4" depth="$6"
  local headtext="${_PFG_SS_S:$s:$((oppos-s))}"
  # peel env/command/exec and find the program basename of this segment's head (quote-aware tokenize).
  _pfg_ss_tokenize "$headtext"
  set -- "${_PFG_SS_TOK[@]}"
  while [ "$#" -gt 0 ]; do
    case "$1" in [A-Za-z_]*=*) shift ;; command|builtin|exec|env) shift ;; *) break ;; esac
  done
  local prog="${1:-}" base=""
  if [ -n "$prog" ]; then
    _pfg_ss_token_is_computed "$prog"
    if [ "$_PFG_SS_R_COMPUTED" != 1 ]; then _pfg_ss_unquote "$prog"; base="${_PFG_SS_R_LIT##*/}"; base="${base%.exe}"; fi
  fi
  # Determine the heredoc kind and recover the delimiter word so we can SKIP the body (it is DATA, not
  # commands — emitting nodes for body lines was a false-positive, e.g. `cat <<EOF … gh pr merge … EOF`).
  # `<<<` is a here-STRING (one line, no delimiter); `<<`/`<<-` is a here-DOC ending at a line == delimiter.
  local op3="${_PFG_SS_S:$((oppos+2)):1}" afterop
  local is_herestring=0
  if [ "$op3" = '<' ]; then is_herestring=1; afterop=$((oppos+3)); else afterop=$((oppos+2)); fi
  # for <<- the leading '-' allows tab-indented delimiter; consume it.
  [ "$is_herestring" = 0 ] && [ "${_PFG_SS_S:$afterop:1}" = '-' ] && afterop=$((afterop+1))
  case "$base" in
    bash|sh|dash|zsh|ksh|eval)
      _pfg_ss_emit "$parent" HERE_DOCUMENT_EXECUTION "$s" "$oppos" "$base" 0 "" 0 "" OPAQUE \
        "here-document/here-string fed into a shell (its body is executed; the concealed commands cannot be statically resolved)"
      ;;
    *)
      # here-doc as ordinary DATA to a non-shell program → emit the simple head command; body is literal.
      _pfg_ss_analyze_simple "$parent" "$ctx" "$s" "$oppos" "$headtext" "$depth"
      ;;
  esac
  if [ "$is_herestring" = 1 ]; then
    # here-string: the WORD after <<< is data on the same logical line; advance past <<< and let the normal
    # scan treat the rest of the line as arguments (the head command is already emitted). Safe: no body lines.
    _PFG_SS_DELIM_END="$afterop"
    return 0
  fi
  # here-DOC: recover the delimiter token (first token after the operator, quotes stripped), then skip from
  # the next newline up to and including the line that equals the delimiter. The skipped region is DATA.
  local rest="${_PFG_SS_S:$afterop}"
  _pfg_ss_tokenize "$rest"
  local delim_raw="${_PFG_SS_TOK[0]:-}"
  _pfg_ss_unquote "$delim_raw"; local delim="$_PFG_SS_R_LIT"
  if [ -z "$delim" ]; then
    # malformed heredoc (no delimiter) with execution potential → opaque, fail-closed.
    _PFG_SS_ABORT="OPAQUE"; PFG_SS_STATUS_REASON="here-document with no recoverable delimiter"
    _PFG_SS_DELIM_END="$_PFG_SS_N"; return 0
  fi
  # find the end of the current physical line (the heredoc body starts on the NEXT line).
  local k="$afterop" n="$_PFG_SS_N"
  while [ "$k" -lt "$n" ] && [ "${_PFG_SS_S:$k:1}" != $'\n' ]; do k=$((k+1)); done
  # k now at the newline (or EOF). Scan body lines for one equal to the delimiter (ignoring leading tabs for <<-).
  k=$((k+1))   # first body char
  local lstart="$k"
  while [ "$k" -le "$n" ]; do
    if [ "$k" -eq "$n" ] || [ "${_PFG_SS_S:$k:1}" = $'\n' ]; then
      local line="${_PFG_SS_S:$lstart:$((k-lstart))}"
      # strip leading tabs (the <<- form trims them; harmless for <<)
      line="${line#"${line%%[![:space:]]*}"}"
      # strip a trailing CR (Windows)
      line="${line%$'\r'}"
      if [ "$line" = "$delim" ]; then _PFG_SS_DELIM_END=$((k+1)); return 0; fi
      lstart=$((k+1))
    fi
    k=$((k+1))
  done
  # delimiter never found → unterminated heredoc. If the consuming program executes it (shell) it is already
  # OPAQUE; either way the body is unresolved → continue past EOF (nothing left to scan).
  _PFG_SS_DELIM_END="$_PFG_SS_N"
  return 0
}

# ── Public entrypoint ────────────────────────────────────────────────────────────────────────────────────
# pfg_ss_parse <command-string>
#   Builds the IR into the PFG_SS_* arrays. Sets PFG_SS_STATUS to one of:
#     OK         — parsed; PFG_SS_NODE_COUNT nodes available (some may be OPAQUE).
#     OPAQUE     — a malformed/unterminated executable structure was hit; caller fails CLOSED.
#     SIZE_LIMIT / NODE_LIMIT / DEPTH_LIMIT — a budget was exceeded; caller fails CLOSED.
#     ERROR      — an internal parser failure; caller fails CLOSED.
#   Returns 0 always (the status is in PFG_SS_STATUS); never executes input.
pfg_ss_parse() {
  _pfg_ss_reset
  local cmd="$1"
  # SIZE budget first (before any scan work).
  if [ "${#cmd}" -gt "$PFG_SS_MAX_BYTES" ]; then
    PFG_SS_STATUS="SIZE_LIMIT"; PFG_SS_STATUS_REASON="command exceeds the $PFG_SS_MAX_BYTES-byte parser budget"
    return 0
  fi
  _PFG_SS_S="$cmd"; _PFG_SS_N="${#cmd}"
  _pfg_ss_scan -1 TOPLEVEL 0 "$_PFG_SS_N" 0
  if [ -n "$_PFG_SS_ABORT" ]; then
    PFG_SS_STATUS="$_PFG_SS_ABORT"
    # OPAQUE aborts already set a reason; limit aborts set a reason in _pfg_ss_emit/_pfg_ss_scan.
    [ -z "$PFG_SS_STATUS_REASON" ] && PFG_SS_STATUS_REASON="parser aborted ($_PFG_SS_ABORT)"
    return 0
  fi
  PFG_SS_STATUS="OK"
  return 0
}

# ── Family-neutral structural queries (NO policy — for later-stage classifiers and tests) ────────────────
# basename of a node's static executable token, or '' if none/computed.
pfg_ss_exec_basename() {  # $1 = node id
  local i="$1" e="${PFG_SS_EXEC[$1]}"
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
