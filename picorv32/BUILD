# PicoRV32, a size-optimized RISC-V CPU, in both source languages.
#
# verilog/picorv32.v is vendored VERBATIM from upstream
# (https://github.com/YosysHQ/picorv32, ISC — see verilog/COPYING); the only
# hand-written Verilog file is picorv32_top.v, a parameter-pinning wrapper
# (its header says why). pyrope/ is a maintained translation of that same
# design, with per-instance constant generics; see README.md.
#
# SCOPE: both languages here ARE the same design. The suite wrapper retains
# its existing parameter values. Additional PCPI/M/D and ALU configurations are
# checked by check_configurations.py; standalone arithmetic uses
# check_arithmetic.py. validation.md distinguishes unbounded and partial proofs.

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
# checked-in copies — a second copy of the whole CPU would have to be updated
# in lockstep with the tree. The glob stays so
# the filegroup exists and a future checked-in variant needs no BUILD edit.
filegroup(
    name = "tests",
    srcs = glob(["tests/**"], allow_empty = True),
    visibility = ["//visibility:public"],
)
