---------------- MODULE ApalacheRPCClient ---------------------
EXTENDS Integers, AapalacheRPCProtocol

\* -----------------------------------------------------------------------------
\* This module models the observable behavior of the Haskell Apalache.Rpc.Client
\* (the JSON-RPC client wrapper) as a nondeterministic oracle.
\*
\* It EXTENDS AapalacheRPCProtocol so that each client RPC call is modeled as a
\* wrapper around the corresponding Explorer server-side operation.
\*
\* Each RPC call nondeterministically:
\*   - Succeeds → the Explorer state advances per the protocol oracle
\*   - Fails   → an error (HTTP transport, protocol, or parse) is returned;
\*               the Explorer state is unchanged
\*
\* The client tracks:
\*   - clSessionId : the session id returned by a successful loadSpec;
\*                   NO_SESSION (0) when no session is active
\*   - clLastMethod : the last RPC method called (for trace inspection)
\*   - clLastResult : the result of the last call
\*   - clReqId      : a monotonically increasing JSON-RPC request id
\*
\* Scope: a SINGLE session at a time is modeled (MaxSessions = 1). The real
\* server supports concurrent sessions; that is out of scope for this oracle.
\*
\* assumeTransition and nextStep are modeled as separate calls, mirroring
\* the real API: a successful assumeTransition records the pending
\* transition in expPending (ENABLED) or not (DISABLED), and nextStep is
\* only meaningful while a transition is pending — calling it otherwise
\* yields a server protocol error.
\*
\* Wire details (HTTP, JSON parsing, Manager) are NOT modeled.
\* Integration tests against a real apalache-mc server verify that the
\* implementation's behavior is consistent with these oracle rules.
\* -----------------------------------------------------------------------------

\* -----------------------------------------------------------------------------
\* Constants
\* -----------------------------------------------------------------------------

\* Session-ID sentinel: no active session.
NO_SESSION == 0
\* Single-session scope (see module header).
MaxSessions == 1

\* -----------------------------------------------------------------------------
\* Client-observable result kinds
\* -----------------------------------------------------------------------------

RPC_OK         == "ok"            \* call succeeded, value decoded
RPC_HTTP_ERR   == "http_error"    \* transport-layer failure (connection refused, etc.)
RPC_PROTO_ERR  == "protocol_error" \* JSON-RPC error returned by server
RPC_PARSE_ERR  == "parse_error"   \* response could not be decoded

\* -----------------------------------------------------------------------------
\* Client-side variables
\* -----------------------------------------------------------------------------

VARIABLE
  \* @type: Int;
  clSessionId,
  \* @type: Str;
  clLastMethod,
  \* @type: Str;
  clLastResult,
  \* @type: Int;
  clReqId,
  \* @type: Int;
  clLastTid,    \* transition id of the last assumeTransition (NO_PENDING if none)
  \* @type: Int;
  clLastIid,    \* invariant id of the last checkInvariant (NO_PENDING if none)
  \* @type: Int;
  clLastSnap    \* snapshot id of the last rollback (NO_PENDING if none)

\* -----------------------------------------------------------------------------
\* Client: health
\*
\* Server health check.  No session required — works as long as the server is
\* reachable.  Observable outcomes:
\*   - ok          : server responded with health status
\*   - http_error  : server unreachable
\*   - parse_error : response malformed
\* -----------------------------------------------------------------------------

ClientHealth ==
  /\ clLastMethod' = "health"
  /\ clReqId' = clReqId + 1
  /\ \/ clLastResult' = RPC_OK
     \/ clLastResult' = RPC_HTTP_ERR
     \/ clLastResult' = RPC_PARSE_ERR
  /\ UNCHANGED <<expPhase, expStep, expSnapshot, expPending, action_taken, clSessionId,
                  clLastTid, clLastIid, clLastSnap>>

\* -----------------------------------------------------------------------------
\* Client: loadSpec
\*
\* Loads a TLA+ specification.  On success the server creates a session and
\* the client captures the session id.  If the server rejects the spec
\* (parse error, missing operators, etc.) the call returns a protocol
\* error and NO session is created.
\*
\* Maps to ExplorerLoadSpec.
\* -----------------------------------------------------------------------------

