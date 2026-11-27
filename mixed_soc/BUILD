load("@rules_shell//shell:sh_test.bzl", "sh_test")

sh_test(
    name = "topology_test",
    size = "small",
    srcs = ["scripts/test.sh"],
    args = ["topology"],
    data = ["scripts/floorplan.py", "scripts/topology.py"],
)

# These explicit integration tests need a host Verilator 5 installation.
# The ordinary suite can still run the topology test on a machine without one.
[
    sh_test(
        name = mode + "_sim",
        size = "medium",
        srcs = ["scripts/test.sh"],
        args = [mode],
        data = ["scripts/generate_rtl.py", "scripts/simulate.py", "scripts/topology.py", "sim/" + mode + "_tb.sv"] +
               glob(["rtl/*.sv"]) +
               (["//rocket:verilog", "//boom:verilog", "//gemmini/Mesh16:verilog"] if mode == "system" else []),
        tags = ["manual", "requires-verilator"],
    )
    for mode in ["mesh", "system"]
]

# Imported source trees stay at their original runfile paths: a flat writable
# tree would break the explicit cross-package imports and duplicate the CPUs.
filegroup(
    name = "pyrope",
    srcs = glob(["pyrope/*.prp"]) + ["//chipyard:interrupts", "//rocket:pyrope2", "//boom4:pyrope", "//gemmini/Mesh16:pyrope2"],
    visibility = ["//visibility:public"],
)
filegroup(
    name = "pyrope_top",
    srcs = ["pyrope/MixedSocTop.prp"],
    visibility = ["//visibility:public"],
)
filegroup(
    name = "verilog",
    srcs = glob(["rtl/*.sv"]) + ["//rocket:verilog", "//boom:verilog", "//gemmini/Mesh16:verilog"],
    visibility = ["//visibility:public"],
)
filegroup(
    name = "sim",
    srcs = glob(["sim/*.prp", "sim/*.cpp"]),
    visibility = ["//visibility:public"],
)
exports_files(["scripts/test.sh", "scripts/run_sim.py", "scripts/generate_rtl.py", "scripts/topology.py"])

[
    test_suite(
        name = "sim_" + mode,
        tests = ["//bench:mixed_soc_sim_" + mode],
        visibility = ["//visibility:public"],
    )
    for mode in ["pyrope", "verilator"]
]

test_suite(
    name = "sim_test",
    tests = [":sim_pyrope", ":sim_verilator"],
    visibility = ["//visibility:public"],
)

[
    sh_test(
        name = mode,
        size = "small" if mode == "interrupt_mmio" else "large",
        srcs = ["scripts/test.sh"],
        args = [mode, "$(rlocationpath @livehd//lhd:lhd)"],
        data = [":pyrope", "sim/" + mode + ".prp", "@livehd//lhd:lhd"],
    )
    for mode in ["coherent_harts", "interrupt_harts", "interrupt_mmio"]
]
