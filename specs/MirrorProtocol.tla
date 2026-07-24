---------------- MODULE MirrorProtocol ---------------------
EXTENDS Integers, Sequences, Apalache

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
REGISTER_TRACES    == 10
REGISTER_TRACE_GEN == 11
GEN_TRACES_DONE    == 12
REGISTER_EXPLORE   == 13
REGISTER_EXPLORER_SESSION == 14
EXPLORER_READY     == 15
EXPLORE_CMD        == 16
EXPLORE_RESULT     == 17
EXPLORE_DONE       == 18

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
  \* @type: Seq(Int);
  cl_to_mir,    \* client → mirror: message queue (tags)
  \* @type: Seq(Int);
  mir_to_cl,    \* mirror → client: message queue (tags)
  \* @type: Bool;
  report_matches, \* payload bit set by ClientReport: whether the client's
                 \* reported state matches the expected state. Chosen
                 \* nondeterministically so the model (not the fixture)
                 \* decides the Ok/AllDone/Mismatch branch.
  \* @type: Bool;
  faulted,      \* set by fault-injection actions (MirrorProtocolFaults);
                \* invariants are only checked on fault-free paths
  \* @type: Bool;
  cl_closed,    \* client closed the connection prematurely
  \* @type: Bool;
  mir_closed    \* mirror closed the connection prematurely

\* -----------------------------------------------------------------------------
\* Client actions — send
\* -----------------------------------------------------------------------------

ClientRegister ==
  /\ cp = "idle"
  /\ mp = "idle"
  /\ cl_to_mir = <<>>
  /\ cp' = "waiting_validation"
  /\ cl_to_mir' = Append(cl_to_mir, REGISTER)
  /\ action_taken' = "ClientRegister"
  /\ UNCHANGED <<mp, mir_to_cl, mflow, report_matches, faulted, cl_closed, mir_closed>>

ClientRegisterTraces ==
  /\ cp = "idle"
  /\ mp = "idle"
  /\ cl_to_mir = <<>>
  /\ cp' = "waiting_validation"
  /\ cl_to_mir' = Append(cl_to_mir, REGISTER_TRACES)
  /\ action_taken' = "ClientRegisterTraces"
  /\ UNCHANGED <<mp, mir_to_cl, mflow, report_matches, faulted, cl_closed, mir_closed>>

ClientRegisterGenTraces ==
  /\ cp = "idle"
  /\ mp = "idle"
  /\ cl_to_mir = <<>>
  /\ cp' = "waiting_gen"
  /\ cl_to_mir' = Append(cl_to_mir, REGISTER_TRACE_GEN)
  /\ action_taken' = "ClientRegisterGenTraces"
  /\ UNCHANGED <<mp, mir_to_cl, mflow, report_matches, faulted, cl_closed, mir_closed>>

\* Interactive symbolic exploration: at the message level the explore
\* flow is identical to Register (validate → step through states), so it
\* reuses the same mirror/client phases and step messages.
ClientRegisterExplore ==
  /\ cp = "idle"
  /\ mp = "idle"
  /\ cl_to_mir = <<>>
  /\ cp' = "waiting_validation"
  /\ cl_to_mir' = Append(cl_to_mir, REGISTER_EXPLORE)
  /\ action_taken' = "ClientRegisterExplore"
  /\ UNCHANGED <<mp, mir_to_cl, mflow, report_matches, faulted, cl_closed, mir_closed>>

\* Client-driven interactive symbolic checking: the client opens an
\* explore session and then issues explorer commands (assumeTransition,
\* nextStep, query, checkInvariant, assumeState, rollback) itself; the
\* mirror forwards them to the apalache explorer server and returns the
\* results. Commands and results strictly alternate.
ClientRegisterExploreSession ==
  /\ cp = "idle"
  /\ mp = "idle"
  /\ cl_to_mir = <<>>
  /\ cp' = "waiting_validation"
  /\ cl_to_mir' = Append(cl_to_mir, REGISTER_EXPLORER_SESSION)
  /\ action_taken' = "ClientRegisterExploreSession"
  /\ UNCHANGED <<mp, mir_to_cl, mflow, report_matches, faulted, cl_closed, mir_closed>>

ClientExploreCmd ==
  /\ cp = "exploring"
  /\ cl_to_mir = <<>>
  /\ mir_to_cl = <<>>
  /\ cl_to_mir' = Append(cl_to_mir, EXPLORE_CMD)
  /\ action_taken' = "ClientExploreCmd"
  /\ UNCHANGED <<mp, cp, mir_to_cl, mflow, report_matches, faulted, cl_closed, mir_closed>>

