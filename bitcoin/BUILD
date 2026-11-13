# The LogikBench bitcoin miner in both source languages.
#
# verilog/ holds the four LogikBench bitcoin*.v files and the three secworks
# sha256_* files they instantiate, all vendored VERBATIM (see README.md for the
# sources and LICENSE / LICENSE.sha256 for their licenses); bitcoin_top.v is
# the one hand-written file, a wrapper pinning NENGINES = 16.
#
# pyrope/ is NOT a raw emission: it is the hand-cleaned, loop-based translation
# of the same design (README.md says how it was checked against the Verilog).

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
    srcs = glob(["pyrope/*.prp"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "pyrope_top",
    srcs = ["pyrope/bitcoin_top.prp"],
    visibility = ["//visibility:public"],
)

# pyrope2/ is the Pyrope target proper: the same design and the same top, reworked to be efficient
# and Pyrope friendly rather than a module-by-module image of the Verilog (README.md says what
# differs and how it was checked). See //bench:bitcoin_sim_pyrope2.
filegroup(
    name = "pyrope2",
    srcs = glob(["pyrope2/*.prp"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "pyrope2_top",
    srcs = ["pyrope2/bitcoin_top.prp"],
    visibility = ["//visibility:public"],
)

# bitcoin_mine_tb.prp mines the genesis block and then a stream of easy-target
# work items; the C++ twin runs the same schedule under Verilator.
filegroup(
    name = "sim",
    srcs = glob(["sim/*.prp", "sim/*.cpp"]),
    visibility = ["//visibility:public"],
)

# bitcoin_engine.verify.prp (the `unit`), sha256_core.verify.prp (the
# `seq_unit`), and bitcoin_compare.verify.prp (the target check; not wired to a
# bench scenario, run it by hand — see its header).
filegroup(
    name = "verif",
    srcs = glob(["verif/*.prp"]),
    visibility = ["//visibility:public"],
)

# GENERATED variants (see the CORES entry): bug1 and comment1 are one-line
# edits of pyrope/bitcoin_engine.prp made by bench/common.sh. The glob keeps
# the filegroup so a future checked-in variant needs no BUILD edit.
filegroup(
    name = "tests",
    srcs = glob(["tests/**"], allow_empty = True),
    visibility = ["//visibility:public"],
)