ClientLoadSpec ==
  /\ clLastMethod' = "loadSpec"
  /\ clReqId' = clReqId + 1
  /\ \/ /\ ExplorerLoadSpec /\ expPhase' = "ready"
        /\ \E sid \in 1 .. MaxSessions : clSessionId' = sid
        /\ clLastResult' = RPC_OK
     \/ /\ ExplorerLoadSpec /\ expPhase' = "terminal"
        /\ clSessionId' = NO_SESSION
        /\ clLastResult' = RPC_PROTO_ERR
     \/ /\ UNCHANGED <<expPhase, expStep, expSnapshot, expPending, action_taken, clSessionId>>
        /\ clLastResult' \in {RPC_HTTP_ERR, RPC_PARSE_ERR}
  /\ UNCHANGED <<clLastTid, clLastIid, clLastSnap>>

\* -----------------------------------------------------------------------------
\* Client: assumeTransition(tid)
\*
\* Maps to ExplorerAssume.  An ENABLED outcome records tid in expPending
\* (observable in the model state); a DISABLED outcome leaves expPending
\* at NO_PENDING.  Both are transport-level successes (RPC_OK).  A
\* server-side internal error ("terminal") surfaces as a protocol error.
\* -----------------------------------------------------------------------------

ClientAssumeTransition(tid) ==
  /\ clLastMethod' = "assumeTransition"
  /\ clReqId' = clReqId + 1
  /\ \/ /\ ExplorerAssume(tid) /\ expPhase' /= "terminal"
        /\ clLastResult' = RPC_OK
     \/ /\ ExplorerAssume(tid) /\ expPhase' = "terminal"
        /\ clLastResult' = RPC_PROTO_ERR
     \/ /\ UNCHANGED <<expPhase, expStep, expSnapshot, expPending, action_taken>>
        /\ clLastResult' \in {RPC_HTTP_ERR, RPC_PARSE_ERR}
  /\ UNCHANGED clSessionId
  /\ clLastTid' = tid
  /\ UNCHANGED <<clLastIid, clLastSnap>>

\* -----------------------------------------------------------------------------
\* Client: nextStep
\*
\* Maps to ExplorerAdvance, which requires a pending (ENABLED) transition.
\* Calling nextStep with nothing pending makes ExplorerAdvance disabled,
\* so only the error branch can fire — modeling the server's protocol
\* error response.
\* -----------------------------------------------------------------------------

ClientNextStep ==
  /\ clLastMethod' = "nextStep"
  /\ clReqId' = clReqId + 1
  /\ \/ /\ ExplorerAdvance /\ expPhase' /= "terminal"
        /\ clLastResult' = RPC_OK
     \/ /\ ExplorerAdvance /\ expPhase' = "terminal"
        /\ clLastResult' = RPC_PROTO_ERR
     \/ /\ UNCHANGED <<expPhase, expStep, expSnapshot, expPending, action_taken>>
        /\ clLastResult' \in {RPC_HTTP_ERR, RPC_PROTO_ERR, RPC_PARSE_ERR}
  /\ UNCHANGED clSessionId
  /\ UNCHANGED <<clLastTid, clLastIid, clLastSnap>>

\* -----------------------------------------------------------------------------
\* Client: checkInvariant(iid)
\*
\* Checks an invariant at the current state.  Maps to ExplorerCheckInvariant.
\* -----------------------------------------------------------------------------

ClientCheckInvariant(iid) ==
  /\ clLastMethod' = "checkInvariant"
  /\ clReqId' = clReqId + 1
  /\ \/ /\ ExplorerCheckInvariant(iid)
        /\ clLastResult' = RPC_OK
     \/ /\ UNCHANGED <<expPhase, expStep, expSnapshot, expPending, action_taken>>
        /\ clLastResult' \in {RPC_HTTP_ERR, RPC_PROTO_ERR, RPC_PARSE_ERR}
  /\ UNCHANGED clSessionId
  /\ clLastIid' = iid
  /\ UNCHANGED <<clLastTid, clLastSnap>>