ClientExploreDone ==
  /\ cp = "exploring"
  /\ cl_to_mir = <<>>
  /\ mir_to_cl = <<>>
  /\ cl_to_mir' = Append(cl_to_mir, EXPLORE_DONE)
  /\ cp' = "waiting_done"
  /\ action_taken' = "ClientExploreDone"
  /\ UNCHANGED <<mp, mir_to_cl, mflow, report_matches, faulted, cl_closed, mir_closed>>

ClientReport ==
  /\ cp = "waiting_action"
  /\ cl_to_mir = <<>>
  /\ cp' = "waiting_ack"
  /\ cl_to_mir' = Append(cl_to_mir, REPORT_STATE)
  /\ report_matches' \in BOOLEAN
  /\ action_taken' = "ClientReport"
  /\ UNCHANGED <<mp, mir_to_cl, mflow, faulted, cl_closed, mir_closed>>

\* -----------------------------------------------------------------------------
\* Client actions — receive messages from mirror
\* -----------------------------------------------------------------------------

ClientRecvSpecValidated ==
  /\ mir_to_cl /= <<>> /\ Head(mir_to_cl) = SPEC_VALIDATED
  /\ cp = "waiting_validation"
  /\ cp' = "waiting_init"
  /\ mir_to_cl' = Tail(mir_to_cl)
  /\ action_taken' = "ClientRecvSpecValidated"
  /\ UNCHANGED <<mp, cl_to_mir, mflow, report_matches, faulted, cl_closed, mir_closed>>

ClientRecvGenTracesDone ==
  /\ mir_to_cl /= <<>> /\ Head(mir_to_cl) = GEN_TRACES_DONE
  /\ cp = "waiting_gen"
  /\ cp' = "idle"
  /\ mir_to_cl' = Tail(mir_to_cl)
  /\ action_taken' = "ClientRecvGenTracesDone"
  /\ UNCHANGED <<mp, cl_to_mir, mflow, report_matches, faulted, cl_closed, mir_closed>>

ClientRecvInitialState ==
  /\ mir_to_cl /= <<>> /\ Head(mir_to_cl) = INITIAL_STATE
  /\ cp = "waiting_init"
  /\ cp' = "waiting_action"
  /\ mir_to_cl' = Tail(mir_to_cl)
  /\ action_taken' = "ClientRecvInitialState"
  /\ UNCHANGED <<mp, cl_to_mir, mflow, report_matches, faulted, cl_closed, mir_closed>>

ClientRecvNextStep ==
  /\ mir_to_cl /= <<>> /\ Head(mir_to_cl) = NEXT_STEP
  /\ cp = "waiting_ack"
  /\ cp' = "waiting_action"
  /\ mir_to_cl' = Tail(mir_to_cl)
  /\ action_taken' = "ClientRecvNextStep"
  /\ UNCHANGED <<mp, cl_to_mir, mflow, report_matches, faulted, cl_closed, mir_closed>>

ClientRecvStepOk ==
  /\ mir_to_cl /= <<>> /\ Head(mir_to_cl) = STEP_OK
  /\ cp = "waiting_ack"
  /\ cp' = "waiting_ack"
  /\ mir_to_cl' = Tail(mir_to_cl)
  /\ action_taken' = "ClientRecvStepOk"
  /\ UNCHANGED <<mp, cl_to_mir, mflow, report_matches, faulted, cl_closed, mir_closed>>

ClientRecvStepMismatch ==
  /\ mir_to_cl /= <<>> /\ Head(mir_to_cl) = STEP_MISMATCH
  /\ cp' = "done"
  /\ mir_to_cl' = Tail(mir_to_cl)
  /\ action_taken' = "ClientRecvStepMismatch"
  /\ UNCHANGED <<mp, cl_to_mir, mflow, report_matches, faulted, cl_closed, mir_closed>>

ClientRecvAllStepsDone ==
  /\ mir_to_cl /= <<>> /\ Head(mir_to_cl) = ALL_STEPS_DONE
  /\ cp = "waiting_ack"
  /\ cp' = "done"
  /\ mir_to_cl' = Tail(mir_to_cl)
  /\ action_taken' = "ClientRecvAllStepsDone"
  /\ UNCHANGED <<mp, cl_to_mir, mflow, report_matches, faulted, cl_closed, mir_closed>>

ClientRecvRegisterError ==
  /\ mir_to_cl /= <<>> /\ Head(mir_to_cl) = REGISTER_ERROR
  /\ cp = "waiting_validation"
  /\ cp' = "done"
  /\ mir_to_cl' = Tail(mir_to_cl)
  /\ action_taken' = "ClientRecvRegisterError"
  /\ UNCHANGED <<mp, cl_to_mir, mflow, report_matches, faulted, cl_closed, mir_closed>>

