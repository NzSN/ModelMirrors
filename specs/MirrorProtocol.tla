---------------- MODULE MirrorProtocol ---------------------
EXTENDS Integers

\* -----------------------------------------------------------------------------
\* Protocol phases (mirror side)
\* -----------------------------------------------------------------------------

Ms == {"idle", "validating", "generating", "ready", "stepping", "done"}

\* Client phases
Cs == Ms \cup {"waiting_validation", "waiting_gen", "waiting_init", "waiting_action", "waiting_ack"}

\* Message tags (integers so TLC can enumerate the domain)
REGISTER           == 0
REGISTER_ERROR     == 1
REPORT_STATE       == 2
SPEC_VALIDATED     == 3
INITIAL_STATE      == 4
NEXT_STEP          == 5
STEP_OK            == 6
STEP_MISMATCH      == 7
ALL_STEPS_DONE     == 8
PROTOCOL_ERROR     == 9
REGISTER_TRACES    == 10
REGISTER_TRACE_GEN == 11
GEN_TRACES_DONE    == 12

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
  \* @type: Str;
  action_taken, \* label of the action executed at this step
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
  /\ action_taken' = "ClientRegister"
  /\ UNCHANGED <<mp, mir_to_cl>>

ClientRegisterTraces ==
  /\ cp = "idle"
  /\ mp = "idle"
  /\ cl_to_mir = NO_MSG
  /\ cp' = "waiting_validation"
  /\ cl_to_mir' = REGISTER_TRACES
  /\ action_taken' = "ClientRegisterTraces"
  /\ UNCHANGED <<mp, mir_to_cl>>

ClientRegisterGenTraces ==
  /\ cp = "idle"
  /\ mp = "idle"
  /\ cl_to_mir = NO_MSG
  /\ cp' = "waiting_gen"
  /\ cl_to_mir' = REGISTER_TRACE_GEN
  /\ action_taken' = "ClientRegisterGenTraces"
  /\ UNCHANGED <<mp, mir_to_cl>>

ClientReport ==
  /\ cp = "waiting_action"
  /\ cl_to_mir = NO_MSG
  /\ cp' = "waiting_ack"
  /\ cl_to_mir' = REPORT_STATE
  /\ action_taken' = "ClientReport"
  /\ UNCHANGED <<mp, mir_to_cl>>

\* -----------------------------------------------------------------------------
\* Client actions — receive messages from mirror
\* -----------------------------------------------------------------------------

ClientRecvSpecValidated ==
  /\ mir_to_cl = SPEC_VALIDATED
  /\ cp = "waiting_validation"
  /\ cp' = "waiting_init"
  /\ mir_to_cl' = NO_MSG
  /\ action_taken' = "ClientRecvSpecValidated"
  /\ UNCHANGED <<mp, cl_to_mir>>

ClientRecvGenTracesDone ==
  /\ mir_to_cl = GEN_TRACES_DONE
  /\ cp = "waiting_gen"
  /\ cp' = "idle"
  /\ mir_to_cl' = NO_MSG
  /\ action_taken' = "ClientRecvGenTracesDone"
  /\ UNCHANGED <<mp, cl_to_mir>>

ClientRecvInitialState ==
  /\ mir_to_cl = INITIAL_STATE
  /\ cp = "waiting_init"
  /\ cp' = "waiting_action"
  /\ mir_to_cl' = NO_MSG
  /\ action_taken' = "ClientRecvInitialState"
  /\ UNCHANGED <<mp, cl_to_mir>>

ClientRecvNextStep ==
  /\ mir_to_cl = NEXT_STEP
  /\ cp = "waiting_ack"
  /\ cp' = "waiting_action"
  /\ mir_to_cl' = NO_MSG
  /\ action_taken' = "ClientRecvNextStep"
  /\ UNCHANGED <<mp, cl_to_mir>>

ClientRecvStepOk ==
  /\ mir_to_cl = STEP_OK
  /\ cp = "waiting_ack"
  /\ cp' = "waiting_ack"
  /\ mir_to_cl' = NO_MSG
  /\ action_taken' = "ClientRecvStepOk"
  /\ UNCHANGED <<mp, cl_to_mir>>

ClientRecvStepMismatch ==
  /\ mir_to_cl = STEP_MISMATCH
  /\ cp' = "done"
  /\ mir_to_cl' = NO_MSG
  /\ action_taken' = "ClientRecvStepMismatch"
  /\ UNCHANGED <<mp, cl_to_mir>>

ClientRecvAllStepsDone ==
  /\ mir_to_cl = ALL_STEPS_DONE
  /\ cp = "waiting_ack"
  /\ cp' = "done"
  /\ mir_to_cl' = NO_MSG
  /\ action_taken' = "ClientRecvAllStepsDone"
  /\ UNCHANGED <<mp, cl_to_mir>>

ClientRecvProtocolError ==
  /\ mir_to_cl = PROTOCOL_ERROR
  /\ cp' = "done"
  /\ mir_to_cl' = NO_MSG
  /\ action_taken' = "ClientRecvProtocolError"
  /\ UNCHANGED <<mp, cl_to_mir>>

ClientRecvRegisterError ==
  /\ mir_to_cl = REGISTER_ERROR
  /\ cp = "waiting_validation"
  /\ cp' = "done"
  /\ mir_to_cl' = NO_MSG
  /\ action_taken' = "ClientRecvRegisterError"
  /\ UNCHANGED <<mp, cl_to_mir>>

\* -----------------------------------------------------------------------------
\* Mirror actions — receive messages from client
\* -----------------------------------------------------------------------------

