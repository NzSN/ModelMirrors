# ModelMirrors → r-windev: deployment design

Design only — no service changes made. Grounded in read-only probes of the
target box (`DESKTOP-6DKB5JD`, `192.168.150.219`) and in the current repo
state. A prior session already drafted most of this in
`docs/deploy-r-windev.md` and deployed a live instance; this document
consolidates that work, corrects it where the box disagrees, and lists the
remaining deltas.

---

## 0. Baseline reality (what already exists on the box)

The box is **not greenfield** — a v0.1.0.0 deployment is already running:

| Component | Current state |
|---|---|
| Service | NSSM service `ModelMirrors` — **Running**, Auto-start, LocalSystem, restart-on-exit + 5 s delay |
| Binary | `D:\ModelMirrors\bin\ModelMirrors.exe` (Aug 18), plus ad-hoc `.old*`/`.prev` copies |
| Launcher shim | `D:\ModelMirrors\bin\apalache-mc.exe` (85 KB) |
| Certs | `D:\ModelMirrors\certs\` — CA/server/client, SAN `IP:192.168.150.219`, generated Aug 15, **expires ~Nov 13, 2025** |
| Config | `AppParameters = --server 8999 --tls --cert/--key/--ca …\certs\… --jobs 4`; env block sets `APALACHE_MC`, `TEMP/TMP`, `LC_ALL/LANG=C.UTF-8`, minimal PATH incl. Oracle `javapath` |
| Source | `D:\ModelMirrors\src` = git clone @ `c904e5e`, with the portability patch **uncommitted**, plus stray untracked `ModelMirrors/` dir and `scripts/apalache-mc-shim.c` |
| Toolchain | ghcup GHC 9.14.1 + cabal 3.16 (`D:\Programs\ghcup\ghcup\bin`, on PATH); Oracle Java 21 (no `JAVA_HOME`); apalache **0.58.2** at `D:\Programs\apalache` (`bin` on PATH but only `.bat`/`.sh`); OpenSSL 3.5.6; Consul exe present, **no agent** |
| Ops artifacts | `logs\service.err.log` shows the expected noise (unauthenticated-handshake rejections + `recvBuf` client-drop lines); **two** `ModelMirrors.exe` processes were observed in Session 0 — needs the single-instance health check in §11 |

So the design below is the **target state**; §13 lists the deltas that remain
between it and what's deployed.

---

## 1. Target environment (probed facts)

| Fact | Value | Design consequence |
|---|---|---|
| OS | Win10 22H2 (19045.6456), Chinese locale, git-bash MINGW64 | JVM stdout charset = GBK → force `-Dfile.encoding=UTF-8`; drive ops via `.cmd`, not bash quoting |
| CPU/RAM | Ryzen 9 7950X, 63 GB, 32 logical CPUs | `--jobs 4` × apalache `-Xmx4096m` ≈ 16 GB peak — comfortable; headroom to raise later |
| Disk | **C: 13 GB free (95% full)**; D: 466 GB free | Everything — build store, TEMP, runtime — pinned to `D:` |
| GHC/cabal | 9.14.1 / 3.16.0.0 (ghcup) | Version parity with the workstation; `cabal.project` `allow-newer` already covers base 4.22 |
| Java | 21.0.11 via Oracle `javapath` on PATH, no `JAVA_HOME` | Service PATH must include `javapath`; apalache `.bat` needs it |
| apalache | 0.58.2 at `D:\Programs\apalache` (`.bat` + `.sh` + jar) | Code verified against 0.57 → **re-verify exit-code contract** (0/12/120/255) before trusting verdicts |
| Process spawn | Raw `CreateProcess` cannot run `.bat` (WinError 2/193) | Launcher shim required (§4) |
| Network | github.com/hackage reachable; firewall **OFF** on all profiles; 8999 and 8500 free | No inbound rule needed today; rule specified in §7 for hardening |
| Privileges | ssh shell is **ADMIN** | Service install allowed |
| WSL2 | Ubuntu distro present | Plan-B runtime (§13) |

---

## 2. Topology and ports

```
Clients (this workstation / LAN / CI)
   |  mTLS 1.3, JSON-lines over TCP — 192.168.150.219:8999
   v