ClientRecvExplorerReady ==
  /\ mir_to_cl /= <<>> /\ Head(mir_to_cl) = EXPLORER_READY
  /\ cp = "waiting_validation"
  /\ cp' = "exploring"
  /\ mir_to_cl' = Tail(mir_to_cl)
  /\ action_taken' = "ClientRecvExplorerReady"
  /\ UNCHANGED <<mp, cl_to_mir, mflow, report_matches, faulted, cl_closed, mir_closed>>

ClientRecvExploreResult ==
  /\ mir_to_cl /= <<>> /\ Head(mir_to_cl) = EXPLORE_RESULT
  /\ cp = "exploring"
  /\ mir_to_cl' = Tail(mir_to_cl)
  /\ action_taken' = "ClientRecvExploreResult"
  /\ UNCHANGED <<mp, cp, cl_to_mir, mflow, report_matches, faulted, cl_closed, mir_closed>>

ClientRecvExploreDoneAck ==
  /\ mir_to_cl /= <<>> /\ Head(mir_to_cl) = EXPLORE_DONE
  /\ cp = "waiting_done"
  /\ cp' = "done"
  /\ mir_to_cl' = Tail(mir_to_cl)
  /\ action_taken' = "ClientRecvExploreDoneAck"
  /\ UNCHANGED <<mp, cl_to_mir, mflow, report_matches, faulted, cl_closed, mir_closed>>

\* -----------------------------------------------------------------------------
\* Mirror actions — receive messages from client
\* -----------------------------------------------------------------------------

MirrorRecvRegister ==
  /\ cl_to_mir /= <<>> /\ Head(cl_to_mir) = REGISTER
  /\ mp = "idle"
  /\ mp' = "validating"
  /\ mflow' = "traces"
  /\ cl_to_mir' = Tail(cl_to_mir)
  /\ action_taken' = "MirrorRecvRegister"
  /\ UNCHANGED <<cp, mir_to_cl, report_matches, faulted, cl_closed, mir_closed>>

MirrorRecvRegisterTraces ==
  /\ cl_to_mir /= <<>> /\ Head(cl_to_mir) = REGISTER_TRACES
  /\ mp = "idle"
  /\ mp' = "ready"
  /\ mflow' = "traces"
  /\ cl_to_mir' = Tail(cl_to_mir)
  /\ mir_to_cl' = Append(mir_to_cl, SPEC_VALIDATED)
  /\ action_taken' = "MirrorRecvRegisterTraces"
  /\ UNCHANGED <<cp, report_matches, faulted, cl_closed, mir_closed>>

MirrorRecvRegisterGenTraces ==
  /\ cl_to_mir /= <<>> /\ Head(cl_to_mir) = REGISTER_TRACE_GEN
  /\ mp = "idle"
  /\ mp' = "generating"
  /\ mflow' = "traces"
  /\ cl_to_mir' = Tail(cl_to_mir)
  /\ action_taken' = "MirrorRecvRegisterGenTraces"
  /\ UNCHANGED <<cp, mir_to_cl, report_matches, faulted, cl_closed, mir_closed>>

MirrorRecvRegisterExplore ==
  /\ cl_to_mir /= <<>> /\ Head(cl_to_mir) = REGISTER_EXPLORE
  /\ mp = "idle"
  /\ mp' = "validating"
  /\ mflow' = "traces"
  /\ cl_to_mir' = Tail(cl_to_mir)
  /\ action_taken' = "MirrorRecvRegisterExplore"
  /\ UNCHANGED <<cp, mir_to_cl, report_matches, faulted, cl_closed, mir_closed>>

MirrorRecvRegisterExploreSession ==
  /\ cl_to_mir /= <<>> /\ Head(cl_to_mir) = REGISTER_EXPLORER_SESSION
  /\ mp = "idle"
  /\ mp' = "validating"
  /\ mflow' = "session"
  /\ cl_to_mir' = Tail(cl_to_mir)
  /\ action_taken' = "MirrorRecvRegisterExploreSession"
  /\ UNCHANGED <<cp, mir_to_cl, report_matches, faulted, cl_closed, mir_closed>>

MirrorRecvExploreCmd ==
  /\ cl_to_mir /= <<>> /\ Head(cl_to_mir) = EXPLORE_CMD
  /\ mp = "exploring"
  /\ cl_to_mir' = Tail(cl_to_mir)
  /\ mir_to_cl' = Append(mir_to_cl, EXPLORE_RESULT)
  /\ action_taken' = "MirrorRecvExploreCmd"
  /\ UNCHANGED <<mp, cp, mflow, report_matches, faulted, cl_closed, mir_closed>>