\* -----------------------------------------------------------------------------
\* Client: query
\*
\* Read-only: returns current state, trace, or operator value.
\* Maps to ExplorerQuery.
\* -----------------------------------------------------------------------------

ClientQuery ==
  /\ clLastMethod' = "query"
  /\ clReqId' = clReqId + 1
  /\ \/ /\ ExplorerQuery
        /\ clLastResult' = RPC_OK
     \/ /\ UNCHANGED <<expPhase, expStep, expSnapshot, expPending, action_taken>>
        /\ clLastResult' \in {RPC_HTTP_ERR, RPC_PROTO_ERR, RPC_PARSE_ERR}
  /\ UNCHANGED clSessionId
  /\ UNCHANGED <<clLastTid, clLastIid, clLastSnap>>

\* -----------------------------------------------------------------------------
\* Client: assumeState
\*
\* Requests the server to advance to a state satisfying given equalities.
\* Maps to ExplorerAssumeState.
\* -----------------------------------------------------------------------------

ClientAssumeState ==
  /\ clLastMethod' = "assumeState"
  /\ clReqId' = clReqId + 1
  /\ \/ /\ ExplorerAssumeState /\ expPhase' /= "terminal"
        /\ clLastResult' = RPC_OK
     \/ /\ ExplorerAssumeState /\ expPhase' = "terminal"
        /\ clLastResult' = RPC_PROTO_ERR
     \/ /\ UNCHANGED <<expPhase, expStep, expSnapshot, expPending, action_taken>>
        /\ clLastResult' \in {RPC_HTTP_ERR, RPC_PARSE_ERR}
  /\ UNCHANGED clSessionId
  /\ UNCHANGED <<clLastTid, clLastIid, clLastSnap>>

\* -----------------------------------------------------------------------------
\* Client: rollback(snap)
\*
\* Rolls back to a prior snapshot.
\* Maps to ExplorerRollback.
\* -----------------------------------------------------------------------------

ClientRollback(snap) ==
  /\ clLastMethod' = "rollback"
  /\ clReqId' = clReqId + 1
  /\ \/ /\ ExplorerRollback(snap)
        /\ clLastResult' = RPC_OK
     \/ /\ UNCHANGED <<expPhase, expStep, expSnapshot, expPending, action_taken>>
        /\ clLastResult' \in {RPC_HTTP_ERR, RPC_PROTO_ERR, RPC_PARSE_ERR}
  /\ UNCHANGED clSessionId
  /\ clLastSnap' = snap
  /\ UNCHANGED <<clLastTid, clLastIid>>

\* -----------------------------------------------------------------------------
\* Client: disposeSpec
\*
\* Ends the exploration session.  On success the session id is cleared
\* (NO_SESSION), preventing further session-dependent operations from
\* succeeding (they will fall through to the error branch).
\*
\* Maps to ExplorerDispose.
\* -----------------------------------------------------------------------------

ClientDispose ==
  /\ clLastMethod' = "disposeSpec"
  /\ clReqId' = clReqId + 1
  /\ \/ /\ ExplorerDispose
        /\ clSessionId' = NO_SESSION
        /\ clLastResult' = RPC_OK
     \/ /\ UNCHANGED <<expPhase, expStep, expSnapshot, expPending, action_taken>>
        /\ clLastResult' \in {RPC_HTTP_ERR, RPC_PROTO_ERR, RPC_PARSE_ERR}
        /\ UNCHANGED clSessionId
  /\ UNCHANGED <<clLastTid, clLastIid, clLastSnap>>

\* -----------------------------------------------------------------------------
\* Init
\* -----------------------------------------------------------------------------

ClientInit ==
  /\ ExplorerInit
  /\ clSessionId = NO_SESSION
  /\ clLastMethod = "none"
  /\ clLastResult = "none"
  /\ clReqId = 1
  /\ clLastTid = NO_PENDING
  /\ clLastIid = NO_PENDING
  /\ clLastSnap = NO_PENDING

\* -----------------------------------------------------------------------------
\* Next
\* -----------------------------------------------------------------------------

