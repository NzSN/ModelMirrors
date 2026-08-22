# Deploying ModelMirrors in Server Mode

This document is the operational guide for running a ModelMirrors mirror as a
long-lived server daemon. It covers the three server shapes the executable
supports, prerequisites, TLS provisioning, service installation on POSIX and
Windows, verification, and day-2 operations (upgrade, rollback, cert renewal,
registry).

For the machine-specific design notes of the r-windev deployment (Windows 10
box, NSSM, apalache shim), see [`deploy-r-windev.md`](deploy-r-windev.md);
for the protocol itself, see [`protocol-spec.md`](protocol-spec.md).

## 1. Server shapes

`ModelMirrors` has one executable with four modes; two of them are servers:

| Mode | Command | Transport | Use case |
|---|---|---|---|
| Stdio mirror (default) | `ModelMirrors` | stdio, one session | ad-hoc, editor/IDE integration |
| Plain TCP daemon | `ModelMirrors --serve <port> [--bind <addr>]` | plaintext TCP, one session per connection | trusted networks, local experimentation |
| **mTLS daemon** | `ModelMirrors --server <port> --tls --cert C --key K --ca A [--jobs N] [--bind <addr>] [--registry URL]` | TLS 1.3 mutual auth, bounded concurrency | **the production shape** |

The rest of this document focuses on the mTLS `--server` mode, with `--serve`
noted where it differs.

### `--server` options (from `Protocol.ServerOpts`)

| Option | Meaning |
|---|---|
| `--server <port>` | TCP port to listen on (first positional of the mode) |
| `--tls` | required; enables the TLS 1.3 server params |
| `--cert <file>` | server certificate (PEM), must chain to `--ca` |
| `--key <file>` | server private key (PEM); POSIX builds assert mode 0600 |
| `--ca <file>` | CA bundle; **client certificates are required** (mutual auth) |
| `--jobs <n>` | max concurrent sessions (bounded dispatcher). `1` (default semantics: sequential accept loop) up to N worker threads; each session owns one apalache JVM |
| `--bind <addr>` | restrict the listener to an address (default: all interfaces) |
| `--registry <url>` | Consul HTTP API endpoint (or `MODELMIRRORS_REGISTRY` env) — register with a 10 s TTL heartbeat and deregister on shutdown |

Startup validation: the server refuses to start unless the CA chain and the
server certificate's SANs check out; near-expiry certificates produce warnings
in the log.

## 2. Prerequisites

- **Build**: GHC 9.10+ (verified with 9.14.1), `cabal` 3.x. On POSIX simply:
  ```sh
  cabal build exe:ModelMirrors
  # artifact: dist-newstyle/build/<plat>/ghc-<ver>/ModelMirrors-<v>/x/ModelMirrors/build/ModelMirrors/ModelMirrors
  ```
- **Runtime**: `apalache-mc` on `PATH`, or pointed at by `APALACHE_MC`.
  Each validate/explore session spawns an apalache JVM — budget ~2–4 GB RAM
  per concurrent session.
- **Locale**: apalache's config parser fails without UTF-8; export
  `LC_ALL=C.UTF-8` in the service environment.
- **Temp space**: per-session temp dirs (apalache run dirs, `_apalache-out`)
  land under `TMPDIR`/`TEMP`; give the service a writable, sizeable temp dir
  and clean it on restarts if you run many sessions.
- **Windows only**: the `unix` package does not build — the checkout needs the
  portability patch (CPP guards, `if !os(windows)` cabal stanza) and apalache
  must be launched via a shim `.exe` (see `deploy-r-windev.md` §3, §6).

## 3. TLS identity (mTLS)

Generate the private CA + server/client certs with the repo script:

```sh
scripts/gen-certs.sh <outdir> <host> [days]     # host may be a DNS name or IP
```

Output in `<outdir>`:

