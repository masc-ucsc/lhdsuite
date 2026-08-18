"""core_benches: one sh_test per (core, scenario), all wired to the from-source
lhd.

Every target gets the same runfiles contract (see bench/common.sh): LHD points
at @livehd//lhd:lhd, CORE_* at the design sources and module names, MODE
selects the scenario inside a shared script family (e.g. synth.sh runs cold vs
incremental). Targets are named `<core>_<scenario>`, so a single core runs
with `bazel test //bench:<core>` and a single scenario with
`bazel test //bench:<core>_<scenario>`.

Adding a full core = one CORES entry + a package exposing the same filegroup
names as //dino.  A `synth_only` core needs only verilog,
verilog_filelist, pyrope, and pyrope_top; it emits the compile and synthesis
scenarios, not simulation/formal/LEC scenarios.
"""

load("@rules_shell//shell:sh_test.bzl", "sh_test")

# Per-core knobs:
#   top       whole-design top, in BOTH languages (compile, synthesis, LEC).
#   unit      module carrying the verify sidecar and the bug1/comment1
#             variants; must be inside the top's cone.
#   seq_unit  module carrying a SEQUENTIAL verify sidecar
#             (<core>/verif/<seq_unit>.verify.prp), i.e. one whose properties
#             relate a cycle to the next with `past`/`stable`/`rose`/... The
#             `unit` sidecars are pure arithmetic and cannot exercise that at
#             all. "" = the core has none and no `<core>_verify_temporal` is
#             generated.
#   v_flags   extra slang options for this core's Verilog, appended after the
#             `--` of `lhd compile verilog` (on top of the shared
#             -F filelist.f -DSYNTHESIS).
#   color_algs  which `pass color` algorithms are meaningful for this core.
#             `flat` fuses the whole hierarchy into ONE abc region, so it does
#             not scale past a certain design size; a core that omits it also
#             loses its `synth_lec_flat` target.
#   sim_tb    asserted, timed sim benchmark. sim_cycles is its explicit cycle
#             count. sim_top_tb / sim_prog_tb are additional whole-top
#             correctness drivers ("" = none). sim_top_cycles /
#             sim_prog_cycles make their otherwise in-source test defaults
#             explicit in the bench log and report ("" when the corresponding
#             driver is absent).
#   sim_tb_unit / sim_top_tb_unit / sim_prog_tb_unit
#             the module each of those three drivers DRIVES, i.e. the name it
#             spells in its `import("lg:NAME")`. bench/sim.sh supplies that
#             module ahead of the testbench: the unit's own source under
#             MODE=pyrope, an `lg:` library rooted at it under MODE=verilog.
#             It must be a per-driver name rather than just `top`, because
#             `lhd sim` cgen's EVERY graph in the library it is handed — point
#             it at the whole-core library and it refuses over modules the
#             testbench never instantiates (minion's tensor RF benchmark dies
#             on `vpu_ctrl` and `intpipe_csr_file`). Drivers sharing a unit
#             share the one compile. "" where the driver is "".
#   sim_tb_v  MODE=verilog override for sim_tb (optional; "" or absent = drive
#             both modes with the one sim_tb). Needed when the two sides
#             declare a port differently and a driver written for one shape
#             names no field of the other. The former dino StageReg
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
#   sim_sets  extra `--set k=v` flags for THIS core's `lhd sim` invocations
#             (both the timed benchmark and the correctness drivers), space
#             separated, each already spelled `--set k=v`. "" = none. It exists
#             for a driver whose contract needs a knob the shared script cannot
#             infer. No current core needs one: Minion's architectural state is
#             initialized by its boot ROM and its control bookkeeping resets in
#             hardware, so it runs correctly with randomized startup.
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
#   verilator_tb  C++ testbench under <core>/sim/ that mirrors sim_tb for the
#             Verilator comparison target ("" or absent = this core has no
#             verilator scenario, and no `<core>_sim_verilator` is generated).
#             It is held to the SAME sim_marker / sim_expect gates as `lhd
#             sim`, so it doubles as a cross-simulator oracle: two independent
#             simulators disagreeing about the design fails a target.
#   verilator_flags  extra verilator options for this core, the counterpart of
#             v_flags on the slang side (they are NOT interchangeable —
#             v_flags are slang spellings).
#   verilator_cycles  cycle count for the LONG verilator throughput run.
#             sim_cycles is also run, so the matched-count columns line up with
#             the lhd targets, but at verilator speeds it is over in single-
#             digit milliseconds — mostly process startup — so the cycles/s
#             number comes from this longer run instead.
CORES = {
    "dino": {
        "pkg": "//dino",
        "top": "PipelinedDualIssueCPU",
        "unit": "ALU",
        # The pipeline stage register: load / hold / flush / reset are all
        # "one cycle after", so its whole contract is a `past` property.
        "seq_unit": "StageReg",
        "v_flags": "",
        "color_algs": ["flat", "synth"],
        # Time the real program on the whole CPU. This checks architectural
        # state through the program's stores, unlike the old StageReg
        # microbench. The program's two stores land at cycle 521 and it then
        # spins, so every cycle past that is pure throughput and the gates hold
        # at any count.
        #
        # The count has been re-tuned as the simulator improved, always for the
        # same reason:
        # it must keep the measured interval above this box's noise floor (see
        # best_run in common.sh). 2k was 0.22 s. 20k was ~2.2 s — until
        # livehd's sim cgen stopped calling Slop::get_mask_op for constant bit
        # slices (439 call sites -> 3) and dino went from ~9k to ~383k
        # cycles/s, which put 20k back down to 52 ms, i.e. mostly process
        # startup. Use 4M so both `lhd sim` and Verilator spend enough time in
        # the active workload to keep startup and scheduling noise secondary.
        # Re-check this number after any large sim speedup — a benchmark that
        # has outrun its own cycle count reports startup, not the simulator.
        "sim_tb": "dino_prog_tb.prp",
        "sim_cycles": 4000000,
        "sim_tb_unit": "PipelinedDualIssueCPU",
        "sim_tb_v": "",
        "sim_marker": "dino program:",
        "sim_expect": "x2=100 -x3=102",
        "sim_top_tb": "dino_tb.prp",
        "sim_top_tb_unit": "PipelinedDualIssueCPU",
        "sim_top_cycles": 1000,
        # The program driver above is already asserted and timed, so do not run
        # it a second time as an auxiliary correctness driver.
        "sim_prog_tb": "",
        "sim_prog_tb_unit": "",
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
        # The Verilator comparison. dino/sim/dino_prog_tb_verilator.cpp is a
        # line-by-line twin of dino_prog_tb.prp (same ROM, same poke/peek
        # order), and all three simulators print the same
        # `x2=100 -x3=102, done at cycle 521, IPC=641`.
        # 8M cycles for the throughput run: verilator does dino at ~4.3M
        # cycles/s (re-measured 2026-08-09; it was ~2.8M when this knob was
        # added), so anything shorter measures process startup. The matched 4M
        # and long 8M runs keep the historical ~17-19 ms process startup
        # secondary; rerun both modes before quoting a new steady-state ratio.
        "verilator_tb": "dino_prog_tb_verilator.cpp",
        "verilator_flags": "",
        "verilator_cycles": 8000000,
    },
    "cva6": {
        "pkg": "//cva6",
        # tag_cmp_wrap, not tag_cmp: tag_cmp takes its cache-line types as
        # module PARAMETERS, and standalone they default to `logic` — the tag
        # compare collapses and hit_way_o is undriven, so every property over it
        # passes vacuously. The wrapper binds them as std_nbdcache.sv does.
        "top": "tag_cmp_wrap",
        "unit": "tag_cmp_wrap",
        # No sequential sidecar yet; the onehot property already uses `past`.
        "seq_unit": "",
        # CVA6 packages reference identifiers across files, so one compilation
        # unit; the filelist carries the elaboration order.
        "v_flags": "--single-unit",
        "color_algs": ["flat", "synth"],
        "sim_tb": "tag_cmp_tb.prp",
        "sim_tb_unit": "tag_cmp_wrap",
        "sim_cycles": "200",
        "sim_marker": "cva6 tag_cmp:",
        # An empty cache must report NO hit. The line array is 1392 bits and a
        # testbench scalar truncates past 64, so a populated array cannot be
        # driven at all — the miss path is what is checkable here.
        "sim_expect": "hit_way=0",
        "sim_top_tb": "",
        "sim_prog_tb": "",
        "lec_trust": "",
        "verilator_tb": "",
    },
    "minion": {
        "pkg": "//minion",
        "top": "minion_top",
        "unit": "txfma_adder",
        # No sequential sidecar yet. vpu_trans or a dcache handshake would be
        # the natural target — both are stateful and already in the top's cone.
        "seq_unit": "",
        # minion's RTL needs both: enums assigned from plain bits, and
        # identifiers referenced above their declaration. The generated
        # intpipe_csr_file_auto_*.svh includes resolve relative to the file
        # that includes them, so no -I is required.
        "v_flags": "--relax-enum-conversions --allow-use-before-declare",
        # No `flat`: one region over all 534k nodes projects ~801 GiB at the
        # ABC mapping peak, so `pass abc` refuses it outright. Only the
        # partitioned `color synth` is meaningful at this size.
        "color_algs": ["synth"],
        # THE benchmark is the whole-core program workload, the counterpart of
        # dino_prog — a real RISC-V instruction stream on minion_top, with a C++
        # twin (minion_prog_tb_verilator.cpp) so the Verilator comparison is the
        # same design and the same stimulus. The tensor-RF and vpu_top drivers
        # below are kept as secondary correctness/debug runs.
        "sim_tb": "minion_prog_tb.prp",
        # 100k: the driver's own default, and its instruction stream loops
        # forever so the workload stays ACTIVE for the whole count (it never
        # falls into an idle spin the way a completed program would). This
        # keeps the measured interval comfortably above the noise floor.
        "sim_cycles": 100000,
        # minion_top, the whole core. This USED to be impossible — the comment
        # here recorded that `lhd sim` refused the whole-core library over
        # `vpu_ctrl` (a false combinational loop) and `intpipe_csr_file` (a
        # derived clock). Both are gone: the loop was a false positive the
        # colour planner now orders, and the clock gates fold into flop enables
        # ("`intpipe_csr_file`: inlined 2 clock-gate cell(s)").
        "sim_tb_unit": "minion_top",
        # minion_top's ports are flat on both sides — one driver serves
        # MODE=pyrope and MODE=verilog.
        "sim_tb_v": "",
        # The boot ROM zeros the architectural integer registers. The mul/div
        # phase-pair control state also has an explicit reset, so the whole-core
        # workload is deterministic under fully randomized simulator startup.
        "sim_sets": "",
        "sim_marker": "minion program:",
        # Marker only, deliberately. The driver's own asserts are the real gate
        # (`retired >= 100`, `1024 <= last_pc < 1088`), and they are the RIGHT
        # gate: the two simulators sit at a small phase offset, so an exact retire count
        # is not a valid cross-simulator oracle — and sim_expect is applied to
        # the verilator scenario too.
        "sim_expect": "",
        "sim_top_tb": "vpu_top_tb.prp",
        "sim_top_tb_unit": "vpu_top",
        "sim_top_cycles": 64,
        # Secondary: the tensor-RF microbenchmark that used to be the timed
        # benchmark. Kept as an untimed correctness driver — it is a much
        # smaller cone than the core and exercises the preview/commit latch
        # protocol, which the program workload does not reach.
        "sim_prog_tb": "tensora_rf_tb.prp",
        "sim_prog_tb_unit": "vpu_tensora_rf",
        "sim_prog_cycles": 100000,
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
        "lec_trust": "",  # emptied 2026-08-02: prim_rf_1r1w_diff_preview PROVES now (it was blocked by the comb-memory phase-gating bug, not by clocks)
        # The Verilator comparison, now that the timed benchmark is the program
        # workload: minion_prog_tb_verilator.cpp is a line-by-line twin of
        # minion_prog_tb.prp (same ROM, same poke/observe order, same stimulus
        # schedule). It was written before this entry existed — the previous
        # comment here asked for exactly this file.
        "verilator_tb": "minion_prog_tb_verilator.cpp",
        "verilator_flags": "",
        # 200k for the throughput run: 10x the matched count, so the measured
        # interval is dominated by simulation rather than process startup.
        "verilator_cycles": 200000,
    },
    # The two XS blocks that also carry the SIM phase. Their drivers are
    # compile/throughput benchmarks and a cross-language oracle, NOT functional
    # coverage: `lhd sim` refuses to WRITE a hierarchical path more than one
    # level into a DUT port, and a testbench scalar truncates past 64 bits, so
    # Alu's whole datapath (ctrl.*, data.*) and Rob's 4080-bit io_enq_req are
    # left at their defaults. What they DO measure is exactly what this loop
    # optimizes — codegen time, host C++ compile time and cycles/s — and the
    # checksum is cross-validated against the Verilog side rather than blessed
    # from one run.
    "xs_rob": {
        "pkg": "//xiangshan/Backend",
        "top": "Rob",
        "unit": "Rob",
        "v_flags": "--single-unit",
        "color_algs": ["synth"],
        "synth_only": True,
        "sim_tb": "xs_rob_tb.prp",
        "sim_cycles": 1000,
        "sim_tb_unit": "Rob",
        "sim_marker": "xs_rob:",
        # Verilog side prints sum=4607111980261556205; the Pyrope side became
        # compilable only once the DPI sink models existed, so the two are
        # cross-checked by the sim_pyrope/sim_verilog pair rather than pinned
        # here from one side's output.
        "sim_expect": "",
        # Rob at 1000 cycles simulates in milliseconds — that count is the
        # marker/checksum gate, not a throughput measurement (T1).
        "sim_perf_cycles": 200000,
    },
    "xs_alu": {
        "pkg": "//xiangshan/Backend",
        "top": "Alu",
        "unit": "Alu",
        "v_flags": "--single-unit",
        "color_algs": ["synth"],
        "synth_only": True,
        "sim_tb": "xs_alu_tb.prp",
        "sim_cycles": 1000,
        "sim_tb_unit": "Alu",
        "sim_marker": "xs_alu:",
        # Verified identical from BOTH language sides at 1000 cycles, which is
        # what makes it safe to pin: 888709067567740450 from the .prp tree and
        # from `lhd compile verilog --top Alu`.
        "sim_expect": "sum=888709067567740450",
        "sim_perf_cycles": 2000000,
    },
    "xs_div": {
        "pkg": "//xiangshan/Backend",
        "top": "DivUnit",
        "unit": "DivUnit",
        "v_flags": "--single-unit",
        "color_algs": ["synth"],
        "synth_only": True,
    },
    "xs_exu": {
        "pkg": "//xiangshan/Backend",
        "top": "ExuBlock",
        "unit": "ExuBlock",
        "v_flags": "--single-unit",
        "color_algs": ["synth"],
        "synth_only": True,
        "slow": True,
    },
    "xs_backend": {
        "pkg": "//xiangshan/Backend",
        "top": "Backend",
        "unit": "Backend",
        "v_flags": "--single-unit",
        "color_algs": ["synth"],
        "synth_only": True,
        "slow": True,
    },
}

