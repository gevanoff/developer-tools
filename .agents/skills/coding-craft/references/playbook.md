# Coding Craft Playbook

**Make the intended behavior reliable, comprehensible, and cheap to change.**
Use with `method.md`. This is for implementing, repairing, refactoring, and
reviewing software. It is not a mandate to redesign a repository during a small fix.

## 1. The engineering contract

Name the user-visible outcome before the architecture. Record one concrete
before/after example, supported callers and environments, invariants, and failure
behavior. Read the closest repository instructions and the existing implementation.
Identify data ownership, compatibility obligations, and the boundary of this change.
Use precise names, units, schema fields, error codes, and measurements when needed.
Clarity does not justify deleting necessary technical detail.

For significant changes, keep a short decision note with alternatives and the
reason for the chosen tradeoff. For a defect, preserve a reproducer or failing
check when feasible. Distinguish observed cause from a plausible hypothesis.

## 2. Design tests

- Can the smallest complete user path be traced from input to durable outcome?
- Which invariant must survive exceptions, cancellation, retries, and restarts?
- At each trust boundary, who authenticates, who authorizes, and who validates?
- What happens with empty, malformed, large, duplicate, delayed, or concurrent input?
- What existing caller or persisted record would break after this change?
- Can a maintainer understand the ownership and state transitions without guessing?

Use the repository's abstractions before adding new ones. Abstract when multiple
real callers share a stable contract; avoid speculative frameworks. Keep I/O and
policy separable enough to verify, without splitting a simple operation into a maze.
Prefer explicit state and ownership over hidden mutation or clever control flow.

## 3. Pilot a complete slice

Implement the narrowest path that crosses the risky boundary: real persistence,
an API round trip, a UI action through the service, or the actual parser format.
Use mocks for controlled cases, then identify what they cannot establish. A mocked
provider response proves local handling, not provider availability or compatibility.
Do not build all screens around an unverified endpoint or a stubbed success path.

## 4. Implementation craft

Keep names tied to domain meaning. Make units and nullable states explicit. Handle
errors where enough context exists to act; preserve causes without leaking secrets.
Do not swallow failures, fabricate success, or silently weaken validation.
For retries, identify idempotency, duplicate effects, bounds, and cancellation.
For shared state, test the contested transition rather than assuming serialized use.
Avoid logging credentials or unnecessary personal data. Use established validation,
parameterization, and escaping at the appropriate boundary.

Keep comments for rationale, constraints, and surprising behavior; remove narration
that merely repeats code. Update user-facing help when behavior changes. Preserve
unrelated edits and dependency versions unless the task requires changing them.

## 5. Evidence that earns acceptance

Choose tests by consequence and uncertainty. A trivial reversible wording change
may need inspection only. A stateful fix needs a reproducer, the corrected path,
and a likely regression. Tests should check externally meaningful behavior rather
than mock-call choreography that reproduces the implementation.

Run the project's relevant checks after the final edit. Record exact commands,
environment, result, and gaps. For migrations, inspect old data and verify both the
upgrade and the recovery/compatibility plan before rollout. For performance work,
compare equivalent workloads and report distribution, resource limits, and baseline.
For a UI, exercise the changed flow, keyboard/focus behavior, and error state where
applicable. Compilation alone establishes none of those interactions.

## 6. Adversarial critic lenses

**Maintainer:** Trace a realistic change request through the design. Is the contract
clear? Is complexity paying for a current need? What can be removed without losing
the behavior? Flag coupling and misleading names with concrete maintenance costs.

**Hostile caller / reliability engineer:** Attempt malformed input, unauthorized
access, duplicate requests, interrupted writes, races, and dependency failure where
relevant. Give a reproducible path and consequence, not a generic security checklist.

**User / regression reviewer:** Start from the original problem. Demonstrate the
before/after path and inspect affected callers. Seek tests that could pass while the
bug remains. Verify that docs and error messages match actual behavior.

Apply the shared loop. Fix structural ownership or contract errors before formatting.
No average score can compensate for data loss, broken authorization, or a required
path that still fails. Review-only tasks report findings without inventing fixes.

## 7. Delivery and failure modes

Inspect the final diff, stage only intended files, and follow the project's Git
publication rules. A commit is not a deployment; passing CI is not production
qualification. Report branch, commit, checks, and any unverified environment.
If deployment is authorized, verify the specific deployed version and the requested
end-to-end behavior, with an appropriate recovery path.

Common traps: polishing a wrong abstraction; adding tests that only echo the code;
patching symptoms while the state model remains broken; unbounded retries; claiming
success from a healthy process; growing the change to solve unrelated problems.

### Calibration case

An import retries after timing out, but the first request already saved the record.
An extra retry can make the interface look fixed while duplicating data. The critic
asks for a timeout-after-write reproduction and the domain's intended duplicate
semantics. Resolve ownership/idempotency, then verify the resulting durable records;
do not accept a test that merely asserts the retry function was called.

For operational changes, also require an observable failure signal and a diagnostic
path that does not expose secrets. A rollback may be impossible after a destructive
data migration; name the forward-repair or restore plan instead of promising undo.

```text
Change brief
Trigger and observed failure:
Required behavior / invariant:
Callers and compatibility:
Smallest fix / deliberate exclusions:
Failure and concurrency cases relevant here:
Validation command -> expected observation:
Delivery and recovery requirements:
```
