---------------- MODULE MirrorProtocolFaults ----------------
\* Fault injection on top of MirrorProtocol: multi-element channels with
\* drop, duplicate (stale replay), and premature-close actions. Fault
\* actions set `faulted`, which scopes the base invariants to fault-free
\* paths.
EXTENDS MirrorProtocol

\* Lose the queued client → mirror message.
DropClMsg ==
  /\ cl_to_mir /= <<>>
  /\ cl_to_mir' = Tail(cl_to_mir)
  /\ faulted' = TRUE
  /\ action_taken' = "DropClMsg"
  /\ UNCHANGED <<mp, cp, mflow, mir_to_cl, report_matches, cl_closed, mir_closed>>

\* Lose the queued mirror → client message.
DropMirMsg ==
  /\ mir_to_cl /= <<>>
  /\ mir_to_cl' = Tail(mir_to_cl)
  /\ faulted' = TRUE
  /\ action_taken' = "DropMirMsg"
  /\ UNCHANGED <<mp, cp, mflow, cl_to_mir, report_matches, cl_closed, mir_closed>>

\* Duplicate the queued client → mirror message: the receiver processes a
\* stale replay (an out-of-order/unexpected message on the impl side).
DupClMsg ==
  /\ cl_to_mir /= <<>>
  /\ cl_to_mir' = cl_to_mir \o <<Head(cl_to_mir)>>
  /\ faulted' = TRUE
  /\ action_taken' = "DupClMsg"
  /\ UNCHANGED <<mp, cp, mflow, mir_to_cl, report_matches, cl_closed, mir_closed>>

\* Duplicate the queued mirror → client message.
DupMirMsg ==
  /\ mir_to_cl /= <<>>
  /\ mir_to_cl' = mir_to_cl \o <<Head(mir_to_cl)>>
  /\ faulted' = TRUE
  /\ action_taken' = "DupMirMsg"
  /\ UNCHANGED <<mp, cp, mflow, cl_to_mir, report_matches, cl_closed, mir_closed>>

\* Client closes the connection mid-session: queued messages are wiped.
ClientCloseConn ==
  /\ ~cl_closed
  /\ cp \in Cs \ {"idle", "done"}
  /\ cl_closed' = TRUE
  /\ cl_to_mir' = <<>>
  /\ faulted' = TRUE
  /\ action_taken' = "ClientCloseConn"
  /\ UNCHANGED <<mp, cp, mflow, mir_to_cl, report_matches, mir_closed>>

\* Mirror closes the connection mid-session.
MirrorCloseConn ==
  /\ ~mir_closed
  /\ mp \in Ms \ {"idle", "done"}
  /\ mir_closed' = TRUE
  /\ mir_to_cl' = <<>>
  /\ faulted' = TRUE
  /\ action_taken' = "MirrorCloseConn"
  /\ UNCHANGED <<mp, cp, mflow, cl_to_mir, report_matches, cl_closed>>

\* Mirror notices the closed connection and aborts the session.
MirrorDetectClose ==
  /\ cl_closed
  /\ mp \in {"validating", "generating", "ready", "stepping", "exploring"}
  /\ mp' = "done"
  /\ mir_to_cl' = <<>>
  /\ faulted' = TRUE
  /\ action_taken' = "MirrorDetectClose"
  /\ UNCHANGED <<cp, mflow, cl_to_mir, report_matches, cl_closed, mir_closed>>

\* Client notices the closed connection and aborts the session.
ClientDetectClose ==
  /\ mir_closed
  /\ cp \in Cs \ {"idle", "done"}
  /\ cp' = "done"
  /\ faulted' = TRUE
  /\ action_taken' = "ClientDetectClose"
  /\ UNCHANGED <<mp, mflow, cl_to_mir, mir_to_cl, report_matches, cl_closed, mir_closed>>

FaultNext ==
  \/ Next
  \/ DropClMsg
  \/ DropMirMsg
  \/ DupClMsg
  \/ DupMirMsg
  \/ ClientCloseConn
  \/ MirrorCloseConn
  \/ MirrorDetectClose
  \/ ClientDetectClose

vars == <<mp, cp, action_taken, mflow, cl_to_mir, mir_to_cl, report_matches, faulted, cl_closed, mir_closed>>

FaultSpec == Init /\ [][FaultNext]_vars

\* Witness-forcing invariants: violations yield fault traces.
NoDropCl     == action_taken /= "DropClMsg"
NoDupCl      == action_taken /= "DupClMsg"
NoCloseTrace == action_taken /= "MirrorDetectClose"
==============================================================================