# Scenario table shared by every core:
# (suffix, script, MODE, timeout, needs_color, needs_cfg). A scenario with
# needs_color set is generated only for cores whose `color_algs` include it; one
# with needs_cfg set only for cores whose CORES entry has that key non-empty.
# Both exist so a core that cannot run a scenario has no target for it at all,
# rather than a target that fails or silently no-ops.
_SCENARIOS = [
    # --- Lgraph creation throughput (LoC/s, words/s) ---
    ("compile_verilog", "compile.sh", "verilog", "long", "", ""),
    ("compile_pyrope", "compile.sh", "pyrope", "long", "", ""),
    # Per-file separate compilation driven by a real build system: `lhd scan`
    # dependency discovery -> generated Makefile (one rule per file, deps = its
    # direct imports, pruned to --top's cone) -> `make -j`. Dependencies ride in
    # pre-lowered as positional `lg:DIR` inputs (IR inputs are positional, never
    # a flag), falling back to `ln:DIR` only for packages that emit no lgraph.
    ("compile_pyrope_parallel", "compile.sh", "pyrope_parallel", "eternal", "", ""),
    # The three-pass front-end rebuild over ONE --workdir: cold, comment-only
    # touch, one real edit. Gated on WALL TIME, never on a hit count (I4) —
    # there is no front-end cache yet, so its job on day one is to put the cold
    # numbers in the ledger and make a future L8 lever attributable.
    ("compile_incremental", "compile.sh", "incr", "eternal", "", ""),
    # --- coloring + abc synthesis; cold vs --workdir incremental ---
    ("synth", "synth.sh", "cold", "eternal", "", ""),
    ("synth_incremental", "synth.sh", "incr", "eternal", "", ""),
    # Netlist integrity: LEC the 2nd (incremental) synthesis run's netlist
    # against the design, via the partition twin + Liberty gensim models.
    ("synth_lec_flat", "synth.sh", "lec_flat", "eternal", "flat", ""),
    ("synth_lec_synth", "synth.sh", "lec_synth", "eternal", "synth", ""),
    # --- asserted simulation benchmark, both language sources ---
    # needs_cfg="sim_tb": a core with no driver has no sim target at all, rather
    # than one that fails on `--top ''`. That is also what lets a synth-only
    # core opt IN to simulation just by naming a driver.
    ("sim_verilog", "sim.sh", "verilog", "long", "", "sim_tb"),
    ("sim_pyrope", "sim.sh", "pyrope", "long", "", "sim_tb"),
    # The sim counterpart of synth_incremental: three passes over ONE workdir
    # AND one emit dir, reporting sim_setup_ms / sim_cc_ms / sim_exec_ms on
    # every pass. sim_exec_ms is the I3 guardrail — a pass that cuts the host
    # compile while slowing the simulation fails here.
    ("sim_incremental", "sim.sh", "incr", "eternal", "", "sim_tb"),
    # The same benchmark under Verilator, for cores carrying a C++ twin of
    # their sim_tb: how `lhd sim` compares against the reference simulator on
    # compile time AND on cycles/s. Held to the same output gates, so it is
    # also a cross-simulator oracle. Skips (does not fail) where verilator is
    # not installed.
    ("sim_verilator", "sim_verilator.sh", "verilator", "long", "", "verilator_tb"),
    # --- LEC: proven / injected bug caught / warm re-run ---
    ("lec", "lec.sh", "pass", "eternal", "", ""),
    ("lec_bug", "lec.sh", "bug", "eternal", "", ""),
    ("lec_incremental", "lec.sh", "incr", "eternal", "", ""),
    # --- formal assert/assume on one unit; cold vs bug-caught vs warm ---
    ("verify", "verify.sh", "cold", "eternal", "", ""),
    # The formal twin of lec_bug: proving the sidecar is only half the contract,
    # the other half is that a real bug is CAUGHT. Without this the verify flow
    # could regress to proving nothing and stay green.
    ("verify_bug", "verify.sh", "bug", "eternal", "", ""),
    # The suite's TEMPORAL coverage: properties that relate one cycle to the
    # next (`past`, `stable`), which the combinational `unit` sidecars cannot
    # reach. Deeper bound than the arithmetic scenarios — a sequential claim
    # that only holds for two cycles is not worth much.
    ("verify_temporal", "verify.sh", "temporal", "eternal", "", "seq_unit"),
    ("verify_incremental", "verify.sh", "incr", "eternal", "", ""),
]

