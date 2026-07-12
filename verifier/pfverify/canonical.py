"""Canonical JSON serialization + hashing (deterministic, stdlib only).

Determinism is a first-class requirement: the same input must always produce the
same digest and the same decision bytes, on any host, so golden tests are stable.
We use RFC-8785-style canonicalization (sorted keys, no insignificant whitespace,
UTF-8) — sufficient for our own artifacts, which use only JSON scalars/objects/arrays.
"""
from __future__ import annotations

import hashlib
import hmac
import json
from typing import Any


def canonical_bytes(obj: Any) -> bytes:
    """Serialize `obj` to canonical JSON bytes: sorted keys, compact separators, UTF-8.

    ensure_ascii=False keeps UTF-8 text as bytes (stable across hosts); separators
    remove insignificant whitespace so formatting never changes the digest.
    """
    return json.dumps(
        obj,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")


def sha256_hex(data: bytes) -> str:
    """Lowercase hex sha256 of raw bytes."""
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: str, chunk: int = 65536) -> str:
    """Lowercase hex sha256 of a file's bytes, streamed (never loads the whole file)."""
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while True:
            block = fh.read(chunk)
            if not block:
                break
            h.update(block)
    return h.hexdigest()


def bundle_digest(bundle: dict) -> str:
    """Canonical sha256 over the bundle with its `attestation` field removed.

    The attestation carries the digest itself, so it MUST be excluded from the
    digest computation. We shallow-copy and drop the key rather than mutating the
    caller's object.
    """
    body = {k: v for k, v in bundle.items() if k != "attestation"}
    return sha256_hex(canonical_bytes(body))


def hmac_sha256_hex(key: bytes, message: str) -> str:
    """Lowercase hex HMAC-SHA256 of `message` (utf-8) under `key`."""
    return hmac.new(key, message.encode("utf-8"), hashlib.sha256).hexdigest()


def consttime_eq(a: str, b: str) -> bool:
    """Constant-time string comparison for secret-bearing checks (signatures)."""
    return hmac.compare_digest(a, b)
