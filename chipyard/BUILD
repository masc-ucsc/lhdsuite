load("@rules_shell//shell:sh_test.bzl", "sh_test")

filegroup(
    name = "interrupts",
    srcs = [
        "pyrope/CLINT.prp",
        "pyrope/InterruptMMIO.prp",
        "pyrope/LevelGateway.prp",
        "pyrope/PLICFanIn.prp",
        "pyrope/TLPLIC.prp",
    ],
    visibility = ["//visibility:public"],
)

exports_files(["pyrope/Fibonacci16.prp"], visibility = ["//visibility:public"])

sh_test(
    name = "pyrope_test",
    size = "small",
    srcs = ["pyrope/tests/check.sh"],
    args = ["$(rlocationpath @livehd//lhd:lhd)"],
    data = glob(["pyrope/*.prp"]) + [
        "pyrope/tests/lfsr_tb.prp",
        "//rocket:pyrope2",
        "@livehd//lhd:lhd",
    ],
)
