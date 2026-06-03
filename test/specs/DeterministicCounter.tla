---------------- MODULE DeterministicCounter ----------------
EXTENDS Integers

VARIABLE
  \* @type: Int;
  count,
  \* @type: Str;
  action_taken,
  \* @type: Int;
  step_count

Init ==
  count = 0 /\
  action_taken = "init" /\
  step_count = 0

Next ==
  count' = count + 1 /\
  action_taken' = "inc" /\
  step_count' = step_count + 1

\* Apalache treats a violated invariant as a counterexample = the test trace.
TraceComplete == step_count < 5

Spec == Init /\ [][Next]_count
=============================================================