ModelMirrors.exe   (NSSM service "ModelMirrors", LocalSystem, auto-restart)
   |  APALACHE_MC → D:\ModelMirrors\bin\apalache-mc.exe
   |     → cmd /c D:\Programs\apalache\bin\apalache-mc.bat
   |     → java -Xmx4096m -jar apalache.jar   (one JVM per session, cwd = per-session temp dir)
   v
apalache 0.58.2   (typecheck + check; explorer servers on ephemeral 127.0.0.1 ports)
   |
   +-- optional Phase-2: Consul agent 127.0.0.1:8500 (TTL 30 s check, 10 s heartbeat)
```

Ports: **8999** mTLS daemon · **8500** Consul agent (optional) · ephemeral
loopback ports for explorer servers (per session, killed with the shim's job
object).

---

## 3. Required repo changes (inputs to the pipeline)

The working tree already drafts all of these; they must be **committed and
tagged** to make the deployment reproducible (currently they exist only as
uncommitted changes in both checkouts).

1. **Portability patch** (`ModelMirrors.cabal`, `app/Main.hs`,
   `src-tls/Protocol/Transport/Tls.hs`, `src/Protocol/Transport/Tcp.hs`):
   `unix` is `buildable: False` on Windows. Gate `unix` behind
   `if !os(windows)`, add `default-extensions: CPP`, use
   `Network.Socket.getHostName` (or `COMPUTERNAME`) instead of
   `nodeName <$> getSystemID`, and guard the POSIX private-key `fileMode`
   checks with `#ifndef mingw32_HOST_OS` — on Windows, key protection is
   enforced by NTFS ACLs instead.
2. **Launcher shim** `scripts/apalache-mc-shim.c` (~60 lines C): contract
   below (§4).
3. **Service scripts** `scripts/setup-service.cmd`, `scripts/set-acls.cmd`:
   NSSM install/config and `icacls` cert lockdown (see §6/§7).
4. **Hygiene**: gitignore stray `*.hi`/`*.o`, remove the accidental nested
   `ModelMirrors/` dir in the remote clone, and version-bump before the next
   release.

---

## 4. apalache launcher shim (`apalache-mc.exe`)

`Apalache.Command.apalacheBin` honors `APALACHE_MC`, so the service env points
it at the shim. Contract:

1. Build `cmd.exe /c "D:\Programs\apalache\bin\apalache-mc.bat" <original args…>`
   from `GetCommandLineW`, preserving quoting (paths with spaces, e.g. temp
   dirs).
2. `CreateProcess` with inherited std handles (the mirror pipes them) and
   `CREATE_NO_WINDOW`.
3. Assign the child to a **Job Object with `KILL_ON_JOB_CLOSE`**: when the
   mirror `terminateProcess`es the shim (explorer-server teardown), the whole
   `cmd → java` tree dies — no orphan JVMs, no leaked ports.
4. `WaitForSingleObject`; **forward the exit code verbatim** — the 0/12/120/255
   contract drives the mirror's VALID/INVALID/infrastructure classification.

Build once with the GHC-bundled clang:
`clang --target=x86_64-unknown-windows-gnu -O2 -o apalache-mc.exe apalache-mc-shim.c`.

**Refinement over the existing doc**: add
`JAVA_TOOL_OPTIONS=-Dfile.encoding=UTF-8 -Duser.language=en` to the service
env block. The JVM on a Chinese-locale Windows defaults to GBK and ignores
`LC_ALL`; forcing UTF-8 keeps apalache's stderr (fed back into client
verdicts) parseable and ASCII-safe.

---

## 5. Build pipeline (on-box, native Windows build)

