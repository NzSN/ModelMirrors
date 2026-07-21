---------------- MODULE MirrorProtocol ---------------------
EXTENDS Integers

\* -----------------------------------------------------------------------------
\* Protocol phases (mirror side)
\* -----------------------------------------------------------------------------

Ms == {"idle", "validating", "generating", "ready", "stepping", "exploring", "done"}

\* Client phases
Cs == Ms \cup {"waiting_validation", "waiting_gen", "waiting_init", "waiting_action", "waiting_ack", "waiting_done"}

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
REGISTER_EXPLORE   == 13
REGISTER_EXPLORER_SESSION == 14
EXPLORER_READY     == 15
EXPLORE_CMD        == 16
EXPLORE_RESULT     == 17
EXPLORE_DONE       == 18

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
  \* @type: Str;
  mflow,        \* active registration flow: "none" | "traces" | "session"
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
  /\ UNCHANGED <<mp, mir_to_cl, mflow>>

ClientRegisterTraces ==
  /\ cp = "idle"
  /\ mp = "idle"
  /\ cl_to_mir = NO_MSG
  /\ cp' = "waiting_validation"
  /\ cl_to_mir' = REGISTER_TRACES
  /\ action_taken' = "ClientRegisterTraces"
  /\ UNCHANGED <<mp, mir_to_cl, mflow>>

ClientRegisterGenTraces ==
  /\ cp = "idle"
  /\ mp = "idle"
  /\ cl_to_mir = NO_MSG
  /\ cp' = "waiting_gen"
  /\ cl_to_mir' = REGISTER_TRACE_GEN
  /\ action_taken' = "ClientRegisterGenTraces"
  /\ UNCHANGED <<mp, mir_to_cl, mflow>>

\* Interactive symbolic exploration: at the message level the explore
\* flow is identical to Register (validate → step through states), so it
\* reuses the same mirror/client phases and step messages.
ClientRegisterExplore ==
  /\ cp = "idle"
  /\ mp = "idle"
  /\ cl_to_mir = NO_MSG
  /\ cp' = "waiting_validation"
  /\ cl_to_mir' = REGISTER_EXPLORE
  /\ action_taken' = "ClientRegisterExplore"
  /\ UNCHANGED <<mp, mir_to_cl, mflow>>

\* Client-driven interactive symbolic checking: the client opens an
\* explore session and then issues explorer commands (assumeTransition,
\* nextStep, query, checkInvariant, assumeState, rollback) itself; the
\* mirror forwards them to the apalache explorer server and returns the
\* results. Commands and results strictly alternate.
ClientRegisterExploreSession ==
  /\ cp = "idle"
  /\ mp = "idle"
  /\ cl_to_mir = NO_MSG
  /\ cp' = "waiting_validation"
  /\ cl_to_mir' = REGISTER_EXPLORER_SESSION
  /\ action_taken' = "ClientRegisterExploreSession"
  /\ UNCHANGED <<mp, mir_to_cl, mflow>>

ClientExploreCmd ==
  /\ cp = "exploring"
  /\ cl_to_mir = NO_MSG
  /\ mir_to_cl = NO_MSG
  /\ cl_to_mir' = EXPLORE_CMD
  /\ action_taken' = "ClientExploreCmd"
  /\ UNCHANGED <<mp, cp, mir_to_cl, mflow>>

ClientExploreDone ==
  /\ cp = "exploring"
  /\ cl_to_mir = NO_MSG
  /\ mir_to_cl = NO_MSG
  /\ cl_to_mir' = EXPLORE_DONE
  /\ cp' = "waiting_done"
  /\ action_taken' = "ClientExploreDone"
  /\ UNCHANGED <<mp, mir_to_cl, mflow>>

ClientReport ==
  /\ cp = "waiting_action"
  /\ cl_to_mir = NO_MSG
  /\ cp' = "waiting_ack"
  /\ cl_to_mir' = REPORT_STATE
  /\ action_taken' = "ClientReport"
  /\ UNCHANGED <<mp, mir_to_cl, mflow>>

\* -----------------------------------------------------------------------------
\* Client actions — receive messages from mirror
\* -----------------------------------------------------------------------------

