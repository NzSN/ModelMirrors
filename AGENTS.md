# AGENTS.md

## Build & Test

```sh
cabal build all    # build library + executable
cabal test all     # run tests
```

There is no lint, format, typecheck, or CI config. Build with `-Wall` (set in `.cabal`). To make warnings fatal: `cabal build --ghc-options=-Werror`.

## Prerequisites

- GHC 9.12+ (`base ^>= 4.22.0.0` in `ModelMirros.cabal`)
- `apalache-mc` on `PATH` (tests shell out to it)

## Package Structure (single package)

- Package name: **`ModelMirros`** (missing 'r' — intentional typo in `ModelMirros.cabal`)
- Library: exposes `Apalache`, `Apalache.Types`, `Apalache.Command`, `Apalache.Trace`
- Executable: `app/Main.hs` — currently a stub
- Tests: `test/Main.hs` — hand-written `IO ()` runners, no test framework
- Test spec: `test/specs/HourClock.tla` (real TLA+ spec used by tests)

## Testing Notes

Tests are integration tests that invoke `apalache-mc` on `test/specs/HourClock.tla` — typecheck + model check + trace generation. Expect seconds to minutes runtime. `apalache-mc` must be on `PATH` or tests will fail.

Run a single test by calling its spec function from `test/Main.hs` via `cabal repl`.

## Key Quirks

- No lockfile, no stack, no nix — plain `cabal` only
- `Protocol/` directory exists but is empty (IPC layer not yet implemented)
- `src/MyLib.hs` is not in `exposed-modules` (dead code / internal helper)