- `ca.crt` / `ca.key` — the CA; keep the key on the server only
- `server.crt` / `server.key` — SAN matches `<host>`; clients connect by that name/IP
- `client.crt` / `client.key` — client identity (`CN=modelmirrors-client`);
  one shared pair, or one pair per consumer for revocation granularity

Protect the keys: on POSIX `chmod 0600` (the server asserts this); on Windows
restrict the directory ACLs (`icacls <certs> /inheritance:r /grant:r
"SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F"`).

Clients pin the server cert by SHA-256 fingerprint:

```sh
openssl x509 -in server.crt -noout -fingerprint -sha256
# -> pass to validate as --pin sha256-<hex>  (optional hardening)
```

## 4. Running the server

### 4.1 Manual smoke run

```sh
LC_ALL=C.UTF-8 ./ModelMirrors --server 8999 \
  --tls --cert certs/server.crt --key certs/server.key --ca certs/ca.crt \
  --jobs 4 --bind 0.0.0.0
```

Logs (client drops, handshake failures, session errors, registry warnings) go
to stderr. The listener treats per-connection failures as survivable; only a
listener-level failure is fatal — restarting the process is the
orchestrator's job (hence the service wrapper below).

Plain TCP variant: `./ModelMirrors --serve 8999 [--bind 127.0.0.1]` — no TLS,
one session per connection, sequential accept loop.

### 4.2 systemd unit (POSIX)

```ini
# /etc/systemd/system/modelmirrors.service
[Unit]
Description=ModelMirrors mTLS mirror daemon
After=network-online.target

[Service]
ExecStart=/opt/modelmirrors/bin/ModelMirrors --server 8999 --tls \
  --cert /opt/modelmirrors/certs/server.crt \
  --key  /opt/modelmirrors/certs/server.key \
  --ca   /opt/modelmirrors/certs/ca.crt \
  --jobs 4 --bind 0.0.0.0
Environment=LC_ALL=C.UTF-8
Environment=APALACHE_MC=/opt/modelmirrors/bin/apalache-mc
Environment=TMPDIR=/var/tmp/modelmirrors
Restart=on-failure
RestartSec=5
User=modelmirrors
AmbientCapabilities=CAP_NET_BIND_SERVICE        # if using a port < 1024
StandardOutput=append:/var/log/modelmirrors/service.log
StandardError=append:/var/log/modelmirrors/service.log

[Install]
WantedBy=multi-user.target
```

```sh
sudo systemctl daemon-reload && sudo systemctl enable --now modelmirrors
```

