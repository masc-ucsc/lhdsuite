# Dino dual-issue RISC-V CPU, in both source languages. The Verilog is a fork
# of https://github.com/masc-ucsc/simplechisel (7/7/26); the Pyrope is the
# LiveHD-generated translation of the same design (manifest.json lists the
# per-module content hashes).

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
    srcs = glob(["pyrope/*.prp"]) + ["pyrope/manifest.json"],
    visibility = ["//visibility:public"],
)

filegroup(
    name = "pyrope_top",
    srcs = ["pyrope/PipelinedDualIssueCPU.prp"],
    visibility = ["//visibility:public"],
)

# Simulation driver (hello-world testbench) — plain suite code, usable outside
# bazel too: sim/dino_tb.prp next to any Pyrope tree of the design.
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
# holds patched copies of dino/pyrope files that scripts overlay onto a copy
# of the design (`diff dino/pyrope/ALU.prp dino/tests/bug1/ALU.prp` shows the
# injected change): bug1 = real bug (LEC/formal must catch), comment1 =
# comment-only touch (incremental caches must hit).
filegroup(
    name = "tests",
    srcs = glob(["tests/**"]),
    visibility = ["//visibility:public"],
)
