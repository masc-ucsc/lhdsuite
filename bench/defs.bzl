"""core_benches: one sh_test per (core, scenario), all wired to the from-source
lhd.

Every target gets the same runfiles contract (see bench/common.sh): LHD points
at @livehd//lhd:lhd, CORE_* at the design sources and module names, MODE
selects the scenario inside a shared script family (e.g. synth.sh runs cold vs
incremental). Targets are named `<core>_<scenario>`, so a single core runs
with `bazel test //bench:<core>` and a single scenario with
`bazel test //bench:<core>_<scenario>`.

Adding a core = one CORES entry + a package exposing the same filegroup names
as //dino (verilog, verilog_filelist, pyrope, pyrope_top, sim, verif, tests).
"""

load("@rules_shell//shell:sh_test.bzl", "sh_test")

# Per-core knobs:
#   top       whole-design top, in BOTH languages (compile, synthesis, LEC).
#   unit      module carrying the verify sidecar and the bug1/comment1
#             variants; must be inside the top's cone.
#   v_flags   extra slang options for this core's Verilog, appended after the
#             `--` of `lhd compile verilog` (on top of the shared
#             -F filelist.f -DSYNTHESIS).
#   color_algs  which `pass color` algorithms are meaningful for this core.
#             `flat` fuses the whole hierarchy into ONE abc region, so it does
#             not scale past a certain design size; a core that omits it also
#             loses its `synth_lec_flat` target.
#   sim_tb    asserted sim smoke; sim_top_tb / sim_prog_tb are informational
#             drivers ("" = none).
#   sim_expect  fixed string the asserted sim's output must contain besides
#             the "hello world" line — the testbench's known-good data
#             readback. Guards against a sim that runs but computes wrong
#             values (a silently-miscompiled schedule prints data=0 and
#             would otherwise go green). "" = hello-world gate only.
#   lec_trust  comma-separated module-def names the LEC scenarios ASSUME
#             equivalent WITHOUT proving them (`--set formal.lec.trust=…`) —
#             the escape hatch for modules whose cone holds a cell the LEC
#             encoder cannot model yet (a latch: "sequential op 'latch' not
#             supported yet"). The driver skips proving each listed def and
#             black-boxes its instances, so the latch-free majority is still
#             proven bottom-up instead of the whole design refusing. lec.sh
#             also sets formal.strict=true whenever this is non-empty, so a
#             witness-free UNKNOWN top is a hard fail (a trust list must not
#             turn an inconclusive run green). Every trusted def is disclosed
#             ("PROVEN under N trusted def(s)"); include each parameterized
#             `_pN` twin, since a variant is a distinct def. "" = trust
#             nothing (the encoder proves or refuses every def). See the
#             fixme issue 1 roadmap; shrink to "" once latch encoding lands.
CORES = {
    "dino": {
        "pkg": "//dino",
        "top": "PipelinedDualIssueCPU",
        "unit": "ALU",
        "v_flags": "",
        "color_algs": ["flat", "synth"],
        "sim_tb": "stagereg_tb.prp",
        "sim_expect": "data=4660",
        "sim_top_tb": "dino_tb.prp",
        "sim_prog_tb": "dino_prog_tb.prp",
        # dino is latch-free — the encoder proves every def, no trust needed.
        "lec_trust": "",
    },
    "minion": {
        "pkg": "//minion",
        "top": "minion_top",
        "unit": "txfma_adder",
        # minion's RTL needs both: enums assigned from plain bits, and
        # identifiers referenced above their declaration. The generated
        # intpipe_csr_file_auto_*.svh includes resolve relative to the file
        # that includes them, so no -I is required.
        "v_flags": "--relax-enum-conversions --allow-use-before-declare",
        # No `flat`: one region over all 534k nodes projects ~801 GiB at the
        # ABC mapping peak, so `pass abc` refuses it outright. Only the
        # partitioned `color synth` is meaningful at this size.
        "color_algs": ["synth"],
        "sim_tb": "tensora_rf_tb.prp",
        "sim_expect": "data=4660",
        "sim_top_tb": "vpu_top_tb.prp",
        "sim_prog_tb": "",
        # Latch-bearing modules the LEC encoder cannot model yet (fixme issue
        # 1): the 15 minion latch modules plus every parameterized `_pN` twin
        # (a variant is a distinct def, so each must be named). Trusting these
        # lets the ~90 latch-free modules prove bottom-up instead of the whole
        # design refusing on the first latch cone. `trans_top` is deliberately
        # NOT here: it carries an always_latch that lowers to comb and PROVES.
        "lec_trust": ",".join([
            "prim_clk_gate",
            "prim_phase_pair_hi_lo", "prim_phase_pair_hi_lo_p1",
            "prim_phase_pair_lo_hi", "prim_phase_pair_lo_hi_p1",
            "prim_rf_1r1w_preview",
            "prim_rf_1r1w_preview_p1", "prim_rf_1r1w_preview_p2",
            "prim_rf_1r1w_preview_p3", "prim_rf_1r1w_preview_p4",
            "prim_rf_1r1w_preview_p5", "prim_rf_1r1w_preview_p6",
            "prim_rf_1r1w_par_preview", "prim_rf_1r1w_par_preview_p1",
            "prim_rf_1r1w_diff_preview",
            "prim_rf_1r1w_reg_preview",
            "prim_rf_2r1w_preview",
            "prim_rf_3r2w_preview",
            "prim_rf_single_1r1w_par_preview",
            "prim_write_commit_en", "prim_write_commit_en_p1", "prim_write_commit_en_p2",
            "prim_write_commit_rst_en",
            "prim_write_commit_rst_en_p1", "prim_write_commit_rst_en_p2",
            "prim_write_commit_rst_en_p3", "prim_write_commit_rst_en_p4",
            "prim_write_commit_rst_en_p5",
            "prim_write_preview_en", "prim_write_preview_en_p1",
            "intpipe_mul_div_ctl", "intpipe_mul_div_dp",
        ]),
    },
}

