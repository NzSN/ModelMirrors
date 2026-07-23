# Server Mode with mTLS — Implementation Plan

Implementation plan for `docs/server-mode-mtls-design.md`. Phased so each phase lands a buildable, testable increment; earlier phases ship value even if later ones are deferred.

## Phase 0 — Dependency and build groundwork

**Goal**: `tls`, `x509`, `x509-store` build under both cabal and Bazel before any code depends on them.

Tasks:

1. Add to `ModelMirrors.cabal` library `build-depends`: `tls >= 2.0`, `x509 >= 1.7`, `x509-store >= 1.6`.
2. Add the same packages to `stackage_snapshot.yaml` (resolver `nightly-2026-05-01`; verify versions exist in the snapshot, pin in `extra-deps` style if not).
3. Add `@stackage//:tls`, `@stackage//:x509`, `@stackage//:x509-store` to `src/BUILD.bazel` `deps`.
4. Verify: `cabal build all` and `bazel build //...`.

Gate: both builds green. **Risk**: Stackage nightly may lag `tls` releases — if the snapshot lacks a compatible version, pin one in the snapshot file; this is the highest-uncertainty item in the whole plan, so it goes first.

## Phase 1 — `TlsTransport` and server-side TLS accept loop

**Goal**: the mirror can serve one authenticated TLS client per connection; no CLI wiring yet.

Tasks:

1. New module `src/Protocol/Transport/Tls.hs`:
   - `TlsTransport` wrapping a `tls` `Context`, implementing the existing two-method `Transport` class (`send` = one JSON line via `sendData`, `recv` = accumulate `recvData` until newline — the `tls` package is stream-oriented, so newline framing must be re-implemented on top; reuse the same framing convention as `Stdio.hs:10-16`).
   - `mkServerParams :: FilePath -> FilePath -> FilePath -> IO ServerParams` — load cert/key/CA via `x509-store`, configure `tls` for TLS 1.3 only, `requireClientCert`.
2. `serveTls :: ServerParams -> PortNumber -> IO ()` in the same module, mirroring the structure of `serveTcp` (`Tcp.hs:53-72`): `AI_PASSIVE` bind, sequential accept, per-connection `try`, log-and-survive client drops. Each accepted socket is upgraded via `contextNew` + `handshake` before `run`.
3. Export `Protocol.Transport.Tls` from the library (cabal `exposed-modules`, Bazel picks it up via `glob`).
4. Unit test with `Mock`-style harness where possible; real TLS handshake test deferred to Phase 4.

Gate: `bazel build //...`, existing `bazel test //test:ModelMirrors-test` still green (no behavior change).

## Phase 2 — CLI wiring and startup validation

**Goal**: `ModelMirrors --server <port> --tls --cert c --key k --ca ca [--bind addr]` starts the mTLS server.

Tasks:

1. `app/Main.hs:8-13`: extend the argument case to parse `--server` mode and TLS flags (simple pattern-match parser, consistent with the current style — no optparse-applicative dependency).
2. Startup validation (fail fast, clear errors, before binding):
   - all files readable; key file mode `0600`;
   - certificate chain validates against the CA; SAN non-empty;
   - cert expiry < 7 days → log a warning (per design residual-risk mitigation).
3. `--bind <addr>`: thread the address through `serveTls` (and optionally `serveTcp`) instead of `AI_PASSIVE`-only.
4. `MainSpec`/integration smoke test that the binary rejects bad flag combinations and missing files with exit-code failures.

Gate: manual smoke — generate throwaway certs with openssl, start `--server --tls`, connect with `openssl s_client -connect ... -cert client.crt -key client.key`, observe the mirror waiting for `Register`.

## Phase 3 — Client-side TLS support

**Goal**: library clients can connect over mTLS.

Tasks:

1. `Protocol.Transport.Tls`: client-side `connectTls :: ClientParams -> HostName -> PortNumber -> IO TlsTransport` — load CA + client cert/key, validate server chain and hostname.
2. `Protocol.Client`: thread TLS parameters into the client entry points (`runClient`, `runClientExplore`, etc., `Client.hs:31-82`) — either a `TlsConfig` argument variant or a `Transport`-agnostic refactor so callers pass any ready `Transport` (prefer the latter: keeps `Client.hs` free of transport specifics).
3. JSON framing on the client side reuses the Phase 1 `TlsTransport`.

