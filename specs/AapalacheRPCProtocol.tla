---------------- MODULE AapalacheRPCProtocol ---------------------
EXTENDS Integers

\* -----------------------------------------------------------------------------
\* This module models the observable behavior of the apalache explorer server
\* as a nondeterministic oracle. Each apalache operation (assumeTransition,
\* nextStep, checkInvariant, query, assumeState, rollback, disposeSpec) is
\* abstracted as a nondeterministic choice among its possible observable
\* outcomes.
\*
\* JSON-RPC wire details (HTTP, session IDs, error codes) are NOT modeled.
\* This is the abstract oracle — the Explorer Haskell code is the concrete
\* implementation. Integration tests against a real apalache-mc server verify
\* that the implementation's behavior is consistent with these oracle rules.
\* -----------------------------------------------------------------------------

\* -----------------------------------------------------------------------------
\* Explorer phases
\* -----------------------------------------------------------------------------

Ex == {"uninitialized", "ready", "running", "terminal", "disposed"}

\* Sentinel for "no operation is pending"
NO_OP == -1

\* -----------------------------------------------------------------------------
\* Variables
\* -----------------------------------------------------------------------------

VARIABLE
  \* @type: Str;
  expPhase,       \* explorer lifecycle phase
  \* @type: Int;
  expStep,        \* number of transitions taken since loadSpec
  \* @type: Int;
  expSnapshot,    \* current snapshot id (for rollback)
  \* @type: Str;
  action_taken    \* label of the oracle operation executed

\* -----------------------------------------------------------------------------
\* Explorer: loadSpec
\*
\* Observable outcomes:
\*   - Spec parses and loads successfully → phase becomes "ready"
\*   - Spec is malformed, missing dependencies, etc. → phase becomes "terminal"
\* -----------------------------------------------------------------------------

ExplorerLoadSpec ==
  /\ expPhase = "uninitialized"
  /\ \/ /\ expPhase' = "ready"
        /\ expStep' = 0
        /\ expSnapshot' = 0
        /\ action_taken' = "ExplorerLoadSpec"
     \/ /\ expPhase' = "terminal"
        /\ action_taken' = "ExplorerLoadSpec"
        /\ UNCHANGED <<expStep, expSnapshot>>

\* -----------------------------------------------------------------------------
\* Explorer: assumeTransition(tid) + nextStep  (composite operation)
\*
\* This models the combined operation used by exploreInit / exploreNext.
\* The mirror tells apalache: "assume transition tid, then advance."
\*
\* Observable outcomes:
\*   - Transition is enabled, state advances → "running", step+1, snapshot+1
\*   - Transition is disabled at current state → phase unchanged
\*   - Internal error or timeout → "terminal"
\* -----------------------------------------------------------------------------

ExplorerStep(tid) ==
  /\ expPhase \in {"ready", "running"}
  /\ \/ /\ expPhase' = "running"
        /\ expStep' = expStep + 1
        /\ expSnapshot' = expSnapshot + 1
        /\ action_taken' = "ExplorerStep"
     \/ /\ expPhase' = expPhase
        /\ action_taken' = "ExplorerStep"
        /\ UNCHANGED <<expStep, expSnapshot>>
     \/ /\ expPhase' = "terminal"
        /\ action_taken' = "ExplorerStep"
        /\ UNCHANGED <<expStep, expSnapshot>>

\* -----------------------------------------------------------------------------
\* Explorer: checkInvariant(iid, kind)
\*
\* Observable outcomes:
\*   - Invariant holds at current state → phase unchanged
\*   - Invariant is violated → "terminal" (counterexample found)
\* -----------------------------------------------------------------------------

ExplorerCheckInvariant(iid) ==
  /\ expPhase = "running"
  /\ \/ /\ expPhase' = "running"
        /\ action_taken' = "ExplorerCheckInvariant"
        /\ UNCHANGED <<expStep, expSnapshot>>
     \/ /\ expPhase' = "terminal"
        /\ action_taken' = "ExplorerCheckInvariant"
        /\ UNCHANGED <<expStep, expSnapshot>>

\* -----------------------------------------------------------------------------
\* Explorer: queryState and queryOperator
\*
\* Queries are read-only: they return the current state or operator value
\* without changing the explorer's phase, step, or snapshot.
\* -----------------------------------------------------------------------------

ExplorerQuery ==
  /\ expPhase \in {"ready", "running"}
  /\ action_taken' = "ExplorerQuery"
  /\ UNCHANGED <<expPhase, expStep, expSnapshot>>