# Scenario table shared by every core:
# (suffix, script, MODE, timeout, needs_color). A scenario with needs_color set
# is generated only for cores whose `color_algs` include it.
_SCENARIOS = [
    # --- Lgraph creation throughput (LoC/s, words/s) ---
    ("compile_verilog", "compile.sh", "verilog", "long", ""),
    ("compile_pyrope", "compile.sh", "pyrope", "long", ""),
    # Per-file separate compilation: `lhd scan` dependency discovery, parallel
    # leaf compiles, dependents reuse the pre-compiled units by naming each as
    # a positional `ln:DIR` input (IR inputs are positional, never a flag).
    ("compile_pyrope_parallel", "compile.sh", "pyrope_parallel", "eternal", ""),
    # --- coloring + abc synthesis; cold vs --workdir incremental ---
    ("synth", "synth.sh", "cold", "eternal", ""),
    ("synth_incremental", "synth.sh", "incr", "eternal", ""),
    # Netlist integrity: LEC the 2nd (incremental) synthesis run's netlist
    # against the design, via the partition twin + Liberty gensim models.
    ("synth_lec_flat", "synth.sh", "lec_flat", "eternal", "flat"),
    ("synth_lec_synth", "synth.sh", "lec_synth", "eternal", "synth"),
    # --- hello-world simulation smoke, both language tops ---
    ("sim_verilog", "sim.sh", "verilog", "long", ""),
    ("sim_pyrope", "sim.sh", "pyrope", "long", ""),
    # --- LEC: proven / injected bug caught / warm re-run ---
    ("lec", "lec.sh", "pass", "eternal", ""),
    ("lec_bug", "lec.sh", "bug", "eternal", ""),
    ("lec_incremental", "lec.sh", "incr", "eternal", ""),
    # --- formal assert/assume on one unit; cold vs warm ---
    ("verify", "verify.sh", "cold", "eternal", ""),
    ("verify_incremental", "verify.sh", "incr", "eternal", ""),
]

def _lhd_bench(name, core, cfg, script, mode, timeout):
    pkg = cfg["pkg"]
    sh_test(
        name = name,
        size = "medium",
        timeout = timeout,
        srcs = [script],
        data = [
            "common.sh",
            # lhd's own runfiles carry the `lhd sim` runtime headers (slop.hpp
            # & friends) — no extra staging needed here.
            "@livehd//lhd:lhd",
            pkg + ":pyrope",
            pkg + ":pyrope_top",
            pkg + ":sim",
            pkg + ":tests",
            pkg + ":verif",
            pkg + ":verilog",
            pkg + ":verilog_filelist",
        ],
        env = {
            "LHD": "$(rlocationpath @livehd//lhd:lhd)",
            "CORE": core,
            "CORE_V_FLIST": "$(rlocationpath %s:verilog_filelist)" % pkg,
            "CORE_P_TOP": "$(rlocationpath %s:pyrope_top)" % pkg,
            "CORE_TOP": cfg["top"],
            "CORE_V_FLAGS": cfg["v_flags"],
            "CORE_UNIT": cfg["unit"],
            "CORE_COLOR_ALGS": " ".join(cfg["color_algs"]),
            "CORE_SIM_TB": cfg["sim_tb"],
            "CORE_SIM_EXPECT": cfg["sim_expect"],
            "CORE_SIM_TOP_TB": cfg["sim_top_tb"],
            "CORE_SIM_PROG_TB": cfg["sim_prog_tb"],
            "CORE_LEC_TRUST": cfg.get("lec_trust", ""),
            "MODE": mode,
        },
        # Timing benchmarks: never share the machine with other tests.
        tags = ["exclusive", "core_" + core],
    )

def core_benches(core):
    """Generate every scenario for one core plus a `//bench:<core>` suite."""
    cfg = CORES[core]
    names = []
    for suffix, script, mode, timeout, needs_color in _SCENARIOS:
        if needs_color and needs_color not in cfg["color_algs"]:
            continue  # e.g. no synth_lec_flat on a core too big to color flat
        name = "%s_%s" % (core, suffix)
        _lhd_bench(name, core, cfg, script, mode, timeout)
        names.append(":" + name)

    # `bazel test //bench:<core>` — every scenario for this core only.
    native.test_suite(name = core, tests = names)
