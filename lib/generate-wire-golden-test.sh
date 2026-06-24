#!/usr/bin/env bash
# generate-wire-golden-test.sh — WIRE-B generator (issue #5, the mechanical close).
#
# Usage:
#   bash lib/generate-wire-golden-test.sh <wire-golden.json> <output.cs> [--runner console|xunit]
#     wire-golden.json  the captured wire contract (shape below)
#     output.cs         the generated C# golden test (console runner by default;
#                       --runner xunit emits an xunit test class for consumer test projects)
#
# Exit: 0 = generated · 2 = usage/validation error (missing fields, bad JSON)
#
# ── WHAT THIS CLOSES (and what WIRE-A could not) ─────────────────────────────
# WIRE-A (spec-level) COMPUTES serialized names by applying a captured naming
# policy — labeled INFERRED/prompt-level because the LLM performs the
# transform. WIRE-B is the MECHANICAL close: the generated test serializes a
# real instance through the service's ACTUAL configured JsonSerializerOptions
# and ORDINAL-BYTE-COMPARES the output against the captured legacy wire string.
# One comparison covers all three residual dimensions:
#   - property NAMING (camelCase vs PascalCase, attribute overrides)
#   - NULL-EMISSION policy (WhenWritingNull vs include — a null sample property
#     either appears in the bytes or doesn't)
#   - FIELD ORDERING (byte equality is order-sensitive; a reordered declaration
#     or JsonPropertyOrder change moves bytes)
# It also corroborates WIRE-A's inferred null_emitted/serialized_name
# observables with runtime evidence when both are wired.
#
# HONESTY LABEL: MECHANICAL but STACK-BOUND (.NET / System.Text.Json) and
# GOLDEN-BOUND — it proves byte-parity against the CAPTURED legacy strings.
# If the golden was captured wrong (e.g. from a stale legacy build), the test
# faithfully enforces the wrong bytes; golden capture provenance is recorded in
# the contract file ("captured_from") and is a human-verified input, not
# something this generator can authenticate. The migrate skill emits this as a
# Phase-2 deliverable; the shipped CI template runs it as a BLOCKING step
# (wire-fidelity failure fails the build). Promotion to required is a human
# call (Class-B); generation itself is Class-A.
#
# ── wire-golden.json shape ───────────────────────────────────────────────────
# {
#   "captured_from": "legacy CTIAPI @ <sha-or-build>, endpoint <route>",
#   "options_accessor": "WireGolden.ServiceWireOptions.Options",
#   "cases": [
#     {
#       "name": "SessionTokenResponse_v1_happy",
#       "type": "SessionTokenResponse",
#       "sample": { "resultCode": "S0000", "sessionToken": "abc" },
#       "golden": "{\"resultCode\":\"S0000\",\"sessionToken\":\"abc\"}"
#     }
#   ]
# }
# "sample" is deserialized into <type> with a case-insensitive reader (so the
# sample can be written in wire casing), then re-serialized through the
# accessor's options. "options_accessor" must resolve to the SERVICE'S real
# configured JsonSerializerOptions (the same instance AddJsonOptions builds) —
# pointing it at a hand-made options object would test the wrong thing; the
# generated header repeats this warning.

set -uo pipefail

CONTRACT="${1:-}"
OUTPUT="${2:-}"
RUNNER="console"
if [ "${3:-}" = "--runner" ]; then RUNNER="${4:-console}"; fi

if [ -z "$CONTRACT" ] || [ -z "$OUTPUT" ]; then
  echo "Usage: $0 <wire-golden.json> <output.cs> [--runner console|xunit]" >&2
  exit 2
fi
if [ ! -f "$CONTRACT" ]; then
  echo "ERROR: contract file not found: $CONTRACT" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required" >&2
  exit 2
fi
if ! jq -e '.cases | type == "array" and length > 0' "$CONTRACT" >/dev/null 2>&1; then
  echo "ERROR: contract has no non-empty .cases array" >&2
  exit 2
fi
# Validate every case carries the four required fields.
BAD=$(jq -r '[.cases[] | select((.name and .type and .sample != null and .golden) | not)] | length' "$CONTRACT")
if [ "$BAD" != "0" ]; then
  echo "ERROR: $BAD case(s) missing required fields (name, type, sample, golden)" >&2
  exit 2
