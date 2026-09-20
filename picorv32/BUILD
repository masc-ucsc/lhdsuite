load("@rules_shell//shell:sh_test.bzl", "sh_test")

# PicoRV32, a size-optimized RISC-V CPU, in both source languages.
#
# verilog/picorv32.v is vendored VERBATIM from upstream
# (https://github.com/YosysHQ/picorv32, ISC — see verilog/COPYING); the only
# hand-written Verilog file is picorv32_top.v, a parameter-pinning wrapper
# (its header says why). pyrope/ is the generated benchmark translation;
# pyrope2/ retains configurable shift/ALU parameters.
#
# SCOPE: the suite wrapper retains its existing parameter values. sim_configs
# compares four shift/ALU configurations against Verilator, using pyrope2 and
# scratch wrapper edits. See sim/README.md for the workload and reuse checks.

filegroup(
    name = "verilog",
    srcs = glob(["verilog/*.v"]) + ["verilog/filelist.f"],
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

filegroup(
    name = "pyrope_top",
    srcs = ["pyrope/picorv32_top.prp"],
    visibility = ["//visibility:public"],
)

# Simulation drivers. picorv32_prog_tb.prp runs a real RISC-V program with the
# testbench acting as the CPU's memory; the C++ twin checks the same workload.
filegroup(
    name = "sim",
    srcs = glob(
        [
            "sim/*.prp",
            "sim/*.cpp",
        ],
        allow_empty = True,
    ),
    visibility = ["//visibility:public"],
)

# Formal assert/assume sidecars. picorv32.verify.prp is picorv32's OWN
# `ifdef FORMAL` spec translated, two of whose four properties are sequential.
filegroup(
    name = "verif",
    srcs = glob(["verif/*.prp"]),
    visibility = ["//visibility:public"],
)

# This core uses GENERATED variants (see the CORES entry): bug1 and comment1
# are one-line mutations of pyrope/picorv32.prp made by bench/common.sh, not
# checked-in copies — a second copy of the whole CPU would have to be updated
# in lockstep with the tree. The glob stays so
# the filegroup exists and a future checked-in variant needs no BUILD edit.
filegroup(
    name = "tests",
    srcs = glob(["tests/**"], allow_empty = True),
    visibility = ["//visibility:public"],
)

# Exercise both parameter values, partial compile reuse, and fresh simulation
# against the same Verilator instruction program and completion cycle.
sh_test(
    name = "sim_configs",
    size = "large",
    timeout = "long",
    srcs = ["check_sim_configs.py"],
    args = ["--lhd", "$(rlocationpath @livehd//lhd:lhd)"],
    data = glob(["pyrope2/*.prp"]) + [
        ":sim",
        ":verilog",
        "@livehd//lhd:lhd",
    ],
    tags = ["exclusive"],
)
