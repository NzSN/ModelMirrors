#!/bin/sh
# Regenerate the checked-in witness traces in specs/traces/ from
# specs/MirrorProtocolWitness.tla (and specs/MirrorProtocolFaults.tla for
# the fault trace). Run from the repository root; requires apalache-mc on
# PATH. CI runs this and fails if specs/traces/ differs from the checked-in
# copies (git diff --exit-code).
set -eu

OUT=specs/traces
mkdir -p "$OUT"

gen() { # <out-name> <invariant> <spec> [extra apalache args...]
  name=$1; inv=$2; spec=$3; shift 3
  echo "== $name ($inv)"
  apalache-mc check --inv="$inv" --length=20 --max-error=1 "$@" "$spec" >/dev/null 2>&1 || {
    code=$?
    # apalache exits 12 when a counterexample (= our witness) is found
    [ "$code" = 12 ] || { echo "apalache failed for $name (exit $code)"; exit "$code"; }
  }
  dir=$(ls -td "_apalache-out/$(basename "$spec")"/*/ | head -1)
  cp "$dir/violation.itf.json" "$OUT/$name.itf.json"
  echo "wrote $OUT/$name.itf.json"
}

gen all_steps_done NoAllStepsDone specs/MirrorProtocolWitness.tla
gen step_mismatch NoStepMismatch specs/MirrorProtocolWitness.tla
gen register_error NoRegisterError specs/MirrorProtocolWitness.tla
gen explore_cmd NoExploreCmdRound specs/MirrorProtocolWitness.tla
gen explore_session NoExploreSessionDone specs/MirrorProtocolWitness.tla
gen fault_close NoCloseTrace specs/MirrorProtocolFaults.tla --init=Init --next=FaultNext
