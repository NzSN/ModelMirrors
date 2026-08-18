# Deploying ModelMirrors to r-windev (DESKTOP-6DKB5JD)

Target: the Windows dev box reached via `r_windev` (`ssh windows-dev`,
192.168.150.219). This document is the deployment design: environment facts
(probed), the required portability patch, build pipeline, runtime layout,
Windows service design, TLS identity, optional Consul registry, operations
runbook, and the acceptance checklist.

## 1. Target environment (probed facts)

| Fact | Value | Impact |
|---|---|---|
| OS | Windows 10 22H2 (10.0.19045), Chinese locale, MSYS2 git-bash (MINGW64) | Console encoding; run setup via `.cmd`, not bash quoting |
| CPU / RAM | AMD Zen4+ (Family 25 Model 97), 66 GB RAM, ~35 GB free | `--jobs 4` is comfortable; each session is a JVM |
| Disk | C: 239 GB, **13 GB free (95% used)**; D: 3.7 TB, 467 GB free | **Everything (build, runtime, temp) goes on D:** |
| GHC | 9.14.1 via ghcup at `D:\Programs\ghcup\ghcup\ghc\9.14.1` (clang/lld C toolchain bundled) | Version parity with the local build (base 4.22); `cabal.project` allow-newer already covers it |
| cabal | 3.16.0.0 | fine |
| Java | 21.0.11 LTS (Oracle, `javapath` on system PATH, **no `JAVA_HOME`**) | apalache `.bat` uses `java` from PATH — service env must include `javapath` |
| apalache | **0.58.2** at `D:\Programs\apalache` (`bin/apalache-mc.bat` + `.sh`, `lib/apalache.jar`) | Not on PATH; code was verified against 0.57 → verify exit codes, pin 0.57.x if needed |
| Consul | `D:\Programs\Consul\consul.exe` present, **no agent running** | Registry feature available but currently unused |
| `unix` package | **NOT in the GHC 9.14.1 Windows package DB** (`unix.cabal`: `buildable: False` on Windows) | **Portability patch required** (section 3) |
| Spawning `.bat` | Raw process create fails (`WinError 2/193`); MSYS git-bash present; `openssl`, `unzip`, `tar` present; **no rsync, no pacman, no nssm, no pwsh** (PowerShell 5.1 `powershell.exe` exists) | apalache launcher **shim required** (section 4.2) |
| Network | github.com, hackage, downloads.haskell.org reachable; repo `NzSN/ModelMirrors` is public | Clone/build/download all fine |
| Firewall | All profiles **OFF**; ports 8999 and 8500 free (netstat verified) | No inbound rule needed today; hardening option in section 8 |
| Privileges | Current ssh shell is **ADMIN** | Can install services |
| SSH note | ControlMaster socket bind denied under sandbox → use `ssh -o ControlMaster=no` | ops detail only |

## 2. Topology

```
Clients (LAN / CI / MirrorECMA, MirrorRust)
   |  mTLS 1.3, JSON-lines over TCP :8999
   v
ModelMirrors.exe  (Windows service "ModelMirrors", NSSM, LocalSystem, auto-restart)
   |  APALACHE_MC -> D:\ModelMirrors\bin\apalache-mc.exe (shim)
   |                -> cmd /c D:\Programs\apalache\bin\apalache-mc.bat
   |                -> java -jar apalache.jar   (per-session JVM, cwd = per-session temp dir)
   v
apalache 0.58.2  (validate/check + explorer server on ephemeral 127.0.0.1 ports)
   |
   +-- optional: Consul agent on 127.0.0.1:8500  (TTL 30s check, 10s heartbeat)
```

Ports: **8999** (mTLS daemon, verified free), 8500 (Consul agent, optional),
ephemeral loopback ports for explorer servers (per-session).

## 3. Portability patch (required — repo change)

`unix` cannot be built on Windows (Hackage `unix-2.8.8.0`: `buildable: False`
under `os(windows)`), and the Windows GHC bindist ships `Win32` instead. Two
modules import `unix`; both get a minimal, behavior-preserving change:

### 3.1 `ModelMirrors.cabal`

