# Bazel Module Setup — Design Spec

**Date:** 2026-06-03
**Bazel:** 9.1.0 (bzlmod)
**GHC:** 9.10.3

## Goal

Add Bazel build support alongside the existing cabal build. Cabal remains for Hackage publishing and IDE (hie.yaml). Bazel becomes the primary/CI build.

## Approach

Minimal Bazel — hand-written BUILD files, Stackage snapshot for deps, apalache-mc as a Bazel toolchain.

## New Files

```
ModelMirrors/
├── MODULE.bazel              # bzlmod module declaration
├── MODULE.bazel.lock         # auto-generated
├── .bazelversion             # "9.1.0"
├── .bazelrc                  # build flags
├── BUILD.bazel               # root placeholder
├── src/BUILD.bazel           # haskell_library
├── app/BUILD.bazel           # haskell_binary
├── test/BUILD.bazel          # haskell_test
└── apalache-mc/              # toolchain for test runner
    ├── BUILD.bazel
    └── toolchain.bzl
```

No existing files are modified.

## MODULE.bazel

- Module name: `modelmirros`, version `0.1.0.0`
- Dep: `rules_haskell` (from GitHub, specific commit/tag supporting bzlmod)
- Dep: `rules_cc` (transitive)
- Stackage snapshot via `rules_haskell` `stack_snapshot` extension
  - Snapshot: nightly or LTS compatible with GHC 9.10.3 + base 4.20.x (LTS version determined during implementation)
  - Packages: aeson, bytestring, containers, directory, filepath, process, text, tasty, tasty-hunit, QuickCheck
- Local GHC toolchain: resolves via `ghc --print-libdir` from PATH
- GHC location pinned via `.bazelrc` `--repo_env=GHC=...`
- apalache-mc toolchain registered

## src/BUILD.bazel

- `haskell_library(name = "ModelMirros")`
- Exposes all 15 modules (matches cabal `exposed-modules`)
- Language: `GHC2024`
- Compiler flags: `-Wall`
- Deps from stackage: base, aeson, bytestring, containers, directory, filepath, process, text

## app/BUILD.bazel

- `haskell_binary(name = "ModelMirros")`
- Main: `Main.hs`
- Deps: `//src:ModelMirros`, containers, text

## test/BUILD.bazel

- `haskell_test(name = "ModelMirros-test")`
- Main: `Main.hs`
- Other modules: CommandSpec, TraceSpec, TypesSpec, ClientSpec, EngineSpec, MainSpec
- Deps: `//src:ModelMirros`, bytestring, containers, directory, process, tasty, tasty-hunit, text
- Data deps: `test/specs/*.tla` via `data` attribute, resolved via `$(rootpath ...)` runfile APIs
- apalache-mc toolchain provides `apalache-mc` on PATH during test execution

## apalache-mc Toolchain

- `toolchain_type(name = "apalache_mc_toolchain")`
- `apalache_mc_toolchain` rule that resolves `apalache-mc` from PATH
- Tests declare this toolchain as a dependency; test runner receives `apalache-mc` in PATH

## Build Targets

```
bazel build //src:ModelMirros       # library
bazel build //app:ModelMirros       # executable
bazel test  //test:ModelMirros-test # test suite
```

## .bazelrc

```
build --compiler=ghc-9.10.3
test  --test_output=all
build --repo_env=GHC=/home/nzsn/.ghcup/ghc/9.10.3/bin/ghc  # local dev only; override for CI
```

## Notes

- `rules_haskell` exact version/commit determined during implementation; must support bzlmod + GHC 9.10
- Test code currently uses relative paths to spec files (e.g. `"test/specs/HourClock.tla"`). When running under `bazel test`, tests execute from the runfiles tree. The test runner or BUILD file must provide an env var or argument pointing to the runfiles root so tests can locate `.tla` data deps.
- `apalache-mc` toolchain resolves from PATH; a `which apalache-mc` equivalent. Will fail at test time if not installed.

## Non-Goals

- Hermetic GHC via nix (future)
- Gazelle auto-generation
- Replacing cabal for IDE support (hie.yaml stays cabal cradle)
- Bazel build of TLA+ specs themselves (they are test data only)