MirrorRecvRegister ==
  /\ cl_to_mir = REGISTER
  /\ mp = "idle"
  /\ mp' = "validating"
  /\ cl_to_mir' = NO_MSG
  /\ action_taken' = "MirrorRecvRegister"
  /\ UNCHANGED <<cp, mir_to_cl>>

MirrorRecvRegisterTraces ==
  /\ cl_to_mir = REGISTER_TRACES
  /\ mp = "idle"
  /\ mp' = "ready"
  /\ cl_to_mir' = NO_MSG
  /\ mir_to_cl' = SPEC_VALIDATED
  /\ action_taken' = "MirrorRecvRegisterTraces"
  /\ UNCHANGED cp

MirrorRecvRegisterGenTraces ==
  /\ cl_to_mir = REGISTER_TRACE_GEN
  /\ mp = "idle"
  /\ mp' = "generating"
  /\ cl_to_mir' = NO_MSG
  /\ action_taken' = "MirrorRecvRegisterGenTraces"
  /\ UNCHANGED <<cp, mir_to_cl>>

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
     \/ /\ mp' = "stepping"            \* match, last step
        /\ mir_to_cl' = ALL_STEPS_DONE
     \/ /\ mp' = "done"                \* mismatch
        /\ mir_to_cl' = STEP_MISMATCH
  /\ UNCHANGED cp

\* -----------------------------------------------------------------------------
\* Mirror actions — send messages to client
\* -----------------------------------------------------------------------------

MirrorSendGenTracesDone ==
  /\ mp = "generating"
  /\ mir_to_cl = NO_MSG
  /\ mp' = "idle"
  /\ mir_to_cl' = GEN_TRACES_DONE
  /\ action_taken' = "MirrorSendGenTracesDone"
  /\ UNCHANGED <<cp, cl_to_mir>>

MirrorSendSpecValidatedValid ==
  /\ mp = "validating"
  /\ mir_to_cl = NO_MSG
  /\ mp' = "ready"
  /\ mir_to_cl' = SPEC_VALIDATED
  /\ action_taken' = "MirrorSendSpecValidatedValid"
  /\ UNCHANGED <<cp, cl_to_mir>>

MirrorSendSpecValidatedInvalid ==
  /\ mp = "validating"
  /\ mir_to_cl = NO_MSG
  /\ mp' = "done"
  /\ mir_to_cl' = SPEC_VALIDATED
  /\ action_taken' = "MirrorSendSpecValidatedInvalid"
  /\ UNCHANGED <<cp, cl_to_mir>>

MirrorSendRegisterError ==
  /\ mp = "validating"
  /\ mir_to_cl = NO_MSG
  /\ mp' = "done"
  /\ mir_to_cl' = REGISTER_ERROR
  /\ action_taken' = "MirrorSendRegisterError"
  /\ UNCHANGED <<cp, cl_to_mir>>

MirrorSendInitialState ==
  /\ mp = "ready"
  /\ mir_to_cl = NO_MSG
  /\ mp' = "stepping"
  /\ mir_to_cl' = INITIAL_STATE
  /\ action_taken' = "MirrorSendInitialState"
  /\ UNCHANGED <<cp, cl_to_mir>>

\* After sending step_ok, mirror sends next_step if more steps remain.
MirrorSendNextStep ==
  /\ mir_to_cl = NO_MSG
  /\ cl_to_mir = NO_MSG
  /\ mp = "stepping"
  /\ cp = "waiting_ack"
  /\ mp' = "stepping"
  /\ mir_to_cl' = NEXT_STEP
  /\ action_taken' = "MirrorSendNextStep"
  /\ UNCHANGED <<cp, cl_to_mir>>

\* -----------------------------------------------------------------------------
\* Init
\* -----------------------------------------------------------------------------

Init ==
  /\ mp = "idle"
  /\ cp = "idle"
  /\ action_taken = "init"
  /\ cl_to_mir = NO_MSG
  /\ mir_to_cl = NO_MSG

\* -----------------------------------------------------------------------------
\* Next
\* -----------------------------------------------------------------------------

Next ==
  \/ ClientRegister
  \/ ClientRegisterTraces
  \/ ClientRegisterGenTraces
  \/ ClientReport
  \/ ClientRecvSpecValidated
  \/ ClientRecvGenTracesDone
  \/ ClientRecvInitialState
  \/ ClientRecvNextStep
  \/ ClientRecvStepOk
  \/ ClientRecvStepMismatch
  \/ ClientRecvAllStepsDone
  \/ ClientRecvProtocolError
  \/ ClientRecvRegisterError
  \/ MirrorRecvRegister
  \/ MirrorRecvRegisterTraces
  \/ MirrorRecvRegisterGenTraces
  \/ MirrorRecvReportState
  \/ MirrorSendGenTracesDone
  \/ MirrorSendSpecValidatedValid
  \/ MirrorSendSpecValidatedInvalid
  \/ MirrorSendRegisterError
  \/ MirrorSendInitialState
  \/ MirrorSendNextStep

\* -----------------------------------------------------------------------------
\* Specification
\* -----------------------------------------------------------------------------

Spec == Init /\ [][Next]_<<mp, cp, action_taken, cl_to_mir, mir_to_cl>>

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

Inv == PhaseOk /\
       NoProtocolError

\* Force trace generation: Apalache finds counterexamples
\* showing paths from idle to done.
TraceComplete ==
  cp /= "done"

\* Force stepping path through ClientReport and mirror response.
TraceStepping ==
  mir_to_cl /= STEP_OK

\* View that captures protocol-relevant state for trace inspection.
MirrorView == <<mp, cp, action_taken, cl_to_mir, mir_to_cl>>

==============================================================================
