# Bazel Module Setup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Bazel 9.1.0 bzlmod build support alongside existing cabal build for GHC 9.10.3.

**Architecture:** Single bzlmod module pulling `rules_haskell` for Haskell compilation, a Stackage snapshot for dependencies, GHC 9.10.3 toolchain via bindist or local PATH, and a lightweight `apalache-mc` repo rule for test execution.

**Tech Stack:** Bazel 9.1.0, rules_haskell (bzlmod), GHC 9.10.3, Stackage snapshot

---

## File Structure

| File | Purpose |
|---|---|
| `.bazelversion` | Pin Bazel version to `9.1.0` |
| `.bazelrc` | Build flags, GHC bindist config, test output settings |
| `MODULE.bazel` | bzlmod module: rules_haskell, GHC toolchain, stack_snapshot deps |
| `BUILD.bazel` (root) | Placeholder / alias |
| `src/BUILD.bazel` | `haskell_library` — all 15 modules |
| `app/BUILD.bazel` | `haskell_binary` — stub executable |
| `test/BUILD.bazel` | `haskell_test` — 6 test modules + TLA+ data deps |
| `apalache-mc/repo.bzl` | Repository rule to find `apalache-mc` on PATH |
| `apalache-mc/BUILD.bazel` (template) | `sh_binary` wrapping `apalache-mc` |
| `WORKSPACE.bazel` | Empty (required by bzlmod) |

No existing files are modified.

---

### Task 1: Bootstrap — .bazelversion, .bazelrc, WORKSPACE.bazel, root BUILD.bazel

**Files:**
- Create: `.bazelversion`
- Create: `.bazelrc`
- Create: `WORKSPACE.bazel`
- Create: `BUILD.bazel`

- [ ] **Step 1: Create `.bazelversion`**

```
9.1.0
```

- [ ] **Step 2: Create `.bazelrc`**

```
# Test output
test --test_output=errors

# Build options
build --experimental_ui_event_max_actions=10000
```

- [ ] **Step 3: Create empty `WORKSPACE.bazel`**

```python
# Required for bzlmod compatibility.
# All configuration is in MODULE.bazel.
```

- [ ] **Step 4: Create root `BUILD.bazel`**

```python
load("@rules_haskell//haskell:defs.bzl", "haskell_toolchain_library")
```

(Minimal — a placeholder. Actual targets in subdirectories.)

- [ ] **Step 5: Verify Bazel 9.1.0**

Run: `bazel version`
Expected: `Build label: 9.1.0`

- [ ] **Step 6: Commit**

```bash
git add .bazelversion .bazelrc WORKSPACE.bazel BUILD.bazel
git commit -m "chore: add Bazel bootstrap files (.bazelversion, .bazelrc, WORKSPACE, root BUILD)"
```

---

### Task 2: MODULE.bazel — bzlmod module with rules_haskell

**Files:**
- Create: `MODULE.bazel`

- [ ] **Step 1: Discover rules_haskell version in BCR**

Run: `bazel help module 2>&1` (will report available versions once MODULE.bazel exists)
Alternative: check `https://registry.bazel.build/modules/rules_haskell`

For this plan we target `rules_haskell` at a recent commit on `master` (supports bzlmod, GHC 9.10.3). Use `archive_override` as fallback if BCR version is stale.

- [ ] **Step 2: Create `MODULE.bazel` with module declaration and deps**

```python
module(
    name = "modelmirros",
    version = "0.1.0.0",
)

bazel_dep(name = "rules_haskell", version = "0.22")
bazel_dep(name = "rules_cc", version = "0.0.9")
bazel_dep(name = "platforms", version = "0.0.10")
bazel_dep(name = "bazel_skylib", version = "1.7.1")

# If rules_haskell 0.22 is not in BCR, replace the bazel_dep line above with:
# bazel_dep(name = "rules_haskell", version = "0.22")
# archive_override(
#     module_name = "rules_haskell",
#     urls = ["https://github.com/tweag/rules_haskell/archive/refs/heads/master.tar.gz"],
#     integrity = "sha256-<FILL>",
#     strip_prefix = "rules_haskell-master",
# )
```