Cross-compiling GHC Linux→Windows is unsupported — build on the box. All
commands below are the exact `r_windev` forms (remember the `':; …'` prefix so
the wrapper's `bash -c` only eats the no-op `:`):

```sh
r_windev ':; export CABAL_DIR="D:\ModelMirrors\.cabal"; export TEMP="D:\ModelMirrors\tmp"; export TMP="D:\ModelMirrors\tmp"; echo env ok'
r_windev ':; cd /d/ModelMirrors/src && git -c core.autocrlf=false pull --ff-only && git log --oneline -1'
r_windev ':; cd /d/ModelMirrors/src && cabal update && cabal build exe:ModelMirrors 2>&1 | tail -5'
```

Artifact:
`dist-newstyle\build\x86_64-windows\ghc-9.14.1\ModelMirrors-0.1.1.0\x\ModelMirrors\ModelMirrors.exe`.

Release step (versioned, never in-place):

```sh
r_windev ':; mkdir -p /d/ModelMirrors/releases/v0.1.1.0 && cp /d/ModelMirrors/src/dist-newstyle/build/x86_64-windows/ghc-9.14.1/ModelMirrors-0.1.1.0/x/ModelMirrors/build/ModelMirrors/ModelMirrors.exe /d/ModelMirrors/releases/v0.1.1.0/ && sha256sum /d/ModelMirrors/releases/v0.1.1.0/ModelMirrors.exe'
```

Then copy to `bin\ModelMirrors.exe` only after the smoke test (§12). The
current ad-hoc `.old*` pile in `bin\` gets retired in favor of
`releases\<version>\` + a single `.prev`.

---

## 6. Windows service design (NSSM 2.24)

Wrapper: NSSM (already in `D:\ModelMirrors\tools`). Target config — **matches
what's installed**, plus the two starred refinements:

| Setting | Value |
|---|---|
| Application / AppDirectory | `D:\ModelMirrors\bin\ModelMirrors.exe` / `D:\ModelMirrors` |
| AppParameters | `--server 8999 --tls --cert D:\ModelMirrors\certs\server.crt --key …\server.key --ca …\ca.crt --jobs 4` |
| AppExit | Default → Restart, delay 5000 ms |
| Stdout/Stderr | `D:\ModelMirrors\logs\service.{out,err}.log`, rotate at 10 MB |
| AppEnvironmentExtra | `APALACHE_MC=…\bin\apalache-mc.exe`, `TEMP/TMP=D:\ModelMirrors\tmp`, `LC_ALL/LANG=C.UTF-8`, **★ `JAVA_TOOL_OPTIONS=-Dfile.encoding=UTF-8 -Duser.language=en`**, `PATH=C:\Windows\System32;C:\Windows;%Oracle javapath%` |
| Start / ObjectName | `SERVICE_AUTO_START` / LocalSystem (simplest given the certs are ACL'd to SYSTEM/Administrators; a dedicated low-priv account is the hardening option) |

Why the service env matters: the mirror spawns apalache per session, so
`APALACHE_MC`, Java's PATH entry, and UTF-8 forcing all propagate; `TEMP` on
`D:` keeps apalache's `_apalache-out`/`tmp` writes (which land in each child's
cwd anyway) off the 95%-full C: drive.

---

## 7. TLS identity and certificate lifecycle

- Generate on the box with git-bash (openssl 3.5.6 present):
  `gen-certs.sh certs 192.168.150.219 365` — the dotted quad becomes an `IP:`
  SAN, matching how clients reach the box. CA key never leaves the box.
- Client identity: one shared `client.crt/key` (`CN=modelmirrors-client`)
  distributed per consumer, or one pair per consumer later. Distribution from
  this workstation: `scp "windows-dev:D:/ModelMirrors/certs/ca.crt" …`
  (Windows-style path per the skill), then **verify `sha256sum` on both
  sides**.
- Server fingerprint for `--pin`:
  `openssl x509 -in server.crt -noout -fingerprint -sha256`.
- ACLs (replaces the POSIX `chmod 0600` check that the patch disables on
  Windows):
  `icacls D:\ModelMirrors\certs /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F"`.
- Renewal: re-run `gen-certs.sh` (CA is reused when `ca.key` exists) →
  restart service → redistribute `client.*`. **Current certs expire ~Nov 13,
  2025** — put a calendar reminder now.
- Hardening (firewall is currently OFF; when re-enabled):
  `netsh advfirewall firewall add rule name="ModelMirrors" dir=in action=allow protocol=TCP localport=8999`.

---

## 8. Client access patterns

From this workstation (or any consumer), after copying
`ca.crt`/`client.crt`/`client.key` locally:

```sh
# acceptance: expected VALID (exit 0)
ModelMirrors validate --host 192.168.150.219 --port 8999 \
  --spec test/specs/HourClock.tla --bound 10 \
  --tls --cert client.crt --key client.key --ca ca.crt [--pin <sha256>]

# negative: failing invariant → INVALID (exit 1); bad bound (0 or >100) / wrong CA → exit 2
```

Debug modes on the box itself: stdio mirror (default, pipe a session over
stdin) and `--serve <port>` plain TCP for no-cert local testing; `--jobs 4`
only affects the mTLS daemon path.

---

## 9. Optional Consul registry (Phase 2)

`D:\Programs\Consul\consul.exe` exists but no agent runs. Design: run
`consul agent -dev` (or a real config) as a second NSSM service on
127.0.0.1:8500; append `--registry http://127.0.0.1:8500` to AppParameters.
The code already handles Windows: service ID becomes
`modelmirrors-DESKTOP-6DKB5JD-8999`, registered with a 30 s TTL check and a
10 s heartbeat; registry outages never kill the accept loop
(registration/`heartbeatLoop` failures are swallowed by design). Defer until a
real discovery consumer exists.

---

## 10. Upgrade / rollback

1. Build + release under `releases\v<next>\` (§5), verify sha256.
2. Smoke test the new exe in `--serve` debug mode against `HourClock.tla`
   (VALID + INVALID + infra cases) **before** touching the service.
3. `nssm stop ModelMirrors` → copy `bin\ModelMirrors.exe` to
   `bin\ModelMirrors.exe.prev` → install new exe → `nssm start ModelMirrors`.
4. Rollback = stop, restore `.prev`, start. Verify single listener on 8999
   afterwards (§11).

---

## 11. Operations runbook (via `r_windev`)

```sh
r_windev ':; /d/ModelMirrors/tools/nssm.exe status ModelMirrors'
r_windev ':; netstat -ano | grep LISTEN | grep :8999'            # exactly ONE listener
r_windev ':; tasklist //fi "imagename eq ModelMirrors.exe"'      # exactly ONE process expected
r_windev ':; tail -20 /d/ModelMirrors/logs/service.err.log'
```

- **Single-instance invariant**: two `ModelMirrors.exe` PIDs were observed in
  Session 0. NSSM should own exactly one mirror; a second PID means a stuck
  instance during a restart cycle — investigate before upgrades.
- Log noise policy: `HandshakeFailed (… CertificateRequired)` and
  `recvBuf … invalid argument` lines are *expected* (unauthenticated probes /
  dropped clients are logged and survived by design) — triage only new,
  repeated exceptions.
- Disk watch: C: at 13 GB free — confirm no apalache/JVM output ever lands on
  C: (TEMP is redirected; watch for `java.io.tmpdir` drift if the JVM ignores
  `TMP`).
- Temp hygiene: per-session `--run-dir` dirs under `D:\ModelMirrors\tmp`
  should be empty between sessions; sweep orphans older than 1 day.
- Cert renewal: see §7 (expiry ~Nov 13, 2025).

---

## 12. Acceptance checklist

1. Service `ModelMirrors` Running + Auto; exactly one listener on 8999.
2. `validate` over mTLS → `VALID`, exit 0 (HourClock, bound 10).
3. Failing invariant → `INVALID`, exit 1; `--bound 0`/`101` → infrastructure
   exit 2 (no crash, service survives).
4. No client cert / wrong CA → handshake rejected, mirror keeps serving (log
   noise only).
5. Explorer/trace session torn down cleanly — **no orphan `java.exe`
   processes**, ephemeral ports freed (this validates the shim's job object).
6. apalache exit codes re-verified against **0.58.2** (code was qualified on
   0.57).
7. `releases\v0.1.1.0` contains the sha256-verified artifact; `bin\` holds
   current + `.prev` only.

---

## 13. Open decisions and risks

| Item | Risk / decision |
|---|---|
| apalache 0.58.2 vs verified 0.57 | Re-verify exit-code contract on the box; pin 0.57.x if any drift |
| Portability patch uncommitted (both checkouts) | Must be committed + tagged upstream, or the deployment is not reproducible from the public repo |
| C: at 13 GB free | All build/runtime/temp paths already on D:; monitor |
| Firewall OFF on all profiles | Rule ready in §7 for when it's re-enabled |
| `--jobs 4` sizing | Fine on 63 GB; raise only after measuring apalache peak RSS |
| WSL2 Ubuntu (Plan B) | If native-Windows issues ever block, the Linux binary + bash `apalache-mc` run unmodified under WSL2 with localhost forwarding — no shim needed, but the service model changes (Task Scheduler in WSL + `wsl --exec`, or run-on-boot via `/etc/wsl.conf`) |
| LocalSystem vs dedicated account | LocalSystem is acceptable given ACL'd certs; dedicated low-priv account is the hardening step |
| Two-process observation | Reconcile before the next upgrade (§11) |

The single real prerequisite is committing §3's patch + shim so the design is
fully reproducible; everything else on the box already conforms to this target
state.
