"""seal_bundle.py — helper to (re)compute artifact hashes + bundleDigest for a bundle.

This is a PRODUCER-side helper (used by adapters and test fixtures), NOT part of the
verifier trust core. It fills in each evidence artifact's sha256 from the file on
disk and computes the attestation.bundleDigest (and an HMAC signature if a key is
given). The verifier independently recomputes and checks all of these — sealing here
is a convenience, never a trust source.

Usage:
    python seal_bundle.py --bundle BUNDLE.json --evidence-root DIR [--out OUT.json]
        [--attestation-key-file KEY] [--no-recompute-artifacts]
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pfverify import canonical  # noqa: E402


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bundle", required=True)
    ap.add_argument("--evidence-root", default=".")
    ap.add_argument("--out", default=None)
    ap.add_argument("--attestation-key-file", default=None)
    ap.add_argument("--no-recompute-artifacts", action="store_true",
                    help="Keep declared artifact hashes as-is (for forgery fixtures).")
    args = ap.parse_args(argv)

    with open(args.bundle, "r", encoding="utf-8") as fh:
        bundle = json.load(fh)

    if not args.no_recompute_artifacts:
        for ev in bundle.get("evidence", []):
            art = ev.get("artifact")
            if not art:
                continue
            apath = os.path.join(args.evidence_root, art["path"])
            art["sha256"] = canonical.sha256_file(apath)

    digest = canonical.bundle_digest(bundle)
    att = bundle.setdefault("attestation", {})
    att["bundleDigest"] = digest
    if args.attestation_key_file:
        with open(args.attestation_key_file, "rb") as fh:
            key = fh.read().strip()
        att["algo"] = "hmac-sha256"
        att["signature"] = canonical.hmac_sha256_hex(key, digest)
    else:
        att.setdefault("algo", "sha256")

    out = args.out or args.bundle
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(canonical.canonical_bytes(bundle).decode("utf-8") + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
