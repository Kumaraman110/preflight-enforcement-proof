# Preflight Protocol v0.1

A **model-neutral accountability protocol**: a wire contract by which ANY producer
(an LLM agent, a CI job, a script, a human tool) declares an action it intends to take
and submits the evidence that should authorize it, and by which a **server-authoritative
verifier** — which the producer cannot forge past — returns a deterministic decision.

This is the first bounded milestone toward decoupling Preflight's *enforcement* from any
one model or runtime. Today's local trust kernel (the Claude Code router → engine →
`pre-push-gate` chain) is preserved unchanged and re-expressed as **one producer adapter**
(`verifier/pfverify/adapters/claude_code_adapter.py`), not the platform core.

## Why a protocol (the problem it addresses)

The local kernel writes HEAD-keyed evidence files under `.preflight/gate/` and decides
in-process, on the **same machine and trust domain** as the agent it governs.
`hooks/write-gate-evidence` states plainly that it "enforces NO actor check — the
restriction is prompt-level." So the governed agent can, in principle, mint its own
clearance. That is acceptable for a local self-discipline aid; it is **not** an
accountability guarantee an external party can rely on.

The protocol separates the **producer of evidence** from an **independent verifier** that
re-derives the decision from first principles — recomputing hashes, checking provenance
and freshness, and evaluating a declared policy — so a decision does not rest on trusting
the producer's self-report.

## The three versioned artifacts

All schemas are JSON Schema draft 2020-12 (a bounded subset — see the verifier README).
Each carries a `schemaVersion` (full semver) and the file name carries the major (`.v1.`).

| Artifact | Schema | Role |
|---|---|---|
| **Action Intent** | `schemas/action-intent.v1.schema.json` | What the actor intends to do, and the subject (repo + head) it targets. |
| **Evidence Bundle** | `schemas/evidence-bundle.v1.schema.json` | The evidence items + an attestation envelope submitted to justify the intent. |
| **Policy Decision** | `schemas/policy-decision.v1.schema.json` | The verifier's deterministic verdict: `ALLOW` / `REQUIRE_APPROVAL` / `BLOCK`, with reasons, violations, and the individual checks it ran. |

The three decisions map onto the kernel's existing reversibility tiers:
`ALLOW ↔ AUTO`, `REQUIRE_APPROVAL ↔ CONFIRM`, `BLOCK ↔ BLOCK`.

## Policies

A policy is **parameter-declarative**, not an embedded rule language — the verifier
interprets a fixed typed structure, keeping the attack surface bounded and reviewable.
The shipped exemplar `policies/push-safety.v1.policy.json` declares:

- `requiredEvidence` — the evidence types that must be present, their required claims,
  and each one's freshness mode;
- `freshnessWindowSeconds` — the max age of evidence relative to the reference time;
- `tierDecisionMap` — how a *verified* reversibility tier maps to a decision;
- `tierEvidenceType` / `tierClaimKey` — where the tier is read from **verified evidence**
  (never from the untrusted `intent.context.tier` the producer asserts).

## Decision flow

```
producer/adapter                      server-authoritative verifier (pfverify)
────────────────                      ─────────────────────────────────────────
gather evidence ─┐
build Intent     │   Action Intent  ┌─▶ 1  validate Intent schema
seal Bundle      ├──────────────────┤   2  validate Bundle schema
(hashes+digest)  │   Evidence Bundle│   3  provenance: known issuer/adapter?
                 ┘                  │   4  consistency: intentRef == intent (id+head)
                                    │   5  consistency: every evidence bound to head, none future
                                    │   6  artifact hashes: recompute sha256 == declared
                                    │   7  attestation digest: recompute canonical digest == declared
                                    │   8  attestation signature: HMAC verified IFF a key is supplied
                                    │   9  freshness: within window AND head-fresh
                                    │  10  policy: required evidence present + claims satisfied
                                    └▶ 11  decision: map VERIFIED tier → ALLOW/REQUIRE_APPROVAL/BLOCK
                                          │
                                          ▼
                                       Policy Decision (deterministic JSON; exit 0/10/20)
```

Any failed check that a policy depends on drives **BLOCK**. The verifier never returns
`ALLOW` unless every relevant check passed (fail-closed by construction — see
`threat-model.md`).

## Determinism

The reference time ("now", for freshness) is **injected** (`--now` or
`intent.context.referenceTime`), never read from a hidden wall clock in the decision path.
Serialization is canonical (sorted keys, compact separators, UTF-8); `reasons` and
`violations` are sorted. Identical inputs therefore produce byte-identical decision output
— which the test suite asserts.

## Compatibility & non-goals for v0.1

- **Additive**: `protocol/` and `verifier/` are new top-level directories outside the
  installer's shipped surfaces (`agents/ skills/ lib/ hooks/ examples/ docs/ defaults/`),
  so the local kernel, its installer, its manifest/verifier, and hook registration are
  untouched. See `DECISIONS.md` D1.
- **Not yet a network service.** The verifier is a local, deterministic CLI/library. It is
  "server-authoritative" in *trust model* (an independent verifier the producer cannot forge
  past) — the transport/hosting is future work.
- **Unauthenticated by default.** Without `--attestation-key`, a forger who edits the bundle
  AND recomputes the digest is not caught by digest alone. This is a stated boundary, closed
  by supplying an HMAC key held server-side. See the threat model.
