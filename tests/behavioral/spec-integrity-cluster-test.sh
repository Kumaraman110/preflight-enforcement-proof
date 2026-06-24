#!/usr/bin/env bash
# Behavioral test for the spec-integrity-check.sh cluster: M4 + H5 + M7 (one file, three interacting fixes).
#
# THE THREE FINDINGS (FRAMEWORK-SCRUTINY-FINDINGS + MEDIUM-FIXES-DESIGN.md Cluster A):
#   M4 (fail-open, silent-absence): a source dir with ZERO .cs files left every SOURCE_* empty -> both
#       directions skipped -> "PASSED" exit 0. "Nothing to compare" read as "verified". FIX: a could-not-
#       verify FAIL fires when the spec declares an anchor of a type but the source has no .cs.
#   H5 (fail-open): the source->spec FORGE-CATCH inner-guarded each block on [ -n "$SPEC_* ], so an empty
#       (or empty-category) spec SKIPPED the catch -> the most aggressive forge (drop the whole category)
#       passed GREEN. FIX: drop the inner guard so the catch fires whenever SOURCE has anchors regardless
#       of whether SPEC has any (empty SPEC_* means "every source anchor is missing", not "skip").
#   M7 (over-block, correctness): the MODEL_FIELDS regex matched a K&R `public class Foo {` decl line and
#       harvested the class name `Foo` as a phantom field -> false-FAIL on an honest spec. FIX: a negative-
#       match drops class/interface/struct/enum/record decl lines before the field-name capture.
#
# THE LOAD-BEARING 3-WAY GUARD: after all three, a REAL source property OMITTED from the spec must STILL
# FAIL source->spec — proving M7's narrowing of MODEL_FIELDS did not blunt H5's now-unguarded forge-catch.
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SIC="$ROOT/lib/spec-integrity-check.sh"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

