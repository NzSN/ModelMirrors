---------------- MODULE Counter ----------------
EXTENDS Integers

CONSTANTS
  \* @type: Set(Int);
  STRIDES

VARIABLE
  \* @type: Int;
  count,
  \* @type: { stride: Int };
  parameters,
  \* @type: Str;
  action_taken,
  \* @type: Int;
  step_count

Init ==
  count = 0 /\
  parameters = [stride |-> 0] /\
  action_taken = "init" /\
  step_count = 0

\* @type: () => Bool;
CInit == STRIDES = {2, 3}

TICK(S) ==
  S \in STRIDES /\
  count' = count + S /\
  parameters' = [stride |-> S] /\
  action_taken' = "tick" /\
  step_count' = step_count + 1

Next ==
  \E S \in STRIDES: TICK(S)

\* Apalache treats a violated invariant as a counterexample = the test trace.
TraceComplete == step_count < 5

Spec == Init /\ [][Next]_<<count, parameters>>
========================================================
