# MBT: remaining work

Status as of the MBT bring-up (see `specs/MirrorProtocol.tla`,
`specs/MirrorProtocolWitness.tla`, `specs/traces/`, `test/MirrorProtocolSpec.hs`).

Done: protocol model fixed (dead `PROTOCOL_ERROR` path removed,
`MirrorSendSpecValidatedInvalid` removed, report action split into
`MirrorRecvReportOk`/`AllDone`/`Mismatch`, explicit `Halt`,
`ClientNeverStuck` invariant, `ProjectAction`/`ProjectTrace` projection),
witness traces exported for all flows, `testMbtMirrorProtocol` conformance
driver green (protocol-shape comparison).

Remaining:

1. **Controllable match/mismatch testing** — add a payload bit to the model
   (e.g. `report_matches \in BOOLEAN`) so the model, not the fixture, decides
   the Ok/Mismatch branch; the driver then reports a deliberately wrong state
   to exercise the mismatch path deterministically. Currently the branch is
   uncontrollable and only protocol shape is compared.
2. **Transport coverage** — run the MBT driver over `Stdio`/`Tcp`/`Tls`
   transports in addition to `Mock` (gate slower suites behind a flag).
3. **Fault injection** — multi-element channels in the model plus drop,
   reorder, and premature-close actions for negative tests; expect
   `REGISTER_ERROR`/disconnect handling on the impl side.
4. **Witness traces checked into CI** — regenerate `specs/traces/*.itf.json`
   from `MirrorProtocolWitness.tla` in CI and use them as fixed regression
   scenarios (not only freshly sampled traces).
5. **Bazel build** — `bazel build //...` still fails: TLS deps (`tls`,
   `crypton*`) are cabal-only (`hpke` doesn't build under rules_haskell);
   `Protocol.Transport.Tls` must be excluded or split out of
   `src/BUILD.bazel`'s glob for the Bazel build to pass.