- [ ] **Step 3: Add rules_haskell_dependencies extension**

Append to `MODULE.bazel` (before toolchains):

```python
# Internal dependencies for rules_haskell
rules_haskell_dependencies = use_extension(
    "@rules_haskell//extensions:rules_haskell_dependencies.bzl",
    "rules_haskell_dependencies",
)
use_repo(
    rules_haskell_dependencies,
    "Cabal",
    "os_info",
    "rules_haskell_stack",
    "rules_haskell_stack_update",
    "rules_haskell_worker_dependencies",
)
```

- [ ] **Step 4: Add GHC version + toolchain extensions**

Append to `MODULE.bazel`:

```python
# Pin GHC to 9.10.3 (used by bindists and stack_snapshot)
ghc_version = use_extension(
    "@rules_haskell//extensions:ghc_version.bzl",
    "ghc_default_version",
)
ghc_version.set(version = "9.10.3")
use_repo(ghc_version, "rules_haskell_ghc_version")

# GHC 9.10.3 toolchain — downloaded by rules_haskell bindists extension
haskell_toolchains = use_extension(
    "@rules_haskell//extensions:haskell_toolchains.bzl",
    "haskell_toolchains",
)
haskell_toolchains.bindists()
# If bindists() supports a direct version arg, use: bindists(version = "9.10.3")
# The version is otherwise picked up from the ghc_version extension above.
use_repo(haskell_toolchains, "all_bindist_toolchains")
register_toolchains("@all_bindist_toolchains//:all")
```

- [ ] **Step 4: Add stack_snapshot extension for Haskell deps**

Append to `MODULE.bazel`:

```python
# Haskell dependencies via Stackage snapshot
stack_snapshot = use_extension(
    "@rules_haskell//extensions:stack_snapshot.bzl",
    "stack_snapshot",
)

# Library + executable deps
stack_snapshot.package(name = "aeson")
stack_snapshot.package(name = "bytestring")
stack_snapshot.package(name = "containers")
stack_snapshot.package(name = "directory")
stack_snapshot.package(name = "filepath")
stack_snapshot.package(name = "process")
stack_snapshot.package(name = "text")

# Test deps
stack_snapshot.package(name = "tasty")
stack_snapshot.package(name = "tasty-hunit")

# Snapshot — needs a stackage snapshot YAML; create in Task 3
stack_snapshot.snapshot(local_snapshot = "@modelmirros//:stackage_snapshot.yaml")

use_repo(stack_snapshot, "stackage", "stackage-exe", "stackage-extra-deps")
```

- [ ] **Step 5: Commit**

```bash
git add MODULE.bazel
git commit -m "chore: add MODULE.bazel with rules_haskell, GHC 9.10.3 toolchain, stackage snapshot"
```

---

### Task 3: Stackage snapshot YAML for GHC 9.10.3

**Files:**
- Create: `stackage_snapshot.yaml`

- [ ] **Step 1: Determine a compatible Stackage snapshot**

GHC 9.10.3 shipped with base 4.20.x. As of 2026, check for a stable LTS or nightly:

- Nightly: `nightly-2026-01-01` (or whatever latest nightly uses GHC 9.10)
- Or a pinned LTS if one exists for GHC 9.10

The snapshot must include all packages: aeson, bytestring, containers, directory, filepath, process, text, tasty, tasty-hunit. These are all core/common packages available in any snapshot.

- [ ] **Step 2: Create `stackage_snapshot.yaml`**

Snapshots can be inline YAML. For a nightly-based approach:

```yaml
resolver: nightly-2026-05-01
packages:
  - aeson
  - bytestring
  - containers
  - directory
  - filepath
  - process
  - text
  - tasty
  - tasty-hunit
```