ClientRecvSpecValidated ==
  /\ mir_to_cl = SPEC_VALIDATED
  /\ cp = "waiting_validation"
  /\ cp' = "waiting_init"
  /\ mir_to_cl' = NO_MSG
  /\ action_taken' = "ClientRecvSpecValidated"
  /\ UNCHANGED <<mp, cl_to_mir, mflow>>

ClientRecvGenTracesDone ==
  /\ mir_to_cl = GEN_TRACES_DONE
  /\ cp = "waiting_gen"
  /\ cp' = "idle"
  /\ mir_to_cl' = NO_MSG
  /\ action_taken' = "ClientRecvGenTracesDone"
  /\ UNCHANGED <<mp, cl_to_mir, mflow>>

ClientRecvInitialState ==
  /\ mir_to_cl = INITIAL_STATE
  /\ cp = "waiting_init"
  /\ cp' = "waiting_action"
  /\ mir_to_cl' = NO_MSG
  /\ action_taken' = "ClientRecvInitialState"
  /\ UNCHANGED <<mp, cl_to_mir, mflow>>

ClientRecvNextStep ==
  /\ mir_to_cl = NEXT_STEP
  /\ cp = "waiting_ack"
  /\ cp' = "waiting_action"
  /\ mir_to_cl' = NO_MSG
  /\ action_taken' = "ClientRecvNextStep"
  /\ UNCHANGED <<mp, cl_to_mir, mflow>>

ClientRecvStepOk ==
  /\ mir_to_cl = STEP_OK
  /\ cp = "waiting_ack"
  /\ cp' = "waiting_ack"
  /\ mir_to_cl' = NO_MSG
  /\ action_taken' = "ClientRecvStepOk"
  /\ UNCHANGED <<mp, cl_to_mir, mflow>>

ClientRecvStepMismatch ==
  /\ mir_to_cl = STEP_MISMATCH
  /\ cp' = "done"
  /\ mir_to_cl' = NO_MSG
  /\ action_taken' = "ClientRecvStepMismatch"
  /\ UNCHANGED <<mp, cl_to_mir, mflow>>

ClientRecvAllStepsDone ==
  /\ mir_to_cl = ALL_STEPS_DONE
  /\ cp = "waiting_ack"
  /\ cp' = "done"
  /\ mir_to_cl' = NO_MSG
  /\ action_taken' = "ClientRecvAllStepsDone"
  /\ UNCHANGED <<mp, cl_to_mir, mflow>>

ClientRecvProtocolError ==
  /\ mir_to_cl = PROTOCOL_ERROR
  /\ cp' = "done"
  /\ mir_to_cl' = NO_MSG
  /\ action_taken' = "ClientRecvProtocolError"
  /\ UNCHANGED <<mp, cl_to_mir, mflow>>

ClientRecvRegisterError ==
  /\ mir_to_cl = REGISTER_ERROR
  /\ cp = "waiting_validation"
  /\ cp' = "done"
  /\ mir_to_cl' = NO_MSG
  /\ action_taken' = "ClientRecvRegisterError"
  /\ UNCHANGED <<mp, cl_to_mir, mflow>>

ClientRecvExplorerReady ==
  /\ mir_to_cl = EXPLORER_READY
  /\ cp = "waiting_validation"
  /\ cp' = "exploring"
  /\ mir_to_cl' = NO_MSG
  /\ action_taken' = "ClientRecvExplorerReady"
  /\ UNCHANGED <<mp, cl_to_mir, mflow>>

ClientRecvExploreResult ==
  /\ mir_to_cl = EXPLORE_RESULT
  /\ cp = "exploring"
  /\ mir_to_cl' = NO_MSG
  /\ action_taken' = "ClientRecvExploreResult"
  /\ UNCHANGED <<mp, cp, cl_to_mir, mflow>>

ClientRecvExploreDoneAck ==
  /\ mir_to_cl = EXPLORE_DONE
  /\ cp = "waiting_done"
  /\ cp' = "done"
  /\ mir_to_cl' = NO_MSG
  /\ action_taken' = "ClientRecvExploreDoneAck"
  /\ UNCHANGED <<mp, cl_to_mir, mflow>>

