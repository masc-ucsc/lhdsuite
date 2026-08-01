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
#   sim_tb    asserted, timed sim benchmark. sim_cycles is its explicit cycle
#             count; sim_tb_top says it needs the whole-design source supplied
#             before the testbench (e.g. a program driver importing `lg:top`).
#             sim_top_tb / sim_prog_tb are additional whole-top correctness
#             drivers ("" = none). sim_top_cycles / sim_prog_cycles make their
#             otherwise in-source test defaults explicit in the bench log and
#             report ("" when the corresponding driver is absent).
#   sim_tb_v  MODE=verilog override for sim_tb (optional; "" or absent = drive
#             both modes with the one sim_tb). The two trees are the same
#             design but not the same Pyrope: a `struct packed` port is
#             re-emitted from Verilog as a tuple port
#             (`io_in:(instruction:u32, …)`) while the checked-in Pyrope tree
#             may declare it flat (`io_in:u97`), and a driver written for one
#             shape names no field of the other. The former dino StageReg
#             microbenchmark needed this; no current core does.
#   sim_top_assert  whether this core's additional drivers (sim_top_tb and
#             sim_prog_tb) are a GATE rather than a metric. They are always
#             reported as METRIC sim_cpu_top_ok / sim_cpu_prog_ok; with this
#             set, a driver that scores 0 also FAILS the target. Set it once a
#             core's drivers pass in BOTH modes — leaving it off on a core whose
#             top still hits an lhd gap keeps the metric visible without
#             painting the target red. "" = metric only.
#   sim_expect  fixed string the asserted sim's output must contain besides
#             sim_marker — the testbench's known-good data
#             readback. Guards against a sim that runs but computes wrong
#             values (a silently-miscompiled schedule prints data=0 and
#             would otherwise go green). "" = marker gate only.
#   lec_trust  comma-separated module-def names the LEC scenarios ASSUME
#             equivalent WITHOUT proving them (`--set formal.lec.trust=…`) —
#             the escape hatch for defs holding a latch or negedge flop the LEC
#             encoder cannot normalize across a module boundary yet ("def `X`
#             holds N latch cell(s) … not supported yet"). A latch in the
#             design's OWN body encodes fine; it is the hierarchy that refuses.
#             The driver skips proving each listed def and
#             black-boxes its instances, so the latch-free majority is still
#             proven bottom-up instead of the whole design refusing. lhd is
#             strict by default, so a witness-free UNKNOWN top is a hard fail
#             (a trust list must not turn an inconclusive run green). Every
#             trusted def is disclosed
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
        # Time the real program on the whole CPU. This is long enough to be a
        # useful throughput measurement and checks architectural state through
        # the program's stores, unlike the old 200k-cycle StageReg microbench.
        "sim_tb": "dino_prog_tb.prp",
        "sim_cycles": 2000,
        "sim_tb_top": True,
        "sim_tb_v": "",
        "sim_marker": "dino program:",
        "sim_expect": "x2=100 -x3=102",
        "sim_top_tb": "dino_tb.prp",
        "sim_top_cycles": 1000,
        # The program driver above is already asserted and timed, so do not run
        # it a second time as an auxiliary correctness driver.
        "sim_prog_tb": "",
        "sim_prog_cycles": "",
        # Both whole-CPU drivers are GATES, in both modes: the timed program
        # driver asserts in-source, while dino_tb scores 1 on the checked-in
        # Pyrope tree and on the re-emitted Verilog one (which needed the sim
        # cgen to stop spelling a child instance's tuple port
        # `io_data_instruction` in the parent and `io_data.instruction` in the
        # child). dino_tb asserts that the PC advanced past reset;
        # dino_prog_tb asserts that the program stored both counters and that
        # x2/x3 hold the architected values.
        "sim_top_assert": True,
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
        "sim_cycles": 200000,
        "sim_tb_top": False,
        # vpu_tensora_rf's ports are all flat in both trees — one driver serves
        # MODE=pyrope and MODE=verilog.
        "sim_tb_v": "",
        "sim_marker": "hello world",
        "sim_expect": "data=4660",
        "sim_top_tb": "vpu_top_tb.prp",
        "sim_top_cycles": 64,
        "sim_prog_tb": "",
        "sim_prog_cycles": "",
        # Informational: `lhd sim` still refuses vpu_top — "module
        # `vpu_trans.vpu_trans`: flop `flop_76:id_insert_en_o` has a derived
        # clock inou.cgen.sim cannot fold into a commit guard", the same
        # gated-clock cone as fixme issue 1, on the sim-cgen side. Flip this to
        # True once that lands.
        "sim_top_assert": False,
        # MEASURED trust list (2026-08-01). It used to hold 32 entries — every
        # latch-bearing module — because the LEC encoder refused a `Latch` cell
        # outright. With the formal phase schedule (livehd todo/livehd/2f-lec
        # "phase-schedule" / 2f-latch M10) the encoder models latches, negedge
        # endpoints and clock gates directly, and 31 of those 32 defs now PROVE
        # standalone; each was re-measured one at a time with
        #   lhd lec --impl lg:impl --ref lg:ref --top <def>
        # ONE entry survives, and it is a real scope limit rather than a missing
        # feature: `prim_rf_1r1w_diff_preview` is the DIFFERENT-preview-clock
        # variant, so `preview_clk_i` and `rf_clk_i` are genuinely unrelated nets
        # (its siblings tie them together at every instantiation site, which is
        # what the design-wide clock-port propagation now proves). It also holds a
        # clock-role latch on `preview_clk_i` and a negedge flop plus a memory on
        # `rf_clk_i`, so scheduling it needs a total order between two unrelated
        # roots — which v1 refuses BY NAME rather than invent. Retire this entry
        # when multi-root scheduling lands.
        "lec_trust": "prim_rf_1r1w_diff_preview",
    },
}

