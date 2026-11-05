# Gemmini (ucb-bar DNN accelerator generator), standalone TPU-like core: a 4x4
# systolic mesh (8-bit inputs, 32-bit accumulators) + AccumulatorMem, without
# the RoCC/rocket-chip front end. Verilog = GemminiTPU.sv from the Chisel 6.2.0
# extraction in /mada/users/frabieik/gemmini_tpu (`sbt "runMain gemmini.Top"`);
# pyrope/ = `lhd compile verilog --top GemminiTPU` (lhd d088d9039).

filegroup(
    name = "verilog",
    srcs = glob(["verilog/*.sv"]) + ["verilog/filelist.f"],
    visibility = ["//visibility:public"],
)

filegroup(
    name = "verilog_filelist",
    srcs = ["verilog/filelist.f"],
    visibility = ["//visibility:public"],
)

filegroup(
    name = "pyrope",
    srcs = glob(["pyrope/*.prp"]) + glob(["pyrope/manifest.json"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "pyrope_top",
    srcs = glob(["pyrope/GemminiTPU.prp"]),
    visibility = ["//visibility:public"],
)

# The hand-maintained, loop-cleaned tree. Same top.
filegroup(
    name = "pyrope2",
    srcs = glob(["pyrope2/*.prp"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "pyrope2_top",
    srcs = ["pyrope2/GemminiTPU.prp"],
    visibility = ["//visibility:public"],
)

filegroup(
    name = "sim",
    srcs = glob(["sim/*.prp", "sim/*.cpp"], allow_empty = True),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "verif",
    srcs = glob(["verif/*.prp"], allow_empty = True),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "tests",
    srcs = glob(["tests/**"], allow_empty = True),
    visibility = ["//visibility:public"],
)