\* -----------------------------------------------------------------------------
\* Mirror actions — receive messages from client
\* -----------------------------------------------------------------------------

MirrorRecvRegister ==
  /\ cl_to_mir = REGISTER
  /\ mp = "idle"
  /\ mp' = "validating"
  /\ mflow' = "traces"
  /\ cl_to_mir' = NO_MSG
  /\ action_taken' = "MirrorRecvRegister"
  /\ UNCHANGED <<cp, mir_to_cl>>

MirrorRecvRegisterTraces ==
  /\ cl_to_mir = REGISTER_TRACES
  /\ mp = "idle"
  /\ mp' = "ready"
  /\ mflow' = "traces"
  /\ cl_to_mir' = NO_MSG
  /\ mir_to_cl' = SPEC_VALIDATED
  /\ action_taken' = "MirrorRecvRegisterTraces"
  /\ UNCHANGED cp

MirrorRecvRegisterGenTraces ==
  /\ cl_to_mir = REGISTER_TRACE_GEN
  /\ mp = "idle"
  /\ mp' = "generating"
  /\ mflow' = "traces"
  /\ cl_to_mir' = NO_MSG
  /\ action_taken' = "MirrorRecvRegisterGenTraces"
  /\ UNCHANGED <<cp, mir_to_cl>>

MirrorRecvRegisterExplore ==
  /\ cl_to_mir = REGISTER_EXPLORE
  /\ mp = "idle"
  /\ mp' = "validating"
  /\ mflow' = "traces"
  /\ cl_to_mir' = NO_MSG
  /\ action_taken' = "MirrorRecvRegisterExplore"
  /\ UNCHANGED <<cp, mir_to_cl>>

MirrorRecvRegisterExploreSession ==
  /\ cl_to_mir = REGISTER_EXPLORER_SESSION
  /\ mp = "idle"
  /\ mp' = "validating"
  /\ mflow' = "session"
  /\ cl_to_mir' = NO_MSG
  /\ action_taken' = "MirrorRecvRegisterExploreSession"
  /\ UNCHANGED <<cp, mir_to_cl>>

MirrorRecvExploreCmd ==
  /\ cl_to_mir = EXPLORE_CMD
  /\ mp = "exploring"
  /\ cl_to_mir' = NO_MSG
  /\ mir_to_cl' = EXPLORE_RESULT
  /\ action_taken' = "MirrorRecvExploreCmd"
  /\ UNCHANGED <<mp, cp, mflow>>

MirrorRecvExploreDone ==
  /\ cl_to_mir = EXPLORE_DONE
  /\ mp = "exploring"
  /\ mp' = "done"
  /\ cl_to_mir' = NO_MSG
  /\ mir_to_cl' = EXPLORE_DONE
  /\ action_taken' = "MirrorRecvExploreDone"
  /\ UNCHANGED <<cp, mflow>>

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
  /\ UNCHANGED <<cp, mflow>>

\* -----------------------------------------------------------------------------
\* Mirror actions — send messages to client
\* -----------------------------------------------------------------------------

MirrorSendGenTracesDone ==
  /\ mp = "generating"
  /\ mir_to_cl = NO_MSG
  /\ mp' = "idle"
  /\ mir_to_cl' = GEN_TRACES_DONE
  /\ action_taken' = "MirrorSendGenTracesDone"
  /\ UNCHANGED <<cp, cl_to_mir, mflow>>

MirrorSendSpecValidatedValid ==
  /\ mp = "validating"
  /\ mflow = "traces"
  /\ mir_to_cl = NO_MSG
  /\ mp' = "ready"
  /\ mir_to_cl' = SPEC_VALIDATED
  /\ action_taken' = "MirrorSendSpecValidatedValid"
  /\ UNCHANGED <<cp, cl_to_mir, mflow>>

MirrorSendSpecValidatedInvalid ==
  /\ mp = "validating"
  /\ mflow = "traces"
  /\ mir_to_cl = NO_MSG
  /\ mp' = "done"
  /\ mir_to_cl' = SPEC_VALIDATED
  /\ action_taken' = "MirrorSendSpecValidatedInvalid"
  /\ UNCHANGED <<cp, cl_to_mir, mflow>>

