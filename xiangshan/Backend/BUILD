# XiangShan Backend snapshot in both source languages. The five synth-only
# bench cores select different --top values over this one shared source tree;
# lhd prunes each compile to the selected top's import cone.

# The DPI sink models are DERIVED from the DummyDPICWrapper_* sources, never
# committed — see the `gen_pyrope_stubs` genrule at the bottom of this file and
# bench/gen_stubs.py for why they have to exist at all. The wrapper -> cell name
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

# The SV wrappers instantiate these DPI cells only under `ifdef DUMMY`, which
# is disabled for synthesis. The translated Pyrope snapshot has no preprocessor
# and retained the imports, so explicit sink models reproduce the synthesis
# behavior without altering the imported design sources.
#
# GENERATED, never committed: checking these in would mean a second source of
# truth that silently rots when the snapshot is regenerated with new cells or
# changed `io` widths. `outs` is derived from the same glob the generator reads,
# so the two cannot disagree.
genrule(
    name = "gen_pyrope_stubs",
    srcs = glob(["pyrope/DummyDPICWrapper_*.prp"]),
    outs = ["synth_stubs/DiffExt%s.prp" % cell for cell in _STUB_CELLS],
    cmd = "python3 $(execpath //bench:gen_stubs.py) " +
          "$$(dirname $$(echo $(SRCS) | cut -d' ' -f1)) $(RULEDIR)/synth_stubs >/dev/null",
    tools = ["//bench:gen_stubs.py"],
)

filegroup(
    name = "pyrope_stubs",
    srcs = [":gen_pyrope_stubs"],
    visibility = ["//visibility:public"],
)

# bench/common.sh takes the DIRECTORY of this one file as $CORE_P_STUB_DIR; any
# generated stub serves, it just has to be a single deterministic label.
filegroup(
    name = "pyrope_stub_top",
    srcs = ["synth_stubs/DiffExt%s.prp" % _STUB_CELLS[0]],
    visibility = ["//visibility:public"],
)
