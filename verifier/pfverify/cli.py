"""pfverify CLI — deterministic, fail-closed entrypoint.

Exit-code contract (mirrors the JSON `decision`, for shell callers):
    0  = ALLOW
    10 = REQUIRE_APPROVAL
    20 = BLOCK               (includes every error/tamper/staleness/missing path)
    30 = USAGE/INTERNAL      (bad invocation; still emits a BLOCK decision to stdout)

The AUTHORITATIVE result is the Policy Decision JSON on stdout. The exit code is a
convenience mirror. There is NO combination of inputs that yields exit 0 without a
fully-passed verification (fail-closed by construction). A top-level try/except
guarantees that even an unexpected exception becomes a BLOCK, never a crash-open.

Usage:
    python -m pfverify --intent INTENT.json --bundle BUNDLE.json --policy POLICY.json
        [--evidence-root DIR] [--now RFC3339] [--attestation-key-file FILE]
        [--schema-dir DIR]
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from . import engine
from .canonical import canonical_bytes

EXIT_BY_DECISION = {"ALLOW": 0, "REQUIRE_APPROVAL": 10, "BLOCK": 20}
EXIT_USAGE = 30

_DEFAULT_SCHEMA_DIR = Path(__file__).resolve().parents[2] / "protocol" / "schemas"


def _load_json(path: str):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def _emit(decision: dict) -> int:
    """Print the decision as canonical JSON and return the mirroring exit code."""
    sys.stdout.write(canonical_bytes(decision).decode("utf-8") + "\n")
    sys.stdout.flush()
    return EXIT_BY_DECISION.get(decision.get("decision"), EXIT_USAGE)


def _hardcoded_block(policy_id: str, reason: str, violation: str, detail: str = "") -> dict:
    """A minimal fail-closed BLOCK decision for errors before the engine can run."""
    return {
        "schemaVersion": engine.DECISION_SCHEMA_VERSION,
        "decision": "BLOCK",
        "policyId": policy_id,
        "intentId": "unknown",
        "evaluatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "reasons": [reason],
        "violations": [violation],
        "checks": [{"name": "policy.decision", "passed": False, "detail": detail or reason}],
    }


def main(argv: Optional[list] = None) -> int:
    ap = argparse.ArgumentParser(prog="pfverify", add_help=True)
    ap.add_argument("--intent", required=True)
    ap.add_argument("--bundle", required=True)
    ap.add_argument("--policy", required=True)
    ap.add_argument("--evidence-root", default=".")
    ap.add_argument("--now", default=None,
                    help="RFC3339 UTC reference time. If omitted, uses intent.context.referenceTime, "
                         "else the current wall clock (non-deterministic; tests should always pass --now).")
    ap.add_argument("--attestation-key-file", default=None,
                    help="File containing the HMAC key. When supplied, the bundle signature is required + verified.")
    ap.add_argument("--schema-dir", default=str(_DEFAULT_SCHEMA_DIR))

    try:
        args = ap.parse_args(argv)
    except SystemExit:
        # argparse already printed usage to stderr; emit a machine BLOCK too.
        _emit(_hardcoded_block("unknown", "usage:bad-invocation", engine.V_INTERNAL))
        return EXIT_USAGE

    # Everything below is wrapped: ANY failure becomes a fail-closed BLOCK.
    try:
        schema_dir = Path(args.schema_dir)
        # Dependency availability: schemas must be present + loadable, else BLOCK.
        try:
            intent_schema = _load_json(str(schema_dir / "action-intent.v1.schema.json"))
            bundle_schema = _load_json(str(schema_dir / "evidence-bundle.v1.schema.json"))
        except (OSError, json.JSONDecodeError) as e:
            return _emit(_hardcoded_block(
                "unknown", "dependency:schema-unavailable", engine.V_DEPENDENCY, str(e)))

        try:
            policy = _load_json(args.policy)
        except (OSError, json.JSONDecodeError) as e:
            return _emit(_hardcoded_block(
                "unknown", "dependency:policy-unavailable", engine.V_DEPENDENCY, str(e)))
        policy_id = policy.get("policyId", "unknown")

        # Load the two governed documents. A malformed (non-JSON) document is a
        # fail-closed BLOCK, NOT a crash.
        try:
            intent = _load_json(args.intent)
        except (OSError, json.JSONDecodeError) as e:
            return _emit(_hardcoded_block(
                policy_id, "malformed:intent-not-json", engine.V_SCHEMA_INTENT, str(e)))
        try:
            bundle = _load_json(args.bundle)
        except (OSError, json.JSONDecodeError) as e:
            return _emit(_hardcoded_block(
                policy_id, "malformed:bundle-not-json", engine.V_SCHEMA_BUNDLE, str(e)))

        # Resolve the reference time deterministically.
        now = _resolve_now(args.now, intent)
        if now is None:
            return _emit(_hardcoded_block(
                policy_id, "freshness:unprovable-no-reference-time", engine.V_FRESH_UNPROVABLE,
                "no --now and no parseable intent.context.referenceTime"))

        key = None
        if args.attestation_key_file:
            try:
                with open(args.attestation_key_file, "rb") as fh:
                    key = fh.read().strip()
            except OSError as e:
                return _emit(_hardcoded_block(
                    policy_id, "dependency:attestation-key-unavailable", engine.V_DEPENDENCY, str(e)))

        verifier = engine.Verifier(
            intent_schema=intent_schema,
            bundle_schema=bundle_schema,
            policy=policy,
            evidence_root=args.evidence_root,
            now=now,
            attestation_key=key,
        )
        decision = verifier.verify(intent, bundle)
        return _emit(decision)

    except Exception as e:  # noqa: BLE001 — the fail-closed backstop is intentional.
        return _emit(_hardcoded_block(
            "unknown", "internal:unhandled-exception", engine.V_INTERNAL,
            f"{type(e).__name__}: {e}"))


def _resolve_now(now_arg, intent):
    from .engine import _parse_rfc3339
    if now_arg:
        dt = _parse_rfc3339(now_arg)
        return dt  # None if unparseable -> caller treats as unprovable BLOCK
    ref = None
    if isinstance(intent, dict):
        ref = (intent.get("context") or {}).get("referenceTime")
    if ref:
        return _parse_rfc3339(ref)
    # No injected time: fall back to wall clock. Deterministic tests always pass --now.
    return datetime.now(timezone.utc)


if __name__ == "__main__":
    sys.exit(main())
