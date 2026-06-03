---------------- MODULE MirrorProtocol ---------------------
EXTENDS Integers

\* -----------------------------------------------------------------------------
\* Protocol phases (mirror side)
\* -----------------------------------------------------------------------------

Ms == {"idle", "validating", "ready", "stepping", "done"}

\* Client phases
Cs == Ms \cup {"waiting_validation", "waiting_init", "waiting_action", "waiting_ack"}

\* Message tags (integers so TLC can enumerate the domain)
REGISTER        == 0
REPORT_STATE    == 1
SPEC_VALIDATED  == 2
INITIAL_STATE   == 3
NEXT_STEP       == 4
STEP_OK         == 5
STEP_MISMATCH   == 6
ALL_STEPS_DONE  == 7
PROTOCOL_ERROR  == 8

\* No-message sentinel — means the channel is empty
NO_MSG == -1

\* -----------------------------------------------------------------------------
\* Variables
\* -----------------------------------------------------------------------------

VARIABLE
  \* @type: Str;
  mp,           \* mirror phase
  \* @type: Str;
  cp,           \* client phase
  \* @type: Int;
  cl_to_mir,    \* client → mirror: message tag or NO_MSG
  \* @type: Int;
  mir_to_cl     \* mirror → client: message tag or NO_MSG

\* -----------------------------------------------------------------------------
\* Client actions — send
\* -----------------------------------------------------------------------------

ClientRegister ==
  /\ cp = "idle"
  /\ mp = "idle"
  /\ cl_to_mir = NO_MSG
  /\ cp' = "waiting_validation"
  /\ cl_to_mir' = REGISTER
  /\ UNCHANGED <<mp, mir_to_cl>>

ClientReport ==
  /\ cp = "waiting_action"
  /\ cl_to_mir = NO_MSG
  /\ cp' = "waiting_ack"
  /\ cl_to_mir' = REPORT_STATE
  /\ UNCHANGED <<mp, mir_to_cl>>

\* -----------------------------------------------------------------------------
\* Client actions — receive messages from mirror
\* -----------------------------------------------------------------------------

ClientRecvSpecValidated ==
  /\ mir_to_cl = SPEC_VALIDATED
  /\ cp = "waiting_validation"
  /\ cp' = "waiting_init"
  /\ mir_to_cl' = NO_MSG
  /\ UNCHANGED <<mp, cl_to_mir>>

ClientRecvInitialState ==
  /\ mir_to_cl = INITIAL_STATE
  /\ cp = "waiting_init"
  /\ cp' = "waiting_action"
  /\ mir_to_cl' = NO_MSG
  /\ UNCHANGED <<mp, cl_to_mir>>

ClientRecvNextStep ==
  /\ mir_to_cl = NEXT_STEP
  /\ cp = "waiting_ack"
  /\ cp' = "waiting_action"
  /\ mir_to_cl' = NO_MSG
  /\ UNCHANGED <<mp, cl_to_mir>>

ClientRecvStepOk ==
  /\ mir_to_cl = STEP_OK
  /\ cp = "waiting_ack"
  \* After step_ok, client stays in waiting_ack:
  \* the mirror will either send next_step or all_steps_done next.
  /\ cp' = "waiting_ack"
  /\ mir_to_cl' = NO_MSG
  /\ UNCHANGED <<mp, cl_to_mir>>

ClientRecvStepMismatch ==
  /\ mir_to_cl = STEP_MISMATCH
  /\ cp' = "done"
  /\ mir_to_cl' = NO_MSG
  /\ UNCHANGED <<mp, cl_to_mir>>

ClientRecvAllStepsDone ==
  /\ mir_to_cl = ALL_STEPS_DONE
  /\ cp = "waiting_ack"
  /\ cp' = "done"
  /\ mir_to_cl' = NO_MSG
  /\ UNCHANGED <<mp, cl_to_mir>>

ClientRecvProtocolError ==
  /\ mir_to_cl = PROTOCOL_ERROR
  /\ cp' = "done"
  /\ mir_to_cl' = NO_MSG
  /\ UNCHANGED <<mp, cl_to_mir>>

