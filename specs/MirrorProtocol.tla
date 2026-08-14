---------------- MODULE MirrorProtocol ---------------------
EXTENDS Integers, Sequences, Apalache

\* -----------------------------------------------------------------------------
\* Protocol phases (mirror side)
\* -----------------------------------------------------------------------------

Ms == {"idle", "validating", "generating", "ready", "stepping", "exploring", "done"}

\* Client phases
Cs == Ms \cup {"waiting_validation", "waiting_gen", "waiting_init", "waiting_action", "waiting_ack", "waiting_done", "waiting_validate"}

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
REGISTER_VALIDATE  == 9
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
  mirror_phase,           \* mirror phase
  \* @type: Str;
  client_phase,           \* client phase
  \* @type: Str;
  action_taken, \* label of the action executed at this step
  \* @type: Str;
  mirror_flow,        \* active registration flow: "none" | "traces" | "session" | "validate"
  \* @type: Seq(Int);
  client_to_mirror,    \* client → mirror: message queue (tags)
  \* @type: Seq(Int);
  mirror_to_client,    \* mirror → client: message queue (tags)
  \* @type: Bool;
  report_matches, \* payload bit set by ClientReport: whether the client's
                 \* reported state matches the expected state. Chosen
                 \* nondeterministically so the model (not the fixture)
                 \* decides the Ok/AllDone/Mismatch branch.
  \* @type: Bool;
  faulted,      \* set by fault-injection actions (MirrorProtocolFaults);
                \* invariants are only checked on fault-free paths
  \* @type: Bool;
  client_closed,    \* client closed the connection prematurely
  \* @type: Bool;
  mirror_closed    \* mirror closed the connection prematurely

\* -----------------------------------------------------------------------------
\* Client actions — send
\* -----------------------------------------------------------------------------

ClientRegister ==
  /\ client_phase = "idle"
  /\ mirror_phase = "idle"
  /\ client_to_mirror = <<>>
  /\ client_phase' = "waiting_validation"
  /\ client_to_mirror' = Append(client_to_mirror, REGISTER)
  /\ action_taken' = "ClientRegister"
  /\ UNCHANGED <<mirror_phase, mirror_to_client, mirror_flow, report_matches, faulted, client_closed, mirror_closed>>

ClientRegisterTraces ==
  /\ client_phase = "idle"
  /\ mirror_phase = "idle"
  /\ client_to_mirror = <<>>
  /\ client_phase' = "waiting_validation"
  /\ client_to_mirror' = Append(client_to_mirror, REGISTER_TRACES)
  /\ action_taken' = "ClientRegisterTraces"
  /\ UNCHANGED <<mirror_phase, mirror_to_client, mirror_flow, report_matches, faulted, client_closed, mirror_closed>>

ClientRegisterGenTraces ==
  /\ client_phase = "idle"
  /\ mirror_phase = "idle"
  /\ client_to_mirror = <<>>
  /\ client_phase' = "waiting_gen"
  /\ client_to_mirror' = Append(client_to_mirror, REGISTER_TRACE_GEN)
  /\ action_taken' = "ClientRegisterGenTraces"
  /\ UNCHANGED <<mirror_phase, mirror_to_client, mirror_flow, report_matches, faulted, client_closed, mirror_closed>>

\* Interactive symbolic exploration: at the message level the explore
\* flow is identical to Register (validate → step through states), so it
\* reuses the same mirror/client phases and step messages.
ClientRegisterExplore ==
  /\ client_phase = "idle"
  /\ mirror_phase = "idle"
  /\ client_to_mirror = <<>>
  /\ client_phase' = "waiting_validation"
  /\ client_to_mirror' = Append(client_to_mirror, REGISTER_EXPLORE)
  /\ action_taken' = "ClientRegisterExplore"
  /\ UNCHANGED <<mirror_phase, mirror_to_client, mirror_flow, report_matches, faulted, client_closed, mirror_closed>>

