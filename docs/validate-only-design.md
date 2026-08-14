# Design: Validate-Only Path

## Goal

Let a client ask the mirror to validate a spec (typecheck + bounded model
check) and stop — no trace generation, no stepping. This makes the existing
`SpecValidated (SpecInvalid ...)` message and the dead
`MirrorSendSpecValidatedInvalid` step actually reachable, and matches the
`Idle → Validating → Done` transition already drawn in
`docs/protocol-spec.md`.

## Key insight

No new *reply* message is needed: `SpecValidated !ValidateResult` already
exists and already carries both outcomes. Only a new *request* is required.

## 1. Protocol (`src/Protocol/Core.hs`)

One new `ClientMessage` constructor:

```haskell
| RegisterValidate !ApalacheConfig !Int !(Maybe ApalacheSpec)
--                                    ^ bound for the model check (validateSpec already takes it)
```

State machine: `Idle ──(RegisterValidate)──→ Validating ──(SpecValidated)──→ Done`
— session ends after the reply, on both valid and invalid outcomes.

Error semantics (three distinct failure tiers, reusing existing messages):

| Failure | Reply | Meaning |
|---|---|---|
| Inline spec materialization fails | `RegisterError` | client sent bad `ApalacheSpec` |
| apalache-mc itself fails to run (`Left ApalacheError`) | `RegisterError` | infrastructure error |
| typecheck or check fails | `SpecValidated (SpecInvalid output)` | the model is invalid — the actual point of this path |
| both pass | `SpecValidated SpecValid` | done |

## 2. Wire format (`src/Protocol/Format/Json.hs`)

Follows the existing `proto_step` tag convention exactly:

```json
{ "proto_step": "register_validate",
  "apalacheConfig": { ... },
  "bound": 5,
  "spec": { ... } }
```

(`spec` is optional, same as `register`.)

Reply reuses the existing `spec_validated` encoding — no changes on that side.

## 3. Mirror (`src/Protocol/Mirror.hs`)

- New step constructors: `MirrorRecvValidate !ApalacheConfig !Int !(Maybe ApalacheSpec)`
  for the receive side; reuse `MirrorSendSpecValidatedValid` /
  `MirrorSendSpecValidatedInvalid` for the send side (the latter becomes
  reachable for the first time).
- New `MkRunValidate` wrapper + `Step` instance, structurally identical to
  `MkRunMirror` but stopping after validation:

```haskell
instance Transport t => Step (MkRunValidate t) where
  exec (MkRunValidate transport cfg bound mSpec) =
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
                    SpecValid      -> MirrorSendSpecValidatedValid
                    SpecInvalid e  -> MirrorSendSpecValidatedInvalid e]
```

- One clause added to the `RecvMsg` dispatch, alongside the other `Register*`
  cases.
- Exported convenience wrapper `runMirrorValidate`, mirroring
  `runMirror`/`runMirrorWithSpec`.
- No changes to transports, `app/Main.hs`, or server modes — `run` dispatches
  on the first message, so stdio/TCP/mTLS all get it for free.

## 4. Apalache layer (`src/Apalache/Command.hs`)

`validateSpec` currently has no `--run-dir` support, so concurrent mTLS
sessions would race on the default `./_apalache-out` (the exact problem
`generateTracesIn` solved). Add a run-dir-taking variant, keeping the old one
as a shim — same pattern as `generateTraces`/`generateTracesIn`:

```haskell
validateSpecIn :: Maybe FilePath -> ApalacheConfig -> Int -> IO (Either ApalacheError ValidateResult)
validateSpec   = validateSpecIn Nothing
```

`checkArgs` gains the `maybe [] (\d -> ["--run-dir=" ++ d]) runDir` clause;
`tcArgs` stays as-is (typecheck writes no run output — verify against
apalache behavior, add `--run-dir` there too if it does).

## 5. Client (`src/Protocol/Client.hs`)

```haskell
runClientValidate :: Transport t => t -> ApalacheConfig -> Int -> Maybe ApalacheSpec -> IO (Either Text ())
```

Sends `RegisterValidate`, expects exactly one reply:
`SpecValidated SpecValid → Right ()`,
`SpecValidated (SpecInvalid e) / RegisterError e / ProtocolError e → Left e`.
Doesn't take a `Client` record — no step handler is ever invoked.

## 6. Tests

- `test/MirrorProtocolSpec.hs`: happy path over mock transport with
  `test/specs/HourClock.tla` (integration, like existing specs) → expects
  `[MirrorRecvValidate…, MirrorSendSpecValidatedValid]`; plus a spec with a
  violated invariant at small bound → `MirrorSendSpecValidatedInvalid`; plus
  an inline-`ApalacheSpec` variant to cover `withSpecDir`.
- JSON roundtrip for `register_validate` in the client/format specs.
- `normalizeMirrorSteps` needs no change (new constructor has no collapse
  rules).

## 7. Docs & formal spec (follow-ups)

- `docs/protocol-spec.md`: add the `register_validate` flow; the `Validating`
  state description becomes literally true.
- `specs/MirrorProtocol.tla`: optionally add a `RegisterValidate` action so
  the checked model stays in sync with the implementation (this is the MBT
  spec the traces in `specs/traces/` come from — flag it in
  `docs/mbt-remaining-work.md` if deferred).
- AGENTS.md module descriptions unchanged (no new modules).

## Out of scope

- Reusing the apalache *explorer server* for validation (heavier, no benefit
  for a one-shot check).
- A `--validate-only` CLI flag for `app/Main.hs` (can be added later on top
  of `runClientValidate`).