MirrorRecvExploreDone ==
  /\ cl_to_mir /= <<>> /\ Head(cl_to_mir) = EXPLORE_DONE
  /\ mp = "exploring"
  /\ mp' = "done"
  /\ cl_to_mir' = Tail(cl_to_mir)
  /\ mir_to_cl' = Append(mir_to_cl, EXPLORE_DONE)
  /\ action_taken' = "MirrorRecvExploreDone"
  /\ UNCHANGED <<cp, mflow, report_matches, faulted, cl_closed, mir_closed>>

\* Mirror receives ReportState.
\* Three distinct actions encode: match with more steps, match on the
\* last step, and mismatch — split so trace projection can tell them apart.
MirrorRecvReportOk ==
  /\ cl_to_mir /= <<>> /\ Head(cl_to_mir) = REPORT_STATE
  /\ mp = "stepping"
  /\ report_matches
  /\ cl_to_mir' = Tail(cl_to_mir)
  /\ mp' = "stepping"                \* match, more steps remain
  /\ mir_to_cl' = Append(mir_to_cl, STEP_OK)            \* queued; NextStep sent separately
  /\ action_taken' = "MirrorRecvReportOk"
  /\ UNCHANGED <<cp, mflow, report_matches, faulted, cl_closed, mir_closed>>

MirrorRecvReportAllDone ==
  /\ cl_to_mir /= <<>> /\ Head(cl_to_mir) = REPORT_STATE
  /\ mp = "stepping"
  /\ report_matches
  /\ cl_to_mir' = Tail(cl_to_mir)
  /\ mp' = "done"                    \* match, last step
  /\ mir_to_cl' = Append(mir_to_cl, ALL_STEPS_DONE)
  /\ action_taken' = "MirrorRecvReportAllDone"
  /\ UNCHANGED <<cp, mflow, report_matches, faulted, cl_closed, mir_closed>>

MirrorRecvReportMismatch ==
  /\ cl_to_mir /= <<>> /\ Head(cl_to_mir) = REPORT_STATE
  /\ mp = "stepping"
  /\ ~report_matches
  /\ cl_to_mir' = Tail(cl_to_mir)
  /\ mp' = "done"                    \* mismatch
  /\ mir_to_cl' = Append(mir_to_cl, STEP_MISMATCH)
  /\ action_taken' = "MirrorRecvReportMismatch"
  /\ UNCHANGED <<cp, mflow, report_matches, faulted, cl_closed, mir_closed>>

\* -----------------------------------------------------------------------------
\* Mirror actions — send messages to client
\* -----------------------------------------------------------------------------

MirrorSendGenTracesDone ==
  /\ mp = "generating"
  /\ mir_to_cl = <<>>
  /\ mp' = "idle"
  /\ mir_to_cl' = Append(mir_to_cl, GEN_TRACES_DONE)
  /\ action_taken' = "MirrorSendGenTracesDone"
  /\ UNCHANGED <<cp, cl_to_mir, mflow, report_matches, faulted, cl_closed, mir_closed>>

MirrorSendSpecValidatedValid ==
  /\ mp = "validating"
  /\ mflow = "traces"
  /\ mir_to_cl = <<>>
  /\ mp' = "ready"
  /\ mir_to_cl' = Append(mir_to_cl, SPEC_VALIDATED)
  /\ action_taken' = "MirrorSendSpecValidatedValid"
  /\ UNCHANGED <<cp, cl_to_mir, mflow, report_matches, faulted, cl_closed, mir_closed>>

MirrorSendRegisterError ==
  /\ mp = "validating"
  /\ mir_to_cl = <<>>
  /\ mp' = "done"
  /\ mir_to_cl' = Append(mir_to_cl, REGISTER_ERROR)
  /\ action_taken' = "MirrorSendRegisterError"
  /\ UNCHANGED <<cp, cl_to_mir, mflow, report_matches, faulted, cl_closed, mir_closed>>

MirrorSendExplorerReady ==
  /\ mp = "validating"
  /\ mflow = "session"
  /\ mir_to_cl = <<>>
  /\ mp' = "exploring"
  /\ mir_to_cl' = Append(mir_to_cl, EXPLORER_READY)
  /\ action_taken' = "MirrorSendExplorerReady"
  /\ UNCHANGED <<cp, cl_to_mir, mflow, report_matches, faulted, cl_closed, mir_closed>>