Note: if the snapshot resolver string doesn't match a valid Stackage release, fall back to `stack_snapshot.snapshot(snapshot = "lts-22.0")` or similar, and adjust during `bazel build` testing.

- [ ] **Step 3: Commit**

```bash
git add stackage_snapshot.yaml
git commit -m "chore: add stackage_snapshot.yaml for GHC 9.10.3 package resolution"
```

---

### Task 4: src/BUILD.bazel — haskell_library

**Files:**
- Create: `src/BUILD.bazel`

- [ ] **Step 1: Create `src/BUILD.bazel`**

```python
load("@rules_haskell//haskell:defs.bzl", "haskell_library")

haskell_library(
    name = "ModelMirros",
    srcs = glob(["**/*.hs"]),
    compiler_flags = ["-Wall"],
    default_language = "GHC2024",
    deps = [
        "@stackage//:aeson",
        "@stackage//:base",
        "@stackage//:bytestring",
        "@stackage//:containers",
        "@stackage//:directory",
        "@stackage//:filepath",
        "@stackage//:process",
        "@stackage//:text",
    ],
)
```

- [ ] **Step 2: Test build**

Run: `bazel build //src:ModelMirros`

If dependency resolution fails (missing packages from snapshot), adjust `stackage_snapshot.yaml` or the `stack_snapshot.package()` calls in `MODULE.bazel`.

Expected: library compiles with GHC 9.10.3, all 15 modules compiled.

- [ ] **Step 3: Commit**

```bash
git add src/BUILD.bazel
git commit -m "chore: add src/BUILD.bazel — haskell_library with 15 modules"
```

---

### Task 5: app/BUILD.bazel — haskell_binary

**Files:**
- Create: `app/BUILD.bazel`

- [ ] **Step 1: Create `app/BUILD.bazel`**

```python
load("@rules_haskell//haskell:defs.bzl", "haskell_binary")

haskell_binary(
    name = "ModelMirros",
    srcs = ["Main.hs"],
    compiler_flags = ["-Wall"],
    default_language = "GHC2024",
    deps = [
        "//src:ModelMirros",
        "@stackage//:base",
        "@stackage//:containers",
        "@stackage//:text",
    ],
)
```

- [ ] **Step 2: Test build**

Run: `bazel build //app:ModelMirros`
Expected: executable links successfully.

- [ ] **Step 3: Commit**

```bash
git add app/BUILD.bazel
git commit -m "chore: add app/BUILD.bazel — haskell_binary"
```

---

### Task 6: apalache-mc repo rule — locate apalache-mc on PATH

**Files:**
- Create: `apalache-mc/repo.bzl`
- Create: `apalache-mc/BUILD.template`

- [ ] **Step 1: Create `apalache-mc/repo.bzl`**

```python
def _apalache_mc_repo_impl(repository_ctx):
    apalache = repository_ctx.which("apalache-mc")
    if apalache == None:
        fail("apalache-mc not found on PATH. Install it: https://github.com/informalsystems/apalache")
    repository_ctx.file("BUILD.bazel", '''
sh_binary(
    name = "apalache-mc",
    srcs = ["apalache-mc.sh"],
    visibility = ["//visibility:public"],
)
''')
    repository_ctx.file("apalache-mc.sh", """#!/bin/bash
exec {} "$@"
""".format(apalache), executable = True)

apalache_mc_repository = repository_rule(
    implementation = _apalache_mc_repo_impl,
    local = True,
)
```

- [ ] **Step 2: Register the repo rule in `MODULE.bazel`**

Append to `MODULE.bazel`:

```python
apalache_mc = use_repo_rule(
    "//apalache-mc:repo.bzl",
    "apalache_mc_repository",
)
apalache_mc(name = "apalache_mc")
```

- [ ] **Step 3: Commit**

```bash
git add apalache-mc/repo.bzl
git commit -m "chore: add apalache-mc Bazel repository rule"
```

---