\* Client-driven interactive symbolic checking: the client opens an
\* explore session and then issues explorer commands (assumeTransition,
\* nextStep, query, checkInvariant, assumeState, rollback) itself; the
\* mirror forwards them to the apalache explorer server and returns the
\* results. Commands and results strictly alternate.
ClientRegisterExploreSession ==
  /\ client_phase = "idle"
  /\ mirror_phase = "idle"
  /\ client_to_mirror = <<>>
  /\ client_phase' = "waiting_validation"
  /\ client_to_mirror' = Append(client_to_mirror, REGISTER_EXPLORER_SESSION)
  /\ action_taken' = "ClientRegisterExploreSession"
  /\ UNCHANGED <<mirror_phase, mirror_to_client, mirror_flow, report_matches, faulted, client_closed, mirror_closed>>

\* Validate-only path: the client asks the mirror to validate the spec
\* (typecheck + bounded model check) and stop — no trace generation, no
\* stepping. The SpecValidated reply (valid or invalid) ends the session.
ClientRegisterValidate ==
  /\ client_phase = "idle"
  /\ mirror_phase = "idle"
  /\ client_to_mirror = <<>>
  /\ client_phase' = "waiting_validate"
  /\ client_to_mirror' = Append(client_to_mirror, REGISTER_VALIDATE)
  /\ action_taken' = "ClientRegisterValidate"
  /\ UNCHANGED <<mirror_phase, mirror_to_client, mirror_flow, report_matches, faulted, client_closed, mirror_closed>>

ClientExploreCmd ==
  /\ client_phase = "exploring"
  /\ client_to_mirror = <<>>
  /\ mirror_to_client = <<>>
  /\ client_to_mirror' = Append(client_to_mirror, EXPLORE_CMD)
  /\ action_taken' = "ClientExploreCmd"
  /\ UNCHANGED <<mirror_phase, client_phase, mirror_to_client, mirror_flow, report_matches, faulted, client_closed, mirror_closed>>

ClientExploreDone ==
  /\ client_phase = "exploring"
  /\ client_to_mirror = <<>>
  /\ mirror_to_client = <<>>
  /\ client_to_mirror' = Append(client_to_mirror, EXPLORE_DONE)
  /\ client_phase' = "waiting_done"
  /\ action_taken' = "ClientExploreDone"
  /\ UNCHANGED <<mirror_phase, mirror_to_client, mirror_flow, report_matches, faulted, client_closed, mirror_closed>>

ClientReport ==
  /\ client_phase = "waiting_action"
  /\ client_to_mirror = <<>>
  /\ client_phase' = "waiting_ack"
  /\ client_to_mirror' = Append(client_to_mirror, REPORT_STATE)
  /\ report_matches' \in BOOLEAN
  /\ action_taken' = "ClientReport"
  /\ UNCHANGED <<mirror_phase, mirror_to_client, mirror_flow, faulted, client_closed, mirror_closed>>

\* -----------------------------------------------------------------------------
\* Client actions — receive messages from mirror
\* -----------------------------------------------------------------------------

ClientRecvSpecValidated ==
  /\ mirror_to_client /= <<>> /\ Head(mirror_to_client) = SPEC_VALIDATED
  /\ client_phase = "waiting_validation"
  /\ client_phase' = "waiting_init"
  /\ mirror_to_client' = Tail(mirror_to_client)
  /\ action_taken' = "ClientRecvSpecValidated"
  /\ UNCHANGED <<mirror_phase, client_to_mirror, mirror_flow, report_matches, faulted, client_closed, mirror_closed>>

\* Validate-only: the SpecValidated reply (valid or invalid — same tag,
\* the outcome rides in the payload) ends the session.
ClientRecvSpecValidatedDone ==
  /\ mirror_to_client /= <<>> /\ Head(mirror_to_client) = SPEC_VALIDATED
  /\ client_phase = "waiting_validate"
  /\ client_phase' = "done"
  /\ mirror_to_client' = Tail(mirror_to_client)
  /\ action_taken' = "ClientRecvSpecValidatedDone"
  /\ UNCHANGED <<mirror_phase, client_to_mirror, mirror_flow, report_matches, faulted, client_closed, mirror_closed>>

