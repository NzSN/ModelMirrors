# Server Mode — Design and Implementation Plan

This document consolidates the former separate server-mode design docs:

- `server-mode-discovery-design.md` — UDP broadcast discovery (**superseded**, retained below as legacy record)
- `server-mode-auth-design.md` — PSK + HMAC authentication (**retained alternative** for trusted-LAN use)
- `server-mode-mtls-design.md` — TLS 1.3 mutual authentication (**current** secure transport)
- `server-mode-registry-design.md` — Consul service-registry discovery (**current** discovery mechanism)
- `server-mode-mtls-plan.md` — phased implementation plan

The current server mode is **mTLS transport + optional Consul service registry**. The UDP-broadcast and PSK/HMAC designs are retained in this document for the record and as lightweight alternatives; where they conflict, the mTLS and registry sections take precedence.

## Contents

1. [Overview](#1-overview)
2. [Secure transport: mTLS](#2-secure-transport-mtls)
3. [Discovery: service registry](#3-discovery-service-registry)
4. [Implementation plan](#4-implementation-plan)
5. [Legacy: UDP broadcast discovery](#5-legacy-udp-broadcast-discovery-superseded)
6. [Alternative: PSK + HMAC authenticated mode](#6-alternative-psk--hmac-authenticated-mode)

---

## 1. Overview

Server mode originated because a client could only find a mirror out-of-band: it either spawned the mirror as a stdio subprocess or connected to a hardcoded `host:port`, with no way to locate mirrors running elsewhere on a LAN. Server mode closes that gap without changing the session protocol.

| Mode | Invocation | Transport | Authentication | Discovery |
|------|-----------|-----------|----------------|-----------|
| Stdio (default) | `ModelMirrors` | stdin/stdout | n/a (subprocess inherits parent's trust) | n/a |
| TCP daemon (legacy) | `ModelMirrors --serve <port>` | plain TCP | none | none |
| Server (mTLS) | `ModelMirrors --server <port> --tls ...` | TLS 1.3 over TCP | mutual, certificate-based | optional Consul registry (`--registry <url>`) |

The session protocol (`docs/protocol-spec.md`) is unchanged in every mode: after transport setup, the first client message is still one of the `Register*` messages; no handshake, version negotiation, or greeting is added at the protocol level.

---

## 2. Secure transport: mTLS

This is the current secure-transport design. It supersedes the PSK + HMAC scheme (Section 6) for deployments requiring high security, replacing it with **TLS 1.3 mutual authentication (mTLS)**, which provides mutual authentication, confidentiality, integrity, and forward secrecy in a single vetted protocol. The PSK design remains valid for trusted-LAN use; mTLS covers untrusted-network and multi-user deployments.

### Threat model

An attacker on the network may:

- Spoof discovery replies to redirect clients to a malicious mirror.
- Intercept, replay, or modify session traffic (active man-in-the-middle).
- Connect to the daemon and drive a session with attacker-chosen spec paths.
- Attempt to extract credentials from a compromised client or server host.

Additional requirements beyond the PSK design:

- **Confidentiality**: session traffic (specs, traces, reported states) must not be readable on the wire.
- **Forward secrecy**: compromise of a long-term key must not decrypt previously recorded sessions.
- **Per-client identity**: the server must distinguish clients for future authorization and audit.

Out of scope (residual risks, handled orthogonally): full denial-of-service hardening beyond the bounded dispatcher, and filesystem confinement of `specPath`/trace destinations (a `--root <dir>` allowlist).

### Design choices

- **TLS 1.3 mutual authentication** via the Haskell `tls`, `x509`, and `x509-store` packages — pure Haskell, compatible with plain cabal.
- **Private CA**: one offline CA signs the server certificate and per-client certificates. No public CA involved.
- **No custom protocol design**: authentication happens entirely inside the TLS handshake. The session protocol after the handshake is byte-for-byte identical to today's; the change is confined to transport setup.
- **Opt-in**: stdio and `--serve` remain unchanged. mTLS is gated behind `ModelMirrors --server <port> --tls`.

### TLS parameters

- **Version**: TLS 1.3 only (no fallback to 1.2; simplifies cipher configuration and guarantees forward secrecy).
- **Server auth**: server presents its certificate chain; clients pin the CA certificate and validate the chain + hostname (SAN).
- **Client auth**: server requires a client certificate (`requireClientCert`); the chain is validated against the same CA. The client certificate's CN/SAN is the authenticated principal, logged per session and reserved for future authorization.
- **Key exchange**: TLS 1.3 ephemeral (EC)DHE — forward secrecy by construction.

### PKI and key management

- **CA**: generated once, offline, private key stored encrypted and never on server or client hosts. A small script (`scripts/gen-certs.sh` or similar) wraps the `openssl` invocations.
- **Server certificate**: SAN set to the server's hostname/IP; clients validate it.
- **Client certificates**: one per client principal, CN identifying the client (e.g. `ci-runner-3`, `dev-alice`).
- **Lifetime**: short-lived certs (days to weeks) give revocation-by-expiration; CRL/OCSP is deliberately omitted. Renewal is re-running the script.
- **File permissions**: private key files must be `0600`; checked at startup, server refuses to start otherwise.
- **Clock dependency**: certificate validity checks require roughly correct clocks on both hosts (±cert validity window); document this failure mode.

### CLI flags

```
ModelMirrors --server <port> --tls \
    --cert <server.crt> --key <server.key> --ca <ca.crt> \
    [--registry <url>] [--jobs <n>] [--bind <addr>]
```

Startup validation: all files readable, key file mode `0600`, chain validates against the CA, SAN non-empty. Any failure → exit with a clear error before binding sockets.

### Discovery relationship

Discovery is delegated to the service registry described in Section 3; the registry answers *where* mirrors are and mTLS answers *whether to trust them*.

- Registry candidates are connected with mTLS, so a spoofed or compromised registry can at worst cause a client to attempt a TLS connection to a host that fails certificate validation — a failed connection, not a compromise.
- **Fingerprint pinning (defense-in-depth)**: when a registry entry carries `cert-sha256`, clients compare it against the peer certificate fingerprint after the handshake and fail closed on mismatch.
- The legacy UDP broadcast design (Section 5) is retained only for the record. If it were ever used alongside mTLS, TLS authentication would make discovery opportunistic rather than load-bearing, and the per-IP rate limiting described in Section 5 would still apply.

### Session protocol

Unchanged. After the TLS handshake completes:

1. The client sends a `Register*` message as its first message, exactly as today.
2. The mirror accepts each connection and upgrades the accepted socket to a TLS context before entering `run`.
3. Failed handshakes are logged (source IP, TLS alert) and the connection is closed; per-IP backoff mitigates handshake-flooding.

No auth messages are added to `Protocol.Core` — the `AuthHello`/`AuthReply`/`AuthFinish` variants from the PSK design are unnecessary here.

### Changes to existing modules

| Module | Change |
|--------|--------|
| `app/Main.hs` | `--serve`/`--server` parsing via `Protocol.ServerOpts`; `--server --tls` startup validation; registry registration, heartbeat, and best-effort shutdown deregistration; `validate --registry` discovery mode |
| `Protocol.Transport.Tls` (new) | `serveTls`/`serveTlsOn`/`serveTlsConcurrentOn`: wraps each accepted socket in a TLS server context (`tls` package); exposes a `TlsTransport` implementing the existing two-method `Transport` class over the TLS channel |
| `Protocol.Transport.Tcp` | `serveTcpOn`: host-aware bind in addition to `serveTcp`; both share the existing listener-address selection |
| `Protocol.ServerOpts` (new) | Pure, order-independent parser for `--serve` and `--server` (port, TLS files, registry, jobs, bind) |
| `Protocol.Discover` (new) | Transport-agnostic candidate iteration (`tryCandidates`) and fingerprint selection (`candidateFingerprint`) for registry discovery |
| `Protocol.ValidateOpts` | `--registry` mode for `validate`: mTLS-only discovery, mutually exclusive with `--host`/`--port` |
| `Protocol.Client`, `Protocol.Mirror`, `Protocol.Core`, `Protocol.Format.Json` | **Unchanged** |
| `scripts/gen-certs.sh` (new) | CA + server + client cert generation helper |
| `.cabal` | Add `tls`, `crypton`, `crypton-x509`, `crypton-x509-store`, `crypton-x509-validation` dependencies |

### Compatibility

- Stdio and `--serve` are byte-for-byte unchanged.
- mTLS clients cannot talk to `--serve` daemons and vice versa; the failure is a clean TLS/handshake error, never a protocol confusion.
- A mirror binary built without the TLS dependencies retains all current behavior.

### Pros / cons summary

**Pros**: mutual auth + encryption + forward secrecy in one vetted protocol; no custom crypto to audit; per-client identity enables future authorization; cert expiry gives revocation; clients in any language have mature TLS library support.

**Cons**: dependency jump (`tls`/`x509`/`asn1-*`) for a currently lean package; PKI operations (issuance, renewal, expiry outages) are the main ongoing cost; clock skew becomes a failure mode; dev ergonomics need the cert-free stdio mode preserved (it is).

### Residual risks

- **DoS**: mitigated by the bounded dispatcher (`serveTlsConcurrent`): the TLS handshake runs in the worker thread, so a slow or stalled handshake never blocks the accept loop, and concurrent sessions are capped by `--jobs <n>` (default 4). Excess connections wait in the accept backlog. Per-IP rate limits remain future work.
- **Session isolation**: concurrent sessions each get a per-session apalache `--run-dir` temp dir (removed on session exit) and an explorer server on an ephemeral port; sessions share no filesystem or port state.
- **Filesystem access**: mTLS proves identity but does not constrain requests. Add `--root <dir>` to confine `specPath` and trace destinations (separate change).
- **Cert expiry outages**: mitigated by renewal automation and startup warnings when certs are near expiry (implemented: stderr warning at < 7 days remaining).

---

## 3. Discovery: service registry

This design supersedes UDP broadcast discovery (Section 5). Discovery is delegated to an external **service registry** over its HTTP API.

### Why a registry instead of UDP broadcast

- **Source of truth**: registrations are explicit, TTL-bound entries in a registry, not best-effort broadcast replies. Stale entries expire via TTL/health checks.
- **Cross-subnet by construction**: no reliance on broadcast/multicast reachability.
- **Health awareness**: only healthy servers are returned to clients.
- **Separation of concerns**: the registry answers *where* mirrors are; mTLS (Section 2) answers *whether to trust them*. A compromised registry can at worst point clients at hosts that fail TLS authentication — a failed connection, not impersonation.

### Registry choice: Consul HTTP API

- The API is plain HTTP/JSON, so the client uses the **existing `http-client` dependency** — no new libraries.
- Alternatives considered: etcd (gRPC-first; HTTP gateway is second-class), Kubernetes Endpoints API (right answer only if deployed in k8s; possible future backend), self-hosted registry mode (reinvents Consul; rejected).
- The implementation targets the small stable subset of the Consul agent API; any Consul-compatible endpoint works.

### Server side: registration

On `ModelMirrors --server <port> --tls ... --registry <url>`:

1. **Register**: `PUT /v1/agent/service/register`

   ```json
   {
     "ID": "modelmirrors-<host>-<port>",
     "Name": "modelmirrors",
     "Address": "<advertised host>",
     "Port": <port>,
     "Meta": { "cert-sha256": "<SHA-256 fingerprint of server cert>" },
     "Check": { "TTL": "30s" }
   }
   ```

2. **Heartbeat**: a forked thread sends `PUT /v1/agent/check/pass/service:<id>` every 10 s. If the heartbeat fails repeatedly, the TTL check lapses and the registry marks the service critical — clients stop seeing it. Thread failures are caught and retried, never killing the accept loop (same resilience pattern as `serveTls`).
3. **Deregister** (best-effort, on shutdown): `PUT /v1/agent/service/deregister/<id>`.

The registry URL comes from `--registry <url>` or `MODELMIRRORS_REGISTRY`; without it, `--server` runs with no registration (direct-connect only), matching today's behavior. A server whose certificate fingerprint cannot be computed refuses to start rather than publishing a pin-less registry entry.

### Client side: discovery

```haskell
discoverServices :: RegistryUrl -> IO [ServiceInfo]
```

`GET /v1/health/service/modelmirrors?passing=true`, parsing each entry's `Service.Address`, `Service.Port`, and `Service.Meta.cert-sha256`.

Client flow:

1. `discoverServices` → candidates.
2. `connectTls` to a candidate (mTLS authenticates the server regardless of registry honesty).
3. **Fingerprint pinning (defense-in-depth)**: if the entry carries `cert-sha256`, compare it against the peer certificate fingerprint after the handshake; mismatch → close and try the next candidate.

### Validate CLI discovery

The `validate` CLI can use the registry instead of a hardcoded `--host`/`--port`:

```sh
ModelMirrors validate --registry <url> --spec Spec.tla \
    --tls --cert C --key K --ca CA [--pin SHA256]
```

- `--registry` is mutually exclusive with `--host`/`--port` and discovery is mTLS-only: `--tls --cert --key --ca` are required.
- `discoverServices` returns healthy candidates; `Protocol.Discover.tryCandidates` tries them in order and keeps the first transport that connects.
- The registry-advertised `cert-sha256` is pinned with `connectTlsPinned`; an explicit `--pin` overrides the registry metadata. Entries without a fingerprint use plain `connectTls`.
- If the registry returns no candidates, or every candidate fails, the CLI prints the collected diagnostics and exits 2.

### Security model

- **Registry compromise**: an attacker who can write the registry can make clients connect to attacker hosts, but those hosts cannot complete mTLS without a CA-signed certificate, and cannot match the pinned fingerprint. Worst case: denial of service (clients find no usable server).
- **Registry availability**: discovery fails closed — clients can still connect to a known `host:port` directly.
- **Registry access control**: out of scope for the mirror itself; operators should enable Consul ACLs and TLS on the registry in untrusted environments. Documented as an operational requirement, matching the trust level of the mTLS CA.

### Failure modes

| Failure | Behavior |
|---|---|
| Registry unreachable at server startup | Log warning, serve without registration |
| Heartbeat thread dies / registry down mid-run | TTL lapses; clients stop discovering the server; direct connections still work |
| Registry returns malformed JSON | `discoverServices` returns `[]` (fail closed) |
| Fingerprint mismatch | Client closes connection, tries next candidate |

### Alternatives rejected

- **UDP broadcast** (previous design): no source of truth, LAN-scope only, spoofable without an added signature layer.
- **mDNS/DNS-SD**: platform mDNS stack dependency, same LAN-scope limitation.
- **Built-in registry mode** (`ModelMirrors --registry`): centralizes discovery into the tool and reinvents TTL/health/storage; revisit only if Consul proves too heavy for typical deployments.

---

## 4. Implementation plan

Implementation plan for the mTLS + registry design (Sections 2 and 3). Phased so each phase lands a buildable, testable increment; earlier phases ship value even if later ones are deferred.

### Phase 0 — Dependency and build groundwork

**Goal**: `tls`, `x509`, `x509-store` build under cabal before any code depends on them.

Tasks:

1. Add to `ModelMirrors.cabal` library `build-depends`: `tls >= 2.0`, `x509 >= 1.7`, `x509-store >= 1.6`.
2. Verify: `cabal build all`.

Gate: build green. **Risk**: the cabal resolver may lag `tls` releases — fall back to `allow-newer` or a compatible version pin in `cabal.project` if needed.

### Phase 1 — `TlsTransport` and server-side TLS accept loop

**Goal**: the mirror can serve one authenticated TLS client per connection; no CLI wiring yet.

Tasks:

1. New module `src-tls/Protocol/Transport/Tls.hs`:
   - `TlsTransport` wrapping a `tls` `Context`, implementing the existing two-method `Transport` class (`send` = one JSON line via `sendData`, `recv` = accumulate `recvData` until newline — the `tls` package is stream-oriented, so newline framing must be re-implemented on top; reuse the same framing convention as the stdio transport).
   - `mkServerParams :: FilePath -> FilePath -> FilePath -> IO ServerParams` — load cert/key/CA via `x509-store`, configure `tls` for TLS 1.3 only, `requireClientCert`.
2. `serveTls :: ServerParams -> PortNumber -> IO ()` in the same module, mirroring the structure of `serveTcp`: `AI_PASSIVE` bind, sequential accept, per-connection `try`, log-and-survive client drops. Each accepted socket is upgraded via `contextNew` + `handshake` before `run`.
3. Export `Protocol.Transport.Tls` from the library (`exposed-modules`).
4. Unit test with `Mock`-style harness where possible; real TLS handshake test deferred to Phase 3.

Gate: existing `cabal build all` / `cabal test all` still green (no behavior change).

### Phase 2 — CLI wiring and startup validation

**Goal**: `ModelMirrors --server <port> --tls --cert c --key k --ca ca [--bind addr]` starts the mTLS server.

Tasks:

1. `src/Protocol/ServerOpts.hs` + `app/Main.hs`: replace fixed-pattern `--server` matching with a pure, order-independent parser (`parseServerOpts`/`parseServeCli`, consistent with `Protocol.ValidateOpts` — no optparse-applicative dependency).
2. Startup validation (fail fast, clear errors, before binding):
   - all files readable; key file mode `0600`;
   - certificate chain validates against the CA; SAN non-empty;
   - cert expiry < 7 days → log a warning (per design residual-risk mitigation).
3. `--bind <addr>`: add `serveTlsOn`/`serveTlsConcurrentOn` (and `serveTcpOn`) so listeners can bind a specific address instead of `AI_PASSIVE`-only.
4. Smoke test that the binary rejects bad flag combinations and missing files with exit-code failures.

Gate: manual smoke — generate throwaway certs with openssl, start `--server --tls`, connect with `openssl s_client -connect ... -cert client.crt -key client.key`, observe the mirror waiting for `Register`.

### Phase 3 — Client-side TLS support

**Goal**: library clients can connect over mTLS.

Tasks:

1. `Protocol.Transport.Tls`: client-side `connectTls :: ClientParams -> HostName -> PortNumber -> IO TlsTransport` — load CA + client cert/key, validate server chain and hostname.
2. `Protocol.Client`: thread TLS parameters into the client entry points (`runClient`, `runClientExplore`, etc.) — either a `TlsConfig` argument variant or a `Transport`-agnostic refactor so callers pass any ready `Transport` (prefer the latter: keeps `Client.hs` free of transport specifics).
3. JSON framing on the client side reuses the Phase 1 `TlsTransport`.

Gate: round-trip test — `serveTls` on a forked thread + `runClient` over `connectTls`, running the existing `HourClock` register flow end-to-end.

### Phase 4 — Discovery integration (service registry)

**Goal**: `--server` mode registers itself in a service registry; clients locate and verify it.

Per Section 3: Consul HTTP API via the existing `http-client` dependency. The registry does location only; mTLS does authentication, with the registry's `cert-sha256` meta used for fingerprint pinning.

Tasks:

1. New module `src/Protocol/Registry.hs`:
   - `registerService :: RegistryUrl -> ServiceInfo -> IO Bool` (`PUT /v1/agent/service/register` with TTL check; returns `False` on failure instead of throwing)
   - `heartbeatLoop :: RegistryUrl -> ServiceId -> IO ()` (forked; `PUT /v1/agent/check/pass/service:<id>` every 10 s, `try`-guarded, never kills the accept loop)
   - `deregisterService :: RegistryUrl -> ServiceId -> IO ()` (best-effort)
   - `discoverServices :: RegistryUrl -> IO [ServiceInfo]` (`GET /v1/health/service/modelmirrors?passing=true`; malformed JSON → `[]`, fail closed)
2. `app/Main.hs`: `--registry <url>` flag (or `MODELMIRRORS_REGISTRY` env var) on `--server`; require a computable cert fingerprint, register + fork heartbeat on startup, deregister best-effort on shutdown. Without a registry, serve unregistered as today.
3. New module `src/Protocol/Discover.hs`: `tryCandidates` (try discovered candidates in order, concatenating diagnostics on total failure) and `candidateFingerprint` (explicit `--pin` wins over registry metadata).
4. `validate --registry <url>`: mTLS-only discovery through `Protocol.ValidateOpts` registry mode; try each candidate with `connectTlsPinned`/`connectTls`, exiting 2 if none is reachable.
5. Tests: JSON encode/decode round-trips; `discoverServices` against a minimal stub HTTP server (raw socket returning a canned Consul response); malformed-response handling; parser tests for registry/direct-mode exclusivity.

Gate: full flow demo — start server with `--registry` against a local Consul dev agent, client discovers by name, verifies fingerprint, completes mTLS handshake, runs a `Register` session.

### Phase 5 — Cert tooling and docs

**Goal**: the PKI is usable without reading the design docs.

Tasks:

1. `scripts/gen-certs.sh`: generate CA, server cert (SAN from argument), client cert (CN from argument); set `0600` on keys; print renewal instructions. Plain `openssl`, no new tooling dependency.
2. README section: quick-start for `--server --tls` (generate certs → start server → connect client), cert renewal procedure, expiry warning behavior.
3. Update `docs/protocol-spec.md` transport section: note TLS as a session transport with identical message format.

Gate: a fresh clone can follow the README to a working mTLS session.

### Test strategy

- **Unit**: startup validation logic (Phase 2) as pure-ish functions over file paths.
- **Integration** (tasty, alongside existing specs):
  - TLS round-trip over loopback with test certs generated into a temp dir (Phase 3) — follow the `TcpTransportSpec` structure.
  - Mutual-auth negative tests: no client cert → handshake rejected; wrong CA → rejected.
  - Registry discovery round-trip against a stub HTTP server and malformed-response handling (Phase 4).
- Test certs: generated per-run into a temp dir by the test setup (never committed) or committed with a clearly-test-only CA; prefer per-run generation to avoid expired-cert flakes — pin validity to a wide window.
- **No `apalache-mc` dependency** for the new transport tests; keep them fast like the TCP transport spec, unlike the Apalache integration specs.
- Full suite green under `cabal test all` before each phase merges.

### Deferred (explicitly out of scope)

- `--root <dir>` path confinement for `specPath`/trace destinations — separate security change.
- Per-IP connection rate limiting and handshake timeouts on the TCP accept loop — DoS hardening, follow-up.
- Per-client authorization based on cert CN — identity is logged this iteration; policy comes later.
- PSK mode (Section 6) — not implemented if mTLS lands first; the design stays in this document as the lightweight alternative.

### Milestone summary

| Phase | Deliverable | Depends on |
|-------|-------------|------------|
| 0 | TLS deps build under cabal | — |
| 1 | `TlsTransport` + `serveTls` | 0 |
| 2 | `--server --tls` CLI + validation | 1 |
| 3 | Client TLS + end-to-end session | 1 |
| 4 | Consul registry registration + pinned client discovery | 2, 3 |
| 5 | `gen-certs.sh` + README | 2 |

Phase 4 combines server-side registration (after Phase 2) with client-side pinned discovery (after Phase 3); those two halves can be developed in parallel, but the full phase lands only after both dependencies. Suggested single-developer order: 0 → 1 → 2 → 3 → 4 → 5.

---

## 5. Legacy: UDP broadcast discovery (superseded)

> **Superseded** by the service registry design (Section 3). Retained for the record of the UDP broadcast approach and its limitations.

This design described a third operating mode, **server mode**, which added a network discovery mechanism on top of the TCP daemon.

### Historical design choices

- **Pull-based UDP broadcast**: clients send a probe to the broadcast address; servers answer. This avoids constant beacon traffic and stale announcements.
- **Raw UDP, not mDNS**: mDNS requires an additional library and platform mDNS stacks. Raw UDP broadcast works with the `network` package already in use (`Protocol.Transport.Tcp`), so no new dependencies are introduced.
- **Discovery is transport-adjacent, not protocol-level**: the session protocol is unchanged. After connecting, the first message is still one of the `Register*` messages; no handshake, version negotiation, or greeting is added to the TCP session.

### Wire protocol (discovery)

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

### Server side

#### Startup (`app/Main.hs`)

```haskell
["--server", portStr] -> serveWithDiscovery (fromIntegral (read portStr :: Int))
```

#### `Protocol.Transport.Tcp`

```haskell
serveWithDiscovery :: PortNumber -> IO ()
serveWithDiscovery port = do
  _ <- forkIO (runDiscoveryResponder port)
  serveTcp port
```

The discovery responder runs concurrently with the existing sequential accept loop. Both threads follow the established resilience pattern (`try` around each iteration, log and continue on failure): a discovery error must never take down serving, and vice versa.

#### Discovery responder (`Protocol.Transport.Discover`, new module)

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

### Client side

#### Discovery API (`Protocol.Transport.Discover`, re-exported from `Protocol.Client`)

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

### Compatibility

- Stdio and `--serve` modes are unchanged.
- The session protocol (`docs/protocol-spec.md`) is unchanged: no handshake, version exchange, or greeting on the TCP connection; the first client message remains a `Register*` message.
- Discovery messages live only on UDP port `45700` and never appear on the session transport.

### Hardening if UDP is ever used with mTLS

The original mTLS design treated UDP discovery as opportunistic: the TLS handshake performs the real server authentication, so a spoofed `announce` can at worst cause a client to attempt a TLS connection that fails certificate validation. Hardening retained for that scenario:

- Reply only to well-formed probes; rate-limit replies per source IP.
- Optionally, `announce` carries the SHA-256 fingerprint of the server certificate; clients pin it and fail fast before the TLS handshake on mismatch. This is a cheap defense-in-depth measure, not a load-bearing control.

### Limitations and future work at the time

- **Broadcast scope**: UDP broadcast does not cross subnets. Future work considered: optional multicast group (`--server <port> --mcast`, group `239.255.77.1`) for routed discovery.
- **No security**: probes and replies are unauthenticated plaintext. This matched the trust level of the plain-TCP daemon (no TLS, no auth) and was intended for trusted LANs.
- **No health/liveness**: discovery proved the responder was alive at probe time; a stale announce was possible if the TCP accept loop died but the responder thread survived (and vice versa).

All three limitations are addressed by the registry design in Section 3.

---

## 6. Alternative: PSK + HMAC authenticated mode

> **Retained alternative.** This design originally extended the UDP discovery mechanism (Section 5) with an authentication mechanism. It was superseded by mTLS (Section 2) for deployments requiring high security, and remains the documented lightweight option for trusted-LAN use.

The design addresses the security issues identified in review: spoofed discovery replies, replayed announcements, and unauthenticated access to the TCP session.

### Threat model

The trusted-LAN assumption is dropped. An attacker on the network may:

- Send forged `announce` replies to redirect clients to a malicious mirror.
- Replay previously captured `announce` or session messages.
- Connect to the daemon and drive a session (including `register` with attacker-chosen spec paths).
- Flood the discovery responder or hold the sequential TCP accept loop.

Out of scope (documented as residual risks): traffic confidentiality, denial of service via connection hogging, and filesystem access control for spec paths (addressed separately by a `--root` allowlist).

### Design choices

- **Pre-Shared Key (PSK) + HMAC-SHA256**, via the `cryptonite` package. This adds one pure-Haskell dependency and avoids the operational burden of TLS certificates, matching the project's minimal-dependency style.
- **Two layers**: signed discovery announces (server authentication) and a challenge–response handshake on TCP connect (mutual authentication). The existing session protocol after authentication is unchanged.

### Key management

- The PSK is supplied via `--psk-file <path>` (file permissions must be `0600`, checked at startup) or the `MODELMIRRORS_PSK` environment variable. **Never** as a CLI argument, which would be visible in `ps` output.
- `ModelMirrors --server <port>` in authenticated mode refuses to start without a PSK.
- `--serve` (unauthenticated TCP) and stdio modes remain unchanged for backward compatibility.

### Layer 1: discovery authentication

The `discover` probe is public and unsigned, but gains a random `nonce` (16 bytes, base64):

```json
{ "proto_step": "discover", "version": 2, "nonce": "..." }
```

The `announce` reply is signed:

```json
{
  "proto_step": "announce",
  "version": 2,
  "host": "10.0.0.5",
  "port": 8765,
  "pid": 1234,
  "nonce": "<echo of probe nonce>",
  "timestamp": 1753290000,
  "hmac": "HMAC-SHA256(psk, host|port|nonce|timestamp)"
}
```

Client verification rules:

1. HMAC must verify against the PSK.
2. `nonce` must equal the nonce sent in the probe (binds the reply to this probe, preventing replay of old announces).
3. `timestamp` must be within ±60 seconds of the client's clock.
4. Malformed, unsigned, or invalid replies are silently dropped; collection continues until the timeout.

This fixes **spoofing/redirection** and **announce replay**.

#### Amplification mitigation

HMAC does not stop a spoofed-source probe flood. The responder:

- Replies only to well-formed probes with a known `version` (drop before doing any crypto work beyond parsing).
- Rate-limits replies per source IP (e.g. token bucket, 5 replies/second/IP).
- Keeps replies small (~150 bytes, comparable to the probe), limiting amplification factor.

### Layer 2: session authentication

One extra round-trip at TCP connect, then the protocol proceeds exactly as today. New `ClientMessage`/`MirrorMessage` variants:

```
client → {"proto_step":"auth_hello", "version":2, "nonce_c":"<16 random bytes, base64>"}
server → {"proto_step":"auth_reply", "nonce_s":"<16 random bytes, base64>",
          "hmac": HMAC(psk, "reply"  | nonce_c | nonce_s)}
client → {"proto_step":"auth_finish","hmac": HMAC(psk, "finish" | nonce_s | nonce_c)}
server → {"proto_step":"auth_ok"}
```

Then the mirror enters the existing `RecvMsg` state and expects a `Register*` message as usual.

Properties:

- **Server proves first**, so a rogue server cannot harvest valid client proofs to replay elsewhere.
- **Mutual**: both sides demonstrate knowledge of the PSK; the key itself never crosses the wire.
- **Replay-safe**: fresh random nonces per connection; the domain-separation strings (`"reply"`, `"finish"`) prevent cross-message confusion.
- **Failure handling**: any invalid step → `ProtocolError`, close connection, log the source IP, and apply per-IP backoff (e.g. exponential, starting at 1s) to slow online guessing. HMAC brute-force over a network is infeasible for a 256-bit PSK; backoff primarily protects against weak, human-chosen PSKs.

#### Future encryption hook

After `auth_ok`, both sides can derive a session key:

```
session_key = HKDF-SHA256(psk, nonce_c | nonce_s, info="modelmirrors-session")
```

This enables optional AES-GCM encryption of the session later without changing the handshake. Confidentiality is explicitly out of scope for this iteration.

### Changes to existing modules

| Module | Change |
|--------|--------|
| `app/Main.hs` | `--server <port> [--psk-file <path>]` flag handling; refuse startup without PSK |
| `Protocol.Transport.Discover` (new) | `runDiscoveryResponder` signs announces; `discoverServers` sends nonce, verifies HMAC/timestamp, filters invalid replies; per-IP reply rate limiting |
| `Protocol.Core` | New message variants: `AuthHello`, `AuthReply`, `AuthFinish`, `AuthOk` |
| `Protocol.Format.Json` | JSON instances for the auth messages |
| `Protocol.Mirror` | `run` gains an optional pre-session `Authenticate` step when a PSK is configured; unauthenticated mode is byte-for-byte today's behavior |
| `Protocol.Client` | Auth handshake performed inside the client entry points when the transport is created with a PSK; `discoverServers` returns only verified `ServerInfo`s |

### Compatibility

- Stdio and `--serve` modes are unchanged; authenticated mode is opt-in via `--server` + PSK.
- `version: 1` probes still receive unsigned `version: 1` announces (server answers in the probed version), so old clients keep working against new servers — accepting the spoofing risk knowingly.
- An authenticated client connecting to an unauthenticated `--serve` daemon gets a `ProtocolError` on `auth_hello` and fails cleanly.

### Alternatives considered

| Option | Verdict |
|--------|---------|
| TLS + pinned certificates | Strongest guarantees, but pulls in the `tls`/`x509` stack and certificate management. Adopted as the high-security path in Section 2. The `auth_ok` session-key hook kept this path open. |
| NaCl/libsodium (`saltine`) | Excellent primitives, but a C dependency complicates the cabal build. |
| Static token in every message | Simple, but no replay protection and exposes the token in plaintext on the wire. Rejected. |

### Residual risks

- **DoS**: an attacker can still hold the single sequential TCP connection or flood UDP. Per-IP connection timeouts and the discovery rate limit mitigate but do not eliminate this; full concurrency hardening is orthogonal future work.
- **Filesystem access**: authentication proves identity but does not restrict what an authorized client may ask for. `specPath` and trace-destination paths should be confined with a `--root <dir>` allowlist in server mode (separate change).
- **Weak PSKs**: the scheme is only as strong as the key. Startup should warn if the PSK is shorter than 16 bytes.

---

## Consolidation notes

- Cross-document references were replaced with in-document section links.
- The registry design supersedes UDP discovery; the UDP design is retained in Section 5 for the record.
- The mTLS design supersedes the PSK design for high-security use; the PSK design is retained in Section 6 as the lightweight alternative.
- The implementation plan's Phase 4 was aligned with the registry design (the old milestone row still referred to the UDP `discoverServers` flow), and its final dependency note was made consistent with that milestone table.
- The plan's stale source-file line-number anchors were dropped so the merged document does not drift as those files change.
- The mTLS threat model's outdated "sequential accept loop" DoS wording was reconciled with the bounded-dispatcher residual-risk mitigation in the same section.
- All substantive protocol, wire-format, CLI, module-change, compatibility, risk, and test content from the five source documents is preserved above.