MirrorSendRegisterError ==
  /\ mp = "validating"
  /\ mir_to_cl = NO_MSG
  /\ mp' = "done"
  /\ mir_to_cl' = REGISTER_ERROR
  /\ action_taken' = "MirrorSendRegisterError"
  /\ UNCHANGED <<cp, cl_to_mir, mflow>>

MirrorSendExplorerReady ==
  /\ mp = "validating"
  /\ mflow = "session"
  /\ mir_to_cl = NO_MSG
  /\ mp' = "exploring"
  /\ mir_to_cl' = EXPLORER_READY
  /\ action_taken' = "MirrorSendExplorerReady"
  /\ UNCHANGED <<cp, cl_to_mir, mflow>>

MirrorSendInitialState ==
  /\ mp = "ready"
  /\ mir_to_cl = NO_MSG
  /\ mp' = "stepping"
  /\ mir_to_cl' = INITIAL_STATE
  /\ action_taken' = "MirrorSendInitialState"
  /\ UNCHANGED <<cp, cl_to_mir, mflow>>

\* After sending step_ok, mirror sends next_step if more steps remain.
MirrorSendNextStep ==
  /\ mir_to_cl = NO_MSG
  /\ cl_to_mir = NO_MSG
  /\ mp = "stepping"
  /\ cp = "waiting_ack"
  /\ mp' = "stepping"
  /\ mir_to_cl' = NEXT_STEP
  /\ action_taken' = "MirrorSendNextStep"
  /\ UNCHANGED <<cp, cl_to_mir, mflow>>

\* -----------------------------------------------------------------------------
\* Init
\* -----------------------------------------------------------------------------

Init ==
  /\ mp = "idle"
  /\ cp = "idle"
  /\ action_taken = "init"
  /\ mflow = "none"
  /\ cl_to_mir = NO_MSG
  /\ mir_to_cl = NO_MSG

\* -----------------------------------------------------------------------------
\* Next
\* -----------------------------------------------------------------------------

Next ==
  \/ ClientRegister
  \/ ClientRegisterTraces
  \/ ClientRegisterGenTraces
  \/ ClientRegisterExplore
  \/ ClientRegisterExploreSession
  \/ ClientExploreCmd
  \/ ClientExploreDone
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
  \/ ClientRecvExplorerReady
  \/ ClientRecvExploreResult
  \/ ClientRecvExploreDoneAck
  \/ MirrorRecvRegister
  \/ MirrorRecvRegisterTraces
  \/ MirrorRecvRegisterGenTraces
  \/ MirrorRecvRegisterExplore
  \/ MirrorRecvRegisterExploreSession
  \/ MirrorRecvExploreCmd
  \/ MirrorRecvExploreDone
  \/ MirrorRecvReportState
  \/ MirrorSendGenTracesDone
  \/ MirrorSendSpecValidatedValid
  \/ MirrorSendSpecValidatedInvalid
  \/ MirrorSendRegisterError
  \/ MirrorSendExplorerReady
  \/ MirrorSendInitialState
  \/ MirrorSendNextStep

\* -----------------------------------------------------------------------------
\* Specification
\* -----------------------------------------------------------------------------

Spec == Init /\ [][Next]_<<mp, cp, action_taken, mflow, cl_to_mir, mir_to_cl>>

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

\* Force a trace that completes through a SUCCESSFUL terminal message
\* (step mismatch counts as a completed conformance run). Error paths
\* (register errors, protocol errors) never satisfy this.
TraceSuccess ==
  ~(  action_taken = "ClientRecvAllStepsDone"
   \/ action_taken = "ClientRecvExploreDoneAck"
   \/ action_taken = "ClientRecvStepMismatch")

\* Force stepping path through ClientReport and mirror response.
TraceStepping ==
  mir_to_cl /= STEP_OK

\* View that captures protocol-relevant state for trace inspection.
MirrorView == <<mp, cp, action_taken, mflow, cl_to_mir, mir_to_cl>>

==============================================================================
