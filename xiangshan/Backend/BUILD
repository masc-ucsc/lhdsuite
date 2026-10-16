# XiangShan Backend snapshot in both source languages. The five synth-only
# bench cores select different --top values over this one shared source tree;
# lhd prunes each compile to the selected top's import cone.

# UNUSED since the stub genrule was dropped (see the note at the bottom of this
# file); kept so a snapshot that imports DiffExt cells again can restore it.
# The DPI sink models are DERIVED from the DummyDPICWrapper_* sources, never
# committed — see bench/gen_stubs.py for why they had to exist. The wrapper -> cell name
# map is mechanical (`DummyDPICWrapper_X.prp` -> `DiffExtX.prp`), which is what
# lets the output list be derived here instead of hand-listed: a regenerated
# XiangShan snapshot picks up new or renamed cells with no edit to this file.
_STUB_CELLS = [
    f[len("pyrope/DummyDPICWrapper_"):-len(".prp")]
    for f in glob(["pyrope/DummyDPICWrapper_*.prp"])
]

filegroup(
    name = "verilog",
    srcs = glob(["verilog/*.sv"]) + glob(
        [
            "verilog/*.svh",
            "verilog/*.v",
        ],
        allow_empty = True,
    ) + ["verilog/filelist.f"],
    visibility = ["//visibility:public"],
)

filegroup(
    name = "verilog_filelist",
    srcs = ["verilog/filelist.f"],
    visibility = ["//visibility:public"],
)

filegroup(
    name = "pyrope",
    srcs = glob(["pyrope/*.prp"]) + ["pyrope/manifest.json"],
    visibility = ["//visibility:public"],
)

# Parallel Pyrope implementation of a subset of the same design (hand-written
# variants, not an emitted snapshot — no manifest.json). Exposed so a sim/verif
# target can point at pyrope2/ instead of pyrope/ and share the sim/ drivers.
filegroup(
    name = "pyrope2",
    srcs = glob(["pyrope2/*.prp"]),
    visibility = ["//visibility:public"],
)

# Only the directory matters to bench/common.sh; every synth-only target then
# selects its own $CORE_TOP.prp from the same runfiles tree.
filegroup(
    name = "pyrope_top",
    srcs = ["pyrope/Backend.prp"],
    visibility = ["//visibility:public"],
)

# Free-running sim drivers (bench/sim.sh). Each names its DUT as
# `import("lg:<Block>")`, so ONE driver serves MODE=pyrope (the .prp tree) and
# MODE=verilog (an lg: library built from the .sv tree) — which is what makes
# the two language sides a cross-checkable oracle rather than two numbers.
#
# *.cpp too: each .prp driver has a Verilator twin next to it
# (xs_<block>_tb_verilator.cpp) that bench/sim_verilator.sh stages from here,
# exactly as //dino and //minion do. Without it the verilate step succeeds and
# `make` then dies with "No rule to make target .../xs_alu_tb_verilator.cpp".
filegroup(
    name = "sim",
    srcs = glob([
        "sim/*.prp",
        "sim/*.cpp",
    ]),
    visibility = ["//visibility:public"],
)

# No DiffExt* DPI sink stubs. The SV wrappers instantiate their DPI cell only
# under `ifdef DUMMY` (off for synthesis), and the CURRENT Pyrope snapshot
# already emits every DummyDPICWrapper_* with an empty body and no DiffExt
# import, so there is nothing to stub (bench/defs.bzl passes CORE_P_STUB_TOP="").
# The `gen_pyrope_stubs` genrule that used to live here declared one
# synth_stubs/DiffExt<X>.prp output per wrapper, but bench/gen_stubs.py SKIPs a
# wrapper without a DiffExt import, so it created none of them and failed
# `bazel build //xiangshan/...` (hence `bazel test //...`) with "declared output
# was not created". If a regenerated snapshot ever imports DiffExt cells again,
# run bench/gen_stubs.py <pyrope_dir> <out_dir> and point CORE_P_STUB_TOP (and
# bench/matrix.sh's XS_STUB_DIR) at its output.
