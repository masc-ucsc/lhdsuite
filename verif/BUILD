# Correctness checks that are not timed benchmarks.
#
# //verif:genprp — regenerate each core's Pyrope FROM ITS VERILOG into the
# test's scratch dir and LEC it against that same Verilog. The checked-in
# <core>/pyrope trees came out of this generator but are never re-derived, so
# without this target a `pass.prp_writer` regression stays invisible until
# somebody regenerates by hand. Nothing here writes to the source tree — the
# checked-in trees are read-only inputs to //bench, and this package does not
# touch them at all.
#
#   bazel test //verif:genprp            # all cores
#   bazel test //verif:genprp_dino       # one core
#
# Tagged `manual`: a wildcard (`bazel test //...`) skips them, an explicit name
# runs them. They are the "from time to time" check — run after touching
# upass/prp_writer, inou/slang, or the LEC encoder.
#
# Status (2026-08-12): dino and cva6 are PROVEN equivalent end to end. minion
# regenerates and re-reads cleanly and proves 162/171 defs, then REFUTES at
# `prim_rst_sync` — the SAME family of gap that already fails //bench:minion_lec
# on the CHECKED-IN tree (which refutes at intpipe_mul_div_dp, 158/171). So
# genprp_minion is red today for a pre-existing reason, not a generator
# regression; it is wired up so it goes green when that lands.

load("@rules_shell//shell:sh_test.bzl", "sh_test")
load("//bench:defs.bzl", "CORES")

[
    sh_test(
        name = "genprp_" + core,
        size = "medium",
        timeout = "eternal",
        srcs = ["genprp.sh"],
        data = [
            "@livehd//lhd:lhd",
            CORES[core]["pkg"] + ":verilog",
            CORES[core]["pkg"] + ":verilog_filelist",
        ],
        env = {
            "LHD": "$(rlocationpath @livehd//lhd:lhd)",
            "CORE": core,
            "CORE_TOP": CORES[core]["top"],
            "CORE_V_FLAGS": CORES[core]["v_flags"],
            "CORE_V_FLIST": "$(rlocationpath %s:verilog_filelist)" % CORES[core]["pkg"],
        },
        # LEC on a whole core is CPU-hungry; `manual` keeps it off wildcards.
        tags = [
            "core_" + core,
            "exclusive",
            "manual",
        ],
    )
    for core in [
        "dino",
        "cva6",
        "minion",
    ]
]

test_suite(
    name = "genprp",
    tags = ["manual"],
    tests = [
        ":genprp_cva6",
        ":genprp_dino",
        ":genprp_minion",
    ],
)