fi
ACCESSOR=$(jq -r '.options_accessor // empty' "$CONTRACT")
if [ -z "$ACCESSOR" ]; then
  echo "ERROR: contract missing options_accessor (must point at the service's REAL configured JsonSerializerOptions)" >&2
  exit 2
fi
CAPTURED_FROM=$(jq -r '.captured_from // "UNRECORDED — golden provenance missing (record it!)"' "$CONTRACT")

# (M10) Delimiter-SAFE placeholder substitution. The PRE-FIX code piped emit_case_body through
# `sed -e "s|{{SAMPLE}}|$SAMPLE|g" -e "s|{{GOLDEN}}|$GOLDEN|g" …` — a `|` in a sample/golden value
# (an enum flag "Read|Write", a delimited id) collided with the sed `s|…|` delimiter, sed errored, the
# pipeline emitted NOTHING for that case, and the case scaffold landed WITHOUT its serialize/compare body
# — yet "Generated … N case(s)." exit 0 (an assertion-less, always-green test: a SAFETY-false-green). The
# `/`-delimited {{TYPE}}/{{NAME}} branches were the same class for any `/` in a type/case name.
#
# This replaces sed with an index()-based LITERAL awk splice. CRITICAL: it must NOT use awk gsub — gsub
# treats `&` in the replacement as "the whole matched text" and `\` as an escape, so an `&`/`\` in a
# golden value would be corrupted even though it solved the `|` collision. index()+substr is a true
# literal splice: `|`, `&`, `\`, `/` all pass through byte-for-byte. Values are passed via ENVIRON so no
# shell or awk metacharacter in the data is ever interpreted. All FOUR placeholders are handled.
subst_placeholders() {  # reads stdin; reads PH_TYPE PH_SAMPLE PH_GOLDEN PH_NAME from the environment
  awk '
    function repl(s, ph, val,   out, idx) {
      out = ""
      while ((idx = index(s, ph)) > 0) { out = out substr(s, 1, idx - 1) val; s = substr(s, idx + length(ph)) }
      return out s
    }
    {
      line = $0
      line = repl(line, "{{TYPE}}",   ENVIRON["PH_TYPE"])
      line = repl(line, "{{SAMPLE}}", ENVIRON["PH_SAMPLE"])
      line = repl(line, "{{GOLDEN}}", ENVIRON["PH_GOLDEN"])
      line = repl(line, "{{NAME}}",   ENVIRON["PH_NAME"])
      print line
    }
  '
}