- Library: remove `unix >=2.8` from the shared `build-depends` list; add

  ```cabal
  if !os(windows)
      build-depends: unix >=2.8
  ```

- Library: add `default-extensions: CPP` (enables the guard below without any
  `{-# LANGUAGE #-}` pragma, preserving the project's no-pragmas rule).

- Executable: remove `unix,` from its `build-depends`; add

  ```cabal
  if !os(windows)
      build-depends: unix
  ```

  and add `network` to the executable's unconditional deps (for
  `Network.Socket.getHostName`).

### 3.2 `app/Main.hs`

- Replace `import System.Posix.Unistd (getSystemID, nodeName)` with
  `import Network.Socket (getHostName)`.
- In `serveOne`: `host <- getHostName` instead of `nodeName <$> getSystemID`.
  Identical result on Windows (gethostname → `DESKTOP-6DKB5JD`); service id
  stays `modelmirrors-DESKTOP-6DKB5JD-8999`.

### 3.3 `src-tls/Protocol/Transport/Tls.hs`

- Guard the import: `#ifndef mingw32_HOST_OS` around
  `import System.Posix.Files (fileMode, getFileStatus)`.
- Guard the two private-key mode checks in `mkServerParams`/`mkClientParams`
  (lines ~111–114 and ~141–144) the same way; on Windows the check is skipped
  (NTFS has no POSIX group/other bits; the MSYS `chmod 0600` emulation is not
  something `fileMode` can be trusted with). Windows protection instead comes
  from ACLs on `D:\ModelMirrors\certs` (section 7).

Result: identical behavior on POSIX; on Windows the only loss is the
best-effort key-mode assertion.

## 4. Build pipeline (on r-windev, native Windows build)

Cross-compiling GHC from Linux to Windows is not supported — build on the box.

```sh
# keep C: (13 GB free!) out of the picture
export CABAL_DIR='D:\ModelMirrors\.cabal'
export TEMP='D:\ModelMirrors\tmp' TMP='D:\ModelMirrors\tmp'

mkdir -p /d/ModelMirrors/{src,bin,certs,logs,tmp,releases,tools}
git clone https://github.com/NzSN/ModelMirrors.git /d/ModelMirrors/src

cd /d/ModelMirrors/src
cabal update
cabal build exe:ModelMirrors      # ~10–30 min first time (dep download + compile)
```

Artifact (cabal 3.16 / GHC 9.14.1 / Windows):
`dist-newstyle\build\x86_64-windows\ghc-9.14.1\ModelMirrors-0.1.1.0\x\ModelMirrors\ModelMirrors.exe`

Notes:
- Remote GHC 9.14.1 == local GHC 9.14.1 (local store shows the same version),
  so the `allow-newer: serialise:base, ...` lines in `cabal.project` apply.
- crypton's C stubs compile with the GHC-bundled clang (`--target=x86_64-unknown-windows-gnu`,
  lld) — verified present via `ghc --info`.
- The full test suite can run on the box too (`cabal test all` with
  `APALACHE_MC` pointing at the shim, section 4.2); it is optional for
  deployment — the acceptance checklist (section 10) covers the critical paths.
- Ship the exe as `D:\ModelMirrors\releases\v0.1.1.0\ModelMirrors.exe` and
  copy to `D:\ModelMirrors\bin\ModelMirrors.exe` (upgrade/rollback, section 9).

## 5. Runtime layout

```
D:\ModelMirrors\
├── bin\
│   ├── ModelMirrors.exe          # current server binary
│   ├── ModelMirrors.exe.prev     # previous binary (rollback)
│   └── apalache-mc.exe           # launcher shim (section 4.2)
├── releases\v0.1.1.0\…           # versioned binaries
├── certs\                        # gen-certs.sh output (ACL-restricted)
├── logs\                         # service stdout/stderr, rotated
├── tmp\                          # TEMP/TMP for the service (per-session apalache dirs)
├── tools\                        # nssm.exe (+ unzip cache)
├── consul\                       # Consul data/conf (only if registry enabled)
├── .cabal\                       # CABAL_DIR (build only)
└── src\                          # git clone (build only)
```

## 6. The apalache launcher shim (`apalache-mc.exe`)