ClientRecvGenTracesDone ==
  /\ mirror_to_client /= <<>> /\ Head(mirror_to_client) = GEN_TRACES_DONE
  /\ client_phase = "waiting_gen"
  /\ client_phase' = "idle"
  /\ mirror_to_client' = Tail(mirror_to_client)
  /\ action_taken' = "ClientRecvGenTracesDone"
  /\ UNCHANGED <<mirror_phase, client_to_mirror, mirror_flow, report_matches, faulted, client_closed, mirror_closed>>

ClientRecvInitialState ==
  /\ mirror_to_client /= <<>> /\ Head(mirror_to_client) = INITIAL_STATE
  /\ client_phase = "waiting_init"
  /\ client_phase' = "waiting_action"
  /\ mirror_to_client' = Tail(mirror_to_client)
  /\ action_taken' = "ClientRecvInitialState"
  /\ UNCHANGED <<mirror_phase, client_to_mirror, mirror_flow, report_matches, faulted, client_closed, mirror_closed>>

ClientRecvNextStep ==
  /\ mirror_to_client /= <<>> /\ Head(mirror_to_client) = NEXT_STEP
  /\ client_phase = "waiting_ack"
  /\ client_phase' = "waiting_action"
  /\ mirror_to_client' = Tail(mirror_to_client)
  /\ action_taken' = "ClientRecvNextStep"
  /\ UNCHANGED <<mirror_phase, client_to_mirror, mirror_flow, report_matches, faulted, client_closed, mirror_closed>>

ClientRecvStepOk ==
  /\ mirror_to_client /= <<>> /\ Head(mirror_to_client) = STEP_OK
  /\ client_phase = "waiting_ack"
  /\ client_phase' = "waiting_ack"
  /\ mirror_to_client' = Tail(mirror_to_client)
  /\ action_taken' = "ClientRecvStepOk"
  /\ UNCHANGED <<mirror_phase, client_to_mirror, mirror_flow, report_matches, faulted, client_closed, mirror_closed>>

ClientRecvStepMismatch ==
  /\ mirror_to_client /= <<>> /\ Head(mirror_to_client) = STEP_MISMATCH
  /\ client_phase' = "done"
  /\ mirror_to_client' = Tail(mirror_to_client)
  /\ action_taken' = "ClientRecvStepMismatch"
  /\ UNCHANGED <<mirror_phase, client_to_mirror, mirror_flow, report_matches, faulted, client_closed, mirror_closed>>

ClientRecvAllStepsDone ==
  /\ mirror_to_client /= <<>> /\ Head(mirror_to_client) = ALL_STEPS_DONE
  /\ client_phase = "waiting_ack"
  /\ client_phase' = "done"
  /\ mirror_to_client' = Tail(mirror_to_client)
  /\ action_taken' = "ClientRecvAllStepsDone"
  /\ UNCHANGED <<mirror_phase, client_to_mirror, mirror_flow, report_matches, faulted, client_closed, mirror_closed>>

\* RegisterError replies to any registration request, including
\* RegisterValidate (inline-spec materialization or apalache-mc failure).
ClientRecvRegisterError ==
  /\ mirror_to_client /= <<>> /\ Head(mirror_to_client) = REGISTER_ERROR
  /\ client_phase \in {"waiting_validation", "waiting_validate"}
  /\ client_phase' = "done"
  /\ mirror_to_client' = Tail(mirror_to_client)
  /\ action_taken' = "ClientRecvRegisterError"
  /\ UNCHANGED <<mirror_phase, client_to_mirror, mirror_flow, report_matches, faulted, client_closed, mirror_closed>>

