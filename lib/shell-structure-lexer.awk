# lib/shell-structure-lexer.awk — POSIX-awk STRUCTURAL LEXER for the shared shell-structure parser.
#
# STATUS (Stage 2A of the shared-parser redesign): this program is the LEXER/SCANNER half of the parser.
# It performs the complete per-byte, quote/escape/comment-aware command-position scan + bounded structural
# recursion + simple-command classification that lib/shell-structure.sh performed in pure Bash through
# Stage 1, and emits a BOUNDED, VERSIONED, NON-EVALUATING record protocol on stdout. The Bash wrapper
# (lib/shell-structure.sh, Stage-2A form) validates the protocol and reconstructs the existing PFG_SS_* IR
# arrays; the WRAPPER — not this program — owns all policy, classification into families, verdict, and
# diagnostics. This program is FAMILY-NEUTRAL: it exposes structural facts only.
#
# HARD SAFETY CONTRACT (every one a security property, not a nicety):
#   • Reads command bytes ONLY from stdin. NEVER argv, NEVER -v, NEVER a generated temp shell script.
#   • NO system(), NO getline from a command/pipe, NO filesystem access beyond being -f'd, NO network.
#   • NEVER executes, eval's, sources, or expands the command; it only classifies byte structure.
#   • Byte semantics (all offsets are BYTE offsets): the wrapper sets LC_ALL=C, AND — belt and braces — the
#     BEGIN block SELF-ENFORCES byte mode with a length("\303\251")==2 probe, failing CLOSED to an ERROR
#     terminal if awk is in character mode (so a caller that forgets LC_ALL=C gets an honest ERROR, never a
#     silently offset-shifted / mis-encoded IR). A literal 0x1C in the command → ERROR (never a dropped byte).
#   • Fully DRAINS stdin before exit (even on a recognized syntax error) → no producer-side SIGPIPE under
#     `set -o pipefail`.
#   • Emits a BOUNDED number of records (size/node/depth budgets) then EXACTLY ONE terminal END record;
#     nothing follows the terminal record. Budget exhaustion → an explicit limit status, never truncated OK.
#
# OUTPUT PROTOCOL (one record per line; fields separated by a single ASCII space; version-pinned). The
# records are emitted in EXACT Stage-1 node-emission order so the wrapper reconstructs an identical forest:
#   V <n>                          protocol version (FIRST record; n=1)
#   M <maxbytes> <maxnodes> <maxdepth>   echoed budgets
#   N <id> <parent> <ctxcode> <start> <end> <execflag> <execcomputed> <subcmdcomputed> <opacitycode>
#                                  a command-position node, in emission order (id is monotonic from 0)
#   X <id> <start> <end>           EXEC token byte span for node <id> (wrapper derives the basename)
#   S <id> <start> <end> <n>       nth SUBCMD (leading-arg) token byte span for node <id> (n=1,2)
#   G <id> <start> <end> <n>       nth ENV-assignment prefix byte span for node <id>
#   R <id> <code>                  opacity REASON code for node <id> (see REASON enum)
#   O <statuscode> <reasoncode>    a TOP-LEVEL abort status (OPAQUE/limit/ERROR) — emitted at most once
#   E <nodecount> <statuscode>     terminal record (exactly one; nothing follows)
#
# Spans for INLINE_SHELL child nodes are byte offsets into the RECURSED PAYLOAD string, exactly as Stage 1
# reports them (payload re-based to 0) — the wrapper does not need the payload text to validate them.
#
# ctxcode / statuscode / reasoncode are small integer enums (defined in BEGIN and mirrored in the wrapper)
# so NO free text and NO raw command text ever crosses the boundary.
#
# POSIX awk only: no gensub, no asort, no length(array) hot-path, no gawk-only constructs. substr()/index()/
# and simple arrays only. Verified on GNU awk; written to run identically on mawk (LC_ALL=C byte semantics).

# ────────────────────────────────────────────────────────────────────────────────────────────────────────
# GLOBALS (awk has no locals except function parameters; hot recursive functions declare scratch params):
#   BUF        the command bytes (one exact slurp from stdin)
#   N          length(BUF)
#   NODES      number of emitted nodes (next id)
#   ABORT      "" or a statuscode when a budget/opacity abort fires
#   ABORT_R    reason code accompanying ABORT
#   MAXBYTES/MAXNODES/MAXDEPTH  budgets
#   S_* / T_*  scratch returned by helper functions (awk returns one scalar; multi-value via globals)
# ────────────────────────────────────────────────────────────────────────────────────────────────────────

# char at 0-based byte offset p in the CURRENT scan buffer SB (empty past the ends). SB is the top-level
# command normally, but is temporarily swapped to a recursed inline-shell payload (spans re-based to 0), so
# every scan/tokenize/recurse function reads via ch()/SB/SN — never the original BUF/N (that conflation was
# the F1 bug: reading BUF with a payload-length bound truncated mid-quote → spurious unterminated-quote).
function ch(p) { if (p < 0 || p >= SN) return ""; return substr(SB, p+1, 1) }

