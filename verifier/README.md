# pfverify — Preflight Protocol evidence verifier (MVP)

The **platform core**: a deterministic, fail-closed verifier that accepts an Action Intent
and an Evidence Bundle from any producer, independently re-derives whether the evidence
authorizes the action under a named policy, and returns a machine-readable Policy Decision.

Zero third-party dependencies — **Python 3 standard library only**. A security-critical
verifier must be fully reviewable and reproducible with no external supply chain, so it does
NOT depend on the `jsonschema` package; it ships a **bounded** validator (see below).

## Layout

```
verifier/
  pfverify/
    __init__.py
    canonical.py     — canonical JSON serialization + sha256/HMAC (determinism + integrity)
    schema.py        — BOUNDED JSON-Schema validator (only the keywords our schemas use)
    engine.py        — the verification pipeline (the trust core)
    cli.py           — deterministic CLI + exit-code contract + fail-closed backstop
    __main__.py      — `python -m pfverify`
    adapters/
      claude_code_adapter.py — PRODUCER: bridges the existing .preflight/gate kernel → protocol
  tools/
    seal_bundle.py   — producer-side helper: fill artifact hashes + bundleDigest (+ optional HMAC)
  README.md
```

## Usage

```bash
# Verify an intent + bundle under a policy, with an injected reference time (deterministic):
python -m verifier.pfverify \
    --intent  intent.json \
    --bundle  bundle.json \
    --policy  protocol/policies/push-safety.v1.policy.json \
    --evidence-root  <dir artifact paths are relative to> \
    --now  2026-07-10T09:05:00Z \
    [--attestation-key-file key.bin]   # require + verify an HMAC signature
    [--schema-dir DIR]                 # defaults to <repo>/protocol/schemas

# Producer helper — (re)compute artifact hashes + bundleDigest for a bundle:
python verifier/tools/seal_bundle.py --bundle bundle.json --evidence-root <dir> [--attestation-key-file key.bin]

# Adapter — emit a conforming intent+bundle from an existing .preflight/gate/ install:
python -m verifier.pfverify.adapters.claude_code_adapter \
    --repo-root <consumer> --head <sha> --tier AUTO --remote safe --refspec HEAD:topic \
    --evidence-root <consumer> --out-intent i.json --out-bundle b.json
```

Interpreter note: on some Windows hosts `python3` is a broken Store stub while `python`
works (CI Linux is the inverse). Callers/tests should probe for a working interpreter
(try `python3` then `python`) rather than hard-code one — the test harness does this.

## Exit-code contract

The **authoritative** result is the Policy Decision JSON on stdout. The exit code mirrors it:

| Exit | Meaning |
|---|---|
| `0`  | `ALLOW` |
| `10` | `REQUIRE_APPROVAL` |
| `20` | `BLOCK` — includes every malformed / missing / stale / forged / contradictory / dependency-failure / exception path |
| `30` | usage / bad invocation — still emits a `BLOCK` decision, never an allow |

There is no input that yields exit 0 without a fully-passed verification. A top-level
`try/except` guarantees an unexpected exception becomes `BLOCK`, never a crash-open. A
process kill (timeout) yields rc 124/137 — a non-zero, non-allow result.

## The bounded validator (why not `jsonschema`)

`schema.py` supports EXACTLY the draft-2020-12 keywords our own schemas use: `type`,
`required`, `properties`, `additionalProperties`, `pattern`, `enum`, `minLength`,
`minItems`, `items`. Any keyword it does not recognize raises `SchemaError` — so it can
never *silently under-enforce* a constraint it doesn't understand (fail-closed by
construction). The `schema-contract` test asserts the core shipped schemas validate under
it without raising, i.e. they use only supported keywords.

Five schemas ship: `action-intent.v1`, `evidence-bundle.v1`, `policy-decision.v1` (the
protocol core), plus `decision-attestation.v1` and `approval.v1` (the remote gate). All are
load-bearing — the attestation and approval schemas are enforced by `verify-attestation` /
`verify-approval` via this validator, not decorative.

## Tests

```bash
bash tests/run-all-tests.sh protocol      # all protocol + remote-gate suites
# Protocol core:
bash tests/protocol/verifier-decision-test.sh      # positive/negative/stale/forged/contradictory/dep-fail (29)
bash tests/protocol/schema-contract-test.sh        # schema + validator contract (7)
bash tests/protocol/adapter-and-failmode-test.sh   # adapter-as-producer + fail modes + timeout (11)
# Remote decision gate (v0.2):
bash tests/protocol/identity-reresolution-test.sh  # independent repo/commit re-resolution (18)
bash tests/protocol/attestation-test.sh            # signed attestation: tamper/expiry/replay/wrong-key (11)
bash tests/protocol/approval-test.sh               # REQUIRE_APPROVAL exception path, no self-approve (8)
bash tests/protocol/remote-gate-e2e-test.sh        # portable CI entrypoint end-to-end (8)
bash tests/protocol/workflow-security-test.sh      # GitHub workflow hardening assertions (20)
bash tests/protocol/integration-fixture-test.sh    # deterministic GitHub-equivalent, 7 adversarial cases (9)
bash tests/protocol/learning-loop-demo-test.sh     # two-service learning loop (11)
```

See `../protocol/PROTOCOL.md` for the wire contract, `../docs/remote-gate.md` for the CI
integration + two-stage trusted split, and `../protocol/threat-model.md` for trust boundaries
and stated limitations.
