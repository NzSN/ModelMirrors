# Authenticated Server Mode — Design

This document extends `server-mode-discovery-design.md` with an authentication mechanism, addressing the security issues identified in review: spoofed discovery replies, replayed announcements, and unauthenticated access to the TCP session.

## Threat Model

The trusted-LAN assumption is dropped. An attacker on the network may:

- Send forged `announce` replies to redirect clients to a malicious mirror.
- Replay previously captured `announce` or session messages.
- Connect to the daemon and drive a session (including `register` with attacker-chosen spec paths).
- Flood the discovery responder or hold the sequential TCP accept loop.

Out of scope (documented as residual risks): traffic confidentiality, denial of service via connection hogging, and filesystem access control for spec paths (addressed separately by a `--root` allowlist).

## Design Choices

- **Pre-Shared Key (PSK) + HMAC-SHA256**, via the `cryptonite` package. This adds one pure-Haskell dependency and avoids the operational burden of TLS certificates, matching the project's minimal-dependency style.
- **Two layers**: signed discovery announces (server authentication) and a challenge–response handshake on TCP connect (mutual authentication). The existing session protocol after authentication is unchanged.

## Key Management

- The PSK is supplied via `--psk-file <path>` (file permissions must be `0600`, checked at startup) or the `MODELMIRRORS_PSK` environment variable. **Never** as a CLI argument, which would be visible in `ps` output.
- `ModelMirrors --server <port>` in authenticated mode refuses to start without a PSK.
- `--serve` (unauthenticated TCP) and stdio modes remain unchanged for backward compatibility.

## Layer 1: Discovery Authentication

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

### Amplification mitigation

HMAC does not stop a spoofed-source probe flood. The responder:

- Replies only to well-formed probes with a known `version` (drop before doing any crypto work beyond parsing).
- Rate-limits replies per source IP (e.g. token bucket, 5 replies/second/IP).
- Keeps replies small (~150 bytes, comparable to the probe), limiting amplification factor.

## Layer 2: Session Authentication

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

### Future encryption hook

After `auth_ok`, both sides can derive a session key:

```
session_key = HKDF-SHA256(psk, nonce_c | nonce_s, info="modelmirrors-session")
```

This enables optional AES-GCM encryption of the session later without changing the handshake. Confidentiality is explicitly out of scope for this iteration.

## Changes to Existing Modules

| Module | Change |
|--------|--------|
| `app/Main.hs` | `--server <port> [--psk-file <path>]` flag handling; refuse startup without PSK |
| `Protocol.Transport.Discover` (new) | `runDiscoveryResponder` signs announces; `discoverServers` sends nonce, verifies HMAC/timestamp, filters invalid replies; per-IP reply rate limiting |
| `Protocol.Core` | New message variants: `AuthHello`, `AuthReply`, `AuthFinish`, `AuthOk` |
| `Protocol.Format.Json` | JSON instances for the auth messages |
| `Protocol.Mirror` | `run` gains an optional pre-session `Authenticate` step when a PSK is configured; unauthenticated mode is byte-for-byte today's behavior |
| `Protocol.Client` | Auth handshake performed inside the client entry points when the transport is created with a PSK; `discoverServers` returns only verified `ServerInfo`s |

## Compatibility

- Stdio and `--serve` modes are unchanged; authenticated mode is opt-in via `--server` + PSK.
- `version: 1` probes still receive unsigned `version: 1` announces (server answers in the probed version), so old clients keep working against new servers — accepting the spoofing risk knowingly.
- An authenticated client connecting to an unauthenticated `--serve` daemon gets a `ProtocolError` on `auth_hello` and fails cleanly.

## Alternatives Considered

| Option | Verdict |
|--------|---------|
| TLS + pinned certificates | Strongest guarantees, but pulls in the `tls`/`x509` stack and certificate management. Revisit if the tool ever leaves trusted networks. The `auth_ok` session-key hook keeps this path open. |
| NaCl/libsodium (`saltine`) | Excellent primitives, but a C dependency complicates the plain-cabal and Bazel builds. |
| Static token in every message | Simple, but no replay protection and exposes the token in plaintext on the wire. Rejected. |

## Residual Risks

- **DoS**: an attacker can still hold the single sequential TCP connection or flood UDP. Per-IP connection timeouts and the discovery rate limit mitigate but do not eliminate this; full concurrency hardening is orthogonal future work.
- **Filesystem access**: authentication proves identity but does not restrict what an authorized client may ask for. `specPath` and trace-destination paths should be confined with a `--root <dir>` allowlist in server mode (separate change).
- **Weak PSKs**: the scheme is only as strong as the key. Startup should warn if the PSK is shorter than 16 bytes.