# ── enums ───────────────────────────────────────────────────────────────────────────────────────────────
function setup_enums() {
  CTX["TOPLEVEL"]=1; CTX["PIPELINE"]=2; CTX["SUBSHELL"]=3; CTX["BRACE_GROUP"]=4
  CTX["COMMAND_SUBSTITUTION"]=5; CTX["BACKTICK_SUBSTITUTION"]=6
  CTX["PROCESS_SUBSTITUTION_IN"]=7; CTX["PROCESS_SUBSTITUTION_OUT"]=8
  CTX["IF_BODY"]=9; CTX["ELIF_BODY"]=10; CTX["ELSE_BODY"]=11
  CTX["WHILE_BODY"]=12; CTX["UNTIL_BODY"]=13; CTX["FOR_BODY"]=14; CTX["CASE_BODY"]=15
  CTX["INLINE_SHELL"]=16; CTX["HERE_DOCUMENT_EXECUTION"]=17; CTX["FUNCTION_BODY"]=18
  # status codes
  ST["OK"]=0; ST["OPAQUE"]=1; ST["SIZE_LIMIT"]=2; ST["NODE_LIMIT"]=3; ST["DEPTH_LIMIT"]=4; ST["ERROR"]=5
  # opacity codes
  OP["NONE"]=0; OP["OPAQUE"]=1
  # reason codes (stable; wrapper maps back to the human strings the Stage-1 tests assert substrings of)
  RC["computed-exec"]=1            # "computed executable token"
  RC["computed-subcmd"]=2          # "computed governed-subcommand"
  RC["inline-nopayload"]=3         # "inline shell -c with no recoverable payload"
  RC["inline-dynamic"]=4           # "inline shell -c with a dynamic payload"
  RC["heredoc-shell"]=5            # "here-document/here-string fed into a shell"
  RC["unterminated-quote"]=6       # "unterminated quote"
  RC["unterminated-group"]=7       # "unterminated ... grouping/substitution"
  RC["unterminated-brace"]=8       # "unterminated brace group"
  RC["unterminated-backtick"]=9    # "unterminated backtick substitution"
  RC["unterminated-arith"]=10      # "unterminated arithmetic expression"
  RC["unterminated-param"]=11      # "unterminated ${ } parameter expansion"
  RC["heredoc-nodelim"]=12         # "here-document with no recoverable delimiter"
  RC["depth"]=13                   # depth budget
  RC["node"]=14                    # node budget
  RC["inline-depth"]=15            # inline-shell nesting depth budget
}

# ── emit a node in Stage-1 order; enforce NODE budget exactly like _pfg_ss_emit. Returns the new id, or -1
# if the budget aborted (LAST_ID mirrors Stage-1's _PFG_SS_LAST_ID). exec/subcmd/env spans are emitted by
# the caller AFTER this via emit_exec/emit_sub/emit_env, keyed to the returned id. ─────────────────────────
function emit(parent, ctx, start, end, execflag, execcomp, subcomp, opacity,   id) {
  if (NODES >= MAXNODES) { ABORT="NODE_LIMIT"; ABORT_R=RC["node"]; LAST_ID=-1; return -1 }
  id = NODES
  printf "N %d %d %d %d %d %d %d %d %d\n", id, parent, CTX[ctx], start, end, execflag, execcomp, subcomp, OP[opacity]
  NODES++
  LAST_ID = id
  return id
}
function emit_reason(id, code) { printf "R %d %d\n", id, code }

# hex-encode a resolved token VALUE for injection-safe transport (only [0-9a-f] crosses the boundary; a
# newline/space/delimiter in a quoted token can never inject a fake record). Empty string → empty.
# These resolved tokens (program literal, joined subcommand, joined env prefix) are the MINIMUM structural
# facts the IR requires — NOT bulk command text; the full command / here-doc bodies / payloads never cross.
function hexenc(s,   out, k, c) {
  out = ""
  for (k = 1; k <= length(s); k++) { c = substr(s, k, 1); out = out sprintf("%02x", ORD[c]) }
  return out
}
function emit_exec(id, val) { if (val != "") printf "X %d %s\n", id, hexenc(val) }
function emit_sub(id, val)  { if (val != "") printf "S %d %s\n", id, hexenc(val) }
function emit_env(id, val)  { if (val != "") printf "G %d %s\n", id, hexenc(val) }

# ── unquote a token span [a,b) into its literal value (strip ONE level of quotes/escapes), like Stage-1
# _pfg_ss_unquote. Used internally for basename decisions AND to produce the value the wrapper stores. ─────
function unquote(a, b,   out, i, c, st) {
  out = ""; i = a; st = 0   # 0 NORMAL 1 SQ 2 DQ
  while (i < b) {
    c = ch(i)
    if (st == 0) {
      if (c == "\\") { out = out ch(i+1); i += 2; continue }
      else if (c == "'") { st = 1; i++; continue }
      else if (c == "\"") { st = 2; i++; continue }
      else { out = out c }
    } else if (st == 1) { if (c == "'") st = 0; else out = out c }
    else if (st == 2) {
      if (c == "\\") { out = out ch(i+1); i += 2; continue }
      else if (c == "\"") st = 0
      else out = out c
    }
    i++
  }
  return out
}

