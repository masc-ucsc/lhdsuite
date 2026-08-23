# Matched filter (radar pulse-compression correlator) in both source languages:
# the loop-machinery benchmark block. 64 taps, independent signed 8-bit sample
# and reference streams, and a 6-level registered adder tree. The Pyrope is
# the hand-written source form with one distinct vector per registered tree
# level; the Verilog is an independent explicit-generate implementation.
# See pyrope/matched_filter.prp for the interface and precision contract.

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
    srcs = glob(["pyrope/*.prp"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "pyrope_top",
    srcs = ["pyrope/matched_filter.prp"],
    visibility = ["//visibility:public"],
)

# Simulation drivers: the .prp drives `lhd sim` (both language modes, via
# `import("lg:matched_filter")`), the .cpp is its Verilator twin.
filegroup(
    name = "sim",
    srcs = glob([
        "sim/*.prp",
        "sim/*.cpp",
    ]),
    visibility = ["//visibility:public"],
)

# Formal assert/assume sidecar for the `tap` unit.
filegroup(
    name = "verif",
    srcs = glob(["verif/*.prp"]),
    visibility = ["//visibility:public"],
)

# Source variants for the multi-pass scenarios, overlaid onto a copy of
# pyrope/: bug1 = each loaded reference is corrupted (LEC/formal must catch),
# comment1 = comment-only touch (incremental caches must hit).
filegroup(
    name = "tests",
    srcs = glob(["tests/**"]),
    visibility = ["//visibility:public"],
)
