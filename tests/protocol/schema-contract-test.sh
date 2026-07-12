#!/usr/bin/env bash
# Behavioral test: the protocol SCHEMAS + the bounded validator are self-consistent.
#
# Guards the versioned-schema deliverable itself:
#   • all three schemas exist, are valid JSON, and carry a draft-2020-12 $schema + $id;
#   • the policy-decision schema's `decision` enum is exactly {ALLOW,REQUIRE_APPROVAL,BLOCK};
#   • every schema uses ONLY keywords the bounded validator supports (so it can never
#     silently under-enforce — the validator raises SchemaError on any unknown keyword);
#   • the bounded validator's own unit behavior (type/required/pattern/enum/additionalProperties).
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

if ! _probe_python; then
  bad "no working python3/python interpreter (fail-closed: NOT green)"
  echo ""; echo "schema-contract: ${PASS} passed, ${FAIL} failed"; exit 1
fi

SCHEMA_DIR="$PROTO_ROOT/protocol/schemas"
INTENT_S="$SCHEMA_DIR/action-intent.v1.schema.json"
BUNDLE_S="$SCHEMA_DIR/evidence-bundle.v1.schema.json"
DECISION_S="$SCHEMA_DIR/policy-decision.v1.schema.json"

for f in "$INTENT_S" "$BUNDLE_S" "$DECISION_S"; do
  if [ -f "$f" ] && "$PF_PY" -c "import json,sys;json.load(open(sys.argv[1],encoding='utf-8'))" "$f" >/dev/null 2>&1; then
    ok "schema exists + valid JSON: $(basename "$f")"
  else
    bad "schema missing or invalid JSON: $f"
  fi
done

# $schema + $id present on each
"$PF_PY" - "$INTENT_S" "$BUNDLE_S" "$DECISION_S" <<'PY'
import json,sys
ok=True
for p in sys.argv[1:]:
    d=json.load(open(p,encoding="utf-8"))
    if "$schema" not in d or "draft/2020-12" not in d["$schema"]: print("MISSING-SCHEMA",p); ok=False
    if "$id" not in d: print("MISSING-ID",p); ok=False
sys.exit(0 if ok else 1)
PY
[ $? -eq 0 ] && ok "all schemas declare draft-2020-12 \$schema + \$id" || bad "a schema is missing \$schema/\$id"

# decision enum is EXACTLY the three required verdicts.
# NOTE: pass the path as ARGV, not embedded in -c — MSYS converts /c/... argv args to
# Windows paths for native python.exe, but does NOT rewrite a path baked into the code string.
ENUM="$("$PF_PY" -c "import json,sys;print(','.join(json.load(open(sys.argv[1],encoding='utf-8'))['properties']['decision']['enum']))" "$DECISION_S")"
if [ "$ENUM" = "ALLOW,REQUIRE_APPROVAL,BLOCK" ]; then
  ok "policy-decision enum == ALLOW,REQUIRE_APPROVAL,BLOCK"
else
  bad "policy-decision enum is '$ENUM', expected ALLOW,REQUIRE_APPROVAL,BLOCK"
fi

# every schema loads under the bounded validator WITHOUT raising SchemaError (i.e. uses
# only supported keywords) — a schema with an unsupported keyword would fail-closed loudly.
( cd "$PROTO_ROOT" && "$PF_PY" - <<'PY'
import sys
from verifier.pfverify import schema as S
import json
paths=["protocol/schemas/action-intent.v1.schema.json",
       "protocol/schemas/evidence-bundle.v1.schema.json",
       "protocol/schemas/policy-decision.v1.schema.json",
       "protocol/schemas/decision-attestation.v1.schema.json",
       "protocol/schemas/approval.v1.schema.json"]
try:
    for p in paths:
        sch=json.load(open(p,encoding="utf-8"))
        # validate a trivial instance to force keyword traversal; errors are fine, a raise is not
        S.validate({}, sch)
except S.SchemaError as e:
    print("SCHEMA-ERROR",e); sys.exit(1)
sys.exit(0)
PY
)
[ $? -eq 0 ] && ok "all schemas use only bounded-validator-supported keywords (no silent under-enforcement)" || bad "a schema uses an unsupported keyword"

# validator unit behavior — positive + each rejection kind
( cd "$PROTO_ROOT" && "$PF_PY" - <<'PY'
import sys
from verifier.pfverify import schema as S
checks=[]
sch={"type":"object","additionalProperties":False,"required":["a"],
     "properties":{"a":{"type":"string","pattern":"^x","minLength":1},
                   "b":{"type":"string","enum":["p","q"]}}}
checks.append(("valid", S.validate({"a":"xyz"},sch)==[]))
checks.append(("missing-required", any("missing required" in e for e in S.validate({},sch))))
checks.append(("pattern", any("pattern" in e for e in S.validate({"a":"zzz"},sch))))
checks.append(("enum", any("enum" in e for e in S.validate({"a":"x","b":"r"},sch))))
checks.append(("additional", any("additional property" in e for e in S.validate({"a":"x","c":1},sch))))
checks.append(("type", any("expected type" in e for e in S.validate({"a":5},sch))))
# unsupported keyword -> raises
try:
    S.validate({}, {"type":"object","format":"email"}); checks.append(("raise-on-unknown",False))
except S.SchemaError:
    checks.append(("raise-on-unknown",True))
bad=[n for n,r in checks if not r]
if bad: print("VALIDATOR-UNIT-FAIL",bad); sys.exit(1)
sys.exit(0)
PY
)
[ $? -eq 0 ] && ok "bounded validator unit behavior (valid/required/pattern/enum/additional/type/raise-on-unknown)" || bad "bounded validator unit behavior wrong"

echo ""
echo "schema-contract: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