# ── is token span [a,b) COMPUTED (live substitution/param-expansion outside single quotes)? Like Stage-1
# _pfg_ss_token_is_computed. Returns 1/0. ────────────────────────────────────────────────────────────────
function tok_computed(a, b,   i, c, nx, n2, st) {
  st = 0; i = a
  while (i < b) {
    c = ch(i); nx = ch(i+1); n2 = ch(i+2)
    if (st == 0) {
      if (c == "\\") { i += 2; continue }
      else if (c == "'") { st = 1 }
      else if (c == "\"") { st = 2 }
      else if (c == "`") { return 1 }
      else if (c == "$") {
        if (nx == "(") { if (n2 != "(") return 1 }
        else if (nx == "{") { return 1 }
        else if (nx ~ /[A-Za-z_]/) { return 1 }
      }
    } else if (st == 1) { if (c == "'") st = 0 }
    else if (st == 2) {
      if (c == "\\") { i += 2; continue }
      else if (c == "\"") st = 0
      else if (c == "`") return 1
      else if (c == "$") {
        if (nx == "(") { if (n2 != "(") return 1 }
        else if (nx == "{") return 1
        else if (nx ~ /[A-Za-z_]/) return 1
      }
    }
    i++
  }
  return 0
}

# basename of an unquoted literal, .exe stripped.
function basename(lit,   b, p) { b = lit; p = b; sub(/.*\//, "", b); sub(/\.exe$/, "", b); return b }
# is this unquoted program basename governed (gh/git)? like _pfg_ss_subcmd_governed_basename.
function gov_basename(lit,   b) { b = basename(lit); return (b == "gh" || b == "git") }

# ── QUOTE-AWARE TOKENIZER over CURSTR[s,e): fills TS[1..TN]/TE[1..TN] with token byte spans (start incl,
# end excl), keeping quoted spans + $()/``/${} substitutions intact within one token. Like Stage-1
# _pfg_ss_tokenize. Builtins-equivalent; NEVER expands/executes. ─────────────────────────────────────────
function tokenize(s, e,   i, c, nx, cur_s, have, st, depthp) {
  TN = 0; i = s; cur_s = -1; have = 0; st = 0; depthp = 0
  # st: 0 NORMAL 1 SQ 2 DQ 3 BT 4 CS($()) 5 PE(${})
  while (i < e) {
    c = ch(i); nx = ch(i+1)
    if (st == 0) {
      if (c == " " || c == "\t" || c == "\n") {
        if (have == 1) { TN++; TS[TN] = cur_s; TE[TN] = i; cur_s = -1; have = 0 }
        i++; continue
      }
      else if (c == "\\") { if (!have){cur_s=i;have=1}; i += 2; continue }
      else if (c == "'") { if (!have){cur_s=i;have=1}; st = 1; i++; continue }
      else if (c == "\"") { if (!have){cur_s=i;have=1}; st = 2; i++; continue }
      else if (c == "`") { if (!have){cur_s=i;have=1}; st = 3; i++; continue }
      else if (c == "$") {
        if (!have){cur_s=i;have=1}
        if (nx == "(") { i += 2; st = 4; depthp = 1; continue }
        if (nx == "{") { i += 2; st = 5; depthp = 1; continue }
        i++; continue
      }
      else { if (!have){cur_s=i;have=1}; i++; continue }
    }
    else if (st == 1) { if (c == "'") st = 0; i++; continue }
    else if (st == 2) { if (c == "\\") { i += 2; continue } else if (c == "\"") st = 0; i++; continue }
    else if (st == 3) { if (c == "\\") { i += 2; continue } else if (c == "`") st = 0; i++; continue }
    else if (st == 4) { if (c == "(") depthp++; else if (c == ")") { depthp--; if (depthp == 0) st = 0 } i++; continue }
    else if (st == 5) { if (c == "{") depthp++; else if (c == "}") { depthp--; if (depthp == 0) st = 0 } i++; continue }
  }
  if (have == 1) { TN++; TS[TN] = cur_s; TE[TN] = i }
}

function isident(s) { return (s ~ /^[A-Za-z_][A-Za-z0-9_]*$/) }

# ── SIMPLE-COMMAND analyzer: given the byte span [start,end) of ONE simple command in the current scan
# buffer SB, peel env/command/exec/env prefixes, classify the program token + governed leading args, and
# emit ONE node under $parent in $ctx. Faithful port of Stage-1 _pfg_ss_analyze_simple. ──────────────────
function analyze_simple(parent, ctx, start, end, depth,
                        ti, t, eq, env_pfx, prog_s, prog_e, prog_lit, base,
                        found_c, ptok_s, ptok_e, mid, payload, iid,
                        a1s, a1e, a2s, a2e, sub1, sub2, subcmd, subcomp, opacity, rcode,
                        savedSB, savedSN) {
  tokenize(start, end)
  ti = 1; env_pfx = ""
  # peel leading env-assignments + command/builtin/exec/env prefixes
  while (ti <= TN) {
    t = substr(SB, TS[ti]+1, TE[ti]-TS[ti])
    eq = index(t, "=")
    if (eq > 1 && isident(substr(t, 1, eq-1))) { env_pfx = (env_pfx=="" ? t : env_pfx " " t); ti++; continue }
    if (t == "command" || t == "builtin" || t == "exec") { ti++; continue }
    if (t == "env") {
      ti++
      while (ti <= TN) {
        t = substr(SB, TS[ti]+1, TE[ti]-TS[ti])
        if (t == "-i" || t == "--ignore-environment") { ti++ }
        else if (t == "-u") { ti++; if (ti <= TN) ti++ }
        else if (substr(t, 1, 1) == "-") { ti++ }
        else { eq = index(t, "="); if (eq > 1 && isident(substr(t, 1, eq-1))) { env_pfx = (env_pfx=="" ? t : env_pfx " " t); ti++ } else break }
      }
      continue
    }
    break
  }
  if (ti > TN) {                                   # env/assignment-only command position (no program)
    iid = emit(parent, ctx, start, end, 0, 0, 0, "NONE"); if (iid >= 0) emit_env(iid, env_pfx); return
  }
  prog_s = TS[ti]; prog_e = TE[ti]; ti++
  if (tok_computed(prog_s, prog_e)) {              # computed program token → OPAQUE (fixed policy 1)
    iid = emit(parent, ctx, start, end, 0, 1, 0, "OPAQUE")
    if (iid >= 0) { emit_env(iid, env_pfx); emit_reason(iid, RC["computed-exec"]) }
    return
  }
  prog_lit = unquote(prog_s, prog_e); base = basename(prog_lit)
  # ── INLINE SHELL: bash|sh|dash|zsh|ksh [opts] -c <payload> — recurse a static payload as a new context ──
  if (base == "bash" || base == "sh" || base == "dash" || base == "zsh" || base == "ksh") {
    found_c = 0; ptok_s = -1; ptok_e = -1
    while (ti <= TN) {
      t = substr(SB, TS[ti]+1, TE[ti]-TS[ti])
      if (t == "--command" || t == "-c") { found_c = 1; ti++; if (ti <= TN) { ptok_s = TS[ti]; ptok_e = TE[ti] } break }
      else if (t ~ /^-.*c$/) {
        mid = substr(t, 2, length(t)-2)
        if (mid ~ /^[lixeufmnBHT]*$/) { found_c = 1; ti++; if (ti <= TN) { ptok_s = TS[ti]; ptok_e = TE[ti] } break }
        else { ti++ }
      }
      else if (substr(t, 1, 1) == "-") { ti++ }
      else break
    }
    if (found_c == 1) {
      if (ptok_s < 0) {                            # -c with no payload token → OPAQUE
        iid = emit(parent, "INLINE_SHELL", start, end, 1, 0, 0, "OPAQUE")
        if (iid >= 0) { emit_exec(iid, base); emit_sub(iid, "-c"); emit_env(iid, env_pfx); emit_reason(iid, RC["inline-nopayload"]) }
        return
      }
      if (tok_computed(ptok_s, ptok_e)) {          # dynamic payload → OPAQUE
        iid = emit(parent, "INLINE_SHELL", start, end, 1, 0, 0, "OPAQUE")
        if (iid >= 0) { emit_exec(iid, base); emit_sub(iid, "-c"); emit_env(iid, env_pfx); emit_reason(iid, RC["inline-dynamic"]) }
        return
      }
      payload = unquote(ptok_s, ptok_e)
      iid = emit(parent, "INLINE_SHELL", start, end, 1, 0, 0, "NONE")
      if (iid < 0) return
      emit_exec(iid, base); emit_sub(iid, "-c"); emit_env(iid, env_pfx)
      if (ABORT != "") return
      if ((depth+1) > MAXDEPTH) { ABORT = "DEPTH_LIMIT"; ABORT_R = RC["inline-depth"]; return }
      savedSB = SB; savedSN = SN                   # recurse the payload as its own scan buffer (spans re-based to 0)
      SB = payload; SN = length(payload)
      scan(iid, "INLINE_SHELL", 0, SN, depth+1)
      SB = savedSB; SN = savedSN
      return
    }
    # no -c → fall through as a plain shell command node (handled by the generic path below)
  }
  # ── governed leading-argument (subcommand) analysis: ONLY for gh/git (family-neutral structural fact) ──
  subcmd = ""; subcomp = 0; opacity = "NONE"; rcode = 0; sub1 = ""; sub2 = ""
  if (gov_basename(prog_lit)) {
    # v0.10.0-rc.2 FIX: for `git`, SKIP the global-option run before reading the subcommand, mirroring
    # git's option grammar (and the engine's own _pfg_seg_push_args table). Without this, `git -C <dir>
    # push` recorded subcmd="-C <dir>" (never "push") → the IR reported ZERO push nodes → the engine
    # treated a real governed push as a non-push → silent ALLOW (the confirmed local-policy bypass).
    # Separate-value options (-C/--git-dir/--work-tree/--namespace/--super-prefix/--exec-path/-c/
    # --config-env) consume the NEXT token; =-joined and value-less flags are single tokens. An UNKNOWN
    # option (starts with '-') is skipped conservatively (advances past it), so the FIRST non-option
    # token becomes the subcommand. `-C<glued>` is invalid git (rejected by git itself) so it is left
    # as-is (the resulting non-"push" subcmd fails closed downstream). gh has no such global options → skip.
    if (basename(prog_lit) == "git") {
      while (ti <= TN) {
        gt = substr(SB, TS[ti]+1, TE[ti]-TS[ti])
        if (gt == "-C" || gt == "--git-dir" || gt == "--work-tree" || gt == "--namespace" || gt == "--super-prefix" || gt == "--exec-path" || gt == "-c" || gt == "--config-env") { ti++; if (ti <= TN) ti++; continue }
        if (gt ~ /^--git-dir=/ || gt ~ /^--work-tree=/ || gt ~ /^--namespace=/ || gt ~ /^--super-prefix=/ || gt ~ /^--exec-path=/ || gt ~ /^--config-env=/ || gt ~ /^-c=/) { ti++; continue }
        if (gt == "-p" || gt == "--paginate" || gt == "-P" || gt == "--no-pager" || gt == "--bare" || gt == "--no-replace-objects" || gt == "--no-lazy-fetch" || gt == "--no-optional-locks" || gt == "--no-advice" || gt == "--literal-pathspecs" || gt == "--glob-pathspecs" || gt == "--noglob-pathspecs" || gt == "--icase-pathspecs" || gt == "--html-path" || gt == "--man-path" || gt == "--info-path" || gt == "--no-renames") { ti++; continue }
        if (substr(gt, 1, 1) == "-") { ti++; continue }   # unknown option → skip conservatively
        break
      }
    }
    if (ti <= TN) { a1s = TS[ti]; a1e = TE[ti]; if (tok_computed(a1s, a1e)) subcomp = 1; else sub1 = unquote(a1s, a1e) }
    # The 2-token subcommand window (sub1 sub2) exists ONLY for gh's two-word verbs (`gh pr create`,
    # `gh pr merge`). For GIT the subcommand is the SINGLE first non-option token: `git push` is a push,
    # but `git stash push` / `git config push` / `git tag push` are NOT pushes — `push` there is the
    # subcommand's ARGUMENT, not the git subcommand. Reading a 2-token window for git made the engine's
    # `*" push "*` match fire on `stash push` etc. (a false-positive BLOCK on benign local commands). So
    # only widen to sub2 for the gh family; git stays single-token.
    if (basename(prog_lit) != "git" && subcomp == 0 && ti+1 <= TN) { a2s = TS[ti+1]; a2e = TE[ti+1]; if (tok_computed(a2s, a2e)) subcomp = 1; else sub2 = unquote(a2s, a2e) }
    subcmd = sub1; if (sub2 != "") subcmd = sub1 " " sub2
    if (subcomp == 1) { opacity = "OPAQUE"; rcode = RC["computed-subcmd"] }
  }
  iid = emit(parent, ctx, start, end, 1, 0, subcomp, opacity)
  if (iid >= 0) {
    emit_exec(iid, prog_lit); emit_sub(iid, subcmd); emit_env(iid, env_pfx)
    if (rcode) emit_reason(iid, rcode)
  }
}

# finalize [s,e) as a simple command if it has non-whitespace content (Stage-1 _pfg_ss_flush trim).
function do_flush(parent, ctx, depth, s, e,   slice) {
  if (ABORT != "") return
  slice = substr(SB, s+1, e-s)
  if (slice ~ /^[ \t\n]*$/) return
  analyze_simple(parent, ctx, s, e, depth)
}

# ── peek whether SB[i..] begins with a structural keyword followed by a word boundary. Sets R_KW. ────────
function peek_keyword(i, hi,   c0, cands, nc, kw, k, len, after) {
  R_KW = ""; c0 = ch(i)
  if (c0 == "i") cands = "if in"
  else if (c0 == "t") cands = "then"
  else if (c0 == "e") cands = "elif else esac"
  else if (c0 == "f") cands = "fi for function"
  else if (c0 == "w") cands = "while"
  else if (c0 == "u") cands = "until"
  else if (c0 == "d") cands = "do done"
  else if (c0 == "c") cands = "case"
  else return
  nc = split(cands, KWARR, " ")
  for (k = 1; k <= nc; k++) {
    kw = KWARR[k]; len = length(kw)
    if ((i+len) <= hi && substr(SB, i+1, len) == kw) {
      after = ch(i+len)
      if (after == "" || after == " " || after == "\t" || after == "\n" || after == ";" || after == "&" || after == "|" || after == "(") { R_KW = kw; return }
    }
  }
}
function keyword_ctx(kw) {
  if (kw == "if") return "IF_BODY"; if (kw == "then") return "IF_BODY"
  if (kw == "elif") return "ELIF_BODY"; if (kw == "else") return "ELSE_BODY"
  if (kw == "while") return "WHILE_BODY"; if (kw == "until") return "UNTIL_BODY"
  if (kw == "for") return "FOR_BODY"; if (kw == "case") return "CASE_BODY"
  if (kw == "function") return "FUNCTION_BODY"
  return ""
}

# ── recurse a parenthesized body starting at bstart (first char after '('); honors nested () and quotes.
# Emits a group node then scans the body under it. Sets DELIM_END past the matching ')'. ─────────────────
function recurse_paren(parent, ctx, bstart, depth,   j, depthp, st, c, gid) {
  j = bstart; depthp = 1; st = 0
  while (j < SN) {
    c = ch(j)
    if (st == 0) {
      if (c == "\\") { j += 2; continue }
      else if (c == "'") st = 1
      else if (c == "\"") st = 2
      else if (c == "`") { j++; while (j < SN && ch(j) != "`") { if (ch(j) == "\\") j++; j++ } }
      else if (c == "(") depthp++
      else if (c == ")") { depthp--; if (depthp == 0) break }
    } else if (st == 1) { if (c == "'") st = 0 }
    else if (st == 2) { if (c == "\\") { j += 2; continue } else if (c == "\"") st = 0 }
    j++
  }
  if (j >= SN && depthp != 0) { ABORT = "OPAQUE"; ABORT_R = RC["unterminated-group"]; DELIM_END = SN; return }
  gid = emit(parent, ctx, bstart, j, 0, 0, 0, "NONE")
  if (ABORT != "") { DELIM_END = j+1; return }
  scan(gid, ctx, bstart, j, depth+1)
  DELIM_END = j+1
}
# ── recurse a brace-group body after '{'; brace-balanced. Faithful port (incl the ${ skip quirk). ────────
function recurse_brace(parent, ctx, bstart, depth,   j, depthb, st, c, nx, gid) {
  j = bstart; depthb = 1; st = 0
  while (j < SN) {
    c = ch(j); nx = ch(j+1)
    if (st == 0) {
      if (c == "\\") { j += 2; continue }
      else if (c == "'") st = 1
      else if (c == "\"") st = 2
      else if (c == "`") { j++; while (j < SN && ch(j) != "`") { if (ch(j) == "\\") j++; j++ } }
      else if (c == "$") { if (nx == "{") j++ }
      else if (c == "{") depthb++
      else if (c == "}") { depthb--; if (depthb == 0) break }
    } else if (st == 1) { if (c == "'") st = 0 }
    else if (st == 2) { if (c == "\\") { j += 2; continue } else if (c == "\"") st = 0 }
    j++
  }
  if (j >= SN && depthb != 0) { ABORT = "OPAQUE"; ABORT_R = RC["unterminated-brace"]; DELIM_END = SN; return }
  gid = emit(parent, ctx, bstart, j, 0, 0, 0, "NONE")
  if (ABORT != "") { DELIM_END = j+1; return }
  scan(gid, ctx, bstart, j, depth+1)
  DELIM_END = j+1
}
# ── recurse a backtick-delimited body; open = offset of the opening backtick. ────────────────────────────
function recurse_delim(parent, ctx, open, depth,   bstart, j, c, gid) {
  bstart = open+1; j = open+1
  while (j < SN) { c = ch(j); if (c == "\\") { j += 2; continue } else if (c == "`") break; j++ }
  if (j >= SN) { ABORT = "OPAQUE"; ABORT_R = RC["unterminated-backtick"]; DELIM_END = SN; return }
  gid = emit(parent, ctx, bstart, j, 0, 0, 0, "NONE")
  if (ABORT != "") { DELIM_END = j+1; return }
  scan(gid, ctx, bstart, j, depth+1)
  DELIM_END = j+1
}
# ── skip an arithmetic region: p = offset of the first '(' of (( or $((. Sets DELIM_END past )). ─────────
function skip_arith(p,   j, depth, c) {
  j = p; depth = 0
  while (j < SN) { c = ch(j); if (c == "(") depth++; else if (c == ")") { depth--; if (depth == 0) { DELIM_END = j+1; return } } j++ }
  ABORT = "OPAQUE"; ABORT_R = RC["unterminated-arith"]; DELIM_END = SN
}
# ── skip a ${...} parameter expansion: p = offset just after '{'. Sets DELIM_END past '}'. ───────────────
function skip_braceparam(p,   j, depth, c) {
  j = p; depth = 1
  while (j < SN) { c = ch(j); if (c == "\\") { j += 2; continue } else if (c == "{") depth++; else if (c == "}") { depth--; if (depth == 0) { DELIM_END = j+1; return } } j++ }
  ABORT = "OPAQUE"; ABORT_R = RC["unterminated-param"]; DELIM_END = SN
}

# ── here-doc / here-string handler (faithful port of _pfg_ss_handle_heredoc). Sets DELIM_END. ────────────
function handle_heredoc(parent, ctx, seg_start, oppos, depth,
                        headtext_s, headtext_e, ti, t, prog_s, prog_e, base,
                        op3, is_herestring, afterop, delim, k, lstart, line, n, iid) {
  headtext_s = seg_start; headtext_e = oppos
  tokenize(headtext_s, headtext_e); ti = 1
  while (ti <= TN) {
    t = substr(SB, TS[ti]+1, TE[ti]-TS[ti])
    if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || t == "command" || t == "builtin" || t == "exec" || t == "env") { ti++; continue }
    break
  }
  base = ""
  if (ti <= TN) { prog_s = TS[ti]; prog_e = TE[ti]; if (!tok_computed(prog_s, prog_e)) base = basename(unquote(prog_s, prog_e)) }
  op3 = ch(oppos+2); is_herestring = (op3 == "<") ? 1 : 0
  afterop = (is_herestring == 1) ? oppos+3 : oppos+2
  if (is_herestring == 0 && ch(afterop) == "-") afterop++
  if (base == "bash" || base == "sh" || base == "dash" || base == "zsh" || base == "ksh" || base == "eval") {
    iid = emit(parent, "HERE_DOCUMENT_EXECUTION", seg_start, oppos, 1, 0, 0, "OPAQUE")
    if (iid >= 0) { emit_exec(iid, base); emit_reason(iid, RC["heredoc-shell"]) }
  } else {
    analyze_simple(parent, ctx, seg_start, oppos, depth)
  }
  if (is_herestring == 1) { DELIM_END = afterop; return }
  # here-DOC: recover the delimiter token, then skip body lines up to and including the delimiter line.
  tokenize(afterop, SN)
  delim = ""
  if (TN >= 1) delim = unquote(TS[1], TE[1])
  if (delim == "") { ABORT = "OPAQUE"; ABORT_R = RC["heredoc-nodelim"]; DELIM_END = SN; return }
  k = afterop; n = SN
  while (k < n && ch(k) != "\n") k++
  k++                                            # first body char
  lstart = k
  while (k <= n) {
    if (k == n || ch(k) == "\n") {
      line = substr(SB, lstart+1, k-lstart)
      sub(/^[ \t]+/, "", line)                   # <<- trims leading tabs (harmless for <<)
      sub(/\r$/, "", line)                        # strip trailing CR (Windows)
      if (line == delim) { DELIM_END = k+1; return }
      lstart = k+1
    }
    k++
  }
  DELIM_END = n
}

# ── CORE recursive scanner: scans SB[lo..hi) in context $ctx under $parent at $depth. Faithful port of
# _pfg_ss_scan. Splits into command positions on the separators it can see, recurses into grouping/
# substitution/control bodies, analyzes each leaf simple command. Sets ABORT on a budget breach. ─────────
function scan(parent, ctx, lo, hi, depth,
              i, c, nx, nn, st, seg_start, cmdpos, wordstart, kw, kc, sub_close, subctx, pctx, seen_do, seen_in, qc) {
  if (ABORT != "") return
  if (depth > MAXDEPTH) { ABORT = "DEPTH_LIMIT"; ABORT_R = RC["depth"]; return }
  i = lo; st = 0; seg_start = lo; cmdpos = 1; wordstart = 1
  while (i < hi) {
    if (ABORT != "") return
    c = ch(i); nx = ch(i+1); nn = ch(i+2)
    if (st == 0) {
      if (c == "\\") { i += 2; cmdpos = 0; wordstart = 0; continue }
      else if (c == "'") { st = 1; i++; cmdpos = 0; wordstart = 0; continue }
      else if (c == "\"") { st = 2; i++; cmdpos = 0; wordstart = 0; continue }
      else if (c == "#") {
        if (wordstart == 1) { do_flush(parent, ctx, depth, seg_start, i); while (i < hi && ch(i) != "\n") i++; seg_start = i; continue }
        i++; cmdpos = 0; wordstart = 0; continue
      }
      else if (c == ";" || c == "&") {
        do_flush(parent, ctx, depth, seg_start, i)
        if (c == ";" && nx == ";") i++
        i++; seg_start = i; cmdpos = 1; wordstart = 1; continue
      }
      else if (c == "|") {
        do_flush(parent, ctx, depth, seg_start, i)
        if (nx == "|") i++
        i++; seg_start = i; cmdpos = 1; wordstart = 1; continue
      }
      else if (c == "`") {
        recurse_delim(parent, "BACKTICK_SUBSTITUTION", i, depth); if (ABORT != "") return
        i = DELIM_END; cmdpos = 0; wordstart = 0; continue
      }
      else if (c == "$") {
        if (nx == "(") {
          if (nn == "(") { skip_arith(i+1); if (ABORT != "") return; i = DELIM_END; cmdpos = 0; wordstart = 0; continue }
          recurse_paren(parent, "COMMAND_SUBSTITUTION", i+2, depth); if (ABORT != "") return
          i = DELIM_END; cmdpos = 0; wordstart = 0; continue
        }
        if (nx == "{") { skip_braceparam(i+2); if (ABORT != "") return; i = DELIM_END; cmdpos = 0; wordstart = 0; continue }
        i++; cmdpos = 0; wordstart = 0; continue
      }
      else if (c == "(" || c == "{") {
        if (c == "(" && nx == "(") { skip_arith(i); if (ABORT != "") return; i = DELIM_END; cmdpos = 0; wordstart = 0; continue }
        if (cmdpos == 1) {
          do_flush(parent, ctx, depth, seg_start, i)
          if (c == "(") { recurse_paren(parent, "SUBSHELL", i+1, depth) }
          else { recurse_brace(parent, "BRACE_GROUP", i+1, depth) }
          if (ABORT != "") return
          i = DELIM_END; seg_start = i; cmdpos = 0; wordstart = 0; continue
        }
        i++; cmdpos = 0; wordstart = 0; continue
      }
      else if (c == "<" || c == ">") {
        if (nx == "(") {
          pctx = (c == ">") ? "PROCESS_SUBSTITUTION_OUT" : "PROCESS_SUBSTITUTION_IN"
          recurse_paren(parent, pctx, i+2, depth); if (ABORT != "") return
          i = DELIM_END; cmdpos = 0; wordstart = 0; continue
        }
        if (c == "<" && nx == "<") {
          handle_heredoc(parent, ctx, seg_start, i, depth); if (ABORT != "") return
          i = DELIM_END; seg_start = i; cmdpos = 1; wordstart = 1; continue
        }
        i++; cmdpos = 0; wordstart = 0; continue
      }
      else if (c == " " || c == "\t") { i++; wordstart = 1; continue }
      else if (c == "\n") { do_flush(parent, ctx, depth, seg_start, i); i++; seg_start = i; cmdpos = 1; wordstart = 1; continue }
      else if (c == ")") { seg_start = i+1; i++; cmdpos = 1; wordstart = 1; continue }
      else {
        if (cmdpos == 1 && wordstart == 1) {
          peek_keyword(i, hi); kw = R_KW
          if (kw != "") {
            do_flush(parent, ctx, depth, seg_start, i)
            if (kw == "for") {
              i += 3; seen_do = 0
              while (i < hi) {
                peek_keyword(i, hi); if (R_KW == "do") { i += 2; seen_do = 1; break }
                qc = ch(i)
                if (qc == "'") { i++; while (i < hi && ch(i) != "'") i++ }
                else if (qc == "\"") { i++; while (i < hi && ch(i) != "\"") { if (ch(i) == "\\") i++; i++ } }
                i++
              }
              seg_start = i; cmdpos = 1; wordstart = 1; ctx = "FOR_BODY"; continue
            }
            else if (kw == "case") {
              i += 4; seen_in = 0
              while (i < hi) {
                peek_keyword(i, hi); if (R_KW == "in") { i += 2; seen_in = 1; break }
                qc = ch(i)
                if (qc == "'") { i++; while (i < hi && ch(i) != "'") i++ }
                else if (qc == "\"") { i++; while (i < hi && ch(i) != "\"") { if (ch(i) == "\\") i++; i++ } }
                i++
              }
              seg_start = i; cmdpos = 1; wordstart = 1; ctx = "CASE_BODY"; continue
            }
            else {
              i += length(kw); seg_start = i; cmdpos = 1; wordstart = 1
              kc = keyword_ctx(kw); if (kc != "") ctx = kc
              continue
            }
          }
        }
        i++; cmdpos = 0; wordstart = 0; continue
      }
    }
    else if (st == 1) { if (c == "'") st = 0; i++; continue }
    else if (st == 2) {
      if (c == "\\") { i += 2; continue }
      else if (c == "\"") { st = 0; i++; continue }
      else if (c == "`") { recurse_delim(parent, "BACKTICK_SUBSTITUTION", i, depth); if (ABORT != "") return; i = DELIM_END; continue }
      else if (c == "$") {
        if (nx == "(") {
          if (nn == "(") { skip_arith(i+1); if (ABORT != "") return; i = DELIM_END; continue }
          recurse_paren(parent, "COMMAND_SUBSTITUTION", i+2, depth); if (ABORT != "") return; i = DELIM_END; continue
        }
        i++; continue
      }
      else { i++; continue }
    }
  }
  if (st == 1 || st == 2) { ABORT = "OPAQUE"; ABORT_R = RC["unterminated-quote"]; return }
  do_flush(parent, ctx, depth, seg_start, hi)
}

BEGIN {
  # ── TRANSPORT: the command arrives RAW on stdin (one record; the wrapper sends it with LC_ALL=C and, for
  # gawk, -v BINMODE=3 so Windows CRLF→LF text-mode translation is disabled and bytes are exact — without
  # that, a `\r` in the command is stripped and offsets shift, found by the differential fuzzer). RS=0x1C
  # (a byte that does not appear in normal shell commands) makes one record = an exact slurp.
  RS = "\034"; ORS = ""
  setup_enums()
  # SELF-ENFORCED BYTE SEMANTICS (do NOT trust the caller): byte-exact offsets and the %c-built ORD table
  # require byte (not multibyte-character) semantics. The wrapper sets LC_ALL=C, but a future/direct caller
  # might not. Detect character-mode directly and FAIL CLOSED (emit an ERROR terminal, never a wrong IR): a
  # 2-byte UTF-8 sequence must measure length 2 under byte semantics; if it measures 1, awk is in char mode.
  if (length("\303\251") != 2) { print "V 1\n"; printf "M 65536 256 8\n"; printf "O %d 0\n", ST["ERROR"]; printf "E 0 %d\n", ST["ERROR"]; exit 0 }
  for (b = 1; b < 256; b++) ORD[sprintf("%c", b)] = b   # byte→ordinal for injection-safe hex token transport
  BUF = ""
  # exact slurp. A literal 0x1C in the command would split it into >1 record; reassembling WITHOUT the
  # separator would silently drop the byte and shift every downstream offset — so FAIL CLOSED on NR>1 rather
  # than emit a corrupted (offset-shifted, possibly structure-altered) forest. 0x1C in a real command is
  # exotic; a wrong forest is worse than an honest ERROR.
  while ((getline line) > 0) { if (NR > 1) { print "V 1\n"; printf "M 65536 256 8\n"; printf "O %d 0\n", ST["ERROR"]; printf "E 0 %d\n", ST["ERROR"]; exit 0 } BUF = BUF line }
  N = length(BUF)
  MAXBYTES = (MAXBYTES+0 > 0) ? MAXBYTES+0 : 65536
  MAXNODES = (MAXNODES+0 > 0) ? MAXNODES+0 : 256
  MAXDEPTH = (MAXDEPTH+0 > 0) ? MAXDEPTH+0 : 8
  print "V 1\n"
  printf "M %d %d %d\n", MAXBYTES, MAXNODES, MAXDEPTH
  NODES = 0; ABORT = ""; ABORT_R = 0; LAST_ID = -1
  if (N > MAXBYTES) { printf "O %d 0\n", ST["SIZE_LIMIT"]; printf "E %d %d\n", NODES, ST["SIZE_LIMIT"]; exit 0 }
  SB = BUF; SN = N
  scan(-1, "TOPLEVEL", 0, N, 0)
  if (ABORT != "") { printf "O %d %d\n", ST[ABORT], ABORT_R; printf "E %d %d\n", NODES, ST[ABORT]; exit 0 }
  printf "E %d %d\n", NODES, ST["OK"]
  exit 0
}
