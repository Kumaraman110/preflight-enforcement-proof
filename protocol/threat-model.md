# Preflight Protocol — threat model & trust boundaries (v0.1)

This document states, honestly and precisely, what the v0.1 verifier defends against, what
it does NOT, and where the trust boundaries lie. Per the build contract, an overstated
guarantee is a worse defect than an honest gap — so limitations are labelled, not buried.

## Actors & trust domains

| Party | Trusted? | Notes |
|---|---|---|
| **Producer / adapter** (e.g. the Claude Code kernel) | **NOT trusted** for its conclusions | It may be a capable agent acting in good faith, or a compromised/mistaken one. Its self-reported verdict is a *claim*, re-derived by the verifier. |
| **Evidence artifacts on disk** | Trusted only as far as their **hashes** verify | The verifier recomputes sha256 of each artifact; a post-seal edit is caught. |
| **The verifier** (`pfverify`) | **Trusted** — this is the accountability root | It must be run in a trust domain the producer cannot tamper with (see boundary B1). |
| **The attestation key** (`--attestation-key`) | **Trusted secret**, held server-side | When present, defends against a forger who recomputes the bundle digest. The producer must NOT hold it. |

## What v0.1 defends against (demonstrated by the test suite)

| Threat | Mechanism | Violation code | Test |
|---|---|---|---|
| **Malformed input** (non-JSON, wrong shape) | schema validation, top-level exception guard | `schema.*.invalid` / `internal.error` | verifier-decision #4/#5 |
| **Missing evidence** (required type absent) | policy `requiredEvidence` check | `evidence.missing` | verifier-decision #6 |
| **Stale evidence** (outside freshness window) | injected-`now` age check | `freshness.stale` | verifier-decision #7 |
| **Head-stale evidence** (evidence about a different commit) | `boundHead == subjectHead` check | `freshness.stale` | verifier-decision #8 |
| **Forged artifact** (file edited after sealing) | recompute sha256, compare to declared | `hash.mismatch` | verifier-decision #9, adapter #4 |
| **Forged claim without reseal** (edit body, stale digest) | recompute canonical bundle digest | `integrity.digest-mismatch` | verifier-decision #10 |
| **Contradictory evidence** (intentRef ≠ intent, or items disagree) | cross-field consistency checks | `contradiction.intentRef` / `contradiction.boundHead` | verifier-decision #11/#12 |
| **Future-dated evidence** (producedAt after now) | `producedAt <= now` check | `contradiction.future-evidence` | verifier-decision #14 |
| **Unknown producer** (unregistered issuer) | issuer allow-list | `provenance.unknown-issuer` | (engine) |
| **Dependency failure** (schema/policy unreadable) | load guards → fail-closed BLOCK | `dependency.unavailable` | verifier-decision #13, adapter #5 |
| **Timeout / process kill** | exit-code contract: killed verifier ≠ exit 0 | (shell rc 124/137) | adapter #6 |
| **Unhandled exception** | top-level `try/except` → BLOCK | `internal.error` | (cli.py backstop) |
| **Forged tier + resealed digest** — WITH a key | HMAC signature over the digest | `integrity.signature-invalid` | verifier-decision #15b, adapter, engine |
| **Artifact path traversal** (`../` or absolute path outside the evidence root) | realpath confinement BEFORE any filesystem access — a bundle can never make the verifier hash arbitrary host files | `artifact.path-escape` | verifier-decision #16 |
| **Ambiguous tier** (two tier-evidence items disagree) | disagreement → unresolvable tier; never the permissive pick | `policy.tier-unresolved` | verifier-decision #17 |

**Fail-closed invariant:** there is no input — malformed, missing, stale, forged,
contradictory, or exceptional — that yields `ALLOW`. Every error path returns `BLOCK`
(exit 20) or, for a process kill, a non-zero exit that shell callers must not treat as allow.

## Remote-authoritative mode CLOSES the identity gap (v0.1 remote gate)

The single largest local-mode gap — that `subject.repo`/`subject.head` are trusted as
CLAIMED — is closed in **remote-authoritative mode** (`docs/remote-gate.md`). There the
verifier independently re-resolves the repository and commit FROM THE CI CHECKOUT and blocks
on disagreement: `identity.repo-mismatch`, `identity.commit-mismatch`, `identity.worktree-dirty`,
`identity.unresolvable`. A locally self-issued ALLOW (forged head/repo) therefore CANNOT pass
an independently executed verification — proven in `tests/protocol/identity-reresolution-test.sh`
(case 9: ALLOW locally → BLOCK remotely). This holds ONLY in remote-authoritative mode with a
real independent checkout the producer cannot write to; **local-advisory mode retains the B2
boundary below verbatim.**

## What v0.1 does NOT defend against (stated boundaries)

- **B1 — Verifier-domain integrity is assumed.** The verifier is the accountability root;
  if an attacker can modify the verifier code, the schemas, or the policy it loads, they
  own the decision. In a real deployment the verifier + its inputs run in a trust domain
  the producer cannot write to (a server, a signed container) — which is exactly what the
  remote gate's independent CI checkout provides. Locally, this is not enforced.

- **B2 — Unauthenticated *claim* forgery (no key), LOCAL-ADVISORY mode only.** Without
  `--attestation-key`, a forger who edits an evidence **claim** (e.g. flips a fresh,
  hash-valid tier) **and recomputes `bundleDigest`** passes the digest check — the digest
  proves internal consistency, not authenticity. This is demonstrated in verifier-decision
  #15a (ALLOW without a key) and closed in #15b (BLOCK with a key). The MVP surfaces this in
  every decision as the reason `integrity:unauthenticated`. Closing it in production means the
  producer never holds the signing key. In REMOTE-authoritative mode the identity re-resolution
  above blocks the specific case of a forged head/repo regardless of the bundle key. NOTE:
  forgeries that require *structural* changes — a path traversal or a
  disagreeing duplicate tier — are caught regardless of the key (see the defended table:
  `artifact.path-escape`, `policy.tier-unresolved`); B2 is now specifically the residual
  *claim-value* forgery on an otherwise well-formed, hash-consistent item.

- **B3 — Evidence semantics are trusted at face value.** The verifier checks that a
  `tests-pass` artifact exists, hashes correctly, is fresh, and claims `passed: true`. It
  does NOT re-run the tests or parse the log to confirm they truly passed. Binding evidence
  to a *reproducible* attestation (e.g. a signed CI run) is future work.

- **B4 — No revocation / replay window beyond freshness.** Within the freshness window, a
  valid bundle can be re-submitted. Nonce/one-time-use binding is future work.

- **B5 — Not a network service.** "Server-authoritative" here is a *trust-model* claim (an
  independent verifier), not a deployed server. Transport authentication, rate limiting, and
  audit persistence are future work.

- **B6 — Issuer allow-list is static.** The known-issuer set is hard-coded for the MVP. A
  registration/key-distribution mechanism for adapters is future work.

## Relationship to the local trust kernel

The local kernel (router/engine/gate) remains the fast, in-process, prompt-level self-
discipline layer — unchanged. The protocol adds an *external accountability* layer on top:
the kernel becomes a **producer** whose classification is submitted as evidence and
independently re-checked. The two are complementary; v0.1 does not replace or weaken the
kernel, and the kernel's own limitations (documented in `parity-gate-limitations.md`) are
unchanged.
