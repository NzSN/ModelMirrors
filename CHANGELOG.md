# Revision history for ModelMirrors

## Unreleased

* Add `--bind <addr>` to `--server` (and optionally `--serve`), so the mTLS
  and TCP daemons can bind a specific interface instead of the wildcard.
* Refactor `--server` parsing into a pure, order-independent parser
  (`Protocol.ServerOpts`) with clear errors for unknown/duplicate/invalid
  options.
* Registry URL can now come from the `MODELMIRRORS_REGISTRY` environment
  variable (explicit `--registry` still wins).
* `--server` now deregisters best-effort on shutdown: `SIGINT`/`SIGTERM` and
  normal exits on POSIX, normal exits only on Windows. Registration now fails
  startup if the server certificate fingerprint cannot be computed.
* `validate --registry <url>` performs mTLS service discovery: it tries each
  discovered candidate in order (pinning the registry fingerprint unless
  `--pin` overrides it) and exits 2 if no candidate is reachable.
* Startup validation for the mTLS server: the certificate chain must validate
  against the CA file and the leaf must carry a non-empty Subject Alternative
  Name.

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
