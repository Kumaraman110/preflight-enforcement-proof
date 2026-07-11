"""pfverify — Preflight Protocol server-authoritative evidence verifier (MVP).

The platform CORE: it accepts an Action Intent + Evidence Bundle from ANY producer
(the Claude Code adapter is one such producer, not the core), validates schema /
artifact hashes / provenance / freshness / internal consistency, evaluates a named
policy, and returns a deterministic machine-readable Policy Decision. Every error
path fails CLOSED (decision BLOCK). Zero third-party dependencies (stdlib only).
"""

__all__ = ["canonical", "schema", "engine", "cli"]
