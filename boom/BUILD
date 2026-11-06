# chipyard SmallBoomV4Config BoomTile (BOOM v4 core + L1 I/D caches + PTW), in both source languages. The Verilog is
# the firtool emit at chipyard-boom-v4/sims/verilator/generated-src/chipyard.harness.TestHarness.SmallBoomV4Config/
# gen-collateral.dedup-on.bak (the tree the boom/pyrope2 BoomCore LEC used): verilog/filelist.f lists only BoomTile's
# cone (236 modules) plus top.mems.v (the 17 SRAM macros it uses) and plusarg_reader.v. pyrope/ is that cone emitted by
# `lhd compile verilog --top BoomTile` (lhd d088d9039, 2026-11-05). pyrope2/ is the same cone with the hand/loop
# cleanups re-applied module by module (each PROVEN-full vs its pyrope/ twin); its files outside the cone
# (Rob_rob16 + memories, BusyTable) are old-syntax leftovers that the BoomTile top never imports.

filegroup(
    name = "verilog",
    srcs = glob(["verilog/*.sv", "verilog/*.v"]) + ["verilog/filelist.f"],
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
    srcs = ["pyrope/BoomTile.prp"],
    visibility = ["//visibility:public"],
)

# The hand-maintained, loop-cleaned tree (see //bench:boom_sim_pyrope2). Same top.
filegroup(
    name = "pyrope2",
    srcs = glob(["pyrope2/*.prp"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "pyrope2_top",
    srcs = ["pyrope2/BoomTile.prp"],
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
