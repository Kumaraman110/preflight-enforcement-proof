# v0.11 Real Service N → Service N+1 Learning Loop

The survival-thesis proof: close the self-improvement loop **once** on real services — a genuine
historical finding becomes an approved rule that catches an equivalent defect in another real
service before delivery. Not the shipped fictional demo; real data end to end.

## Service N — the genuine historical finding (NOT invented)

**Service**: CPSL SessionToken (`CTIAPI-DEV_Work/CTIAPI/Business/CPSLTokenRepository.cs` +
`Controllers/CPSLTokenController.cs`), migrated in PR-12.

**Behavioral drift** (documented in `docs/pr12-parity-audit.md`, inventory i05/i07/i08/i12): the
migration silently changed the API **wire contract**:
- **Introduced** result codes absent from the legacy contract: `S0000` (invented success code — legacy
  success is implicit) and `W0024` ("Invalid or missing request parameters" — does not exist in legacy).
- **Dropped / substituted** legacy codes: `W0011` ("Version is required") → collapsed into `W0023`;
  `E0002` ("Invalid Profile") → replaced by the invented `W0024`.

**Impact**: any caller that branches on `W0011`/`E0002` to drive user-facing messages or
re-authentication silently never receives them — a behavioral regression invisible to a code-quality review.

**Why the checks missed it** (inventory i13): the Stage-1 code-reviewer scored code quality
(security, patterns, style) but had **no mechanism to verify the migrated wire contract** (result
codes, HTTP statuses, response shapes) against the legacy contract. The drift escaped review.

**Frozen legacy contract** (`serviceN-legacy-codes.txt`, extracted from the real legacy source):
`E0002 E1000 W0002 W0003 W0004 W0005 W0006 W0007 W0008 W0011 W0023`.

## The candidate rule (adjudicated from the finding)

`R-RESULTCODE-PARITY` (`resultcode_parity.py`): given the legacy result-code contract and a migrated
service's source, flag (a) **introduced** codes not in the legacy contract and (b) **dropped** legacy
codes. Severity BLOCK. Origin tagged `adjudicated:pr12-cpsl-sessiontoken:i05,i07,i12`.

## Promotion through the real approval path (no self-promotion)

Promotion is gated by a **distinct-approver-signed** approval using the deployed remote-gate approval
module (`pfverify.approval`, the same mechanism the live gate uses). Proven with the real code path
(`rule-approval.json`, approver=`security-lead`, payloadDigest `e87379be…`):
- **without** an approval → NOT promoted (fail-closed);
- signed with a **producer/wrong key** → `verify_approval` returns `False` (`approval.signature-invalid`)
  → NOT promoted (the engine/agent cannot self-promote);
- signed with the **distinct approver key** → verifies `True` → promoted.

## Service N+1 — a real sibling service, equivalent defect on a DISPOSABLE branch (never merged)

**Service**: `CTI.MicroService.TokenManager` (real CTI microservice, same token domain, same
`ResultCode` wire idiom). Legacy contract (`serviceN1-legacy-codes.txt`): `E0005 E0007 E1000`.

**Controlled equivalent defect**: on a **local, disposable, never-pushed, never-merged** git branch
`disposable/v11-tokenmanager-migration-DRIFT-DO-NOT-MERGE` in `CTIAPI-DEV_Work`:
- drift commit `2ad849f5` — the migrated `TokenService` introduces `S0000` + `W0024` (invented) and
  drops `E0005` (timeout) — the SAME class as the Service N finding;
- correction commit `bd695dc6` — parity restored (emits only `E0005 E0007 E1000`).

**Run Preflight before delivery** (promoted rule vs the real branch working-tree file):
- **DRIFTED** → `clean:false`, 3 violations (`introduced S0000`, `introduced W0024`, `dropped E0005`),
  exit 1 → **caught before delivery**.
- **CORRECTED** → `clean:true`, 0 violations, exit 0 → the corrected change **passes**.

Without the promoted rule (initial code-quality-only ruleset) the equivalent drift **escapes** — the
same failure mode as Service N. Only after the approved promotion is it caught.

## Loop verdict

`run_real_loop.py` → `loop_proven: true` (exit 0): drift escaped the initial ruleset → adjudicated →
promotion required a valid distinct-approver approval (producer key rejected) → equivalent N+1 drift
caught before delivery → corrected change passes. Shipped protocol mechanism test
`learning-loop-demo-test.sh` = **11/0**.

**Guardrails**: Service N finding is genuine (PR-12 audit, not invented). The equivalent defect exists
ONLY on the disposable N+1 branch, local-only, never pushed or merged. The CPSL pilot
(`CPSL_Migration_POC_temp`) and `NLX_Journeys` were NOT modified; the CTIAPI repo was restored to its
original branch `chore/add-migration-review-rubric`.