ClientRecvExplorerReady ==
  /\ mirror_to_client /= <<>> /\ Head(mirror_to_client) = EXPLORER_READY
  /\ client_phase = "waiting_validation"
  /\ client_phase' = "exploring"
  /\ mirror_to_client' = Tail(mirror_to_client)
  /\ action_taken' = "ClientRecvExplorerReady"
  /\ UNCHANGED <<mirror_phase, client_to_mirror, mirror_flow, report_matches, faulted, client_closed, mirror_closed>>

ClientRecvExploreResult ==
  /\ mirror_to_client /= <<>> /\ Head(mirror_to_client) = EXPLORE_RESULT
  /\ client_phase = "exploring"
  /\ mirror_to_client' = Tail(mirror_to_client)
  /\ action_taken' = "ClientRecvExploreResult"
  /\ UNCHANGED <<mirror_phase, client_phase, client_to_mirror, mirror_flow, report_matches, faulted, client_closed, mirror_closed>>

ClientRecvExploreDoneAck ==
  /\ mirror_to_client /= <<>> /\ Head(mirror_to_client) = EXPLORE_DONE
  /\ client_phase = "waiting_done"
  /\ client_phase' = "done"
  /\ mirror_to_client' = Tail(mirror_to_client)
  /\ action_taken' = "ClientRecvExploreDoneAck"
  /\ UNCHANGED <<mirror_phase, client_to_mirror, mirror_flow, report_matches, faulted, client_closed, mirror_closed>>

\* -----------------------------------------------------------------------------
\* Mirror actions — receive messages from client
\* -----------------------------------------------------------------------------

MirrorRecvRegister ==
  /\ client_to_mirror /= <<>> /\ Head(client_to_mirror) = REGISTER
  /\ mirror_phase = "idle"
  /\ mirror_phase' = "validating"
  /\ mirror_flow' = "traces"
  /\ client_to_mirror' = Tail(client_to_mirror)
  /\ action_taken' = "MirrorRecvRegister"
  /\ UNCHANGED <<client_phase, mirror_to_client, report_matches, faulted, client_closed, mirror_closed>>

MirrorRecvRegisterTraces ==
  /\ client_to_mirror /= <<>> /\ Head(client_to_mirror) = REGISTER_TRACES
  /\ mirror_phase = "idle"
  /\ mirror_phase' = "ready"
  /\ mirror_flow' = "traces"
  /\ client_to_mirror' = Tail(client_to_mirror)
  /\ mirror_to_client' = Append(mirror_to_client, SPEC_VALIDATED)
  /\ action_taken' = "MirrorRecvRegisterTraces"
  /\ UNCHANGED <<client_phase, report_matches, faulted, client_closed, mirror_closed>>

MirrorRecvRegisterGenTraces ==
  /\ client_to_mirror /= <<>> /\ Head(client_to_mirror) = REGISTER_TRACE_GEN
  /\ mirror_phase = "idle"
  /\ mirror_phase' = "generating"
  /\ mirror_flow' = "traces"
  /\ client_to_mirror' = Tail(client_to_mirror)
  /\ action_taken' = "MirrorRecvRegisterGenTraces"
  /\ UNCHANGED <<client_phase, mirror_to_client, report_matches, faulted, client_closed, mirror_closed>>

MirrorRecvRegisterExplore ==
  /\ client_to_mirror /= <<>> /\ Head(client_to_mirror) = REGISTER_EXPLORE
  /\ mirror_phase = "idle"
  /\ mirror_phase' = "validating"
  /\ mirror_flow' = "traces"
  /\ client_to_mirror' = Tail(client_to_mirror)
  /\ action_taken' = "MirrorRecvRegisterExplore"
  /\ UNCHANGED <<client_phase, mirror_to_client, report_matches, faulted, client_closed, mirror_closed>>

