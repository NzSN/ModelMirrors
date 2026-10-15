# JSONL transport bounds

The built-in stdio, TCP and TLS adapters send one payload followed by exactly
one LF. A payload may contain at most 65,535 encoded UTF-8 bytes. `sendMsg`
validates the final Aeson encoding, and direct built-in `send` calls enforce
the same limit and reject raw LF. A refused send emits no bytes. Ordinary JSON
encoding, escaping, optional fields and ITF values are unchanged.

Receive framing operates on bytes before JSON decoding. A 65,535-byte payload
followed by LF is accepted; a 65,536th payload byte is refused immediately,
without waiting for LF or EOF. Complete coalesced frames remain separate, and
UTF-8 code points may span reads. Empty EOF returns the established empty-byte
sentinel. Nonempty EOF and read failure throw and close the affected endpoint.
Oversize/truncated input cannot be drained and resumed as another request.
The public `Transport` signatures and nullary `StdioTransport` constructor are
preserved. Framing/read failures propagate as exceptions; existing client
`Either Text` result signatures are unchanged.

The Handle reader consumes one byte at a time through GHC's buffered binary
Handle. It retains at most 65,535 bytes plus bounded list-cell overhead and
does not read past LF. This favors a small implementation preserving stdio's
constructor; future optimization should measure actual throughput first.
The TLS scanner retains at most 65,535 payload bytes plus one input record
suffix, defensively limited to 65,536 bytes. It inspects the first LF before
counting the next frame. The underlying TLS library normally returns one
decrypted record (at most 16 KiB) per read. No chunk is decoded individually.

The server and reference client share these adapters. TCP accept loops close
the Handle that owns each accepted socket, including exceptional framing exit.
`runAsyncSession` owns its supplied per-session job store and releases its
jobs on normal and exceptional exit; callers must not share that store across
connections.

On POSIX, both TLS parameter constructors require `(mode & 07777) == 0600`.
This also rejects owner-only 0400/0700 and special-bit modes. Neither key
contents nor permissions are changed by these constructors. Windows retains
its platform behavior and needs separate ACL validation.

Async submission verifies the accepted kind. Query/await/cancel verify the
echoed job ID before using the reply or issuing another flow message.
Cancellation accepts a matching `job_status` or legal terminal `job_result`
and retains its existing `IO (Either Text ())` API. A mismatch returns a local
error without automatic cancellation or further polling.

Fingerprint pins are compared case-sensitively against lowercase SHA-256 hex.
An uppercase spelling is a documented Haskell exception to clients that
normalize pin case. Mismatching pins close the newly acquired TLS connection.
Server identity uses SAN only, as required by C25. DNS identities require a
DNS SAN and reuse the installed dependency's DNS/wildcard matcher. IP literals
use that dependency's Data.IP parser and exact IPv4/IPv6 SAN address equality;
CN and wrong-type SANs never supply identity. The same SAN check runs before
the dependency's validation cache can authorize a previously accepted CN-only
certificate. Standard default chain, CA, validity and leaf checks retain their
original store, cache, service ID and signed chain. Correct IP-only SANs work
even when CN differs. This closes the separately observed dependency fallback;
previously accepted CN-only certificates now fail TLS identity validation.

## Focused non-model gate

Run from the selected remote WSL checkout with GHC matching the Cabal base
constraint. This coordinator performs no compilation or runtime probes.

```sh
LC_ALL=C.UTF-8 cabal build ModelMirrors-test
LC_ALL=C.UTF-8 cabal test ModelMirrors-test --test-options='--list-tests --pattern NonModel'
LC_ALL=C.UTF-8 cabal test ModelMirrors-test --test-show-details=direct --test-options='--pattern NonModel --num-threads=1'
```

The selected groups are `TransportFramingNonModel`, `StdioFramingNonModel`,
`ServerFramingNonModel`, `ClientReplyNonModel`, and `TlsPolicyNonModel`. They
use actual stdio children, loopback TCP, ephemeral mutual TLS peers and injected
fake job backends. They invoke no model checker. OpenSSL is needed for throwaway
certificates, and POSIX key tests need a filesystem retaining mode bits.
The existing broad test suite still contains model-backed integration tests;
do not substitute `cabal test all` for this focused gate.