# Scenario table shared by every core:
# (suffix, script, MODE, timeout, needs_color). A scenario with needs_color set
# is generated only for cores whose `color_algs` include it.
_SCENARIOS = [
    # --- Lgraph creation throughput (LoC/s, words/s) ---
    ("compile_verilog", "compile.sh", "verilog", "long", ""),
    ("compile_pyrope", "compile.sh", "pyrope", "long", ""),
    # Per-file separate compilation driven by a real build system: `lhd scan`
    # dependency discovery -> generated Makefile (one rule per file, deps = its
    # direct imports, pruned to --top's cone) -> `make -j`. Dependencies ride in
    # pre-lowered as positional `lg:DIR` inputs (IR inputs are positional, never
    # a flag), falling back to `ln:DIR` only for packages that emit no lgraph.
    ("compile_pyrope_parallel", "compile.sh", "pyrope_parallel", "eternal", ""),
    # --- coloring + abc synthesis; cold vs --workdir incremental ---
    ("synth", "synth.sh", "cold", "eternal", ""),
    ("synth_incremental", "synth.sh", "incr", "eternal", ""),
    # Netlist integrity: LEC the 2nd (incremental) synthesis run's netlist
    # against the design, via the partition twin + Liberty gensim models.
    ("synth_lec_flat", "synth.sh", "lec_flat", "eternal", "flat"),
    ("synth_lec_synth", "synth.sh", "lec_synth", "eternal", "synth"),
    # --- asserted simulation benchmark, both language sources ---
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
            # scan.json -> build.mk + BUILD.bazel for MODE=pyrope_parallel.
            "gen_build.py",
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
            "CORE_SIM_CYCLES": str(cfg["sim_cycles"]),
            "CORE_SIM_TB_TOP": "1" if cfg.get("sim_tb_top", False) else "",
            "CORE_SIM_TB_V": cfg.get("sim_tb_v", ""),
            "CORE_SIM_MARKER": cfg["sim_marker"],
            "CORE_SIM_EXPECT": cfg["sim_expect"],
            "CORE_SIM_TOP_TB": cfg["sim_top_tb"],
            "CORE_SIM_TOP_CYCLES": str(cfg.get("sim_top_cycles", "")),
            "CORE_SIM_PROG_TB": cfg["sim_prog_tb"],
            "CORE_SIM_PROG_CYCLES": str(cfg.get("sim_prog_cycles", "")),
            # "1" = the whole-top drivers gate the target; "" = metric only.
            "CORE_SIM_TOP_ASSERT": "1" if cfg.get("sim_top_assert", False) else "",
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
