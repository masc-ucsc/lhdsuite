# One bazel target per scenario so a single thing can be benchmarked or
# debugged in isolation:
#
#   bazel test //bench:compile_verilog --test_output=all
#   bazel test //bench:synth_incremental --test_output=all
#   bazel test //bench:lec_bug --test_output=all
#
# Families share a script; MODE picks the scenario. `bazel test //bench:all`
# still runs everything (serially — targets are tagged exclusive so timing is
# not polluted by parallel tests).

load("@rules_shell//shell:sh_binary.bzl", "sh_binary")
load(":defs.bzl", "lhd_bench")

# `bazel run //bench:show` — pretty-print the last `bazel test //bench:...`
# results from bazel-testlogs (a run target cannot trigger tests, so:
#   bazel test //bench:all; bazel run //bench:show
# ).
sh_binary(
    name = "show",
    srcs = ["show.sh"],
    data = ["show.py"],
)

# --- Lgraph creation throughput (LoC/s, words/s) ---------------------------
lhd_bench(
    name = "compile_verilog",
    mode = "verilog",
    script = "compile.sh",
)

lhd_bench(
    name = "compile_pyrope",
    mode = "pyrope",
    script = "compile.sh",
)

# Per-file separate compilation: `lhd scan` dependency discovery, parallel
# leaf compiles, dependents reuse the pre-compiled units via --in-dir ln:.
lhd_bench(
    name = "compile_pyrope_parallel",
    mode = "pyrope_parallel",
    script = "compile.sh",
)

# --- color flat + abc synthesis; cold vs --workdir incremental -------------
lhd_bench(
    name = "synth",
    mode = "cold",
    script = "synth.sh",
    timeout = "eternal",
)

lhd_bench(
    name = "synth_incremental",
    mode = "incr",
    script = "synth.sh",
    timeout = "eternal",
)

# Netlist integrity: LEC the 2nd (incremental) synthesis run's netlist against
# the design, via the partition twin + Liberty gensim models (lgyosys solver).
lhd_bench(
    name = "synth_lec_flat",
    mode = "lec_flat",
    script = "synth.sh",
    timeout = "eternal",
)

lhd_bench(
    name = "synth_lec_synth",
    mode = "lec_synth",
    script = "synth.sh",
    timeout = "eternal",
)

# --- hello-world simulation smoke, both language tops ----------------------
lhd_bench(
    name = "sim_verilog",
    mode = "verilog",
    script = "sim.sh",
)

lhd_bench(
    name = "sim_pyrope",
    mode = "pyrope",
    script = "sim.sh",
)

# --- LEC: proven / injected bug caught / warm re-run -----------------------
lhd_bench(
    name = "lec",
    mode = "pass",
    script = "lec.sh",
    timeout = "eternal",
)

lhd_bench(
    name = "lec_bug",
    mode = "bug",
    script = "lec.sh",
    timeout = "eternal",
)

lhd_bench(
    name = "lec_incremental",
    mode = "incr",
    script = "lec.sh",
    timeout = "eternal",
)

# --- formal assert/assume on the top; cold vs warm -------------------------
lhd_bench(
    name = "verify",
    mode = "cold",
    script = "verify.sh",
    timeout = "eternal",
)

lhd_bench(
    name = "verify_incremental",
    mode = "incr",
    script = "verify.sh",
    timeout = "eternal",
)

test_suite(
    name = "compile",
    tests = [
        ":compile_pyrope",
        ":compile_pyrope_parallel",
        ":compile_verilog",
    ],
)

test_suite(
    name = "sim",
    tests = [
        ":sim_pyrope",
        ":sim_verilog",
    ],
)
