---------------- MODULE MirrorProtocolFaults ----------------
\* Fault injection on top of MirrorProtocol: multi-element channels with
\* drop, duplicate (stale replay), and premature-close actions. Fault
\* actions set `faulted`, which scopes the base invariants to fault-free
\* paths.
EXTENDS MirrorProtocol

\* Lose the queued client → mirror message.
DropClMsg ==
  /\ client_to_mirror /= <<>>
  /\ client_to_mirror' = Tail(client_to_mirror)
  /\ faulted' = TRUE
  /\ action_taken' = "DropClMsg"
  /\ UNCHANGED <<mirror_phase, client_phase, mirror_flow, mirror_to_client, report_matches, client_closed, mirror_closed>>

\* Lose the queued mirror → client message.
DropMirMsg ==
  /\ mirror_to_client /= <<>>
  /\ mirror_to_client' = Tail(mirror_to_client)
  /\ faulted' = TRUE
  /\ action_taken' = "DropMirMsg"
  /\ UNCHANGED <<mirror_phase, client_phase, mirror_flow, client_to_mirror, report_matches, client_closed, mirror_closed>>

\* Duplicate the queued client → mirror message: the receiver processes a
\* stale replay (an out-of-order/unexpected message on the impl side).
DupClMsg ==
  /\ client_to_mirror /= <<>>
  /\ client_to_mirror' = client_to_mirror \o <<Head(client_to_mirror)>>
  /\ faulted' = TRUE
  /\ action_taken' = "DupClMsg"
  /\ UNCHANGED <<mirror_phase, client_phase, mirror_flow, mirror_to_client, report_matches, client_closed, mirror_closed>>

\* Duplicate the queued mirror → client message.
DupMirMsg ==
  /\ mirror_to_client /= <<>>
  /\ mirror_to_client' = mirror_to_client \o <<Head(mirror_to_client)>>
  /\ faulted' = TRUE
  /\ action_taken' = "DupMirMsg"
  /\ UNCHANGED <<mirror_phase, client_phase, mirror_flow, client_to_mirror, report_matches, client_closed, mirror_closed>>

\* Client closes the connection mid-session: queued messages are wiped.
ClientCloseConn ==
  /\ ~client_closed
  /\ client_phase \in Cs \ {"idle", "done"}
  /\ client_closed' = TRUE
  /\ client_to_mirror' = <<>>
  /\ faulted' = TRUE
  /\ action_taken' = "ClientCloseConn"
  /\ UNCHANGED <<mirror_phase, client_phase, mirror_flow, mirror_to_client, report_matches, mirror_closed>>

\* Mirror closes the connection mid-session.
MirrorCloseConn ==
  /\ ~mirror_closed
  /\ mirror_phase \in Ms \ {"idle", "done"}
  /\ mirror_closed' = TRUE
  /\ mirror_to_client' = <<>>
  /\ faulted' = TRUE
  /\ action_taken' = "MirrorCloseConn"
  /\ UNCHANGED <<mirror_phase, client_phase, mirror_flow, client_to_mirror, report_matches, client_closed>>

\* Mirror notices the closed connection and aborts the session.
MirrorDetectClose ==
  /\ client_closed
  /\ mirror_phase \in {"validating", "generating", "ready", "stepping", "exploring"}
  /\ mirror_phase' = "done"
  /\ mirror_to_client' = <<>>
  /\ faulted' = TRUE
  /\ action_taken' = "MirrorDetectClose"
  /\ UNCHANGED <<client_phase, mirror_flow, client_to_mirror, report_matches, client_closed, mirror_closed>>

\* Client notices the closed connection and aborts the session.
ClientDetectClose ==
  /\ mirror_closed
  /\ client_phase \in Cs \ {"idle", "done"}
  /\ client_phase' = "done"
  /\ faulted' = TRUE
  /\ action_taken' = "ClientDetectClose"
  /\ UNCHANGED <<mirror_phase, mirror_flow, client_to_mirror, mirror_to_client, report_matches, client_closed, mirror_closed>>

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

vars == <<mirror_phase, client_phase, action_taken, mirror_flow, client_to_mirror, mirror_to_client, report_matches, faulted, client_closed, mirror_closed>>

FaultSpec == Init /\ [][FaultNext]_vars

\* Witness-forcing invariants: violations yield fault traces.
NoDropCl     == action_taken /= "DropClMsg"
NoDupCl      == action_taken /= "DupClMsg"
NoCloseTrace == action_taken /= "MirrorDetectClose"
==============================================================================