MirrorSendInitialState ==
  /\ mp = "ready"
  /\ mir_to_cl = <<>>
  /\ mp' = "stepping"
  /\ mir_to_cl' = Append(mir_to_cl, INITIAL_STATE)
  /\ action_taken' = "MirrorSendInitialState"
  /\ UNCHANGED <<cp, cl_to_mir, mflow, report_matches, faulted, cl_closed, mir_closed>>

\* After sending step_ok, mirror sends next_step if more steps remain.
MirrorSendNextStep ==
  /\ mir_to_cl = <<>>
  /\ cl_to_mir = <<>>
  /\ mp = "stepping"
  /\ cp = "waiting_ack"
  /\ mp' = "stepping"
  /\ mir_to_cl' = Append(mir_to_cl, NEXT_STEP)
  /\ action_taken' = "MirrorSendNextStep"
  /\ UNCHANGED <<cp, cl_to_mir, mflow, report_matches, faulted, cl_closed, mir_closed>>

\* -----------------------------------------------------------------------------
\* Init
\* -----------------------------------------------------------------------------

Init ==
  /\ mp = "idle"
  /\ cp = "idle"
  /\ action_taken = "init"
  /\ mflow = "none"
  /\ cl_to_mir = <<>>
  /\ mir_to_cl = <<>>
  /\ report_matches = FALSE
  /\ faulted = FALSE
  /\ cl_closed = FALSE
  /\ mir_closed = FALSE

\* -----------------------------------------------------------------------------
\* Next
\* -----------------------------------------------------------------------------

\* Explicit terminal state: both sides finished; halt cleanly.
Halt ==
  /\ mp = "done"
  /\ cp = "done"
  /\ action_taken' = "Halt"
  /\ UNCHANGED <<mp, cp, mflow, cl_to_mir, mir_to_cl, report_matches, faulted, cl_closed, mir_closed>>

Next ==
  \/ Halt
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
  \/ MirrorRecvReportOk
  \/ MirrorRecvReportAllDone
  \/ MirrorRecvReportMismatch
  \/ MirrorSendGenTracesDone
  \/ MirrorSendSpecValidatedValid
  \/ MirrorSendRegisterError
  \/ MirrorSendExplorerReady
  \/ MirrorSendInitialState
  \/ MirrorSendNextStep

\* -----------------------------------------------------------------------------
\* Specification
\* -----------------------------------------------------------------------------

Spec == Init /\ [][Next]_<<mp, cp, action_taken, mflow, cl_to_mir, mir_to_cl, report_matches, faulted, cl_closed, mir_closed>>

\* -----------------------------------------------------------------------------
\* Invariants
\* -----------------------------------------------------------------------------

\* Both sides are always in valid phases.
PhaseOk ==
  /\ mp \in Ms
  /\ cp \in Cs

\* The client never waits on a message the mirror will never send:
\* when the client is mid-session, the mirror is in a phase that can respond.
\* Only checked on fault-free paths — fault-injection actions
\* (MirrorProtocolFaults) may of course strand the client.
ClientNeverStuck ==
  ~faulted =>
    /\ cp = "waiting_init" => mp \in {"validating", "ready", "stepping"}
    /\ cp = "waiting_ack"  => mp \in {"stepping", "done"}
    /\ cp = "waiting_done" => mp \in {"exploring", "done"}

Inv == PhaseOk /\
       ClientNeverStuck

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
  ~(mir_to_cl /= <<>> /\ Head(mir_to_cl) = STEP_OK)

\* View that captures protocol-relevant state for trace inspection.
MirrorView == <<mp, cp, action_taken, mflow, cl_to_mir, mir_to_cl>>

\* -----------------------------------------------------------------------------
\* Projection to the MirrorStep vocabulary of MinimalTraceCheck
\* ("Init" | "Tick" | "RecvReport" | "StepOk" | "Mismatch" | "AllDone").
\* The runner compares ProjectTrace(expected actions) against the
\* normalized MirrorStep sequence produced by a real ModelMirrors run.
\* -----------------------------------------------------------------------------

ProjectAction(a) ==
  CASE a = "ClientRecvInitialState"    -> <<"Init">>
    [] a = "ClientRecvNextStep"        -> <<"Tick">>
    [] a = "MirrorRecvReportOk"        -> <<"RecvReport", "StepOk">>
    [] a = "MirrorRecvReportAllDone"   -> <<"RecvReport", "AllDone">>
    [] a = "MirrorRecvReportMismatch"  -> <<"RecvReport", "Mismatch">>
    [] OTHER                           -> <<>>

ProjectTrace(actions) ==
  LET AppendStep(acc, a) == acc \o ProjectAction(a)
  IN ApaFoldSeqLeft(AppendStep, <<>>, actions)

==============================================================================