MirrorRecvRegisterExploreSession ==
  /\ client_to_mirror /= <<>> /\ Head(client_to_mirror) = REGISTER_EXPLORER_SESSION
  /\ mirror_phase = "idle"
  /\ mirror_phase' = "validating"
  /\ mirror_flow' = "session"
  /\ client_to_mirror' = Tail(client_to_mirror)
  /\ action_taken' = "MirrorRecvRegisterExploreSession"
  /\ UNCHANGED <<client_phase, mirror_to_client, report_matches, faulted, client_closed, mirror_closed>>

MirrorRecvRegisterValidate ==
  /\ client_to_mirror /= <<>> /\ Head(client_to_mirror) = REGISTER_VALIDATE
  /\ mirror_phase = "idle"
  /\ mirror_phase' = "validating"
  /\ mirror_flow' = "validate"
  /\ client_to_mirror' = Tail(client_to_mirror)
  /\ action_taken' = "MirrorRecvRegisterValidate"
  /\ UNCHANGED <<client_phase, mirror_to_client, report_matches, faulted, client_closed, mirror_closed>>

MirrorRecvExploreCmd ==
  /\ client_to_mirror /= <<>> /\ Head(client_to_mirror) = EXPLORE_CMD
  /\ mirror_phase = "exploring"
  /\ client_to_mirror' = Tail(client_to_mirror)
  /\ mirror_to_client' = Append(mirror_to_client, EXPLORE_RESULT)
  /\ action_taken' = "MirrorRecvExploreCmd"
  /\ UNCHANGED <<mirror_phase, client_phase, mirror_flow, report_matches, faulted, client_closed, mirror_closed>>

MirrorRecvExploreDone ==
  /\ client_to_mirror /= <<>> /\ Head(client_to_mirror) = EXPLORE_DONE
  /\ mirror_phase = "exploring"
  /\ mirror_phase' = "done"
  /\ client_to_mirror' = Tail(client_to_mirror)
  /\ mirror_to_client' = Append(mirror_to_client, EXPLORE_DONE)
  /\ action_taken' = "MirrorRecvExploreDone"
  /\ UNCHANGED <<client_phase, mirror_flow, report_matches, faulted, client_closed, mirror_closed>>

\* Mirror receives ReportState.
\* Three distinct actions encode: match with more steps, match on the
\* last step, and mismatch — split so trace projection can tell them apart.
MirrorRecvReportOk ==
  /\ client_to_mirror /= <<>> /\ Head(client_to_mirror) = REPORT_STATE
  /\ mirror_phase = "stepping"
  /\ report_matches
  /\ client_to_mirror' = Tail(client_to_mirror)
  /\ mirror_phase' = "stepping"                \* match, more steps remain
  /\ mirror_to_client' = Append(mirror_to_client, STEP_OK)            \* queued; NextStep sent separately
  /\ action_taken' = "MirrorRecvReportOk"
  /\ UNCHANGED <<client_phase, mirror_flow, report_matches, faulted, client_closed, mirror_closed>>

MirrorRecvReportAllDone ==
  /\ client_to_mirror /= <<>> /\ Head(client_to_mirror) = REPORT_STATE
  /\ mirror_phase = "stepping"
  /\ report_matches
  /\ client_to_mirror' = Tail(client_to_mirror)
  /\ mirror_phase' = "done"                    \* match, last step
  /\ mirror_to_client' = Append(mirror_to_client, ALL_STEPS_DONE)
  /\ action_taken' = "MirrorRecvReportAllDone"
  /\ UNCHANGED <<client_phase, mirror_flow, report_matches, faulted, client_closed, mirror_closed>>

MirrorRecvReportMismatch ==
  /\ client_to_mirror /= <<>> /\ Head(client_to_mirror) = REPORT_STATE
  /\ mirror_phase = "stepping"
  /\ ~report_matches
  /\ client_to_mirror' = Tail(client_to_mirror)
  /\ mirror_phase' = "done"                    \* mismatch
  /\ mirror_to_client' = Append(mirror_to_client, STEP_MISMATCH)
  /\ action_taken' = "MirrorRecvReportMismatch"
  /\ UNCHANGED <<client_phase, mirror_flow, report_matches, faulted, client_closed, mirror_closed>>

