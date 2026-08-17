# XiangShan Backend snapshot in both source languages. The five synth-only
# bench cores select different --top values over this one shared source tree;
# lhd prunes each compile to the selected top's import cone.

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

# The SV wrappers instantiate these DPI cells only under `ifdef DUMMY`, which
# is disabled for synthesis. The translated Pyrope snapshot has no preprocessor
# and retained the imports, so explicit sink models reproduce the synthesis
# behavior without altering the imported design sources.
filegroup(
    name = "pyrope_stubs",
    srcs = glob(["synth_stubs/*.prp"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "pyrope_stub_top",
    srcs = ["synth_stubs/DiffExtInstrCommit.prp"],
    visibility = ["//visibility:public"],
)
