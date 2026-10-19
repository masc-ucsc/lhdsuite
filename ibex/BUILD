# Ibex, a small RV32IMC RISC-V core from lowRISC, in both source languages.
#
# verilog/ is vendored VERBATIM from https://github.com/lowRISC/ibex at commit
# a3ab21a80b (2026-09-05): rtl/ plus the vendor/lowrisc_ip prims and headers it
# includes, Apache-2.0 (see verilog/LICENSE). The only hand-written Verilog file
# is ibex_suite_top.sv, a parameter-pinning wrapper (its header says why).
# pyrope/ is the generated benchmark translation (AGENTS' regeneration recipe,
# --top ibex_suite_top).
#
# SCOPE: ibex_top's default configuration (RV32I + fast M + Zca/Zcb/Zcmp, FF
# register file), no PMP, icache, SecureIbex or CHERIoT.

filegroup(
    name = "verilog",
    srcs = glob([
        "verilog/*.sv",
        "verilog/*.svh",
    ]) + ["verilog/filelist.f"],
    visibility = ["//visibility:public"],
)

filegroup(
    name = "verilog_filelist",
    srcs = ["verilog/filelist.f"],
    visibility = ["//visibility:public"],
)

filegroup(
    name = "pyrope",
    srcs = glob(["pyrope/*.prp"]) + glob(["pyrope/manifest.json"], allow_empty = True),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "pyrope_top",
    srcs = ["pyrope/ibex_suite_top.prp"],
    visibility = ["//visibility:public"],
)

# Simulation driver. ibex_prog_tb.prp runs a real RISC-V program with the
# testbench acting as Ibex's instruction and data memory.
filegroup(
    name = "sim",
    srcs = glob(["sim/*.prp"]),
    visibility = ["//visibility:public"],
)

# Formal assert/assume sidecar: Ibex's own IbexDataAddrUnaligned, translated.
filegroup(
    name = "verif",
    srcs = glob(["verif/*.prp"]),
    visibility = ["//visibility:public"],
)

# This core uses GENERATED variants (see the CORES entry): bug1 and comment1
# are one-line mutations of pyrope/ibex_load_store_unit.prp made by
# bench/common.sh, not checked-in copies. The glob stays so the filegroup exists.
filegroup(
    name = "tests",
    srcs = glob(["tests/**"], allow_empty = True),
    visibility = ["//visibility:public"],
)