\* -----------------------------------------------------------------------------
\* Mirror actions — send messages to client
\* -----------------------------------------------------------------------------

MirrorSendGenTracesDone ==
  /\ mirror_phase = "generating"
  /\ mirror_to_client = <<>>
  /\ mirror_phase' = "idle"
  /\ mirror_to_client' = Append(mirror_to_client, GEN_TRACES_DONE)
  /\ action_taken' = "MirrorSendGenTracesDone"
  /\ UNCHANGED <<client_phase, client_to_mirror, mirror_flow, report_matches, faulted, client_closed, mirror_closed>>

MirrorSendSpecValidatedValid ==
  /\ mirror_phase = "validating"
  /\ mirror_to_client = <<>>
  /\ \/ /\ mirror_flow = "traces"    \* stepping flow: session continues
        /\ mirror_phase' = "ready"
     \/ /\ mirror_flow = "validate"  \* validate-only flow: session ends
        /\ mirror_phase' = "done"
  /\ mirror_to_client' = Append(mirror_to_client, SPEC_VALIDATED)
  /\ action_taken' = "MirrorSendSpecValidatedValid"
  /\ UNCHANGED <<client_phase, client_to_mirror, mirror_flow, report_matches, faulted, client_closed, mirror_closed>>

\* Invalid outcome of the validate-only path: the reply is still
\* SpecValidated (same tag; the SpecInvalid payload is abstracted away),
\* and the session ends. Split from the valid outcome so traces can tell
\* them apart.
MirrorSendSpecValidatedInvalid ==
  /\ mirror_phase = "validating"
  /\ mirror_flow = "validate"
  /\ mirror_to_client = <<>>
  /\ mirror_phase' = "done"
  /\ mirror_to_client' = Append(mirror_to_client, SPEC_VALIDATED)
  /\ action_taken' = "MirrorSendSpecValidatedInvalid"
  /\ UNCHANGED <<client_phase, client_to_mirror, mirror_flow, report_matches, faulted, client_closed, mirror_closed>>

MirrorSendRegisterError ==
  /\ mirror_phase = "validating"
  /\ mirror_to_client = <<>>
  /\ mirror_phase' = "done"
  /\ mirror_to_client' = Append(mirror_to_client, REGISTER_ERROR)
  /\ action_taken' = "MirrorSendRegisterError"
  /\ UNCHANGED <<client_phase, client_to_mirror, mirror_flow, report_matches, faulted, client_closed, mirror_closed>>

MirrorSendExplorerReady ==
  /\ mirror_phase = "validating"
  /\ mirror_flow = "session"
  /\ mirror_to_client = <<>>
  /\ mirror_phase' = "exploring"
  /\ mirror_to_client' = Append(mirror_to_client, EXPLORER_READY)
  /\ action_taken' = "MirrorSendExplorerReady"
  /\ UNCHANGED <<client_phase, client_to_mirror, mirror_flow, report_matches, faulted, client_closed, mirror_closed>>

MirrorSendInitialState ==
  /\ mirror_phase = "ready"
  /\ mirror_to_client = <<>>
  /\ mirror_phase' = "stepping"
  /\ mirror_to_client' = Append(mirror_to_client, INITIAL_STATE)
  /\ action_taken' = "MirrorSendInitialState"
  /\ UNCHANGED <<client_phase, client_to_mirror, mirror_flow, report_matches, faulted, client_closed, mirror_closed>>

\* After sending step_ok, mirror sends next_step if more steps remain.
MirrorSendNextStep ==
  /\ mirror_to_client = <<>>
  /\ client_to_mirror = <<>>
  /\ mirror_phase = "stepping"
  /\ client_phase = "waiting_ack"
  /\ mirror_phase' = "stepping"
  /\ mirror_to_client' = Append(mirror_to_client, NEXT_STEP)
  /\ action_taken' = "MirrorSendNextStep"
  /\ UNCHANGED <<client_phase, client_to_mirror, mirror_flow, report_matches, faulted, client_closed, mirror_closed>>

