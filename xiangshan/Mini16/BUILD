# XiangShan MinimalRob16Config (Mini16), scoped to the CtrlBlock cone (88 modules):
# verilog/ = the cone of the Chisel emit, pyrope/ = its lhd emit, pyrope2/ = the cleaned tree
# (cleaned modules + the raw rest). Bench core xs_mini16; simulation is not enabled.

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
    srcs = glob(["pyrope/CtrlBlock.prp"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "pyrope2",
    srcs = glob(["pyrope2/*.prp"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "pyrope2_top",
    srcs = ["pyrope2/CtrlBlock.prp"],
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
