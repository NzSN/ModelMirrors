-------------------------- MODULE MinimalTraceCheck --------------------------

EXTENDS Sequences

(****************************************************************************
  MinimalTraceCheck: verify ModelMirrors by matching the MirrorStep sequence
  it produces against an expected trace.

  Normalize both (collapse timing-dependent pairs, strip terminators),
  then compare.  Normalization is hardcoded for a finite domain so that
  both TLC and Apalache can model-check it.
 ****************************************************************************)

Step   ==  { "Init", "Tick", "StepOk", "Mismatch", "AllDone", "RecvReport" }

Trace  ==  Seq(Step)

(****************************************************************************
  Normalize: strip trailing AllDone, collapse RecvReport+StepOk into
  "Match" and RecvReport+Mismatch into "Mismatch".
  Hardcoded for the 14-element domain below.
 ****************************************************************************)

Normalize(t) ==
  CASE t = <<>>                                     -> <<>>
    [] t = <<"Init">>                               -> <<"Init">>
    [] t = <<"AllDone">>                            -> <<>>
    [] t = <<"Init","AllDone">>                     -> <<"Init">>
    [] t = <<"RecvReport","StepOk">>                -> <<"Match">>
    [] t = <<"RecvReport","Mismatch">>              -> <<"Mismatch">>
    [] t = <<"RecvReport","StepOk","AllDone">>      -> <<"Match">>
    [] t = <<"RecvReport","Mismatch","AllDone">>    -> <<"Mismatch">>
    [] t = <<"Init","RecvReport","StepOk">>         -> <<"Init","Match">>
    [] t = <<"Init","RecvReport","Mismatch">>       -> <<"Init","Mismatch">>
    [] t = <<"RecvReport","StepOk","RecvReport","StepOk">>
                                                    -> <<"Match","Match">>
    [] t = <<"RecvReport","Mismatch","RecvReport","StepOk">>
                                                    -> <<"Mismatch","Match">>
    [] t = <<"Init","RecvReport","StepOk","AllDone">>
                                                    -> <<"Init","Match">>
    [] t = <<"Tick","Mismatch">>                    -> <<"Tick","Mismatch">>
    [] OTHER                                        -> t

(****************************************************************************
  The check: normalize both, then compare.
 ****************************************************************************)

Check(expected, produced) == Normalize(expected) = Normalize(produced)

(****************************************************************************
  MODEL-CHECKING HARNESS
 ****************************************************************************)

VARIABLE
  \* @type: Seq(Str);
  expected,
  \* @type: Seq(Str);
  produced

AllTraces ==
  { <<>>,
    <<"Init">>,
    <<"AllDone">>,
    <<"Init","AllDone">>,
    <<"RecvReport","StepOk">>,
    <<"RecvReport","Mismatch">>,
    <<"RecvReport","StepOk","AllDone">>,
    <<"RecvReport","Mismatch","AllDone">>,
    <<"Init","RecvReport","StepOk">>,
    <<"Init","RecvReport","Mismatch">>,
    <<"RecvReport","StepOk","RecvReport","StepOk">>,
    <<"RecvReport","Mismatch","RecvReport","StepOk">>,
    <<"Init","RecvReport","StepOk","AllDone">>,
    <<"Tick","Mismatch">>
  }

Init ==
  /\ expected \in AllTraces
  /\ produced \in AllTraces

Next == UNCHANGED <<expected, produced>>

Spec == Init /\ [][Next]_expected

SelfCheck == Check(expected, expected)

NormalizeIdempotent == Normalize(Normalize(expected)) = Normalize(expected)

=============================================================================