POSIX builds also deregister from Consul on SIGINT/SIGTERM (Windows: normal
exits only — NSSM's graceful stop covers it).

### 4.3 Windows service (NSSM)

Install via a `.cmd` script (MSYS quoting mangles direct `nssm set` calls);
the working reference is `tools/setup-service.cmd` on the r-windev
deployment:

```bat
D:\tools\nssm.exe install ModelMirrors "D:\ModelMirrors\bin\ModelMirrors.exe"
D:\tools\nssm.exe set ModelMirrors AppDirectory "D:\ModelMirrors"
D:\tools\nssm.exe set ModelMirrors AppParameters "--server 8999 --tls --cert D:\ModelMirrors\certs\server.crt --key D:\ModelMirrors\certs\server.key --ca D:\ModelMirrors\certs\ca.crt --jobs 4"
D:\tools\nssm.exe set ModelMirrors AppExit Default Restart
D:\tools\nssm.exe set ModelMirrors AppRestartDelay 5000
D:\tools\nssm.exe set ModelMirrors AppStdout "D:\ModelMirrors\logs\service.out.log"
D:\tools\nssm.exe set ModelMirrors AppStderr "D:\ModelMirrors\logs\service.err.log"
D:\tools\nssm.exe set ModelMirrors AppRotateFiles 1
D:\tools\nssm.exe set ModelMirrors AppRotateBytes 10485760
D:\tools\nssm.exe set ModelMirrors AppEnvironmentExtra "APALACHE_MC=D:\ModelMirrors\bin\apalache-mc.exe" "TEMP=D:\ModelMirrors\tmp" "TMP=D:\ModelMirrors\tmp" "LC_ALL=C.UTF-8" "LANG=C.UTF-8" "PATH=<minimal path incl. java>"
D:\tools\nssm.exe set ModelMirrors Start SERVICE_AUTO_START
D:\tools\nssm.exe start ModelMirrors
```

Key points: explicit env block (the LocalSystem service shell has no useful
PATH; `java` must be reachable for the apalache launcher), temp redirected to
a service-owned directory, rotated logs, auto-restart after 5 s.

## 5. Optional: Consul registration

Add `--registry http://<consul-host>:8500` (or set `MODELMIRRORS_REGISTRY`).
The server then:

- registers itself as `modelmirrors-<hostname>-<port>` with its cert
  fingerprint, address, and port,
- heartbeats a 10 s TTL check,
- deregisters best-effort on shutdown,
- enforces fingerprint pinning: registration fails if the registry returns a
  pinned fingerprint that does not match the server's cert.

Clients discover mirrors with `validate --registry <url> ...` (mutually
exclusive with `--host`/`--port`); candidates are tried in order, and the
registry-advertised fingerprint is pinned unless `--pin` overrides it.

## 6. Verification checklist

After install or upgrade:

1. Service is running and the port is listening
   (`ss -ltnp | grep 8999` / `netstat -ano | findstr 8999`).
2. TLS handshake succeeds **with** a client cert, fails **without** one:
   ```sh
   openssl s_client -connect <host>:8999 -cert client.crt -key client.key \
     -CAfile ca.crt -tls1_3 </dev/null
   ```
3. Functional smoke — validate a known spec, expect `VALID`, exit 0:
   ```sh
   ./ModelMirrors validate --host <host> --port 8999 \
     --spec test/specs/HourClock.tla \
     --tls --cert client.crt --key client.key --ca ca.crt --pin <sha256>
   ```
4. Broken spec → `INVALID`, exit 1. Wrong CA / wrong `--pin` → exit 2
   (infrastructure).
5. Concurrency: `--jobs + 2` parallel validates all complete; per-session
   temp dirs are cleaned up (no orphan apalache JVMs afterwards).
6. Kill -9 the process → the wrapper restarts it within the restart delay.

## 7. Operations runbook

| Action | How |
|---|---|
| Status | `systemctl status modelmirrors` / `nssm status ModelMirrors` |
| Start / stop / restart | `systemctl start\|stop\|restart modelmirrors` / `nssm ...` |
| Logs | journalctl / `tail -f logs/service.err.log` |
| Health | openssl handshake (above) + `validate` smoke |
| Registry health | `curl http://<consul>:8500/v1/health/service/modelmirrors` |

**Upgrade**: build → stage the binary (`releases/v<ver>/`) → stop service →
rotate `bin/ModelMirrors(.prev)` to the new build → start → run §6 checklist.
On Windows, stop the service *before* `cabal build` if the build output path
is the same exe the service runs — a running instance locks the file and
linking fails with `Permission denied`.

**Rollback**: restore `.prev` binary (or previous release dir) → restart.

**Cert renewal**: re-run `gen-certs.sh` with the same host args (the CA is
reused when `ca.key` exists) → restart the service → redistribute
`client.crt`/`client.key` and, if the CA changed, `ca.crt` to consumers.

## 8. Sizing notes

- Each concurrent session = one apalache JVM (≈2–4 GB); `--jobs` should match
  the RAM budget, not the CPU count: `--jobs 4` ≈ up to 16 GB peak.
- Validate bounds are clamped server-side to `[1, 100]`; heavier exploration
  belongs in dedicated runs, not the shared daemon.
- Explorer servers bind ephemeral loopback ports per session — no extra
  inbound firewall rules needed for them.