ClientNext ==
  \/ ClientHealth
  \/ ClientLoadSpec
  \/ \E tid \in 0 .. MaxTransitions : ClientAssumeTransition(tid)
  \/ ClientNextStep
  \/ \E iid \in 0 .. MaxInvariants : ClientCheckInvariant(iid)
  \/ ClientQuery
  \/ ClientAssumeState
  \/ \E snap \in 0 .. MaxSnapshots : ClientRollback(snap)
  \/ ClientDispose

\* -----------------------------------------------------------------------------
\* Specification
\* -----------------------------------------------------------------------------

ClientSpec ==
  ClientInit /\ [][ClientNext]_<<expPhase, expStep, expSnapshot, expPending, action_taken,
                                 clSessionId, clLastMethod, clLastResult, clReqId,
                                 clLastTid, clLastIid, clLastSnap>>

\* -----------------------------------------------------------------------------
\* Invariants
\* -----------------------------------------------------------------------------

\* Request IDs are always positive.
ReqIdPositive ==
  clReqId >= 1

\* The session id is always within its declared domain.
SessionIdValid ==
  clSessionId \in (0 .. MaxSessions)

\* A successful session-gated operation (other than dispose) implies
\* an active session.  disposeSpec is excluded because its post-condition
\* deliberately clears the session id.
SessionGated ==
  (clLastResult = RPC_OK
   /\ clLastMethod \in {"assumeTransition", "nextStep", "checkInvariant",
                        "query", "assumeState", "rollback"})
    => (clSessionId /= NO_SESSION)

ClientInv ==
  /\ ReqIdPositive
  /\ SessionIdValid
  /\ SessionGated

\* -----------------------------------------------------------------------------
\* Trace generation invariants (for apalache counterexample generation)
\* -----------------------------------------------------------------------------

\* Force the trace to include at least one SUCCESSFUL session-dependent call.
\* (Without the RPC_OK conjunct, the invariant is violated by any gated call
\* attempted before a session exists, yielding trivial 1-step traces.)
ClientUntilSessionCall ==
  ~(clLastResult = RPC_OK
    /\ clLastMethod \in {"assumeTransition", "nextStep", "checkInvariant",
                         "query", "assumeState", "rollback"})

\* Trace generation for ServerBehavior replay against a live server.
\* ClientHappyNext prunes all error outcomes (they are nondeterministic
\* and not replayable); ClientReplayTrace is then violated exactly once
\* enough successful RPC calls have been made.
\* Use with: --next=ClientHappyNext --inv=ClientReplayTrace
ClientHappyNext ==
  ClientNext /\ clLastResult' = RPC_OK

ClientReplayTrace ==
  clReqId <= 6

\* Event-targeted falsy invariants: each is violated exactly when the
\* named successful call first occurs, producing a trace that exercises
\* that call. Use with --next=ClientHappyNext.
ClientUntilAdvance ==
  ~(clLastMethod = "nextStep" /\ clLastResult = RPC_OK)

ClientUntilCheck ==
  ~(clLastMethod = "checkInvariant" /\ clLastResult = RPC_OK)

ClientUntilAssumeStateCall ==
  ~(clLastMethod = "assumeState" /\ clLastResult = RPC_OK)

ClientUntilRollback ==
  ~(clLastMethod = "rollback" /\ clLastResult = RPC_OK)

\* Violated by an assumeTransition whose outcome was DISABLED (the call
\* succeeded but no transition is pending afterwards).
ClientUntilDisabled ==
  ~(clLastMethod = "assumeTransition"
    /\ clLastResult = RPC_OK
    /\ expPending = NO_PENDING)

\* View for trace inspection.
ClientView == <<expPhase, clSessionId, clLastMethod, clLastResult, clReqId>>

\* -----------------------------------------------------------------------------
\* Conventional names (so tooling finds Init / Next / Spec without --init etc.)
\* -----------------------------------------------------------------------------

Init == ClientInit
Next == ClientNext
Spec == ClientSpec
Inv  == ClientInv
View == ClientView
Until == ClientUntilSessionCall

=============================================================================
