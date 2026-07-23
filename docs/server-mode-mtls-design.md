# Server Mode with mTLS — Design

This document supersedes `server-mode-auth-design.md` for deployments requiring high security. It replaces the PSK + HMAC scheme with **TLS 1.3 mutual authentication (mTLS)**, which provides mutual authentication, confidentiality, integrity, and forward secrecy in a single vetted protocol. The PSK design remains valid for trusted-LAN use; this document covers untrusted-network and multi-user deployments.

## Threat Model

An attacker on the network may:

- Spoof discovery replies to redirect clients to a malicious mirror.
- Intercept, replay, or modify session traffic (active man-in-the-middle).
- Connect to the daemon and drive a session with attacker-chosen spec paths.
- Attempt to extract credentials from a compromised client or server host.

Additional requirements beyond the PSK design:

- **Confidentiality**: session traffic (specs, traces, reported states) must not be readable on the wire.
- **Forward secrecy**: compromise of a long-term key must not decrypt previously recorded sessions.
- **Per-client identity**: the server must distinguish clients for future authorization and audit.

Out of scope (residual risks, handled orthogonally): denial of service on the sequential accept loop, and filesystem confinement of `specPath`/trace destinations (a `--root <dir>` allowlist).

## Design Choices

- **TLS 1.3 mutual authentication** via the Haskell `tls`, `x509`, and `x509-store` packages — pure Haskell, compatible with plain cabal and the Bazel `stack_snapshot`.
- **Private CA**: one offline CA signs the server certificate and per-client certificates. No public CA involved.
- **No custom protocol design**: authentication happens entirely inside the TLS handshake. The session protocol after the handshake is byte-for-byte identical to today's; the change is confined to transport setup.
- **Opt-in**: stdio and `--serve` remain unchanged. mTLS is gated behind `ModelMirrors --server <port> --tls`.

## Architecture

### Modes

| Mode | Invocation | Transport | Authentication |
|------|-----------|-----------|----------------|
| Stdio (default) | `ModelMirrors` | stdin/stdout | n/a (subprocess inherits parent's trust) |
| TCP daemon (legacy) | `ModelMirrors --serve <port>` | plain TCP | none |
| Server (mTLS) | `ModelMirrors --server <port> --tls ...` | TLS 1.3 over TCP | mutual, certificate-based |

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

### Flags

```
ModelMirrors --server <port> --tls \
    --cert <server.crt> --key <server.key> --ca <ca.crt> [--bind <addr>]
```

Startup validation: all files readable, key file mode `0600`, chain validates against the CA, SAN non-empty. Any failure → exit with a clear error before binding sockets.

## Discovery

Discovery becomes **opportunistic**: the UDP responder and wire format from `server-mode-discovery-design.md` are used unchanged (unsigned, `version: 1`), because the TLS handshake performs the real server authentication. A spoofed `announce` can at worst cause a client to attempt a TLS connection to a host that fails certificate validation — a failed connection, not a compromise.

Hardening retained from the PSK design:

- Reply only to well-formed probes; rate-limit replies per source IP.
- Optionally, `announce` carries the SHA-256 fingerprint of the server certificate; clients pin it and fail fast before the TLS handshake on mismatch. This is a cheap defense-in-depth measure, not a load-bearing control.

## Session Protocol

Unchanged. After the TLS handshake completes:

1. The client sends a `Register*` message as its first message, exactly as today.
2. The mirror runs the existing sequential accept loop; each accepted socket is upgraded to a TLS context before entering `run`.
3. Failed handshakes are logged (source IP, TLS alert) and the connection is closed; per-IP backoff mitigates handshake-flooding.

No auth messages are added to `Protocol.Core` — the `AuthHello`/`AuthReply`/`AuthFinish` variants from the PSK design are unnecessary here.

## Changes to Existing Modules

| Module | Change |
|--------|--------|
| `app/Main.hs` | `--server --tls` flag handling, startup validation, refuse startup on invalid config |
| `Protocol.Transport.Tls` (new) | `serveTls`: like `serveTcp`, but wraps each accepted socket in a TLS server context (`tls` package); exposes a `TlsTransport` implementing the existing two-method `Transport` class over the TLS channel |
| `Protocol.Transport.Tcp` | Extract shared accept-loop structure reused by `serveTls`; `serveTcp` unchanged |
| `Protocol.Client` | Client entry points accept TLS parameters (CA, client cert/key); `discoverServers` optionally verifies the cert fingerprint in `announce` |
| `Protocol.Mirror`, `Protocol.Core`, `Protocol.Format.Json` | **Unchanged** |
| `scripts/gen-certs.sh` (new) | CA + server + client cert generation helper |
| `.cabal` / Bazel `BUILD` | Add `tls`, `x509`, `x509-store` dependencies (and to `stack_snapshot`) |

## Compatibility

- Stdio and `--serve` are byte-for-byte unchanged.
- mTLS clients cannot talk to `--serve` daemons and vice versa; the failure is a clean TLS/handshake error, never a protocol confusion.
- A mirror binary built without the TLS dependencies retains all current behavior.

## Pros / Cons Summary

**Pros**: mutual auth + encryption + forward secrecy in one vetted protocol; no custom crypto to audit; per-client identity enables future authorization; cert expiry gives revocation; clients in any language have mature TLS library support.

**Cons**: dependency jump (`tls`/`x509`/`asn1-*`) for a currently lean package; PKI operations (issuance, renewal, expiry outages) are the main ongoing cost; clock skew becomes a failure mode; dev ergonomics need the cert-free stdio mode preserved (it is).

## Residual Risks

- **DoS**: mitigated by the bounded dispatcher (`serveTlsConcurrent`): the TLS handshake runs in the worker thread, so a slow or stalled handshake never blocks the accept loop, and concurrent sessions are capped by `--jobs <n>` (default 4). Excess connections wait in the accept backlog. Per-IP rate limits remain future work.
- **Session isolation**: concurrent sessions each get a per-session apalache `--run-dir` temp dir (removed on session exit) and an explorer server on an ephemeral port; sessions share no filesystem or port state.
- **Filesystem access**: mTLS proves identity but does not constrain requests. Add `--root <dir>` to confine `specPath` and trace destinations (separate change).
- **Cert expiry outages**: mitigated by renewal automation and startup warnings when certs are near expiry (implemented: stderr warning at < 7 days remaining).
