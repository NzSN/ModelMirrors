# Implementation: Remote Validation (Validate-Only Path)

> **Status: implemented** (plus post-review amendments: typecheck
> isolation, `traceArgs` `--inv` gating, server-side bound cap, MBT
> coverage). This document is kept as the as-built record; where it and
> the code ever disagree, the code is the source of truth.

Implementation plan for the validate-only path designed in
`docs/validate-only-design.md`. The TLA+ model already covers this flow
(`ClientRegisterValidate → MirrorRecvRegisterValidate →
MirrorSendSpecValidated{Valid,Invalid} → ClientRecvSpecValidatedDone` in
`specs/MirrorProtocol.tla`); this document is the code-side plan.

One naming deviation from `validate-only-design.md`: the receive step is
`MirrorRecvRegisterValidate` (not `MirrorRecvValidate`), matching both the
`MirrorRecvRegister*` constructor convention and the checked-in TLA action
names, which the MBT conformance driver compares against
`mirrorStepActionName`.

## Message flow

```
client                                    mirror
  |  RegisterValidate cfg bound mSpec       |
  | --------------------------------------> |  mp: idle -> validating
  |                                         |  typecheck + bounded check
  |  SpecValidated SpecValid                |
  | <-------------------------------------- |  valid:      mp -> done
  |  SpecValidated (SpecInvalid output)     |
  | <-------------------------------------- |  invalid:    mp -> done
  |  RegisterError err                      |
  | <-------------------------------------- |  infra/spec-materialization
  |                                         |  failure:    mp -> done
```

Session ends after exactly one reply. No trace generation, no stepping.

## 1. `src/Protocol/Core.hs`

One new `ClientMessage` constructor, placed after `RegisterExploreSession`:

```haskell
| RegisterValidate !ApalacheConfig !Int !(Maybe ApalacheSpec)
--                 ^ config          ^ check bound   ^ optional inline spec
```

`MirrorMessage` is unchanged — `SpecValidated !ValidateResult` and
`RegisterError` already carry every outcome.

## 2. `src/Protocol/Format/Json.hs`

Follows the `proto_step` convention exactly:

```haskell
-- ToJSON ClientMessage
RegisterValidate cfg bound mSpec -> object $
  [ fromString "proto_step"      .= T.pack "register_validate"
  , fromString "apalacheConfig"  .= cfg
  , fromString "bound"           .= bound
  ] ++ maybe [] (\s -> [fromString "spec" .= s]) mSpec

-- FromJSON ClientMessage, alongside the other register_* clauses
t | t == T.pack "register_validate" ->
    RegisterValidate <$> o .: fromString "apalacheConfig"
                     <*> o .: fromString "bound"
                     <*> o .:? fromString "spec"
```

Reply side (`spec_validated`, `register_error`) is unchanged.

## 3. `src/Apalache/Command.hs`

The original `validateSpec` never returned `Left` — every process failure
became `SpecInvalid`. The validate-only path needs the three-tier split
from the design doc, so a run-dir-taking variant classifies exit
codes the way `generateTracesIn` does:

```haskell
validateSpecIn :: Maybe FilePath -> ApalacheConfig -> Int -> IO (Either ApalacheError ValidateResult)
validateSpec   = validateSpecIn Nothing
```

- `checkArgs` gains `maybe [] (\d -> ["--run-dir=" ++ d]) runDir` (same
  clause as `traceArgs`); its signature takes the `Maybe FilePath`.
- Exit-code classification for both `typecheck` and `check`:
  exit 255 (apalache config/parse error, same convention as
  `generateTracesIn`) → `Left ApalacheError`; other non-zero →
  `Right (SpecInvalid output)`; success of both → `Right SpecValid`.
  **Verified against apalache 0.57**: invariant violations exit 12,
  typecheck failures exit **120** (not 12), parse/config/infrastructure
  errors exit 255. The classification is robust to these differences
  because any non-255 lands in `SpecInvalid`. (Verified against
  apalache 0.57/0.58 — the classification does not depend on the exact
  non-255 codes.)
