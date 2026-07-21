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
\*
\* Abstractions:
\*   - assumeTransition and nextStep are modeled as SEPARATE operations
\*     (ExplorerAssume / ExplorerAdvance), with expPending tracking an
\*     assumed-but-not-yet-advanced transition.
\*   - Snapshot ids are abstracted to one per completed step: the server's
\*     finer-grained snapshots (taken by assumeTransition and assumeState)
\*     are not exposed. Hence expSnapshot = expStep at all times, and
\*     rollback targets are exactly the step boundaries.
\* -----------------------------------------------------------------------------

\* -----------------------------------------------------------------------------
\* Explorer phases
\* -----------------------------------------------------------------------------

Ex == {"uninitialized", "ready", "running", "terminal", "disposed"}

\* Sentinel: no transition has been assumed and is awaiting nextStep.
NO_PENDING == -1

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
  \* @type: Int;
  expPending,     \* assumed-but-not-advanced transition id; NO_PENDING if none
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
        /\ expPending' = NO_PENDING
        /\ action_taken' = "ExplorerLoadSpec"
     \/ /\ expPhase' = "terminal"
        /\ action_taken' = "ExplorerLoadSpec"
        /\ UNCHANGED <<expStep, expSnapshot, expPending>>

\* -----------------------------------------------------------------------------
\* Explorer: assumeTransition(tid)
\*
\* Adds the transition's constraints to the solver context and (if
\* checkEnabled) tests feasibility. Does NOT advance the state; a
\* subsequent ExplorerAdvance (nextStep) is required, and is only legal
\* after an ENABLED assume.
\*
\* Observable outcomes:
\*   - ENABLED  → transition recorded as pending, phase unchanged
\*   - DISABLED → context auto-rolled-back, nothing changes
\*   - Internal error or timeout → "terminal"
\* -----------------------------------------------------------------------------

ExplorerAssume(tid) ==
  /\ expPhase \in {"ready", "running"}
  /\ expPending = NO_PENDING
  /\ \/ /\ expPending' = tid
        /\ action_taken' = "ExplorerAssume"
        /\ UNCHANGED <<expPhase, expStep, expSnapshot>>
     \/ /\ action_taken' = "ExplorerAssume"
        /\ UNCHANGED <<expPhase, expStep, expSnapshot, expPending>>
     \/ /\ expPhase' = "terminal"
        /\ action_taken' = "ExplorerAssume"
        /\ UNCHANGED <<expStep, expSnapshot, expPending>>

\* -----------------------------------------------------------------------------
\* Explorer: nextStep
\*
\* Advances to the next symbolic state after an ENABLED assume: renames
\* primed variables to unprimed, increments step and snapshot, and clears
\* the pending transition.
\*
\* Observable outcomes:
\*   - Success → "running", step+1, snapshot+1, pending cleared
\*   - Internal error → "terminal"
\* -----------------------------------------------------------------------------

ExplorerAdvance ==
  /\ expPhase \in {"ready", "running"}
  /\ expPending /= NO_PENDING
  /\ \/ /\ expPhase' = "running"
        /\ expStep' = expStep + 1
        /\ expSnapshot' = expSnapshot + 1
        /\ expPending' = NO_PENDING
        /\ action_taken' = "ExplorerAdvance"
     \/ /\ expPhase' = "terminal"
        /\ action_taken' = "ExplorerAdvance"
        /\ UNCHANGED <<expStep, expSnapshot, expPending>>

\* -----------------------------------------------------------------------------
\* Explorer: checkInvariant(iid, kind)
\*
\* Observable outcomes:
\*   - Invariant holds at current state → phase unchanged
\*   - Invariant is violated → "terminal" (counterexample found)
\*
\* Note: the real server rolls the context back after checkInvariant and
\* the session remains usable. Here "terminal" models the HARNESS policy
\* (exploreUntilViolation) of stopping exploration once a counterexample
\* is found, not a server-side session state.
\* -----------------------------------------------------------------------------

ExplorerCheckInvariant(iid) ==
  /\ expPhase = "running"
  /\ \/ /\ expPhase' = "running"
        /\ action_taken' = "ExplorerCheckInvariant"
        /\ UNCHANGED <<expStep, expSnapshot, expPending>>
     \/ /\ expPhase' = "terminal"
        /\ action_taken' = "ExplorerCheckInvariant"
        /\ UNCHANGED <<expStep, expSnapshot, expPending>>

\* -----------------------------------------------------------------------------
\* Explorer: queryState and queryOperator
\*
\* Queries are read-only: they return the current state or operator value
\* without changing the explorer's phase, step, or snapshot.
\* -----------------------------------------------------------------------------

ExplorerQuery ==
  /\ expPhase \in {"ready", "running"}
  /\ action_taken' = "ExplorerQuery"
  /\ UNCHANGED <<expPhase, expStep, expSnapshot, expPending>>

\* -----------------------------------------------------------------------------
\* Explorer: assumeState(equalities)
\*
\* The client provides a set of variable equalities. Apalache determines
\* whether a state satisfying these equalities is reachable.
\*
\* The real assumeState asserts equalities against the CURRENT frame: it
\* does NOT advance the step counter (no primed-to-unprimed renaming
\* happens). Its snapshot is abstracted away (see the module header).
\* It is only valid after at least one assumeTransition + nextStep,
\* hence the "running" guard.
\*
\* Observable outcomes:
\*   - State is reachable (ENABLED) → phase unchanged
\*   - State is not reachable (DISABLED) → phase unchanged
\*   - Internal error or timeout → "terminal"
\* -----------------------------------------------------------------------------

ExplorerAssumeState ==
  /\ expPhase = "running"
  /\ \/ /\ expPhase' = "running"
        /\ action_taken' = "ExplorerAssumeState"
        /\ UNCHANGED <<expStep, expSnapshot, expPending>>
     \/ /\ expPhase' = expPhase
        /\ action_taken' = "ExplorerAssumeState"
        /\ UNCHANGED <<expStep, expSnapshot, expPending>>
     \/ /\ expPhase' = "terminal"
        /\ action_taken' = "ExplorerAssumeState"
        /\ UNCHANGED <<expStep, expSnapshot, expPending>>

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
  \* Rolling back to snapshot n also reverts the step counter (snapshots
  \* are one per completed step, so expStep' = snap) and discards any
  \* assumed-but-not-advanced transition.
  /\ expStep' = snap
  /\ expPending' = NO_PENDING

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
  /\ UNCHANGED <<expStep, expSnapshot, expPending>>

\* -----------------------------------------------------------------------------
\* Next relation
\* -----------------------------------------------------------------------------

\* Bounded transition / invariant IDs so TLC can enumerate.
MaxTransitions == 4
MaxInvariants  == 2
MaxSnapshots   == 5

ExplorerNext ==
  \/ ExplorerLoadSpec
  \/ \E tid \in 0 .. MaxTransitions : ExplorerAssume(tid)
  \/ ExplorerAdvance
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
  /\ expPending = NO_PENDING
  /\ action_taken = "ExplorerInit"

\* -----------------------------------------------------------------------------
\* Specification
\* -----------------------------------------------------------------------------

ExplorerSpec ==
  ExplorerInit /\ [][ExplorerNext]_<<expPhase, expStep, expSnapshot, expPending, action_taken>>

\* -----------------------------------------------------------------------------
\* Invariants
\* -----------------------------------------------------------------------------

\* The explorer phase is always valid.
PhaseValid ==
  expPhase \in Ex

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
ExplorerView == <<expPhase, expStep, expSnapshot, expPending, action_taken>>

==============================================================================
