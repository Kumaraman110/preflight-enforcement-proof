"""claude-code adapter — bridges the EXISTING local trust kernel into the protocol.

The current Claude Code enforcement surface (the pre-bash-risk-router → engine →
pre-push-gate chain) writes HEAD-keyed evidence files under `.preflight/gate/`
(format: `GATE=<name>` / `HEAD=<sha>` / `TIMESTAMP=<rfc3339>`), and classifies a
git push into a reversibility tier (AUTO/CONFIRM/BLOCK). Those are LOCAL, prompt-level,
same-trust-domain artifacts.

This adapter READS those existing artifacts and EMITS a model-neutral Action Intent +
Evidence Bundle that the server-authoritative verifier can independently re-check. It
proves the point of the platform direction: the Claude Code implementation is ONE
PRODUCER feeding the verifier, not the platform core. It writes no kernel state and
changes no hook; it only observes the kernel's outputs.

Usage:
    python -m pfverify.adapters.claude_code_adapter \
        --repo-root DIR --gate-dir DIR --head SHA --tier AUTO \
        --action-type git-push --remote safe --refspec HEAD:topic \
        --out-intent intent.json --out-bundle bundle.json --evidence-root DIR
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from pfverify import canonical  # noqa: E402

ADAPTER_ID = "claude-code"
ADAPTER_VERSION = "0.1.0"

# Which local gate-evidence files map to which protocol evidence type.
GATE_TO_EVIDENCE_TYPE = {
    "tests-pass": "tests-pass",
    "stage1-clean": "stage1-clean",
    "map-validated": "map-validated",
    "parity-clean": "parity-clean",
}


def _read_gate_file(path: str) -> dict:
    """Parse a `.preflight/gate/<name>` file (KEY=VALUE lines) into a dict."""
    out = {}
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if "=" in line:
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip()
    return out


def build_intent(repo: str, head: str, branch: str, action_type: str, attributes: dict, intent_id: str) -> dict:
    return {
        "schemaVersion": "1.0.0",
        "intentId": intent_id,
        "action": {"type": action_type, "attributes": attributes},
        "actor": {"kind": "model", "id": os.environ.get("PREFLIGHT_ACTOR_ID", "claude-code-agent")},
        "subject": {"repo": repo, "head": head, "branch": branch} if branch else {"repo": repo, "head": head},
    }


def build_bundle(intent_id: str, head: str, gate_dir: str, evidence_root: str, tier: str) -> dict:
    """Collect gate evidence files + the router tier into an Evidence Bundle.

    Artifact hashes and the bundleDigest are computed here (producer side). The
    verifier recomputes and checks them independently — this sealing is convenience,
    not a trust source.
    """
    evidence = []

    for fname, etype in GATE_TO_EVIDENCE_TYPE.items():
        fpath = os.path.join(gate_dir, fname)
        if not os.path.isfile(fpath):
            continue
        meta = _read_gate_file(fpath)
        # The artifact IS the gate file itself; hash it relative to evidence_root.
        rel = os.path.relpath(fpath, evidence_root)
        evidence.append({
            "type": etype,
            "producedAt": meta.get("TIMESTAMP", ""),
            "boundHead": meta.get("HEAD", head),
            "artifact": {"path": rel.replace(os.sep, "/"),
                         "sha256": canonical.sha256_file(fpath)},
            "claims": {"passed": True, "gate": meta.get("GATE", fname)},
        })

    # The router's reversibility classification, emitted as push-tier evidence. Its
    # artifact is a small tier record co-located under the evidence root so it hashes.
    tier_path = os.path.join(evidence_root, ".pf-adapter-tier.txt")
    with open(tier_path, "w", encoding="utf-8") as fh:
        fh.write(f"tier={tier}\nhead={head}\n")
    # Reuse a gate timestamp for the tier if one exists, else fall back to the
    # newest gate evidence timestamp so the tier is head-fresh with the rest.
    tier_ts = ""
    for ev in evidence:
        if ev["producedAt"]:
            tier_ts = ev["producedAt"]
            break
    evidence.append({
        "type": "push-tier",
        "producedAt": tier_ts,
        "boundHead": head,
        "artifact": {"path": os.path.relpath(tier_path, evidence_root).replace(os.sep, "/"),
                     "sha256": canonical.sha256_file(tier_path)},
        "claims": {"tier": tier},
    })

    bundle = {
        "schemaVersion": "1.0.0",
        "intentRef": {"intentId": intent_id, "subjectHead": head},
        "issuer": {"adapter": ADAPTER_ID, "version": ADAPTER_VERSION},
        "evidence": evidence,
        "attestation": {"algo": "sha256", "bundleDigest": ""},
    }
    bundle["attestation"]["bundleDigest"] = canonical.bundle_digest(bundle)
    return bundle


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo-root", default=".")
    ap.add_argument("--gate-dir", default=None, help="Defaults to <repo-root>/.preflight/gate")
    ap.add_argument("--head", required=True)
    ap.add_argument("--branch", default="")
    ap.add_argument("--tier", required=True, choices=["AUTO", "CONFIRM", "BLOCK"])
    ap.add_argument("--action-type", default="git-push")
    ap.add_argument("--remote", default="")
    ap.add_argument("--refspec", default="")
    ap.add_argument("--intent-id", default="claude-code-intent")
    ap.add_argument("--evidence-root", default=None, help="Defaults to <repo-root>")
    ap.add_argument("--out-intent", required=True)
    ap.add_argument("--out-bundle", required=True)
    args = ap.parse_args(argv)

    repo_root = os.path.abspath(args.repo_root)
    gate_dir = args.gate_dir or os.path.join(repo_root, ".preflight", "gate")
    evidence_root = args.evidence_root or repo_root

    attributes = {}
    if args.remote:
        attributes["remote"] = args.remote
    if args.refspec:
        attributes["refspec"] = args.refspec

    intent = build_intent(os.path.basename(repo_root), args.head, args.branch,
                          args.action_type, attributes, args.intent_id)
    bundle = build_bundle(args.intent_id, args.head, gate_dir, evidence_root, args.tier)

    with open(args.out_intent, "w", encoding="utf-8") as fh:
        fh.write(canonical.canonical_bytes(intent).decode("utf-8") + "\n")
    with open(args.out_bundle, "w", encoding="utf-8") as fh:
        fh.write(canonical.canonical_bytes(bundle).decode("utf-8") + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
