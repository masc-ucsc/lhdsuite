"""lhd_bench: one sh_test per scenario, all wired to the from-source lhd.

Every target gets the same runfiles contract (see bench/common.sh): LHD points
at @livehd//lhd:lhd, DINO_* at the design sources; MODE selects the scenario
inside a shared script family (e.g. synth.sh runs cold vs incremental).
"""

load("@rules_shell//shell:sh_test.bzl", "sh_test")

_BASE_ENV = {
    "LHD": "$(rlocationpath @livehd//lhd:lhd)",
    "DINO_V_FLIST": "$(rlocationpath //dino:verilog_filelist)",
    "DINO_P_TOP": "$(rlocationpath //dino:pyrope_top)",
}

_BASE_DATA = [
    "common.sh",
    # lhd's own runfiles carry the `lhd sim` runtime headers (slop.hpp &
    # friends) — no extra staging needed here.
    "@livehd//lhd:lhd",
    "//dino:pyrope",
    "//dino:pyrope_top",
    "//dino:sim",
    "//dino:tests",
    "//dino:verif",
    "//dino:verilog",
    "//dino:verilog_filelist",
]

def lhd_bench(name, script, mode, data = [], timeout = "long"):
    sh_test(
        name = name,
        size = "medium",
        timeout = timeout,
        srcs = [script],
        data = _BASE_DATA + data,
        env = _BASE_ENV | {"MODE": mode},
        # Timing benchmarks: never share the machine with other tests.
        tags = ["exclusive"],
    )