Windows `CreateProcess` (used by the Haskell `process` library) cannot run a
`.bat`/`.cmd` — confirmed on the box (`subprocess.run(["apalache-mc", …])` →
`WinError 2` even with the `.bat` on PATH). The mirror always launches
`apalacheBin` via `proc`/`readProcessWithExitCode`/`createProcess`
(`Apalache.Command.apalacheBin`, honoring the `APALACHE_MC` override). So we
ship a tiny C shim named `apalache-mc.exe` and set
`APALACHE_MC=D:\ModelMirrors\bin\apalache-mc.exe` in the service env.

Shim contract (≈60 lines of C, compiled once with the GHC-bundled clang):

1. Build the command line
   `cmd.exe /c "D:\Programs\apalache\bin\apalache-mc.bat" <original args…>`
   (use `GetCommandLineW`/`lpCmdLine` tail, not `argv`, to preserve quoting).
2. `CreateProcess` with `STARTF_USESTDHANDLES` inheriting stdin/stdout/stderr
   (the mirror pipes/redirects these) and `CREATE_NO_WINDOW`.
3. Create a **Job Object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`** and assign
   the child: when the mirror `terminateProcess`s the shim (explorer server
   teardown), the whole `cmd → java` tree dies — no orphan JVMs, no leaked
   ports.
4. `WaitForSingleObject`, forward the **exit code verbatim** (apalache's
   exit-code contract — 0 / 12 / 120 / 255 — drives the mirror's
   VALID/INVALID/infrastructure classification).

Compile (from git-bash):

```sh
clang --target=x86_64-unknown-windows-gnu -O2 -o apalache-mc.exe shim.c
# clang at D:\Programs\ghcup\ghcup\ghc\9.14.1\mingw\bin\clang.exe
# (fallback: D:\Programs\Perl\c\bin\gcc.exe — MinGW-W64 13.2.0)
```

The shim also makes `cabal test all` feasible on the box (tests spawn
`apalache-mc`).

## 7. TLS identity (mTLS 1.3)

```sh
cd /d/ModelMirrors && /d/ModelMirrors/src/scripts/gen-certs.sh certs 192.168.150.219 90
```

- `ca.crt` / `ca.key` — CA (key stays on the box, ACL-restricted).
- `server.crt` / `server.key` — SAN `IP:192.168.150.219` (the case in
  `gen-certs.sh` maps a dotted quad to an IP SAN; clients connect by IP).
- `client.crt` / `client.key` — single shared client identity
  (`CN=modelmirrors-client`) distributed to every consumer, or one pair per
  consumer later.
- Server command:
  `--server 8999 --tls --cert certs\server.crt --key certs\server.key --ca certs\ca.crt --jobs 4`
- Clients: `--tls --cert client.crt --key client.key --ca ca.crt [--pin <SHA256 of server.crt>]`
  (`openssl x509 -in server.crt -noout -fingerprint -sha256`).
- Renewal: re-run `gen-certs.sh` with the same args (CA is reused when
  `ca.key` exists), restart the service, redistribute `client.*` to consumers.
  The TLS module logs near-expiry warnings.
- Windows ACLs: restrict `D:\ModelMirrors\certs` to Administrators / SYSTEM
  (`icacls D:\ModelMirrors\certs /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F"`).
  The in-code `chmod 0600` assertion is skipped on Windows by the patch (3.3).

## 8. Windows service design

**Wrapper: NSSM 2.24** (battle-tested: auto-restart, env block, log rotation).
Not installed — download from nssm.cc (network verified open). Fallbacks if
nssm.cc is unreachable: WinSW (single exe + XML config, GitHub) or Task
Scheduler (`schtasks /create /ru SYSTEM /sc ONSTART /rl HIGHEST` +
restart-on-failure settings — zero download, clunkier env/log handling).

Because MSYS mangles `D:\...` arguments, drive setup from a `.cmd` script
(created locally, copied with scp) run as `cmd //c D:\ModelMirrors\tools\setup-service.cmd`:

```bat
REM NSSM will not create parent dirs for log files, and the env block
REM below points TEMP/TMP at D:\ModelMirrors\tmp — create both up front.
if not exist D:\ModelMirrors\logs md D:\ModelMirrors\logs
if not exist D:\ModelMirrors\tmp  md D:\ModelMirrors\tmp
D:\ModelMirrors\tools\nssm.exe install ModelMirrors "D:\ModelMirrors\bin\ModelMirrors.exe"
D:\ModelMirrors\tools\nssm.exe set ModelMirrors AppDirectory "D:\ModelMirrors"
D:\ModelMirrors\tools\nssm.exe set ModelMirrors AppParameters "--server 8999 --tls --cert D:\ModelMirrors\certs\server.crt --key D:\ModelMirrors\certs\server.key --ca D:\ModelMirrors\certs\ca.crt --jobs 4"
REM add "--registry http://127.0.0.1:8500" when Consul is enabled
D:\ModelMirrors\tools\nssm.exe set ModelMirrors AppExit Default Restart
D:\ModelMirrors\tools\nssm.exe set ModelMirrors AppRestartDelay 5000
D:\ModelMirrors\tools\nssm.exe set ModelMirrors AppStdout "D:\ModelMirrors\logs\service.out.log"
D:\ModelMirrors\tools\nssm.exe set ModelMirrors AppStderr "D:\ModelMirrors\logs\service.err.log"
D:\ModelMirrors\tools\nssm.exe set ModelMirrors AppRotateFiles 1
D:\ModelMirrors\tools\nssm.exe set ModelMirrors AppRotateBytes 10485760
D:\ModelMirrors\tools\nssm.exe set ModelMirrors AppEnvironmentExtra "APALACHE_MC=D:\ModelMirrors\bin\apalache-mc.exe" "TEMP=D:\ModelMirrors\tmp" "TMP=D:\ModelMirrors\tmp" "LC_ALL=C.UTF-8" "LANG=C.UTF-8" "JAVA_TOOL_OPTIONS=-Dfile.encoding=UTF-8 -Duser.language=en" "PATH=C:\Windows\System32;C:\Windows;C:\Program Files\Common Files\Oracle\Java\javapath"
D:\ModelMirrors\tools\nssm.exe set ModelMirrors Start SERVICE_AUTO_START
D:\ModelMirrors\tools\nssm.exe set ModelMirrors ObjectName LocalSystem
D:\ModelMirrors\tools\nssm.exe start ModelMirrors
```

Design rationale, mapped to the code:

- **LocalSystem + explicit env block**: the mirror needs `apalache-mc`
  (via `APALACHE_MC`), `java` (the `.bat` calls `java` from PATH), a writable
  `TEMP` (the `temporary` package + apalache's `_apalache-out`/`tmp` land in
  the per-session cwd = temp dir), and a UTF-8 locale (apalache's config
  parser; Java 21 defaults to UTF-8 anyway, belt and braces).
- **`--jobs 4`**: bounded dispatcher (`serveTlsConcurrent`), i.e. at most 4
  apalache JVMs (≈2–4 GB each at `-Xmx4096m`); 66 GB RAM is ample.
