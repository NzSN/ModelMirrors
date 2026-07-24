# MBT: remaining work

All items complete as of this update (see `specs/MirrorProtocol.tla`,
`specs/MirrorProtocolFaults.tla`, `specs/MirrorProtocolWitness.tla`,
`specs/traces/`, `test/MirrorProtocolSpec.hs`).

Done: protocol model fixed (dead `PROTOCOL_ERROR` path removed,
`MirrorSendSpecValidatedInvalid` removed, report action split into
`MirrorRecvReportOk`/`AllDone`/`Mismatch`, explicit `Halt`,
`ClientNeverStuck` invariant, `ProjectAction`/`ProjectTrace` projection),
witness traces exported for all flows, `testMbtMirrorProtocol` conformance
driver green (protocol-shape comparison).

Completed remaining items:

1. **Controllable match/mismatch testing** — DONE. `report_matches \in
   BOOLEAN` added to the model (set nondeterministically by `ClientReport`;
   the three `MirrorRecvReport*` actions are gated on it). The driver
   extracts the bit sequence and reports a deliberately wrong state on
   mismatch reports, so Ok/AllDone/Mismatch branches are exercised
   deterministically; branch comparison is exact (with the AllDone
   abstraction: model `AllDone` ≍ impl `Ok* AllDone`, no impl mismatch).
2. **Transport coverage** — DONE. `testMbtTransports` runs the MBT driver
   over `stdio` (spawned mirror process), `tcp`, and `tls`
   (`serveTlsConcurrent`), gated behind `MBT_TRANSPORTS` (comma-separated;
   unset = no-op, so Bazel/default runs skip it).
3. **Fault injection** — DONE. Channels are multi-element message queues
   (`Seq(Int)`); `specs/MirrorProtocolFaults.tla` adds drop, duplicate,
   and premature-close actions plus a `faulted` flag scoping
   `ClientNeverStuck` to fault-free paths. Impl side: `protocol_error` is
   now sent on undecodable/unexpected mid-session input before the session
   aborts, `serveTcp` catches all per-session exceptions (a client-caused
   `ProtocolException` no longer kills the accept loop), and
   unreadable trace files yield `RegisterError` instead of a crash. Tests:
   out-of-order first message, garbage mid-session, premature close
   (`testPrematureCloseTcp`; note `tcpClose` — `close` on the socket is a
   no-op after `socketToHandle`).
4. **Witness traces in CI** — DONE. `scripts/gen-witness-traces.sh`
   regenerates `specs/traces/*.itf.json` from `MirrorProtocolWitness.tla`
   (+ `fault_close` from `MirrorProtocolFaults.tla`);
   `.github/workflows/witness-traces.yml` regenerates them in CI and fails
   on `git diff`, then runs `cabal test all`. `testWitnessTracesFixed`
   replays the checked-in traces as fixed regression scenarios (shared
   driver with the freshly-sampled MBT test).
5. **Bazel build** — DONE. TLS sources live in `src-tls/` (cabal-only);
   `stubs/` provides Bazel-only stub modules (`Protocol.Transport.Tls`,
   `TlsTransportSpec`). `bazel build //...` and `bazel test` are green.
   Also fixed along the way: the Bazel test sandbox needs a locale
   (`.bazelrc` sets `LANG`/`LC_ALL=C.UTF-8`; without it apalache-mc fails
   with `Configuration error: Input length = 1`) and `size = "large"` for
   the ~400s suite; `specs/traces` added to test data.
