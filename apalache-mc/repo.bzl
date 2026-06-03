def _apalache_mc_repo_impl(repository_ctx):
    apalache = repository_ctx.which("apalache-mc")
    if apalache == None:
        fail("apalache-mc not found on PATH. Install it: https://github.com/informalsystems/apalache")
    repository_ctx.file("BUILD.bazel", """
sh_binary(
    name = "apalache-mc",
    srcs = ["apalache-mc.sh"],
    visibility = ["//visibility:public"],
)
""")
    repository_ctx.file("apalache-mc.sh", """#!/bin/bash
exec {} "$@"
""".format(apalache), executable = True)

apalache_mc_repository = repository_rule(
    implementation = _apalache_mc_repo_impl,
    local = True,
)
