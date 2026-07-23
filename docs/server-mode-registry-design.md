# Server Mode Discovery via Service Registry — Design

This document supersedes `server-mode-discovery-design.md` (UDP broadcast). Discovery is delegated to an external **service registry** over its HTTP API.

## Why a registry instead of UDP broadcast

- **Source of truth**: registrations are explicit, TTL-bound entries in a registry, not best-effort broadcast replies. Stale entries expire via TTL/health checks.
- **Cross-subnet by construction**: no reliance on broadcast/multicast reachability.
- **Health awareness**: only healthy servers are returned to clients.
- **Separation of concerns**: the registry answers *where* mirrors are; mTLS (`server-mode-mtls-design.md`) answers *whether to trust them*. A compromised registry can at worst point clients at hosts that fail TLS authentication — a failed connection, not impersonation.

## Registry choice: Consul HTTP API

- The API is plain HTTP/JSON, so the client uses the **existing `http-client` dependency** — no new libraries.
- Alternatives considered: etcd (gRPC-first; HTTP gateway is second-class), Kubernetes Endpoints API (right answer only if deployed in k8s; possible future backend), self-hosted registry mode (reinvents Consul; rejected).
- The implementation targets the small stable subset of the Consul agent API; any Consul-compatible endpoint works.

## Server side: registration

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

The registry URL comes from `--registry <url>` or `MODELMIRRORS_REGISTRY`; without it, `--server` runs with no registration (direct-connect only), matching today's behavior.

## Client side: discovery

```haskell
discoverServices :: RegistryUrl -> IO [ServiceInfo]
```

`GET /v1/health/service/modelmirrors?passing=true`, parsing each entry's `Service.Address`, `Service.Port`, and `Service.Meta.cert-sha256`.

Client flow:

1. `discoverServices` → candidates.
2. `connectTls` to a candidate (mTLS authenticates the server regardless of registry honesty).
3. **Fingerprint pinning (defense-in-depth)**: if the entry carries `cert-sha256`, compare it against the peer certificate fingerprint after the handshake; mismatch → close and try the next candidate.

## Security model

- **Registry compromise**: an attacker who can write the registry can make clients connect to attacker hosts, but those hosts cannot complete mTLS without a CA-signed certificate, and cannot match the pinned fingerprint. Worst case: denial of service (clients find no usable server).
- **Registry availability**: discovery fails closed — clients can still connect to a known `host:port` directly.
- **Registry access control**: out of scope for the mirror itself; operators should enable Consul ACLs and TLS on the registry in untrusted environments. Documented as an operational requirement, matching the trust level of the mTLS CA.

## Failure modes

| Failure | Behavior |
|---|---|
| Registry unreachable at server startup | Log warning, serve without registration |
| Heartbeat thread dies / registry down mid-run | TTL lapses; clients stop discovering the server; direct connections still work |
| Registry returns malformed JSON | `discoverServices` returns `[]` (fail closed) |
| Fingerprint mismatch | Client closes connection, tries next candidate |

## Alternatives rejected

- **UDP broadcast** (previous design): no source of truth, LAN-scope only, spoofable without an added signature layer.
- **mDNS/DNS-SD**: platform mDNS stack dependency, same LAN-scope limitation.
- **Built-in registry mode** (`ModelMirrors --registry`): centralizes discovery into the tool and reinvents TTL/health/storage; revisit only if Consul proves too heavy for typical deployments.
