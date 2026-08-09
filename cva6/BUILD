# CVA6 (OpenHW Group) cache tag comparator, in both source languages.
#
# SCOPE: this core is the tag_cmp cone, not the whole CVA6 CPU. The full core
# does not read yet (unpacked '{...} assignment patterns, non-constant **, and
# non-const loop bounds are still unsupported by --reader slang), so the suite
# carries the largest CVA6 subset that compiles, round-trips and LECs today.
# Widen it as those reader gaps close — the point of the core is that lhdsuite
# tracks a third real CPU, and this is the part of it that works.
#
# The top is tag_cmp_wrap, NOT tag_cmp. tag_cmp takes its cache-line types as
# module parameters (`parameter type l_data_t = logic`), which cva6 binds at
# instantiation; compiled standalone they default to `logic`, the tag compare
# collapses and hit_way_o is left undriven — so every property over it passes
# VACUOUSLY. tag_cmp_wrap.sv binds them exactly as std_nbdcache.sv does, giving
# the real 44-bit tag compare over a struct-typed line array.
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

# Simulation driver (all-miss smoke: the line array is 1392 bits and a testbench
# scalar truncates past 64, so a populated array cannot be driven — see the
# driver's own comment).
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