def _lhd_bench(name, core, cfg, script, mode, timeout):
    pkg = cfg["pkg"]
    synth_only = cfg.get("synth_only", False)
    data = [
        "common.sh",
        # scan.json -> build.mk + BUILD.bazel for MODE=pyrope_parallel.
        "gen_build.py",
        # lhd's own runfiles carry the `lhd sim` runtime headers (slop.hpp
        # & friends) — no extra staging needed here.
        "@livehd//lhd:lhd",
        pkg + ":pyrope",
        pkg + ":pyrope_top",
        pkg + ":verilog",
        pkg + ":verilog_filelist",
    ]
    if not synth_only:
        data.extend([
            pkg + ":tests",
            pkg + ":verif",
        ])
    else:
        data.extend([
            pkg + ":pyrope_stubs",
            pkg + ":pyrope_stub_top",
        ])

    # The drivers are staged for any core that names one, synth-only or not —
    # otherwise a synth-only core's sim scenario would run with an empty tree/.
    if cfg.get("sim_tb", ""):
        data.append(pkg + ":sim")

    sh_test(
        name = name,
        size = "medium",
        timeout = timeout,
        srcs = [script],
        data = data,
        env = {
            "LHD": "$(rlocationpath @livehd//lhd:lhd)",
            "CORE": core,
            "CORE_V_FLIST": "$(rlocationpath %s:verilog_filelist)" % pkg,
            "CORE_P_TOP": "$(rlocationpath %s:pyrope_top)" % pkg,
            "CORE_P_STUB_TOP": "$(rlocationpath %s:pyrope_stub_top)" % pkg if synth_only else "",
            "CORE_TOP": cfg["top"],
            "CORE_V_FLAGS": cfg["v_flags"],
            "CORE_UNIT": cfg["unit"],
            "CORE_SEQ_UNIT": cfg.get("seq_unit", ""),
            "CORE_COLOR_ALGS": " ".join(cfg["color_algs"]),
            "CORE_SYNTH_ONLY": "1" if synth_only else "",
            # The 30-minute hard gate applies to the end-to-end synthesis
            # scenarios, not source-only compile measurements.
            "CORE_SYNTH_BUDGET_S": "1800" if cfg.get("slow", False) and script == "synth.sh" else "",
            "CORE_SIM_TB": cfg.get("sim_tb", ""),
            "CORE_SIM_CYCLES": str(cfg.get("sim_cycles", "")),
            # The I3 throughput leg's cycle count, when the gate count is too
            # short to clear the noise floor (T1: 1000 cycles measures process
            # startup). "" = time the gate count itself.
            "CORE_SIM_PERF_CYCLES": str(cfg.get("sim_perf_cycles", "")),
            "CORE_SIM_TB_UNIT": cfg.get("sim_tb_unit", ""),
            "CORE_SIM_TOP_UNIT": cfg.get("sim_top_tb_unit", ""),
            "CORE_SIM_PROG_UNIT": cfg.get("sim_prog_tb_unit", ""),
            "CORE_SIM_TB_V": cfg.get("sim_tb_v", ""),
            "CORE_SIM_SETS": cfg.get("sim_sets", ""),
            "CORE_SIM_MARKER": cfg.get("sim_marker", ""),
            "CORE_SIM_EXPECT": cfg.get("sim_expect", ""),
            "CORE_SIM_TOP_TB": cfg.get("sim_top_tb", ""),
            "CORE_SIM_TOP_CYCLES": str(cfg.get("sim_top_cycles", "")),
            "CORE_SIM_PROG_TB": cfg.get("sim_prog_tb", ""),
            "CORE_SIM_PROG_CYCLES": str(cfg.get("sim_prog_cycles", "")),
            # "1" = the whole-top drivers gate the target; "" = metric only.
            "CORE_SIM_TOP_ASSERT": "1" if cfg.get("sim_top_assert", False) else "",
            "CORE_LEC_TRUST": cfg.get("lec_trust", ""),
            "CORE_VERILATOR_TB": cfg.get("verilator_tb", ""),
            "CORE_VERILATOR_FLAGS": cfg.get("verilator_flags", ""),
            "CORE_VERILATOR_CYCLES": str(cfg.get("verilator_cycles", "")),
            "MODE": mode,
        },
        # Timing benchmarks: never share the machine with other tests.
        tags = ["exclusive", "core_" + core] + (["slow"] if cfg.get("slow", False) else []),
    )