\* -----------------------------------------------------------------------------
\* Explorer: assumeState(equalities)
\*
\* The client provides a set of variable equalities. Apalache determines
\* whether a state satisfying these equalities is reachable.
\*
\* Observable outcomes:
\*   - State is reachable → "running", step+1, snapshot+1
\*   - State is not reachable → phase unchanged
\* -----------------------------------------------------------------------------

ExplorerAssumeState ==
  /\ expPhase \in {"ready", "running"}
  /\ \/ /\ expPhase' = "running"
        /\ expStep' = expStep + 1
        /\ expSnapshot' = expSnapshot + 1
        /\ action_taken' = "ExplorerAssumeState"
     \/ /\ expPhase' = expPhase
        /\ action_taken' = "ExplorerAssumeState"
        /\ UNCHANGED <<expStep, expSnapshot>>
     \/ /\ expPhase' = "terminal"
        /\ action_taken' = "ExplorerAssumeState"
        /\ UNCHANGED <<expStep, expSnapshot>>

\* -----------------------------------------------------------------------------
\* Explorer: rollback(snapshotId)
\*
\* Rolls back to a prior snapshot. Only valid if the target snapshot
\* is not newer than the current one.
\*
\* Observable outcomes:
\*   - Rollback succeeds → phase returns to "ready" or "running"
\*     (depending on whether the target snapshot is at or past the init state)
\* -----------------------------------------------------------------------------

ExplorerRollback(snap) ==
  /\ expPhase \in {"ready", "running"}
  /\ snap <= expSnapshot
  /\ \/ /\ snap = 0
        /\ expPhase' = "ready"
     \/ /\ snap > 0
        /\ expPhase' = "running"
  /\ expSnapshot' = snap
  /\ action_taken' = "ExplorerRollback"
  /\ UNCHANGED expStep

\* -----------------------------------------------------------------------------
\* Explorer: disposeSpec
\*
\* Ends the exploration session. Valid from any non-uninitialized phase.
\* -----------------------------------------------------------------------------

ExplorerDispose ==
  /\ expPhase /= "uninitialized"
  /\ expPhase /= "disposed"
  /\ expPhase' = "disposed"
  /\ action_taken' = "ExplorerDispose"
  /\ UNCHANGED <<expStep, expSnapshot>>

\* -----------------------------------------------------------------------------
\* Next relation
\* -----------------------------------------------------------------------------

\* Bounded transition / invariant IDs so TLC can enumerate.
MaxTransitions == 4
MaxInvariants  == 2
MaxSnapshots   == 5

ExplorerNext ==
  \/ ExplorerLoadSpec
  \/ \E tid \in 0 .. MaxTransitions : ExplorerStep(tid)
  \/ \E iid \in 0 .. MaxInvariants : ExplorerCheckInvariant(iid)
  \/ ExplorerQuery
  \/ ExplorerAssumeState
  \/ \E snap \in 0 .. MaxSnapshots : ExplorerRollback(snap)
  \/ ExplorerDispose

\* -----------------------------------------------------------------------------
\* Init
\* -----------------------------------------------------------------------------

ExplorerInit ==
  /\ expPhase = "uninitialized"
  /\ expStep = 0
  /\ expSnapshot = 0
  /\ action_taken = "ExplorerInit"

\* -----------------------------------------------------------------------------
\* Specification
\* -----------------------------------------------------------------------------

ExplorerSpec ==
  ExplorerInit /\ [][ExplorerNext]_<<expPhase, expStep, expSnapshot, action_taken>>

\* -----------------------------------------------------------------------------
\* Invariants
\* -----------------------------------------------------------------------------

\* The explorer phase is always valid.
PhaseValid ==
  expPhase \in Ex

\* A disposed explorer cannot be used again (action property).
DisposedTerminal ==
  (expPhase = "disposed") => (expPhase' = "disposed")

\* Combined state invariant.
ExplorerInv ==
  PhaseValid

\* -----------------------------------------------------------------------------
\* Trace generation invariants (for apalache counterexample generation)
\* -----------------------------------------------------------------------------

\* Force exploration to reach terminal state (via invariant violation or error).
ExploreUntilTerminal ==
  expPhase /= "terminal" /\ expPhase /= "disposed"

\* View for trace inspection.
ExplorerView == <<expPhase, expStep, expSnapshot, action_taken>>

==============================================================================
