---------------- MODULE MirrorProtocolWitness ----------------
EXTENDS MirrorProtocol

\* Witness-forcing invariants: a violation of each yields a trace of
\* the corresponding flow.
NoAllStepsDone    == action_taken /= "ClientRecvAllStepsDone"
NoStepMismatch    == action_taken /= "ClientRecvStepMismatch"
NoRegisterError   == action_taken /= "ClientRecvRegisterError"
NoExploreCmdRound == ~(action_taken = "ClientRecvExploreResult")
NoExploreSessionDone == action_taken /= "ClientRecvExploreDoneAck"
==============================================================
