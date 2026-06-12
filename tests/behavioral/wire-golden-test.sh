#!/usr/bin/env bash
# Behavioral test for lib/generate-wire-golden-test.sh (WIRE-B, issue #5 mechanical close).
#
# Proves with a REAL dotnet build + run (not reasoning) that the generated
# golden test catches the three runtime-serialization divergences WIRE-A could
# only infer:
#   B1. GREEN baseline: types serialized under the LEGACY-equivalent options
#       (camelCase + WhenWritingNull) are byte-equal to the captured golden → exit 0.
#   B2. RED naming: the SAME runner under migrated-default options (PascalCase)
#       diverges → exit 1, divergence names the Naming case.
#   B3. RED null-emission: same migrated-default run also fails the
#       NullEmission case (null property appears in bytes) — proves the
#       null-policy dimension is MECHANICAL here (subsumes WIRE-A's inferred
#       null_emitted with runtime evidence).
#   B4. RED field-ordering: a golden with swapped field order diverges even
#       under legacy options → exit 1 (byte comparison is order-sensitive).
#   B5. Generator validation: a contract missing required fields → exit 2.
#   B6. xunit emission mode produces a [Fact]-bearing class (structural).
#
# REQUIRES the dotnet SDK. If absent, every dotnet-backed assertion reports
# SKIP-DOTNET and the suite exits 0 with a loud warning — an environment
# without the SDK cannot certify WIRE-B (honest skip, never a silent pass of
# the wrong thing). The generator-validation and xunit-structural checks (B5,
# B6) run regardless.
#
# Exit 0 = all runnable assertions passed; exit 1 = any failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GEN="$ROOT/lib/generate-wire-golden-test.sh"
CONTRACT="$ROOT/tests/fixtures/wire-golden/wire-golden.json"
CONTRACT_REORDERED="$ROOT/tests/fixtures/wire-golden/wire-golden-reordered.json"

PASS=0; FAIL=0; SKIP=0
ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }
skp()  { echo "SKIP-DOTNET: $1"; SKIP=$((SKIP+1)); }

for f in "$GEN" "$CONTRACT" "$CONTRACT_REORDERED"; do
  [ -f "$f" ] || { bad "missing $f"; echo ""; echo "wire-golden tests: ${PASS} passed, ${FAIL} failed"; exit 1; }
done

# ── B5: generator validation (no dotnet needed) ───────────────────────────────
TMP="$(mktemp -d)"
printf '%s\n' '{ "options_accessor": "X.Y", "cases": [ { "name": "n", "type": "T" } ] }' > "$TMP/bad.json"
bash "$GEN" "$TMP/bad.json" "$TMP/out.cs" >/dev/null 2>&1; RC=$?
if [ "$RC" -eq 2 ]; then
  ok "B5 generator rejects contract with missing case fields (exit 2)"
else bad "B5 expected exit 2 on bad contract, got $RC"; fi

# ── B6: xunit emission (structural, no dotnet needed) ────────────────────────
bash "$GEN" "$CONTRACT" "$TMP/xunit.cs" --runner xunit >/dev/null 2>&1; RC=$?
if [ "$RC" -eq 0 ] && grep -q '\[Fact\]' "$TMP/xunit.cs" && grep -q 'class WireGoldenTests' "$TMP/xunit.cs"; then
  ok "B6 xunit mode emits a [Fact]-bearing WireGoldenTests class"
else bad "B6 xunit emission failed (rc=$RC)"; fi

# ── dotnet-backed assertions ──────────────────────────────────────────────────
if ! command -v dotnet >/dev/null 2>&1; then
  skp "dotnet SDK not found — B1-B4 (build+run certification) cannot run here"
  echo ""
  echo "wire-golden tests: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped (DOTNET REQUIRED for full certification)"
  rm -rf "$TMP"
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

PROJ="$TMP/proj"
mkdir -p "$PROJ"
cat > "$PROJ/wiregolden.csproj" <<'EOF'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
    <Nullable>enable</Nullable>
    <AssemblyName>wiregolden</AssemblyName>
  </PropertyGroup>