[ -f "$SIC" ] || { bad "missing $SIC"; echo ""; echo "spec-integrity-cluster tests: ${PASS} passed, ${FAIL} failed"; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# rc <spec.json> <src-dir> -> echoes the exit code
rc() { bash "$SIC" "$1" "$2" >/dev/null 2>&1; echo $?; }
# out <spec.json> <src-dir> -> echoes stdout+stderr. Captured into a var by callers (NOT piped directly to
# grep -q): a `bash … | grep -q` pipeline can SIGPIPE the producer when grep matches+exits early, which on
# this spawn-taxed box intermittently drops the captured text. Capturing first is race-free.
out() { local o; o="$(bash "$SIC" "$1" "$2" 2>&1)" || true; printf '%s' "$o"; }
# msg_has <spec> <src> <pattern> -> 0 if the gate's output contains <pattern> (captured, no pipe race)
msg_has() { local o; o="$(out "$1" "$2")"; printf '%s' "$o" | grep -qi "$3"; }

# ── shared sources ───────────────────────────────────────────────────────────
ZEROCS="$T/zerocs"; mkdir -p "$ZEROCS"; printf 'readme, no source here\n' > "$ZEROCS/readme.txt"
EMPTYDIR="$T/emptydir"; mkdir -p "$EMPTYDIR"
# A real .cs source emitting two result codes, two procs, two routes, two model props.
REALSRC="$T/realsrc"; mkdir -p "$REALSRC"
cat > "$REALSRC/Controller.cs" <<'CS'
public class Controller {
    [Route("api/token")]
    public void Get() {
        var a = "E0001";
        var b = "E9999";
        Db.Run("cpsl_getToken");
        Db.Run("cpsl_refresh");
    }
}
CS
cat > "$REALSRC/TokenResponse.cs" <<'CS'
public class TokenResponse {
    public string Token { get; set; }
    public int ExpiresIn { get; set; }
    public List<string> Scopes { get; set; }
    public bool IsActive { get; set; }
}
CS

echo "════════ M4 — zero-.cs source + spec declaring an anchor -> could-not-verify FAIL ════════"
printf '{"result_codes":["E1001"]}'                         > "$T/m4_code.json"
printf '{"fields":[{"field":"TokenValue"}]}'                > "$T/m4_field.json"
printf '{"procs":["cpsl_GetCaller"]}'                       > "$T/m4_proc.json"
printf '{"routes":[{"path":"api/caller"}]}'                 > "$T/m4_route.json"
for kv in "result_code:m4_code" "wire_contract/field:m4_field" "proc:m4_proc" "route:m4_route"; do
  label="${kv%%:*}"; f="${kv##*:}"
  r=$(rc "$T/$f.json" "$ZEROCS")
  [ "$r" = 1 ] && ok "M4 $label declared + zero-.cs source -> FAIL exit 1 (could-not-verify)" \
               || bad "M4 $label zero-.cs: expected FAIL(1), got $r"
done
# empty source DIR variant (no readme even) — same could-not-verify
[ "$(rc "$T/m4_code.json" "$EMPTYDIR")" = 1 ] && ok "M4 empty source dir variant -> FAIL exit 1" \
                                              || bad "M4 empty source dir: expected FAIL(1)"
# the could-not-verify message is surfaced
msg_has "$T/m4_code.json" "$ZEROCS" 'could-not-verify' \
  && ok "M4: the FAIL names 'could-not-verify' (honest message, not a generic mismatch)" \
  || bad "M4: missing could-not-verify message"
echo "──── M4 NO-FALSE-POSITIVE (must stay PASS exit 0) ────"
printf '{}' > "$T/m4_anchorless.json"
[ "$(rc "$T/m4_anchorless.json" "$ZEROCS")" = 0 ] && ok "M4-NFP anchorless spec {} + zero-.cs -> PASS exit 0" \
                                                  || bad "M4-NFP anchorless+zero-.cs: expected PASS(0)"
# A real spec that MATCHES the real source must still PASS (HAS_CS=true path unchanged).
printf '{"result_codes":["E0001","E9999"],"fields":[{"field":"Token"},{"field":"ExpiresIn"},{"field":"Scopes"},{"field":"IsActive"}],"procs":["cpsl_getToken","cpsl_refresh"],"routes":[{"path":"api/token"}]}' > "$T/m4_realmatch.json"
[ "$(rc "$T/m4_realmatch.json" "$REALSRC")" = 0 ] && ok "M4-NFP real spec + matching real .cs source -> PASS exit 0" \
                                                  || bad "M4-NFP real-match: expected PASS(0), got $(rc "$T/m4_realmatch.json" "$REALSRC"); OUT=$(out "$T/m4_realmatch.json" "$REALSRC" | tr '\n' '|')"

echo "════════ H5 — empty/empty-category spec vs real source with anchors -> forge-catch FIRES ════════"
# THE H5 case M4 does NOT cover: .cs IS present (HAS_CS=true), but the spec is empty -> the source->spec
# forge-catch must still fire (was skipped by the inner [ -n "$SPEC_*" ] guard).
printf '{}' > "$T/h5_empty.json"
r=$(rc "$T/h5_empty.json" "$REALSRC")
[ "$r" = 1 ] && ok "H5 empty spec {} vs real .cs source emitting codes/procs/routes/props -> FAIL exit 1 (forge caught)" \
             || bad "H5 empty-spec vs real source: expected FAIL(1), got $r"
msg_has "$T/h5_empty.json" "$REALSRC" 'possible forge' \
  && ok "H5: the FAIL names 'possible forge' (source->spec catch fired)" \
  || bad "H5: missing 'possible forge' message — catch did not fire"
# Empty-CATEGORY: spec populates fields but result_codes:[] — the dropped code category must be caught.
printf '{"result_codes":[],"fields":[{"field":"Token"},{"field":"ExpiresIn"},{"field":"Scopes"},{"field":"IsActive"}],"procs":["cpsl_getToken","cpsl_refresh"],"routes":[{"path":"api/token"}]}' > "$T/h5_emptycat.json"
r=$(rc "$T/h5_emptycat.json" "$REALSRC")
[ "$r" = 1 ] && ok "H5 empty-CATEGORY (result_codes:[] but source emits E0001/E9999) -> FAIL exit 1" \
             || bad "H5 empty-category: expected FAIL(1), got $r"

echo "════════ M7 — K&R 'public class Foo {' must NOT yield a phantom field ════════"
# Honest spec: declares the four REAL fields of TokenResponse, NOT the class name. Source uses K&R brace.
printf '{"fields":[{"field":"Token"},{"field":"ExpiresIn"},{"field":"Scopes"},{"field":"IsActive"}],"result_codes":["E0001","E9999"],"procs":["cpsl_getToken","cpsl_refresh"],"routes":[{"path":"api/token"}]}' > "$T/m7_honest.json"
r=$(rc "$T/m7_honest.json" "$REALSRC")
[ "$r" = 0 ] && ok "M7 honest spec (real fields) + K&R 'public class TokenResponse {' -> PASS exit 0 (no phantom)" \
             || bad "M7 honest spec: expected PASS(0), got $r; OUT=$(out "$T/m7_honest.json" "$REALSRC" | tr '\n' '|')"
# Extraction unit: a fixture with all five decl keywords (K&R) + two real fields; the class names must NOT
# appear as flagged phantom fields, the real fields must (when omitted from spec) be catchable.
KW="$T/kwsrc"; mkdir -p "$KW"
cat > "$KW/AllKindsModel.cs" <<'CS'
public class FooResponse {
public interface IBarResponse {
public struct BazModel {
public enum QuxModel {
public record QuuxResponse {
    public string RealFieldA { get; set; }
    public int RealFieldB { get; set; }
    public ClassRoom Building { get; set; }
    public Record Recorder { get; set; }
}
CS
# Spec declares the real fields + the keyword-prefixed-type fields -> nothing should be flagged as a forge.
printf '{"fields":[{"field":"RealFieldA"},{"field":"RealFieldB"},{"field":"Building"},{"field":"Recorder"}]}' > "$T/m7_kw.json"
r=$(rc "$T/m7_kw.json" "$KW")
[ "$r" = 0 ] && ok "M7 extraction: class/interface/struct/enum/record decl names NOT phantom; keyword-prefixed-type fields (ClassRoom Building, Record Recorder) KEPT -> PASS" \
             || bad "M7 extraction: expected PASS(0) (no phantom, real+keyword-prefixed fields kept), got $r; OUT=$(out "$T/m7_kw.json" "$KW" | tr '\n' '|')"

echo "════════ THE 3-WAY REGRESSION GUARD (most important) ════════"
# A REAL source property (IsActive) OMITTED from the spec must STILL FAIL source->spec after M7's narrowing.
# This proves M7 removed only phantom class names, not real fields — H5's catch still polices real props.
printf '{"fields":[{"field":"Token"},{"field":"ExpiresIn"},{"field":"Scopes"}],"result_codes":["E0001","E9999"],"procs":["cpsl_getToken","cpsl_refresh"],"routes":[{"path":"api/token"}]}' > "$T/guard_omit.json"
r=$(rc "$T/guard_omit.json" "$REALSRC")
GUARD_OUT="$(out "$T/guard_omit.json" "$REALSRC")"
if [ "$r" = 1 ] && printf '%s' "$GUARD_OUT" | grep -qi "property 'IsActive'"; then
  ok "3-WAY GUARD: a REAL property (IsActive) omitted from the spec STILL FAILs source->spec after M4+H5+M7"
else
  bad "3-WAY GUARD: omitted real field must FAIL(1) naming IsActive — got $r; OUT=$(printf '%s' "$GUARD_OUT" | tr '\n' '|')"
fi

echo ""
echo "spec-integrity-cluster tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
