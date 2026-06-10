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
\* Wire details (HTTP, JSON parsing, Manager) are NOT modeled.
\* Integration tests against a real apalache-mc server verify that the
\* implementation's behavior is consistent with these oracle rules.
\* -----------------------------------------------------------------------------

\* -----------------------------------------------------------------------------
\* Constants
\* -----------------------------------------------------------------------------

\* Session-ID sentinel: no active session.
NO_SESSION == 0
MaxSessions == 3

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
  clReqId

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
  /\ UNCHANGED <<expPhase, expStep, expSnapshot, action_taken, clSessionId>>

\* -----------------------------------------------------------------------------
\* Client: loadSpec
\*
\* Loads a TLA+ specification.  On success the server creates a session and
\* the client captures the session id.
\*
\* Maps to ExplorerLoadSpec on success.
\* -----------------------------------------------------------------------------

ClientLoadSpec ==
  /\ clLastMethod' = "loadSpec"
  /\ clReqId' = clReqId + 1
  /\ \/ /\ ExplorerLoadSpec
        /\ \E sid \in 1 .. MaxSessions : clSessionId' = sid
        /\ clLastResult' = RPC_OK
     \/ /\ UNCHANGED <<expPhase, expStep, expSnapshot, action_taken, clSessionId>>
        /\ clLastResult' \in {RPC_HTTP_ERR, RPC_PROTO_ERR, RPC_PARSE_ERR}

\* -----------------------------------------------------------------------------
\* Client: assumeTransition(tid) + nextStep
\*
\* These two client calls are modeled together as ExplorerStep(tid) since the
\* protocol oracle treats the "assume transition then advance" sequence as a
\* single composite operation.
\*
\* ClientAssumeTransition  – picks a transition; maps to ExplorerStep(tid)
\* ClientNextStep          – advances from the previously-assumed transition;
\*                           maps to ExplorerStep with nondeterministic tid
\*                           (the server already knows which transition was
\*                           assumed)
\* -----------------------------------------------------------------------------

ClientAssumeTransition(tid) ==
  /\ clLastMethod' = "assumeTransition"
  /\ clReqId' = clReqId + 1
  /\ \/ /\ ExplorerStep(tid)
        /\ clLastResult' = RPC_OK
     \/ /\ UNCHANGED <<expPhase, expStep, expSnapshot, action_taken>>
        /\ clLastResult' \in {RPC_HTTP_ERR, RPC_PROTO_ERR, RPC_PARSE_ERR}
  /\ UNCHANGED clSessionId

ClientNextStep ==
  /\ clLastMethod' = "nextStep"
  /\ clReqId' = clReqId + 1
  /\ \/ /\ \E tid \in 0 .. MaxTransitions : ExplorerStep(tid)
        /\ clLastResult' = RPC_OK
     \/ /\ UNCHANGED <<expPhase, expStep, expSnapshot, action_taken>>
        /\ clLastResult' \in {RPC_HTTP_ERR, RPC_PROTO_ERR, RPC_PARSE_ERR}
  /\ UNCHANGED clSessionId

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
     \/ /\ UNCHANGED <<expPhase, expStep, expSnapshot, action_taken>>
        /\ clLastResult' \in {RPC_HTTP_ERR, RPC_PROTO_ERR, RPC_PARSE_ERR}
  /\ UNCHANGED clSessionId

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
     \/ /\ UNCHANGED <<expPhase, expStep, expSnapshot, action_taken>>
        /\ clLastResult' \in {RPC_HTTP_ERR, RPC_PROTO_ERR, RPC_PARSE_ERR}
  /\ UNCHANGED clSessionId

\* -----------------------------------------------------------------------------
\* Client: assumeState
\*
\* Requests the server to advance to a state satisfying given equalities.
\* Maps to ExplorerAssumeState.
\* -----------------------------------------------------------------------------

ClientAssumeState ==
  /\ clLastMethod' = "assumeState"
  /\ clReqId' = clReqId + 1
  /\ \/ /\ ExplorerAssumeState
        /\ clLastResult' = RPC_OK
     \/ /\ UNCHANGED <<expPhase, expStep, expSnapshot, action_taken>>
        /\ clLastResult' \in {RPC_HTTP_ERR, RPC_PROTO_ERR, RPC_PARSE_ERR}
  /\ UNCHANGED clSessionId

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
     \/ /\ UNCHANGED <<expPhase, expStep, expSnapshot, action_taken>>
        /\ clLastResult' \in {RPC_HTTP_ERR, RPC_PROTO_ERR, RPC_PARSE_ERR}
  /\ UNCHANGED clSessionId

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
     \/ /\ UNCHANGED <<expPhase, expStep, expSnapshot, action_taken>>
        /\ clLastResult' \in {RPC_HTTP_ERR, RPC_PROTO_ERR, RPC_PARSE_ERR}
        /\ UNCHANGED clSessionId

\* -----------------------------------------------------------------------------
\* Init
\* -----------------------------------------------------------------------------

ClientInit ==
  /\ ExplorerInit
  /\ clSessionId = NO_SESSION
  /\ clLastMethod = "none"
  /\ clLastResult = "none"
  /\ clReqId = 1

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
  ClientInit /\ [][ClientNext]_<<expPhase, expStep, expSnapshot, action_taken,
                                clSessionId, clLastMethod, clLastResult, clReqId>>

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

\* Force the trace to include at least one session-dependent operation.
ClientUntilSessionCall ==
  clLastMethod \notin {"assumeTransition", "nextStep", "checkInvariant",
                       "query", "assumeState", "rollback", "disposeSpec"}

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