- Deliberate classification decision: a spec that **fails typechecking**
  is reported as `SpecInvalid` (the verdict tier), not `RegisterError` —
  a type error is a spec-authored defect, like an invariant violation.
  `RegisterError` is reserved for the mirror being unable to run apalache
  at all (exit 255) and for spec-materialization failures. The CLI maps
  both to distinct exit codes (1 vs 2), and the apalache output in the
  `SpecInvalid` payload (e.g. "Type checker [FAILED]") keeps the two
  distinguishable.
- `tcArgs` **also gains the run-dir** (the plan's "typecheck writes no
  run output" assumption proved false): apalache writes
  `_apalache-out/<Spec>/<timestamp>/{detailed.log,run.txt}` and `tmp/`
  into the process **cwd** on both phases even when `--run-dir` is given.
  So `validateSpecIn` additionally runs both child processes with
  `cwd = runDir` (absolutizing `specPath` first, since a relative path
  would no longer resolve once the child's cwd moves). All stray writes
  then land inside the per-session temp dir — see §4 for why this matters.
- Amendment for remote validation: `checkArgs` also passes
  `--inv=<invariant cfg>` when `invariant cfg` is non-empty — otherwise
  the validate path only checks type correctness and deadlock-freedom,
  and a remote client can't ask "does my invariant hold?".
  (`Register`'s trace flow generates traces via `traceArgs`, which now
  gates `--inv` the same way: it previously passed `--inv=`
  unconditionally, and an empty `--inv=` is an apalache config error —
  exit 255 — that failed the whole trace path for specs without an
  invariant.)

## 4. `src/Protocol/Mirror.hs`

New step constructor + name mapping:

```haskell
| MirrorRecvRegisterValidate !ApalacheConfig !Int !(Maybe ApalacheSpec)
-- mirrorStepActionName: "MirrorRecvRegisterValidate"
```

Send side reuses the existing `MirrorSendSpecValidatedValid` /
`MirrorSendSpecValidatedInvalid` / `MirrorSendRegisterError` constructors —
`MirrorSendSpecValidatedInvalid` becomes reachable for the first time.

New wrapper + `Step` instance, structurally `MkRunMirror` minus replay,
plus a server-side bound cap (post-review amendment — an unbounded
client-controlled `--length` is a DoS knob, so `MkRunValidate` rejects
out-of-range bounds with `RegisterError` *before* spec materialization):

```haskell
data MkRunValidate t = MkRunValidate t ApalacheConfig Int (Maybe ApalacheSpec)

maxValidateBound :: Int
maxValidateBound = 100

instance Transport t => Step (MkRunValidate t) where
  exec (MkRunValidate transport cfg bound mSpec)
    | bound < 1 || bound > maxValidateBound = do
        let msg = ... -- "bound <n> outside allowed range 1..100"
        sendMsg transport (RegisterError msg)
        pure [MirrorSendRegisterError msg]
    | otherwise =
      withSpecDir transport mSpec cfg $ \cfg' ->
        withSessionDir $ \sessionDir -> do
          res <- validateSpecIn (Just sessionDir) cfg' bound
          case res of
            Left err -> do
              sendMsg transport (RegisterError (unApalacheError err))
              pure [MirrorSendRegisterError (unApalacheError err)]
            Right v -> do
              sendMsg transport (SpecValidated v)
              pure [case v of
                      SpecValid     -> MirrorSendSpecValidatedValid
                      SpecInvalid e -> MirrorSendSpecValidatedInvalid e]
```

The TLA model already permits `MirrorSendRegisterError` after
`MirrorRecvRegisterValidate` (materialization/apalache failure), so the
cap needed no spec change; the model's traces never exercise it because
the model abstracts the bound away.

(`withSpecDir` already handles inline-spec materialization failure by
sending `RegisterError` — tier 1 of the design table comes for free.)

One clause in the `RecvMsg` dispatch, next to the other `Register*` cases:

```haskell
Right (RegisterValidate apCfg bound mSpec) -> do
  steps <- exec (MkRunValidate transport apCfg bound mSpec)
  pure (MirrorRecvRegisterValidate apCfg bound mSpec : steps)
```

Exports: add `MkRunValidate (..)` and a convenience wrapper mirroring
`runMirror`/`runMirrorWithSpec`:

```haskell
runMirrorValidate :: Transport t => t -> ApalacheConfig -> Int -> Maybe ApalacheSpec -> IO [MirrorStep]
runMirrorValidate transport cfg bound mSpec = exec (MkRunValidate transport cfg bound mSpec)
```

`normalizeMirrorSteps` needs no change (no collapse rules for the new
constructor). The mirror path needs no changes to transports or server
modes — `run` dispatches on the first message, so stdio/TCP/mTLS all get
the path for free. (Scope note: the §9 *client* CLI does add code to
`app/Main.hs` and the TCP/TLS transports; the claim above covers only
the mirror side.) The concurrent mTLS dispatcher is safe because
`validateSpecIn` confines every apalache write to the per-session
directory: not just via `--run-dir`, but by running both child processes
with `cwd = sessionDir` (apalache also writes `_apalache-out/` and
`tmp/` into the process cwd — see §3).

## 5. `src/Protocol/Client.hs`

```haskell
runClientValidate :: Transport t => t -> ApalacheConfig -> Int -> Maybe ApalacheSpec -> IO (Either Text ValidateResult)
runClientValidate transport cfg bound mSpec = do
  sendMsg transport (RegisterValidate cfg bound mSpec)
  recvMsg transport >>= \case
    Left err                   -> pure (Left (T.pack err))
    Right (SpecValidated v)    -> pure (Right v)
    Right (RegisterError e)    -> pure (Left e)
    Right (ProtocolError e)    -> pure (Left e)
    Right _ -> pure (Left (T.pack "Unexpected message: expected SpecValidated"))
```

Return type amended from the original `Either Text ()`: `Left` is the
infrastructure tier (transport failure, `RegisterError`, `ProtocolError`),
`Right` is the mirror's verdict (`SpecValid` / `SpecInvalid output`). The
command-line client (§9) needs the split to pick its exit code.

Takes a bare transport, not a `Client` record — no step handler is ever
invoked (same bare-transport style as `exploreSession`).

## 6. Tests (`test/MirrorProtocolSpec.hs`, format specs)

- Happy path over mock transport with `test/specs/HourClock.tla`:
  expects exactly `[MirrorRecvRegisterValidate _, MirrorSendSpecValidatedValid]`
  and client `Right SpecValid`.
- Violated invariant at small bound (a one-line `FALSE` invariant wrapper
  spec, or a small inline spec): expects `MirrorSendSpecValidatedInvalid`
  and client `Right (SpecInvalid _)` — the invalid verdict is `Right`;
  `Left` is reserved for the infra tier.
- Inline-`ApalacheSpec` variant to cover `withSpecDir`.
- Bad inline spec (unparseable module) → `RegisterError` tier: client
  `Left`.
- Bound cap: `maxValidateBound + 1` and `0` both → `RegisterError` tier
  (`[MirrorRecvRegisterValidate _, MirrorSendRegisterError _]`, client
  `Left`).
- JSON roundtrip for `register_validate` (a dedicated
  `testRegisterValidateJsonRoundtrip`; the `register*` family roundtrip
  test predates it and does not include it).
- Conformance naming: assert `mirrorStepActionName` of the new
  constructors equals the TLA action names (`MirrorRecvRegisterValidate`,
  `MirrorSendSpecValidatedValid`, `MirrorSendSpecValidatedInvalid`).

## 7. MBT driver (`test/MirrorProtocolSpec.hs`)

Implemented (post-review amendment). The mock-transport MBT test
(`testMbtMirrorProtocol`) partitions sampled traces: validate traces
(those containing `ClientRegisterValidate`) are driven by
`checkValidateTraceAgainstMirror`, which branches on the trace's
expected mirror actions — valid-outcome traces are driven against the
HourClock fixture with `runClientValidate`, invalid-outcome traces
against the inline `invalidSpec` fixture (`Inv == FALSE`), and the
mirror's step trace is compared against the model's mirror-action
sequence. This covers both `MirrorSendSpecValidatedValid` and
`MirrorSendSpecValidatedInvalid` traces.

Still excluded: `RegisterError`-outcome validate traces (infrastructure
failures can't be forced deterministically from the client side) and the
real-transports MBT test (validate over real transports is covered by
the `MainSpec` CLI integration tests instead). See
`docs/mbt-remaining-work.md`.

## 8. Docs

- `docs/protocol-spec.md`: add the `register_validate` flow
  (`Idle → Validating → Done`); the `Validating` state's description
  becomes literally true.
- `docs/mbt-remaining-work.md`: drop the "spec ahead of implementation"
  flag once this lands.
- AGENTS.md: updated for the new `Protocol.ValidateOpts` module (the
  hand-rolled option parser for the §9 CLI) and the `validate`
  subcommand.

## 9. Command-line client

A client-role CLI for the validate-only path: sends a spec to a remote
mirror, prints the verdict, exits with a meaningful code. New `validate`
subcommand in the existing executable (`app/Main.hs` dispatches on argv;
the mirror roles stay as they are).

### Usage

```
ModelMirrors validate --host H --port P --spec Spec.tla [--dep D.tla]...
                      [--bound N] [--inv I] [--init P] [--next P] [--cinit C]
                      [--tls --cert C --key K --ca CA] [--pin SHA256]
```

### Semantics

- **The server never sees the client's filesystem.** The CLI reads
  `--spec` and every `--dep`, and sends them inline as an `ApalacheSpec`
  whose sources are `root : deps` (root first). The mirror's
  `withSpecDir` materializes them to a temp dir named after each MODULE
  header, so `EXTENDS` between the sent files resolves. Resolving the
  transitive dependency set is the user's responsibility (no module-graph
  scanning in v1).
- `ApalacheConfig`: `specPath` = the `--spec` file name (overridden by
  `withSpecDir` on the mirror; kept only for diagnostics), `invariant` =
  `--inv` or `""`, `lengthBound` = `--bound` (default 10),
  `initPredicate`/`nextPredicate`/`constInit` from flags,
  `paramVarNames = ""`.
- Transport: plain TCP by default (`connectTcp`); `--tls` →
  `mkClientParams host cert key ca` + `connectTls`; `--pin` additionally
  → `connectTlsPinned` (the fingerprint a Consul-discovery client would
  fetch from the registry). `--pin` without `--tls` is a parse error.
- No stdio mode: the mirror's stdio transport is for embedding the
  *mirror* role; the client always speaks to a server.
- The mirror caps the accepted bound: outside `[1, maxValidateBound]`
  (100) the reply is `register_error` and the CLI exits 2.

### Exit codes and output

| Exit | Meaning | Output |
|---|---|---|
| 0 | `SpecValid` | `VALID` on stdout |
| 1 | `SpecInvalid output` | `INVALID` + apalache output on stdout |
| 2 | infra tier (`Left`: transport/RegisterError/ProtocolError) | error text on stderr |

So `ModelMirrors validate ... && echo ok` means "the model is valid",
and CI can distinguish a broken model (1) from a broken mirror (2).

### Implementation sketch

(As built — the parser lives in its own module, `Protocol.ValidateOpts`,
with `vo*` record fields; the sketch uses the real names.)

```haskell
-- app/Main.hs
case args of
  ...
  "validate" : rest -> validateCli rest
  ...

validateCli :: [String] -> IO ()
validateCli argv = do
  opts <- either die pure (parseValidateOpts argv)   -- hand-rolled, no new deps
  contents <- mapM TIO.readFile (voSpec opts : voDeps opts)
  let spec = ApalacheSpec contents
      cfg  = ApalacheConfig
        { specPath      = takeFileName (voSpec opts)
        , initPredicate = T.pack <$> voInit opts
        , nextPredicate = T.pack <$> voNext opts
        , constInit     = T.pack <$> voCinit opts
        , invariant     = maybe T.empty T.pack (voInv opts)
        , lengthBound   = voBound opts          -- parser-side default 10
        , paramVarNames = T.empty
        }
  res <- try (bracket (validateTransport opts) closeTransport $ \st -> case st of
        SomeTransport t _ -> runClientValidate t cfg (voBound opts) (Just spec))
    :: IO (Either SomeException (Either Text ValidateResult))
  -- any transport exception also maps to exit 2
  case res of
    Left ex                       -> hPutStrLn stderr (displayException ex) >> exitWith (ExitFailure 2)
    Right (Left err)              -> TIO.hPutStrLn stderr err >> exitWith (ExitFailure 2)
    Right (Right SpecValid)       -> putStrLn "VALID"   >> exitSuccess
    Right (Right (SpecInvalid o)) -> putStrLn "INVALID" >> TIO.putStr o >> exitWith (ExitFailure 1)

validateTransport :: ValidateOpts -> IO SomeTransport  -- TCP via connectTcp, or TLS when --tls
```

`parseValidateOpts` is pure and hand-rolled (the codebase has no
optparse-applicative dependency; keep it that way). `--pin` without
`--tls` is a parse error. TLS transport values need a uniform close —
wrapped as `SomeTransport` with an existential over `Transport`.

One redundancy to know about: the bound travels twice — as
`RegisterValidate`'s `Int` field and inside `cfg.lengthBound`. The
**message field is authoritative**: `MkRunValidate` passes it to
`validateSpecIn` and never reads `lengthBound` on this path. The field
is kept for constructor uniformity with the other `Register*` messages
(and because `ApalacheConfig.lengthBound` predates the message).

### Tests

- `parseValidateOpts`: unit tests (flag combos, missing required flags,
  `--dep` accumulation).
- Integration (`MainSpec`-style): forkIO `serveTcpConcurrent` on an
  ephemeral port, run `validateCli` against `test/specs/HourClock.tla` →
  exit 0 / `VALID`; against a spec with a violated `--inv` → exit 1 /
  `INVALID`; against a closed port → exit 2. TLS variant reusing
  `genCerts` from the TLS tests.
- The mirror-side step log for the TCP session must be
  `[MirrorRecvRegisterValidate _, MirrorSendSpecValidatedValid]` — the
  same assertion as the mock-transport test in §6.

### README

One usage block under a new "Remote validation" heading; mention
`scripts/gen-certs.sh` for the `--tls` flags.

## Out of scope

- Reusing the apalache explorer server for validation.
- TLS-level authorization of who may validate (all mTLS clients may).
  Cost is already bounded server-side by `maxValidateBound` (§4); revisit
  only if validation at that cap still proves expensive enough to meter.

## Validation checklist

1. `cabal build all && cabal test test:ModelMirrors-test --test-options='-p "/alidate/"'`
   (case-insensitive-ish trick: matches both the `validate-only path ...`
   tests and the `parseValidateOpts` cases, which a lowercase
   `/validate/` pattern misses).
2. Full `cabal test all` (integration; needs `apalache-mc` on `PATH`).
3. MBT conformance, including validate traces:
   `cabal test test:ModelMirrors-test --test-options='-p "/mbt/"'`.
4. Re-run `apalache-mc check --inv=Inv --length=20 specs/MirrorProtocol.tla`
   only if the spec side changes (it shouldn't — spec landed first).