def core_benches(core):
    """Generate every scenario for one core plus a `//bench:<core>` suite."""
    cfg = CORES[core]
    names = []
    for suffix, script, mode, timeout, needs_color, needs_cfg in _SCENARIOS:
        # `synth_only` says "this core ships no verify sidecar and no LEC
        # reference", not "this core cannot be simulated". Simulation is
        # decided by needs_cfg="sim_tb" below, so a synth-only core that names
        # a driver gets the sim scenarios and one that does not gets none.
        if cfg.get("synth_only", False) and suffix not in [
            "compile_verilog",
            "compile_pyrope",
            "compile_pyrope_parallel",
            "compile_incremental",
            "synth",
            "synth_incremental",
            "sim_verilog",
            "sim_pyrope",
            "sim_incremental",
        ]:
            continue
        if needs_color and needs_color not in cfg["color_algs"]:
            continue  # e.g. no synth_lec_flat on a core too big to color flat
        if needs_cfg and not cfg.get(needs_cfg, ""):
            continue  # e.g. no sim_verilator on a core with no verilator_tb
        name = "%s_%s" % (core, suffix)
        _lhd_bench(name, core, cfg, script, mode, timeout)
        names.append(":" + name)

    # `bazel test //bench:<core>` — every scenario for this core only.
    native.test_suite(name = core, tests = names)