\* -----------------------------------------------------------------------------
\* Init
\* -----------------------------------------------------------------------------

Init ==
  /\ mirror_phase = "idle"
  /\ client_phase = "idle"
  /\ action_taken = "init"
  /\ mirror_flow = "none"
  /\ client_to_mirror = <<>>
  /\ mirror_to_client = <<>>
  /\ report_matches = FALSE
  /\ faulted = FALSE
  /\ client_closed = FALSE
  /\ mirror_closed = FALSE

\* -----------------------------------------------------------------------------
\* Next
\* -----------------------------------------------------------------------------

\* Explicit terminal state: both sides finished; halt cleanly.
Halt ==
  /\ mirror_phase = "done"
  /\ client_phase = "done"
  /\ action_taken' = "Halt"
  /\ UNCHANGED <<mirror_phase, client_phase, mirror_flow, client_to_mirror, mirror_to_client, report_matches, faulted, client_closed, mirror_closed>>

Next ==
  \/ Halt
  \/ ClientRegister
  \/ ClientRegisterTraces
  \/ ClientRegisterGenTraces
  \/ ClientRegisterExplore
  \/ ClientRegisterExploreSession
  \/ ClientRegisterValidate
  \/ ClientExploreCmd
  \/ ClientExploreDone
  \/ ClientReport
  \/ ClientRecvSpecValidated
  \/ ClientRecvSpecValidatedDone
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
  \/ MirrorRecvRegisterValidate
  \/ MirrorRecvExploreCmd
  \/ MirrorRecvExploreDone
  \/ MirrorRecvReportOk
  \/ MirrorRecvReportAllDone
  \/ MirrorRecvReportMismatch
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

Spec == Init /\ [][Next]_<<mirror_phase, client_phase, action_taken, mirror_flow, client_to_mirror, mirror_to_client, report_matches, faulted, client_closed, mirror_closed>>

\* -----------------------------------------------------------------------------
\* Invariants
\* -----------------------------------------------------------------------------

\* Both sides are always in valid phases.
PhaseOk ==
  /\ mirror_phase \in Ms
  /\ client_phase \in Cs

\* The client never waits on a message the mirror will never send:
\* when the client is mid-session, the mirror is in a phase that can respond.
\* Only checked on fault-free paths — fault-injection actions
\* (MirrorProtocolFaults) may of course strand the client.
ClientNeverStuck ==
  ~faulted =>
    /\ client_phase = "waiting_init" => mirror_phase \in {"validating", "ready", "stepping"}
    /\ client_phase = "waiting_ack"  => mirror_phase \in {"stepping", "done"}
    /\ client_phase = "waiting_done" => mirror_phase \in {"exploring", "done"}

Inv == PhaseOk /\
       ClientNeverStuck

\* Force trace generation: Apalache finds counterexamples
\* showing paths from idle to done.
TraceComplete ==
  client_phase /= "done"

\* Force a trace that completes through a SUCCESSFUL terminal message
\* (step mismatch counts as a completed conformance run). Error paths
\* (register errors, protocol errors) never satisfy this.
TraceSuccess ==
  ~(  action_taken = "ClientRecvAllStepsDone"
   \/ action_taken = "ClientRecvExploreDoneAck"
   \/ action_taken = "ClientRecvStepMismatch")

\* Force stepping path through ClientReport and mirror response.
TraceStepping ==
  ~(mirror_to_client /= <<>> /\ Head(mirror_to_client) = STEP_OK)

\* View that captures protocol-relevant state for trace inspection.
MirrorView == <<mirror_phase, client_phase, action_taken, mirror_flow, client_to_mirror, mirror_to_client>>

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
