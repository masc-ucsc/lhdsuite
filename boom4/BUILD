filegroup(
    name = "pyrope",
    srcs = glob(["pyrope/*.prp", "*/pyrope/*.prp"]) + ["//chipyard:pyrope/Fibonacci16.prp"],
    visibility = ["//visibility:public"],
)

filegroup(
    name = "pyrope_top",
    srcs = ["pyrope/BoomTile.prp"],
    visibility = ["//visibility:public"],
)

filegroup(
    name = "verilog",
    srcs = glob(["verilog/*.sv", "*/verilog/*.sv", "*/verilog/*.v"]) + [":verilog_filelist"],
    visibility = ["//visibility:public"],
)

filegroup(
    name = "verilog_filelist",
    srcs = ["verilog/filelist.f"],
    visibility = ["//visibility:public"],
)

filegroup(
    name = "sim",
    srcs = glob(["sim/**", "*/sim/**"]),
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

exports_files(["synth/constraint.sdc"], visibility = ["//visibility:public"])
