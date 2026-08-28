# One bazel target per (core, scenario) so a single thing can be benchmarked
# or debugged in isolation. Targets are named <core>_<scenario>:
#
#   bazel test //bench:dino_compile_verilog --test_output=all
#   bazel test //bench:minion_synth_incremental --test_output=all
#   bazel test //bench:minion_lec_bug --test_output=all
#
# ALL the tests for ONE core (this is the per-core suite):
#
#   bazel test //bench:dino
#   bazel test //bench:minion
#
# Everything, both cores: `bazel test //bench:all` (serially — targets are
# tagged exclusive so timing is not polluted by parallel tests). Each target
# also carries a `core_<name>` tag, so `--test_tag_filters=core_minion` is an
# equivalent way to select one core across a wider pattern.
#
# Families share a script; MODE picks the scenario. The per-core knobs (tops,
# unit under verification, testbench names) live in the CORES table in
# defs.bzl.

load("@rules_shell//shell:sh_binary.bzl", "sh_binary")
load(":defs.bzl", "core_benches")

# Consumed by //xiangshan/Backend's stub genrule: it derives the DiffExt* DPI
# sink models from the DummyDPICWrapper_* sources instead of checking 20
# generated files into git.
exports_files(["gen_stubs.py"])

# `bazel run //bench:show` — pretty-print the last `bazel test //bench:...`
# results from bazel-testlogs (a run target cannot trigger tests, so:
#   bazel test //bench:all; bazel run //bench:show
# ). Restrict to one core with: bazel run //bench:show -- --core minion
sh_binary(
    name = "show",
    srcs = ["show.sh"],
    data = ["show.py"],
)

# The shared result ledger (bench/ledger.jsonl) and its rendered scoreboard.
#   bazel run //bench:ledger -- add --config-id baseline-v1 matrix_rows.jsonl
#   bazel run //bench:ledger -- append baseline-v1 dino minion xs_alu
#   bazel run //bench:ledger -- render --flow incr
sh_binary(
    name = "ledger",
    srcs = ["ledger.sh"],
    data = ["ledger.py"],
)

# The dino dual-issue RISC-V CPU: one top, complete in both languages.
core_benches("dino")

# CVA6 (OpenHW Group): the whole generated Pyrope core. Its vendored Verilog
# tree is only a tag-comparator cone, so CVA6's cross-language legs are omitted
# rather than benchmarking that smaller design under the same name.
core_benches("cva6")

# Minion: an industrial multi-threaded RISC-V core with a vector/tensor unit.
# Whole-design (Pyrope) top is minion_top; Verilog-side and cross-language
# scenarios use vpu_top, the largest subtree complete in both languages
# (see minion/BUILD for why).
core_benches("minion")

# XiangShan Backend blocks share one 1088-module source tree. These are
# synth-only cores: each top is independently cone-pruned, and the two largest
# blocks carry the `slow` tag for exclusion from the routine loop.
core_benches("xs_rob")
core_benches("xs_alu")
core_benches("xs_renametable")
core_benches("xs_div")
core_benches("xs_exu")
core_benches("xs_backend")
core_benches("matched_filter")

# Cross-core scenario suites, for comparing one flow across both designs.
test_suite(
    name = "compile",
    tests = [
        ":dino_compile_pyrope",
        ":dino_compile_pyrope_parallel",
        ":dino_compile_verilog",
        ":minion_compile_pyrope",
        ":minion_compile_pyrope_parallel",
        ":minion_compile_verilog",
    ],
)

test_suite(
    name = "sim",
    tests = [
        ":dino_sim_pyrope",
        ":dino_sim_verilator",
        ":dino_sim_verilog",
        ":minion_sim_pyrope",
        ":minion_sim_verilator",
        ":minion_sim_verilog",
    ],
)
