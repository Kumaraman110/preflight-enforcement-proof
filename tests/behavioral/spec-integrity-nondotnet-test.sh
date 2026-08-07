#!/usr/bin/env bash
# spec-integrity-nondotnet-test.sh — G3 proof: the spec<->source anti-forgery GUARANTEE applies to a
# NON-.NET (python) stack via the source-language profile, WITHOUT weakening it (the per-category
# could-not-verify fail-closed closes the generalization fail-open trap).
#
# Proves, deterministically (bash + grep/awk, no network):
#   1. CLEAN non-.NET fixture PASSES  (exit 0) — spec matches the python source's emitted codes.
#   2. FORGE non-.NET fixture FAILS   (exit 1) — spec deleted E0005 but the python source still emits it;
#      the source->spec forge-catch fires (criterion 2). [Before G3 the *.cs-only glob saw nothing here
#      and passed green — the fail-open this closes.]
#   3. COULD-NOT-VERIFY fail-closed   (exit 1) — a spec declaring codes against a dir with no recognizable
#      source (only a README) FAILS as could-not-verify, never "nothing to compare" -> green (criterion 3).
#   4. THE FAIL-OPEN TRAP: a spec declaring an UNSUPPORTED category (wire_contract) on the python profile
#      FAILS could-not-verify, rather than silently skipping the source->spec forge-catch for a category
#      the profile can't read. This is the guard that keeps generalization from weakening the guarantee.
#   5. REGRESSION: the .NET path is byte-identical — the existing dotnet fixtures still behave correctly
#      (clean passes, forge fails) under the default profile.
#
# Exit 0 = all passed. Isolated: reads fixtures under tests/behavioral/fixtures/spec-integrity-nondotnet.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CHECK="$ROOT/lib/spec-integrity-check.sh"
FIX="$HERE/fixtures/spec-integrity-nondotnet"
PASS=0; FAIL=0
ok(){ echo "PASS: $1"; PASS=$((PASS+1)); }
bad(){ echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }
trailer(){ echo ""; echo "spec-integrity-nondotnet: ${PASS} passed, ${FAIL} failed"; [ "$FAIL" -eq 0 ]; }
[ -f "$CHECK" ] || { bad "spec-integrity-check.sh missing"; trailer; exit $?; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# run <spec> <source-dir> <src-lang> -> echoes exit code
run(){ bash "$CHECK" "$1" "$2" "$3" >"$TMP/out.txt" 2>&1; echo $?; }

# 1. CLEAN python fixture -> PASS (exit 0)
rc="$(run "$FIX/spec-clean.json" "$FIX/pysrc" python)"
[ "$rc" = 0 ] && ok "non-.NET CLEAN spec passes (exit 0) — guarantee applies to python source" \
  || bad "non-.NET clean spec did not pass (rc=$rc): $(tr -d '\n' <"$TMP/out.txt"|head -c 200)"

# 2. FORGE python fixture -> FAIL (exit 1) with a source->spec forge-catch on E0005
rc="$(run "$FIX/spec-forge.json" "$FIX/pysrc" python)"
if [ "$rc" = 1 ] && grep -q 'source→spec' "$TMP/out.txt" && grep -q 'E0005' "$TMP/out.txt"; then
  ok "non-.NET FORGE caught (source→spec: E0005 emitted in python source but deleted from spec)"
else
  bad "non-.NET forge NOT caught (rc=$rc — pre-G3 fail-open): $(tr -d '\n' <"$TMP/out.txt"|head -c 200)"
fi

# 3. COULD-NOT-VERIFY: spec declares codes, source dir has no recognizable python source -> FAIL exit 1
rc="$(run "$FIX/spec-clean.json" "$FIX/nosrc" python)"
if [ "$rc" = 1 ] && grep -q 'could-not-verify' "$TMP/out.txt"; then
  ok "could-not-verify fail-closed (no recognizable source → FAIL, not 'nothing to compare' → green)"
else
  bad "could-not-verify did NOT fail-close (rc=$rc): $(tr -d '\n' <"$TMP/out.txt"|head -c 200)"
fi

# 4. FAIL-OPEN TRAP: a spec declaring an UNSUPPORTED category on the python profile must FAIL
# could-not-verify, not silently skip. Build a spec that declares a wire field (a category the python
# profile has no extractor for) against the python source.
cat > "$TMP/spec-wire.json" <<'JSON'
{ "service": "x", "wire_contract": [ { "field": "SessionToken" } ] }
JSON
rc="$(run "$TMP/spec-wire.json" "$FIX/pysrc" python)"
if [ "$rc" = 1 ] && grep -q 'wire_contract could-not-verify' "$TMP/out.txt"; then
  ok "unsupported-category (wire_contract on python) FAILS could-not-verify (fail-open trap closed)"
else
  bad "unsupported category silently skipped instead of could-not-verify FAIL (rc=$rc): $(tr -d '\n' <"$TMP/out.txt"|head -c 200)"
fi

# 5. REGRESSION — the .NET path is unchanged. Reuse the shipped verifier/rules fixtures indirectly by
# constructing a tiny dotnet source + spec: a clean .NET case must pass, a forge must fail, under default.
DNET="$TMP/dnet"; mkdir -p "$DNET"
cat > "$DNET/Svc.cs" <<'CS'
public class Svc { public void M() { var r = new Model(); r.ResultCode = "E0005"; } }
CS
cat > "$TMP/dnet-clean.json" <<'JSON'
{ "service": "x", "result_codes": [ { "code": "E0005" } ] }
JSON
cat > "$TMP/dnet-forge.json" <<'JSON'
{ "service": "x", "result_codes": [] }
JSON
rc_clean="$(run "$TMP/dnet-clean.json" "$DNET" dotnet)"
rc_forge="$(run "$TMP/dnet-forge.json" "$DNET" dotnet)"
if [ "$rc_clean" = 0 ] && [ "$rc_forge" = 1 ]; then
  ok ".NET path unchanged (default profile: clean passes, forge of E0005 fails)"
else
  bad ".NET regression (clean rc=$rc_clean expect 0; forge rc=$rc_forge expect 1)"
fi

trailer
