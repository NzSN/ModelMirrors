# Transport Design

## Summary

Define the Transport abstraction and a stdin/stdout implementation for the ModelMirrors
IPC layer. The transport is extensible — new transports (sockets, pipes, etc.) can be
added by implementing the `Transport` typeclass.

## Modules

### `Protocol.Transport.Core` (`src/Protocol/Transport/Core.hs`)

The typeclass and JSON codec combinators. Transport operates at the raw `ByteString` level.

```haskell
class Transport t where
  send :: t -> ByteString -> IO ()
  recv :: t -> IO ByteString
```

Free-standing combinators for JSON-encoded protocol messages:

```haskell
sendMsg :: (Transport t, ToJSON a) => t -> a -> IO ()
sendMsg t = send t . encode . toJSON

recvMsg :: (Transport t, FromJSON a) => t -> IO (Either String a)
recvMsg t = eitherDecode <$> recv t
```

IO exceptions (broken pipe, EOF, etc.) propagate via `IO`. No custom error type.

### `Protocol.Transport.Stdio` (`src/Protocol/Transport/Stdio.hs`)

Line-based stdin/stdout transport (NDJSON):

```haskell
data StdioTransport = StdioTransport

instance Transport StdioTransport where
  send _ bs = BS.putStr bs >> BS.putStr "\n" >> hFlush stdout
  recv _    = BS.getLine
```

Each message is encoded as a single line of JSON. Flush ensures the client sees
output immediately.

## .cabal Changes

Add `Protocol.Transport.Core` and `Protocol.Transport.Stdio` to `exposed-modules`.
No new dependency — `bytestring` and `aeson` are already in `build-depends`.

## Future Transports

| Transport | When needed |
|-----------|-------------|
| Socket (TCP/Unix) | Remote clients, Docker |
| Pipe (named) | Same-machine, language runtime can't do subprocess |
| In-memory (IORef/MVar) | Testing, embedded use |

Each is a new `data` type + `Transport` instance. No changes to existing modules.