- **Auto-restart**: a listener failure is fatal by design ("process restart is
  the orchestrator's job") — NSSM restarts with a 5 s delay.
- **stdout/stderr → rotated files**: the mirror logs client drops, handshake
  failures, session errors, and registration warnings to stderr.
- **Per-session isolation**: cwd-pinned run dirs (Command.hs) keep every
  apalache session's output inside `D:\ModelMirrors\tmp\...`, removed at
  session end — no C: growth, no cross-session contamination.

## 9. Operations runbook

| Action | Command (on r-windev) |
|---|---|
| Status | `D:\ModelMirrors\tools\nssm.exe status ModelMirrors` (or `sc query ModelMirrors`) |
| Start / stop / restart | `nssm start\|stop\|restart ModelMirrors` |
| Logs | `tail -f /d/ModelMirrors/logs/service.err.log` |
| Health (TLS handshake) | `openssl s_client -connect 192.168.150.219:8999 -cert client.crt -key client.key -CAfile ca.crt -tls1_3 </dev/null` |
| Health (functional) | `ModelMirrors validate --host 192.168.150.219 --port 8999 --spec test/specs/HourClock.tla --tls --cert client.crt --key client.key --ca ca.crt --pin <fp>` → `VALID`, exit 0 |
| Registry (if enabled) | `curl http://127.0.0.1:8500/v1/health/service/modelmirrors` |

**Upgrade**: `git -C /d/ModelMirrors/src pull` → `cabal build exe:ModelMirrors`
→ copy artifact to `releases\v<ver>\` and `bin\ModelMirrors.exe` (keep
`bin\ModelMirrors.exe.prev`) → `nssm restart ModelMirrors` → acceptance smoke.

**Rollback**: copy `ModelMirrors.exe.prev` over `ModelMirrors.exe` → restart.

**Cert renewal**: re-run `gen-certs.sh` (same host/args, CA reused) → restart
service → redistribute `client.crt/key` + new `ca.crt` to consumers (CA
reused only if `ca.key` kept; otherwise redistribute everything).

**apalache upgrade**: swap the `.bat` path baked into the shim (or re-point
`APALACHE_MC` at a new shim); re-run the acceptance checklist.

## 10. Verification & acceptance checklist

1. Build on r-windev succeeds after the portability patch (section 3).
2. `ModelMirrors.exe --server … --tls …` starts; service is AUTO_START.
3. TLS handshake from a client (openssl s_client) succeeds with client cert;
   fails without a client cert.
4. `validate` against `HourClock.tla` → `VALID`, exit 0 (valid path).
5. A deliberately broken spec (e.g. wrong `--init` name) → `INVALID`, exit 1.
6. Wrong CA / wrong `--pin` → exit 2 (infrastructure), logged, session ends.
7. Concurrency: 6 parallel `validate` runs against `--jobs 4` — all complete,
   no cross-session contamination (isolated run dirs).
8. Resilience: `taskkill /F /IM ModelMirrors.exe` → NSSM restarts within ~5 s;
   a client drop mid-session doesn't kill the listener.
9. Explorer flow smoke test via a real client (MirrorECMA or the reference
   Haskell client) — `register_explore_session` round-trip; verify no orphan
   `java` after teardown (`tasklist | findstr java`).
10. apalache 0.58.2 exit-code contract matches the mirror's classification
    (0/12/120/255; "Output directory:" line) — if not, **pin apalache 0.57.x**
    (zip from GitHub releases → `D:\Programs\apalache-0.57.x`, re-point shim).
11. Registry (if enabled): service appears healthy in Consul; stopping the
    service flips the check within ~40 s (30 s TTL + 10 s heartbeat).
12. Log rotation: `service.err.log` rolls at 10 MB.

## 11. Risks & mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| `unix` not buildable on Windows | certain | Patch (section 3), small and behavior-preserving |
| `.bat` launcher not spawnable | certain | Shim exe + job object (section 6) |
| apalache 0.58.2 differs from verified 0.57 | medium | Acceptance items 4/5/10; pin 0.57.x fallback |
| C: fills up (13 GB free) | medium | CABAL_DIR, TEMP/TMP, all data on D:; NSSM log rotation |
| MSYS arg mangling breaks setup | certain if bash-driven | All service setup via `.cmd` scripts |
| Orphan JVMs after explorer teardown | high without shim | Job object `KILL_ON_JOB_CLOSE` |
| Windows Firewall currently OFF | note | Enable + inbound rule for 8999 (trusted LAN only); revisit if exposing beyond LAN |
| Antivirus/Defender interference | low | Exclude `D:\ModelMirrors` from scanning |
| `chmod 0600` assertion on Windows | certain | Skipped by patch; ACLs on `certs\` instead |
| Service PATH too small | certain if ignored | Explicit env block in NSSM |

## 12. Decisions to confirm

1. **Port**: 8999 (default proposal; free on the box).
2. **Registry**: enable the local Consul agent (binary already installed) or
   keep the deployment registry-free.
3. **Cert validity**: 90 days (renewal cycle) vs 365.
4. **Service account**: LocalSystem (proposed) vs dedicated low-privilege user.
5. **apalache**: keep 0.58.2 (pending acceptance) vs pin 0.57.x up front.
6. **Client credentials**: one shared `client.crt` for all consumers vs one
   pair per consumer.