emit_case_body() {  # shared per-case check body; $1 = indent
  local ind="$1"
  cat <<EOF
${ind}var obj = JsonSerializer.Deserialize<{{TYPE}}>(@"{{SAMPLE}}", _readOpts)
${ind}          ?? throw new InvalidOperationException("sample deserialized to null for {{NAME}}");
${ind}var actual = JsonSerializer.Serialize(obj, ${ACCESSOR});
${ind}var golden = @"{{GOLDEN}}";
${ind}if (!string.Equals(actual, golden, StringComparison.Ordinal))
${ind}{
${ind}    var i = 0;
${ind}    while (i < actual.Length && i < golden.Length && actual[i] == golden[i]) i++;
${ind}    var msg = "WIRE DIVERGENCE [{{NAME}}] first differing byte at index " + i +
${ind}              "\n  golden: " + golden + "\n  actual: " + actual +
${ind}              "\n  (covers naming policy, null-emission, field ordering — see lib/generate-wire-golden-test.sh)";
EOF
}

{
cat <<EOF
// <auto-generated>
// GENERATED by lib/generate-wire-golden-test.sh — DO NOT EDIT BY HAND.
// WIRE-B golden-output byte-parity test (preflight issue #5, mechanical close).
//
// Golden provenance: ${CAPTURED_FROM}
//
// Each case: deserialize the recorded sample into the migrated type
// (case-insensitive read), re-serialize through the SERVICE'S ACTUAL configured
// JsonSerializerOptions (${ACCESSOR}), and ordinal-byte-compare
// against the captured legacy wire string. Byte equality is order-sensitive:
// this covers property naming, null-emission policy, and field ordering in one
// comparison.
//
// WARNING: ${ACCESSOR} MUST be the very options instance the
// service's pipeline uses (wire it from AddJsonOptions / the DI-resolved
// IOptions<JsonOptions>). Pointing it at a hand-constructed options object
// tests a fiction.
// </auto-generated>
using System;
using System.Text.Json;

EOF

if [ "$RUNNER" = "xunit" ]; then
  cat <<EOF
using Xunit;

public class WireGoldenTests
{
    private static readonly JsonSerializerOptions _readOpts =
        new JsonSerializerOptions { PropertyNameCaseInsensitive = true };

EOF
  N=$(jq '.cases | length' "$CONTRACT")
  i=0
  while [ "$i" -lt "$N" ]; do
    NAME=$(jq -r ".cases[$i].name" "$CONTRACT")
    TYPE=$(jq -r ".cases[$i].type" "$CONTRACT")
    SAMPLE=$(jq -c ".cases[$i].sample" "$CONTRACT" | sed 's/"/""/g')
    GOLDEN=$(jq -r ".cases[$i].golden" "$CONTRACT" | sed 's/"/""/g')
    cat <<EOF
    [Fact]
    public void Wire_${NAME}()
    {
EOF
    # Export PH_* so BOTH sides of the pipe see them — an env-var prefix on the pipeline's first
    # command would NOT reach subst_placeholders' awk (which reads ENVIRON) on the consuming side.
    export PH_TYPE="$TYPE" PH_SAMPLE="$SAMPLE" PH_GOLDEN="$GOLDEN" PH_NAME="$NAME"
    emit_case_body "        " | subst_placeholders
    # Snapshot PIPESTATUS into a local array IMMEDIATELY — any later command (incl. `[`) resets it.
    PS=("${PIPESTATUS[@]}")
    if [ "${PS[0]}" -ne 0 ] || [ "${PS[1]}" -ne 0 ]; then
      echo "ERROR: placeholder substitution failed for case '$NAME' (PIPESTATUS=${PS[*]}) — refusing to emit an assertion-less test body." >&2
      exit 2
    fi
    cat <<EOF
        Assert.Fail(msg);
        }
    }

EOF
    i=$((i + 1))
  done
  echo "}"
else
  cat <<EOF
public static class WireGoldenRunner
{
    private static readonly JsonSerializerOptions _readOpts =
        new JsonSerializerOptions { PropertyNameCaseInsensitive = true };

    public static int Main()
    {
        var failures = 0;
EOF
  N=$(jq '.cases | length' "$CONTRACT")
  i=0
  while [ "$i" -lt "$N" ]; do
    NAME=$(jq -r ".cases[$i].name" "$CONTRACT")
    TYPE=$(jq -r ".cases[$i].type" "$CONTRACT")
    SAMPLE=$(jq -c ".cases[$i].sample" "$CONTRACT" | sed 's/"/""/g')
    GOLDEN=$(jq -r ".cases[$i].golden" "$CONTRACT" | sed 's/"/""/g')
    echo "        { // case: $NAME"
    export PH_TYPE="$TYPE" PH_SAMPLE="$SAMPLE" PH_GOLDEN="$GOLDEN" PH_NAME="$NAME"
    emit_case_body "            " | subst_placeholders
    PS=("${PIPESTATUS[@]}")
    if [ "${PS[0]}" -ne 0 ] || [ "${PS[1]}" -ne 0 ]; then
      echo "ERROR: placeholder substitution failed for case '$NAME' (PIPESTATUS=${PS[*]}) — refusing to emit an assertion-less test body." >&2
      exit 2
    fi
    cat <<EOF
            Console.Error.WriteLine(msg);
            failures++;
            }
            else { Console.WriteLine("WIRE OK [$NAME]"); }
        }
EOF
    i=$((i + 1))
  done
  cat <<EOF
        Console.WriteLine(failures == 0
            ? "WIRE GOLDEN: all cases byte-equal"
            : "WIRE GOLDEN: " + failures + " divergence(s)");
        return failures == 0 ? 0 : 1;
    }
}
EOF
fi
} > "$OUTPUT"

echo "Generated $OUTPUT (${RUNNER} runner, $(jq '.cases | length' "$CONTRACT") case(s))."
exit 0
