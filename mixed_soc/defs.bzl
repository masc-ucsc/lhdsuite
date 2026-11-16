"""Composite simulation targets keep imported source packages intact."""
load("@rules_shell//shell:sh_test.bzl", "sh_test")

def mixed_soc_benches():
    for mode in ["pyrope", "verilator"]:
        sh_test(
            name = "mixed_soc_sim_" + mode,
            size = "large",
            timeout = "long",
            srcs = ["//mixed_soc:scripts/test.sh"],
            args = [mode, "$(rlocationpath @livehd//lhd:lhd)"],
            data = [
                "//mixed_soc:scripts/run_sim.py",
                "//mixed_soc:scripts/generate_rtl.py",
                "//mixed_soc:scripts/topology.py",
                "//mixed_soc:pyrope",
                "//mixed_soc:verilog",
                "//mixed_soc:sim",
                "@livehd//lhd:lhd",
            ],
            tags = ["exclusive", "core_mixed_soc"],
            visibility = ["//visibility:public"],
        )
    native.test_suite(
        name = "mixed_soc",
        tests = [":mixed_soc_sim_pyrope", ":mixed_soc_sim_verilator"],
        visibility = ["//visibility:public"],
    )
