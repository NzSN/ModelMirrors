_APALACHE_VERSION = "0.58.0"
_APALACHE_URL = "https://github.com/apalache-mc/apalache/releases/download/v{version}/apalache-{version}.zip".format(version = _APALACHE_VERSION)
_APALACHE_SHA256 = "d73ad6945ca924155dc9b85c4770bb4e5d5ff6c19366966795e734cbfed58dc2"

def _apalache_mc_repo_impl(repository_ctx):
    downloaded = False
    apalache = repository_ctx.which("apalache-mc")
    if apalache == None:
        repository_ctx.download_and_extract(
            url = _APALACHE_URL,
            sha256 = _APALACHE_SHA256,
            stripPrefix = "apalache-{}".format(_APALACHE_VERSION),
        )
        apalache = "bin/apalache-mc"
        downloaded = True

    if downloaded:
        repository_ctx.file("BUILD.bazel", """load("@rules_shell//shell:sh_binary.bzl", "sh_binary")
sh_binary(
    name = "apalache-mc",
    srcs = ["apalache-mc.sh"],
    data = glob(["bin/**", "lib/**"]),
    visibility = ["//visibility:public"],
)
""")
    else:
        repository_ctx.file("BUILD.bazel", """load("@rules_shell//shell:sh_binary.bzl", "sh_binary")
sh_binary(
    name = "apalache-mc",
    srcs = ["apalache-mc.sh"],
    visibility = ["//visibility:public"],
)
""")

    repository_ctx.file("apalache-mc.sh", """#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "${{BASH_SOURCE[0]}}")" && pwd)"
exec "$DIR/{apalache}" "$@"
""".format(apalache = apalache), executable = True)

apalache_mc_repository = repository_rule(
    implementation = _apalache_mc_repo_impl,
    local = True,
)
