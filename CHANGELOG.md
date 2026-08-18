# Revision history for ModelMirrors

## 0.1.1.0 -- 2026-08-18

* Windows portability: CPP-gate the unix dependency and POSIX-only code,
  prefer an IPv4 listener, and require client certificates for mTLS.
* Rework the TLS backend for Windows (Handle reads with raw-sendAll writes).
* Add the apalache launcher shim (scripts/apalache-mc-shim.c): wraps the
  .bat via cmd.exe inside a KILL_ON_JOB_CLOSE job object and forwards exit
  codes verbatim.
* Add NSSM service setup and certificate ACL lockdown scripts
  (scripts/setup-service.cmd, scripts/set-acls.cmd).
* Add the Windows deployment guide (docs/deploy-r-windev.md).

## 0.1.0.0 -- YYYY-mm-dd

* First version. Released on an unsuspecting world.
