# CVA6 (OpenHW Group) cache tag comparator, in both source languages.
#
# SCOPE: the two languages are NOT the same design here, and that is deliberate.
#   verilog/  the tag_cmp cone only. The full core does not read yet (unpacked
#             '{...} assignment patterns, non-constant **, and non-const loop
#             bounds are still unsupported by --reader slang), so the compile /
#             synthesis / LEC / verify scenarios — everything that needs BOTH
#             sides — run on the largest CVA6 subset that round-trips today.
#   pyrope/   the WHOLE CVA6 core, generated from an upstream checkout by the
#             recipe in cva6/README (a different, larger config than verilog/:
#             cv64a6_imafdc_sv39_wb). Only the simulation scenarios reach it,
#             via the pyrope-only cva6_prog_tb.prp driver below.
# Widen verilog/ as those reader gaps close — the point of the core is that
# lhdsuite tracks a third real CPU.
#
# WHY THE TWO SIDES BIND tag_cmp DIFFERENTLY. tag_cmp takes its cache-line
# types as module parameters (`parameter type l_data_t = logic`), which cva6
# binds at instantiation. Elaborated STANDALONE from Verilog they default to
# `logic`, the tag compare collapses and hit_way_o is left undriven — measured,
# `lhd compile verilog --top tag_cmp` yields rdata_i:u2 / hit_way_o:u2, so every
# property over it would pass VACUOUSLY. That is why the Verilog `top` is
# tag_cmp_wrap.sv (suite code), which reproduces std_nbdcache.sv's binding.
#   The PYROPE side needs no such wrapper any more: cva6/pyrope/tag_cmp.prp is
# emitted from the WHOLE core, where std_nbdcache already binds those types, so
# it arrives concrete (rdata_i:u1392, a 44-bit compare gated by each way's valid
# bit). The verify sidecar and the bug1/comment1 variants therefore bind
# `tag_cmp` directly — that is the `unit` knob in bench/defs.bzl.
#   pyrope/tag_cmp_wrap.prp survives only as `pyrope_top`, i.e. because `top`
# is still tag_cmp_wrap for the Verilog-rooted scenarios. It does NOT currently
# compile (the regenerated tag_cmp exports hit_way_o as a per-leaf struct, and
# is the 5-port instantiation std_nbdcache uses, not the 3-port one
# tag_cmp_wrap.sv binds), so every `top`-rooted Pyrope scenario is red until
# the two trees are brought back to one config. See README's
# "Known-failing scenarios".
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
    srcs = ["pyrope/tag_cmp_wrap.prp"],
    visibility = ["//visibility:public"],
)

# Simulation drivers.
#   tag_cmp_tb.prp    the timed benchmark, on the tag_cmp cone (all-miss smoke:
#                     the line array is 1392 bits and a testbench scalar
#                     truncates past 64, so a populated array cannot be driven
#                     — see the driver's own comment).
#   cva6_prog_tb.prp  a whole RISC-V program on the FULL core, driving `cva6`
#                     over AXI. Its DUT exists only in pyrope/, so the CORES
#                     entry marks it pyrope-only and it has no Verilator twin.
filegroup(
    name = "sim",
    srcs = glob(["sim/*.prp"]),
    visibility = ["//visibility:public"],
)

# Formal assert/assume sidecars — a translation of the module's OWN SVA.
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