\* -----------------------------------------------------------------------------
\* Mirror actions — receive messages from client
\* -----------------------------------------------------------------------------

MirrorRecvRegister ==
  /\ cl_to_mir = REGISTER
  /\ mp = "idle"
  /\ mp' = "validating"
  /\ cl_to_mir' = NO_MSG
  /\ UNCHANGED <<cp, mir_to_cl>>

\* Mirror receives ReportState.
\* Nondeterministic branches encode: state match or mismatch,
\* and whether more trace steps remain.
MirrorRecvReportState ==
  /\ cl_to_mir = REPORT_STATE
  /\ mp = "stepping"
  /\ cl_to_mir' = NO_MSG
  /\ \/ /\ mp' = "stepping"            \* match, more steps remain
        /\ mir_to_cl' = STEP_OK         \* queued; NextStep sent separately
     \/ /\ mp' = "stepping"            \* match, last step
        /\ mir_to_cl' = ALL_STEPS_DONE
     \/ /\ mp' = "done"                \* mismatch
        /\ mir_to_cl' = STEP_MISMATCH
  /\ UNCHANGED cp

\* -----------------------------------------------------------------------------
\* Mirror actions — send messages to client
\* -----------------------------------------------------------------------------

MirrorSendSpecValidatedValid ==
  /\ mp = "validating"
  /\ mir_to_cl = NO_MSG
  /\ mp' = "ready"
  /\ mir_to_cl' = SPEC_VALIDATED
  /\ UNCHANGED <<cp, cl_to_mir>>

MirrorSendSpecValidatedInvalid ==
  /\ mp = "validating"
  /\ mir_to_cl = NO_MSG
  /\ mp' = "done"
  /\ mir_to_cl' = SPEC_VALIDATED
  /\ UNCHANGED <<cp, cl_to_mir>>

MirrorSendInitialState ==
  /\ mp = "ready"
  /\ mir_to_cl = NO_MSG
  /\ mp' = "stepping"
  /\ mir_to_cl' = INITIAL_STATE
  /\ UNCHANGED <<cp, cl_to_mir>>

\* After sending step_ok, mirror sends next_step if more steps remain.
MirrorSendNextStep ==
  /\ mir_to_cl = NO_MSG
  /\ mp = "stepping"
  /\ mp' = "stepping"
  /\ mir_to_cl' = NEXT_STEP
  /\ UNCHANGED <<cp, cl_to_mir>>

\* -----------------------------------------------------------------------------
\* Init
\* -----------------------------------------------------------------------------

Init ==
  /\ mp = "idle"
  /\ cp = "idle"
  /\ cl_to_mir = NO_MSG
  /\ mir_to_cl = NO_MSG

\* -----------------------------------------------------------------------------
\* Next
\* -----------------------------------------------------------------------------

Next ==
  \/ ClientRegister
  \/ ClientReport
  \/ ClientRecvSpecValidated
  \/ ClientRecvInitialState
  \/ ClientRecvNextStep
  \/ ClientRecvStepOk
  \/ ClientRecvStepMismatch
  \/ ClientRecvAllStepsDone
  \/ ClientRecvProtocolError
  \/ MirrorRecvRegister
  \/ MirrorRecvReportState
  \/ MirrorSendSpecValidatedValid
  \/ MirrorSendSpecValidatedInvalid
  \/ MirrorSendInitialState
  \/ MirrorSendNextStep

\* -----------------------------------------------------------------------------
\* Specification
\* -----------------------------------------------------------------------------

Spec == Init /\ [][Next]_<<mp, cp, cl_to_mir, mir_to_cl>>

\* -----------------------------------------------------------------------------
\* Invariants
\* -----------------------------------------------------------------------------

\* Both sides are always in valid phases.
PhaseOk ==
  /\ mp \in Ms
  /\ cp \in Cs

\* The happy path never sends protocol_error.
NoProtocolError ==
  mir_to_cl # PROTOCOL_ERROR

==============================================================================
