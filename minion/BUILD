# Minion: an industrial multi-threaded RISC-V core with a vector/tensor unit
# (VPU, TxFMA, transcendental ROMs, D-cache, TLB), in both source languages.
# The Pyrope is the LiveHD translation of the same RTL.
#
# Top is `minion_top` in BOTH trees: 179 Pyrope files, 146 Verilog modules +
# the 8 generated intpipe_csr_file_auto_*.svh includes.
#
# The Verilog needs two extra slang options, set as `v_flags` in the CORES
# table in bench/defs.bzl: --relax-enum-conversions (enums assigned from plain
# bits) and --allow-use-before-declare. No -I is needed — the .svh includes
# resolve relative to the file that includes them.

# The .svh files are `include`d by intpipe_csr_file.sv (never compiled
# directly, so they are not in filelist.f) — but they must ride into the test
# sandbox, hence the glob.
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
    srcs = ["pyrope/minion_top.prp"],
    visibility = ["//visibility:public"],
)

# Simulation drivers (hello-world testbench) — plain suite code, usable
# outside bazel too: sim/thread_sched_tb.prp next to any Pyrope tree.
filegroup(
    name = "sim",
    srcs = glob(["sim/*.prp"]),
    visibility = ["//visibility:public"],
)

# Formal assert/assume sidecars.
filegroup(
    name = "verif",
    srcs = glob(["verif/*.prp"]),
    visibility = ["//visibility:public"],
)

# Checked-in source variants for the multi-pass scenarios. Each tests/<name>/
# holds patched copies of minion/pyrope files that scripts overlay onto a copy
# of the design (`diff minion/pyrope/intpipe_alu.prp
# minion/tests/bug1/intpipe_alu.prp` shows the injected change): bug1 = real
# bug (LEC/formal must catch), comment1 = comment-only touch (incremental
# caches must hit).
filegroup(
    name = "tests",
    srcs = glob(["tests/**"]),
    visibility = ["//visibility:public"],
)
