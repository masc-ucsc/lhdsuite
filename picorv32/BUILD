# PicoRV32, a size-optimized RISC-V CPU, in both source languages.
#
# verilog/picorv32.v is vendored VERBATIM from upstream
# (https://github.com/YosysHQ/picorv32, ISC — see verilog/COPYING); the only
# hand-written file here is verilog/picorv32_top.v, a parameter-pinning
# wrapper (its header says why). pyrope/ is the LiveHD-generated translation
# of that same configuration.
#
# SCOPE: unlike cva6, both languages here ARE the same design — the wrapper's
# cone in Verilog and the checked-in Pyrope tree are the same two modules, and
# `picorv32_lec` proves them equivalent. What the wrapper does NOT turn on
# (the PCPI multiplier/divider and the IRQ path) is documented in
# picorv32_top.v: each is a LiveHD round-trip gap with a reproducer in the
# README, not a suite preference.

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
# testbench acting as the CPU's memory; there is no Verilator twin yet.
filegroup(
    name = "sim",
    # No Verilator twin yet, so the .cpp glob is allow_empty.
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
# checked-in copies — the unit is a 1352-line whole CPU, and a second copy of
# it would have to be regenerated in lockstep with the tree. The glob stays so
# the filegroup exists and a future checked-in variant needs no BUILD edit.
filegroup(
    name = "tests",
    srcs = glob(["tests/**"], allow_empty = True),
    visibility = ["//visibility:public"],
)