</Project>
EOF

# Types + the options accessor. WIRE_MODE env var selects which serializer
# config "the service" uses — modeling legacy (camelCase + WhenWritingNull)
# vs a migrated service that forgot to configure (STJ defaults: PascalCase,
# nulls included) — the EXACT PR #95 break, without a recompile per mode.
cat > "$PROJ/Types.cs" <<'EOF'
using System;
using System.Text.Json;
using System.Text.Json.Serialization;

public class TokenResponse
{
    public string? ResultCode { get; set; }
    public string? SessionToken { get; set; }
}

public class OrderedResponse
{
    public string? Alpha { get; set; }
    public string? Beta { get; set; }
}

namespace WireGolden
{
    public static class ServiceWireOptions
    {
        public static JsonSerializerOptions Options =>
            Environment.GetEnvironmentVariable("WIRE_MODE") == "legacy"
                ? new JsonSerializerOptions
                  {
                      PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
                      DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
                  }
                : new JsonSerializerOptions(); // migrated-default: PascalCase, nulls included
    }
}
EOF

bash "$GEN" "$CONTRACT" "$PROJ/Program.cs" >/dev/null 2>&1 || { bad "generator failed on main contract"; exit 1; }

if ! BUILD_OUT=$(dotnet build "$PROJ/wiregolden.csproj" -v q --nologo 2>&1); then
  bad "dotnet build failed: $(echo "$BUILD_OUT" | tail -5)"
  echo ""; echo "wire-golden tests: ${PASS} passed, ${FAIL} failed"; rm -rf "$TMP"; exit 1
fi
DLL=$(find "$PROJ/bin" -name wiregolden.dll | head -1)

# B1 GREEN: legacy-equivalent options → byte-equal.
OUT=$(WIRE_MODE=legacy dotnet "$DLL" 2>&1); RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "all cases byte-equal"; then
  ok "B1 GREEN: legacy-config serialization is byte-equal to golden (exit 0)"
else bad "B1 expected exit 0 byte-equal, got RC=$RC OUT=$OUT"; fi

# B2+B3 RED: migrated-default options → naming AND null-emission divergence.
OUT=$(WIRE_MODE=migrated dotnet "$DLL" 2>&1); RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "WIRE DIVERGENCE \[Naming_ResultCode\]"; then
  ok "B2 RED: PascalCase-vs-camelCase divergence caught (Naming_ResultCode)"
else bad "B2 expected naming divergence, got RC=$RC OUT=$OUT"; fi
if printf '%s' "$OUT" | grep -q "WIRE DIVERGENCE \[NullEmission_OptionalOmitted\]"; then
  ok "B3 RED: WhenWritingNull-vs-include divergence caught (NullEmission) — null policy is MECHANICAL here"
else bad "B3 expected null-emission divergence, got OUT=$OUT"; fi

# B4 RED: ordering — reordered golden diverges even under legacy options.
PROJ2="$TMP/proj2"; mkdir -p "$PROJ2"
cp "$PROJ/wiregolden.csproj" "$PROJ2/"; cp "$PROJ/Types.cs" "$PROJ2/"
bash "$GEN" "$CONTRACT_REORDERED" "$PROJ2/Program.cs" >/dev/null 2>&1 || { bad "generator failed on reordered contract"; exit 1; }
if ! dotnet build "$PROJ2/wiregolden.csproj" -v q --nologo >/dev/null 2>&1; then
  bad "B4 build failed"
else
  DLL2=$(find "$PROJ2/bin" -name wiregolden.dll | head -1)
  OUT=$(WIRE_MODE=legacy dotnet "$DLL2" 2>&1); RC=$?
  if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "WIRE DIVERGENCE \[Ordering_Swapped\]"; then
    ok "B4 RED: field-ordering drift caught (byte comparison is order-sensitive)"
  else bad "B4 expected ordering divergence, got RC=$RC OUT=$OUT"; fi
fi

rm -rf "$TMP"
echo ""
echo "wire-golden tests: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
[ "$FAIL" -eq 0 ]