### Task 7: test/BUILD.bazel — haskell_test with TLA+ data deps

**Files:**
- Create: `test/BUILD.bazel`

- [ ] **Step 1: Create `test/BUILD.bazel`**

```python
load("@rules_haskell//haskell:defs.bzl", "haskell_test")

haskell_test(
    name = "ModelMirros-test",
    srcs = glob(
        ["**/*.hs"],
        exclude = ["specs/**"],
    ),
    compiler_flags = ["-Wall"],
    data = glob(["specs/*.tla"]),
    default_language = "GHC2024",
    deps = [
        "//src:ModelMirros",
        "@apalache_mc//:apalache-mc",
        "@stackage//:base",
        "@stackage//:bytestring",
        "@stackage//:containers",
        "@stackage//:directory",
        "@stackage//:process",
        "@stackage//:tasty",
        "@stackage//:tasty-hunit",
        "@stackage//:text",
    ],
)
```

- [ ] **Step 2: Handle data deps path resolution**

Test code uses relative paths like `"test/specs/HourClock.tla"`. Under `bazel test`, the working directory is the runfiles root. Add a Make variable or environment variable for the spec directory:

In `test/BUILD.bazel`, add to the `haskell_test` rule:

```python
    env = {
        "MODELMIRRORS_SPEC_DIR": "test/specs",
    },
```

Then in test code, prepend this env var to spec file paths. Since the test code currently hardcodes paths (e.g., `specFile = "test/specs/HourClock.tla"`), this requires either:

Option A: No code changes — rely on Bazel `runfiles` making the relative path work (test if `bazel test` runs from repo root by default in rules_haskell)
Option B: Add env var `MODELMIRRORS_SPEC_DIR` and modify test code to use it

For now, try Option A first. If tests fail due to missing files, implement Option B.

- [ ] **Step 3: Test**

Run: `bazel test //test:ModelMirros-test`

Expected: tests compile and run. Some may fail if `apalache-mc` path resolution or TLA+ file paths are wrong — iterate.

- [ ] **Step 4: Commit**

```bash
git add test/BUILD.bazel
git commit -m "chore: add test/BUILD.bazel — haskell_test with TLA+ data deps"
```

---

### Task 8: Verify — full build + test against GHC 9.10.3

- [ ] **Step 1: Full library + binary build**

Run: `bazel build //...`
Expected: all targets build successfully.

- [ ] **Step 2: Run tests**

Run: `bazel test //test:ModelMirros-test`
Expected: all 28 tests pass (those requiring `apalache-mc` may take 30+ seconds).

- [ ] **Step 3: Verify cabal still works**

Run: `cabal build all && cabal test all`
Expected: no regressions. Bazel files do not interfere with cabal.

- [ ] **Step 4: Update `.gitignore`**

Append to `.gitignore`:

```
/bazel-*
```

- [ ] **Step 5: Commit**

```bash
git add .gitignore
git commit -m "chore: add bazel-* to .gitignore"
```

---

### Task 9: Update AGENTS.md with Bazel build instructions

**Files:**
- Modify: `AGENTS.md`

- [ ] **Step 1: Edit `AGENTS.md` — add Bazel commands**

Replace the Build & Test section:

```markdown
## Build & Test

### Bazel (primary)
```sh
bazel build //...                            # build all targets
bazel test //test:ModelMirros-test           # run tests
```

### Cabal (for IDE / Hackage)
```sh
cabal build all    # build library + executable
cabal test all     # run tests
```
```

- [ ] **Step 2: Update prereqs section**

Change `GHC 9.12+` to `GHC 9.10.3+` and add Bazel 9.1.0 requirement.

```markdown
## Prerequisites

- Bazel 9.1.0
- GHC 9.10.3+
- `apalache-mc` on `PATH` (tests shell out to it)
```

- [ ] **Step 3: Commit**

```bash
git add AGENTS.md
git commit -m "docs: add Bazel build instructions to AGENTS.md"
```
