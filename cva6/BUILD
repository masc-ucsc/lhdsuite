# CVA6 (OpenHW Group): whole generated Pyrope core plus local Verilog cone.
#
# SCOPE: the two languages are NOT the same design here, and that is deliberate.
#   verilog/  the tag_cmp cone only. The full core does not read yet (unpacked
#             '{...} assignment patterns, non-constant **, and non-const loop
#             bounds are still unsupported by --reader slang). It is retained
#             for local cone work, not used as the benchmark design.
#   pyrope/   the WHOLE CVA6 core, generated from an upstream checkout by the
#             recipe in cva6/README (a different, larger config than verilog/:
#             cv64a6_imafdc_sv39_wb). The main bench uses this whole core for
#             Pyrope compile, synthesis, and simulation. Cross-language
#             Verilog/LEC legs are omitted until the Verilog tree can carry the
#             same top; they are never redirected to the tag_cmp cone.
# Widen verilog/ as those reader gaps close — the point of the core is that
# lhdsuite tracks a third real CPU.
#
# WHY tag_cmp_wrap STILL EXISTS. tag_cmp takes cache-line types as module
# parameters. Elaborated standalone from Verilog they default to `logic`, so
# the comparator collapses; tag_cmp_wrap.sv binds the concrete types for local
# cone work. It is retained as collateral, but neither it nor tag_cmp is the
# benchmark top or formal unit. Formal uses the whole core's integer `alu`.
#
# Sources are vendored unmodified from github.com/openhwgroup/cva6 (Solderpad
# 0.51 / Apache-2.0, see verilog/LICENSE); tag_cmp_wrap.sv is suite code.

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
    srcs = glob(["pyrope/*.prp"]) + glob(["pyrope/manifest.json"], allow_empty = True),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "pyrope_top",
    srcs = ["pyrope/cva6.prp"],
    visibility = ["//visibility:public"],
)

# Simulation drivers.
#   cva6_prog_tb.prp  the asserted, timed benchmark: a whole RISC-V program on
#                     the FULL core over AXI. Its DUT exists only in pyrope/,
#                     so there is no Verilog or Verilator twin.
#   tag_cmp_tb.prp    retained as local cone collateral, not used by //bench.
filegroup(
    name = "sim",
    srcs = glob(["sim/*.prp"]),
    visibility = ["//visibility:public"],
)

# Formal assert/assume sidecars. //bench uses alu.verify.prp; the translated
# tag_cmp SVA remains local cone collateral.
filegroup(
    name = "verif",
    srcs = glob(["verif/*.prp"]),
    visibility = ["//visibility:public"],
)

# Checked-in source variants for the multi-pass scenarios: bug1 = a hit that
# ignores the way's valid bit (the onehot property must catch it), comment1 = a
# comment-only touch (incremental caches must hit).
filegroup(
    name = "tests",
    srcs = glob(["tests/**"]),
    visibility = ["//visibility:public"],
)
