# Server Mode with Discovery — Design

> **Superseded** by `server-mode-registry-design.md` (service registry). Retained for the record of the UDP broadcast approach and its limitations.

This document describes the design for a third operating mode, **server mode**, which adds a network discovery mechanism on top of the existing TCP daemon.

## Motivation

Today a client finds a mirror only out-of-band: it either spawns the mirror as a stdio subprocess or connects to a hardcoded `host:port`. There is no way for a client to locate mirrors running elsewhere on a LAN. Server mode closes that gap without changing the session protocol.

## Modes Overview

| Mode | Invocation | Transport | Discovery |
|------|-----------|-----------|-----------|
| Stdio (default) | `ModelMirrors` | stdin/stdout | n/a (subprocess) |
| TCP daemon | `ModelMirrors --serve <port>` | TCP | none |
| Server | `ModelMirrors --server <port>` | TCP | UDP broadcast responder |

## Design Choices

- **Pull-based UDP broadcast**: clients send a probe to the broadcast address; servers answer. This avoids constant beacon traffic and stale announcements.
- **Raw UDP, not mDNS**: mDNS requires an additional library and platform mDNS stacks. Raw UDP broadcast works with the `network` package already in use (`Protocol.Transport.Tcp`), so no new dependencies are introduced.
- **Discovery is transport-adjacent, not protocol-level**: the session protocol is unchanged. After connecting, the first message is still one of the `Register*` messages; no handshake, version negotiation, or greeting is added to the TCP session.

## Wire Protocol (Discovery)

Discovery uses a fixed UDP port `45700` and JSON messages in the same style as the session protocol.

Client → broadcast:

```json
{ "proto_step": "discover", "version": 1 }
```

Server → client (unicast reply to the probe's source address):

```json
{
  "proto_step": "announce",
  "version": 1,
  "host": "10.0.0.5",
  "port": 8765,
  "pid": 1234
}
```

- `version` leaves room for future negotiation; clients must ignore messages with an unknown `version`.
- Clients must ignore malformed replies and continue collecting until their timeout expires.
- Multiple servers may run on one host (each with a distinct TCP port); all reply to the same probe, so the client collects a list.

## Server Side

### Startup (`app/Main.hs`)

```haskell
["--server", portStr] -> serveWithDiscovery (fromIntegral (read portStr :: Int))
```

### `Protocol.Transport.Tcp`

```haskell
serveWithDiscovery :: PortNumber -> IO ()
serveWithDiscovery port = do
  _ <- forkIO (runDiscoveryResponder port)
  serveTcp port
```

The discovery responder runs concurrently with the existing sequential accept loop. Both threads follow the established resilience pattern (`try` around each iteration, log and continue on failure): a discovery error must never take down serving, and vice versa.

### Discovery responder (`Protocol.Transport.Discover`, new module, ~60 lines)

```haskell
discoveryPort :: PortNumber
discoveryPort = 45700

data ServerInfo = ServerInfo
  { siHost :: String
  , siPort :: Int
  , siPid  :: Int
  }

runDiscoveryResponder :: PortNumber -> IO ()
```

Socket details:

- Bind UDP `0.0.0.0:45700` with `SO_REUSEADDR` so multiple servers on one host can all listen for probes.
- Loop: `recvFrom` → if the payload parses as a `discover` probe with a known `version`, send an `announce` reply to the source address.
- `host` in the reply is the server's best guess at its primary IPv4 address (e.g. via a connected UDP socket to a public address, falling back to the probe's destination address); clients may also fall back to the reply's source IP if `host` is empty.

## Client Side

### Discovery API (`Protocol.Transport.Discover`, re-exported from `Protocol.Client`)

```haskell
discoverServers :: Int {- ^ timeout in milliseconds -} -> IO [ServerInfo]
```

Socket details:

- Create a UDP socket, enable `SO_BROADCAST`.
- Send the probe to `255.255.255.255:45700`.
- Collect `announce` replies with `recvFrom` in a loop wrapped in `timeout`, deduplicating by `(host, port)`.

Typical client flow:

```haskell
servers <- discoverServers 500
case servers of
  (ServerInfo host port _ : _) -> runClient (TcpTransport host port) ...
  []                           -> -- fall back to stdio or error
```

## Compatibility

- Stdio and `--serve` modes are unchanged.
- The session protocol (`docs/protocol-spec.md`) is unchanged: no handshake, version exchange, or greeting on the TCP connection; the first client message remains a `Register*` message.
- Discovery messages live only on UDP port `45700` and never appear on the session transport.

## Limitations and Future Work

- **Broadcast scope**: UDP broadcast does not cross subnets. Future work: optional multicast group (`--server <port> --mcast`, group `239.255.77.1`) for routed discovery.
- **No security**: probes and replies are unauthenticated plaintext. This matches the trust level of the existing plain-TCP daemon (no TLS, no auth) and is intended for trusted LANs.
- **No health/liveness**: discovery proves the responder was alive at probe time; a stale announce is possible if the TCP accept loop died but the responder thread survived (and vice versa). Future work: include a session count or heartbeat timestamp in `announce`.
