---------------- MODULE MirrorProtocolServer -----------------
\* Mirror (server) side of the ModelMirrors protocol.
\* Models the mirror FSM with the client as a nondeterministic
\* external actor.  The TraceComplete invariant forces Apalache
\* to generate counterexample traces through to completion.

EXTENDS Integers

\* -----------------------------------------------------------------------------
\* Mirror phases
\* -----------------------------------------------------------------------------

Ms == {"idle", "validating", "ready", "stepping", "done"}

\* -----------------------------------------------------------------------------
\* Message tags (integers so TLC can enumerate the domain)
\* -----------------------------------------------------------------------------

REGISTER        == 0
REGISTER_ERROR  == 1
REPORT_STATE    == 2
SPEC_VALIDATED  == 3
INITIAL_STATE   == 4
NEXT_STEP       == 5
STEP_OK         == 6
STEP_MISMATCH   == 7
ALL_STEPS_DONE  == 8

\* No-message sentinel — means the channel is empty
NO_MSG == -1

\* -----------------------------------------------------------------------------
\* Variables (mirror-owned)
\* -----------------------------------------------------------------------------

VARIABLE
  \* @type: Str;
  mp,           \* mirror phase
  \* @type: Str;
  action_taken, \* label of the action executed at this step
  \* @type: Int;
  cl_to_mir,    \* client → mirror: message tag or NO_MSG
  \* @type: Int;
  mir_to_cl,    \* mirror → client: message tag or NO_MSG
  \* @type: Int;
  step_count    \* number of stepping rounds performed

\* -----------------------------------------------------------------------------
\* Mirror actions — receive messages from client
\* -----------------------------------------------------------------------------

MirrorRecvRegister ==
  /\ cl_to_mir = REGISTER
  /\ mp = "idle"
  /\ mp' = "validating"
  /\ cl_to_mir' = NO_MSG
  /\ action_taken' = "MirrorRecvRegister"
  /\ UNCHANGED <<mir_to_cl, step_count>>

\* Mirror receives ReportState.
\* Nondeterministic branches encode: state match or mismatch,
\* and whether more trace steps remain.
MirrorRecvReportState ==
  /\ cl_to_mir = REPORT_STATE
  /\ mp = "stepping"
  /\ cl_to_mir' = NO_MSG
  /\ action_taken' = "MirrorRecvReportState"
  /\ \/ /\ mp' = "stepping"            \* match, more steps remain
        /\ mir_to_cl' = STEP_OK         \* queued; NextStep sent separately
        /\ step_count' = step_count + 1
     \/ /\ mp' = "stepping"            \* match, last step
        /\ mir_to_cl' = ALL_STEPS_DONE
        /\ step_count' = step_count + 1
     \/ /\ mp' = "done"                \* mismatch
        /\ mir_to_cl' = STEP_MISMATCH
        /\ step_count' = step_count + 1

\* -----------------------------------------------------------------------------
\* Mirror actions — send messages to client
\* -----------------------------------------------------------------------------

MirrorSendSpecValidatedValid ==
  /\ mp = "validating"
  /\ mir_to_cl = NO_MSG
  /\ mp' = "ready"
  /\ mir_to_cl' = SPEC_VALIDATED
  /\ action_taken' = "MirrorSendSpecValidatedValid"
  /\ UNCHANGED <<cl_to_mir, step_count>>

MirrorSendSpecValidatedInvalid ==
  /\ mp = "validating"
  /\ mir_to_cl = NO_MSG
  /\ mp' = "done"
  /\ mir_to_cl' = SPEC_VALIDATED
  /\ action_taken' = "MirrorSendSpecValidatedInvalid"
  /\ UNCHANGED <<cl_to_mir, step_count>>

MirrorSendRegisterError ==
  /\ mp = "validating"
  /\ mir_to_cl = NO_MSG
  /\ mp' = "done"
  /\ mir_to_cl' = REGISTER_ERROR
  /\ action_taken' = "MirrorSendRegisterError"
  /\ UNCHANGED <<cl_to_mir, step_count>>

MirrorSendInitialState ==
  /\ mp = "ready"
  /\ mir_to_cl = NO_MSG
  /\ mp' = "stepping"
  /\ mir_to_cl' = INITIAL_STATE
  /\ action_taken' = "MirrorSendInitialState"
  /\ UNCHANGED <<cl_to_mir, step_count>>

\* After sending step_ok, mirror sends next_step if more steps remain.
MirrorSendNextStep ==
  /\ mir_to_cl = NO_MSG
  /\ mp = "stepping"
  /\ mp' = "stepping"
  /\ mir_to_cl' = NEXT_STEP
  /\ action_taken' = "MirrorSendNextStep"
  /\ UNCHANGED <<cl_to_mir, step_count>>

\* -----------------------------------------------------------------------------
\* Client actions (abstracted as nondeterministic environment)
\* -----------------------------------------------------------------------------

\* Client sends Register — this starts the protocol.
ClientSendRegister ==
  /\ mp = "idle"
  /\ cl_to_mir = NO_MSG
  /\ cl_to_mir' = REGISTER
  /\ action_taken' = "ClientSendRegister"
  /\ UNCHANGED <<mp, mir_to_cl, step_count>>

\* Client sends ReportState — only when mirror expects it (stepping, no queued msg).
ClientSendReport ==
  /\ mp = "stepping"
  /\ cl_to_mir = NO_MSG
  /\ mir_to_cl \in {STEP_OK, NEXT_STEP, NO_MSG}
  /\ cl_to_mir' = REPORT_STATE
  /\ action_taken' = "ClientSendReport"
  /\ UNCHANGED <<mp, mir_to_cl, step_count>>

\* -----------------------------------------------------------------------------
\* Init
\* -----------------------------------------------------------------------------

Init ==
  /\ mp = "idle"
  /\ action_taken = "init"
  /\ cl_to_mir = NO_MSG
  /\ mir_to_cl = NO_MSG
  /\ step_count = 0

\* -----------------------------------------------------------------------------
\* Next
\* -----------------------------------------------------------------------------

Next ==
  \/ MirrorRecvRegister
  \/ MirrorRecvReportState
  \/ MirrorSendSpecValidatedValid
  \/ MirrorSendSpecValidatedInvalid
  \/ MirrorSendRegisterError
  \/ MirrorSendInitialState
  \/ MirrorSendNextStep
  \/ ClientSendRegister
  \/ ClientSendReport

\* -----------------------------------------------------------------------------
\* Specification
\* -----------------------------------------------------------------------------

Spec == Init /\ [][Next]_<<mp, action_taken, cl_to_mir, mir_to_cl, step_count>>

\* -----------------------------------------------------------------------------
\* Invariants
\* -----------------------------------------------------------------------------

PhaseOk == mp \in Ms

\* Force trace generation: Apalache will find a counterexample
\* showing a path from idle to done within the bounded search.
\* Use --inv=TraceComplete --length=20 with apalache-mc.
TraceComplete == mp /= "done"

===============================================================================