Gate: round-trip test — `serveTls` on a forked thread + `runClient` over `connectTls`, running the existing `HourClock` register flow end-to-end (pattern after `TcpTransportSpec.hs:114-136`).

## Phase 4 — Discovery integration (service registry)

**Goal**: `--server` mode registers itself in a service registry; clients locate and verify it.

Per `server-mode-registry-design.md` (supersedes `server-mode-discovery-design.md`): Consul HTTP API via the existing `http-client` dependency. The registry does location only; mTLS does authentication, with the registry's `cert-sha256` meta used for fingerprint pinning.

Tasks:

1. New module `src/Protocol/Registry.hs`:
   - `registerService :: RegistryUrl -> ServiceInfo -> IO ()` (`PUT /v1/agent/service/register` with TTL check)
   - `heartbeatLoop :: RegistryUrl -> ServiceId -> IO ()` (forked; `PUT /v1/agent/check/pass/service:<id>` every 10 s, `try`-guarded, never kills the accept loop)
   - `deregisterService :: RegistryUrl -> ServiceId -> IO ()` (best-effort)
   - `discoverServices :: RegistryUrl -> IO [ServiceInfo]` (`GET /v1/health/service/modelmirrors?passing=true`; malformed JSON → `[]`, fail closed)
2. `app/Main.hs`: `--registry <url>` flag (or `MODELMIRRORS_REGISTRY` env var) on `--server`; register + fork heartbeat on startup. Without it, serve unregistered as today.
3. Client: fingerprint pinning — after `connectTls`, compare the peer cert SHA-256 against `ServiceInfo` meta when present; mismatch → try next candidate.
4. Tests: JSON encode/decode round-trips; `discoverServices` against a minimal stub HTTP server (raw socket returning a canned Consul response); malformed-response handling.

Gate: full flow demo — start server with `--registry` against a local Consul dev agent, client discovers by name, verifies fingerprint, completes mTLS handshake, runs a `Register` session.

## Phase 5 — Cert tooling and docs

**Goal**: the PKI is usable without reading the design docs.

Tasks:

1. `scripts/gen-certs.sh`: generate CA, server cert (SAN from argument), client cert (CN from argument); set `0600` on keys; print renewal instructions. Plain `openssl`, no new tooling dependency.
2. README section: quick-start for `--server --tls` (generate certs → start server → connect client), cert renewal procedure, expiry warning behavior.
3. Update `docs/protocol-spec.md` transport section: note TLS as a session transport with identical message format.

Gate: a fresh clone can follow the README to a working mTLS session.

## Test strategy

- **Unit**: startup validation logic (Phase 2) as pure-ish functions over file paths; rate limiter (Phase 4).
- **Integration** (tasty, alongside existing specs):
  - TLS round-trip over loopback with test certs generated into a temp dir (Phase 3) — follow `TcpTransportSpec` structure.
  - Mutual-auth negative tests: no client cert → handshake rejected; wrong CA → rejected.
  - Discovery round-trip and malformed-probe handling (Phase 4).
- Test certs: generated per-run into a temp dir by the test setup (never committed) or committed with a clearly-test-only CA; prefer per-run generation to avoid expired-cert flakes — pin validity to a wide window.
- **No `apalache-mc` dependency** for the new transport tests; keep them fast like `TcpTransportSpec`, unlike the Apalache integration specs.
- Full suite green under both `cabal test all` and `bazel test //test:ModelMirrors-test` before each phase merges.

## Deferred (explicitly out of scope)

- `--root <dir>` path confinement for `specPath`/trace destinations — separate security change.
- Per-IP connection rate limiting and handshake timeouts on the TCP accept loop — DoS hardening, follow-up.
- Per-client authorization based on cert CN — identity is logged this iteration; policy comes later.
- PSK mode (`server-mode-auth-design.md`) — not implemented if mTLS lands first; the doc stays as the lightweight alternative.

## Milestone summary

| Phase | Deliverable | Depends on |
|-------|-------------|------------|
| 0 | TLS deps build under cabal + Bazel | — |
| 1 | `TlsTransport` + `serveTls` | 0 |
| 2 | `--server --tls` CLI + validation | 1 |
| 3 | Client TLS + end-to-end session | 1 |
| 4 | Discovery responder + verified `discoverServers` | 2, 3 |
| 5 | `gen-certs.sh` + README | 2 |

Phases 3 and 4 are independent of each other after Phase 1 and can be done in either order (or parallel by different people). Suggested single-developer order: 0 → 1 → 2 → 3 → 4 → 5.
