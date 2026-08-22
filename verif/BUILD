# Correctness checks that are not timed benchmarks.
#
# //verif:genprp — regenerate each core's Pyrope FROM ITS VERILOG into the
# test's scratch dir and LEC it against that same Verilog. The checked-in
# <core>/pyrope trees came out of this generator but are never re-derived, so
# without this target a `pass.prp_writer` regression stays invisible until
# somebody regenerates by hand. Nothing here writes to the source tree — the
# checked-in trees are read-only inputs to //bench, and this package does not
# touch them at all.
#
#   bazel test //verif:genprp            # all cores + the xiangshan modules
#   bazel test //verif:genprp_dino       # one core
#   bazel test //verif:genprp_xs         # just the xiangshan Backend modules
#
# //verif:v2v — the longer round trip: Verilog -> generated Pyrope -> generated
# Verilog, checked back against the ORIGINAL Verilog. See its own header below.
#
# Tagged `manual`: a wildcard (`bazel test //...`) skips them, an explicit name
# runs them. They are the "from time to time" check — run after touching
# upass/prp_writer, inou/slang, or the LEC encoder.
#
# Status (2026-08-21, re-measured after the two `genprp.sh` gate fixes below —
# BEFORE them a failing step exited 0 and the target went GREEN, so any status
# recorded here earlier was reporting the log text, not the verdict):
# dino (17 files, 1088 lines) and cva6 (`tag_cmp_wrap`, its documented cone —
# 2 files, 166 lines) are genuinely PROVEN equivalent end to end.
#
# minion is RED, and NOT where the previous note said. It does not reach lec at
# all: step `gen` exits 7 with `unsupported-driver-order` on `rr16_f6a_h`
# (`minion/verilog/txfma_f6.sv:219`) — "a driver reads that net and also writes
# it, before any driver has written it", the generate-loop reduction-tree
# pattern that `--reader slang` cannot order. So the older "regenerates and
# re-reads cleanly, then REFUTES at prim_rst_sync" reading is stale: nothing is
# regenerated. Still a livehd gap rather than a suite one, and still wired up so
# it goes green when that lands.

load("@rules_shell//shell:sh_binary.bzl", "sh_binary")
load("@rules_shell//shell:sh_test.bzl", "sh_test")
load("//bench:defs.bzl", "CORES")

[
    sh_test(
        name = "genprp_" + core,
        size = "medium",
        timeout = "eternal",
        srcs = ["genprp.sh"],
        data = [
            "@livehd//lhd:lhd",
            CORES[core]["pkg"] + ":verilog",
            CORES[core]["pkg"] + ":verilog_filelist",
        ],
        env = {
            "LHD": "$(rlocationpath @livehd//lhd:lhd)",
            "CORE": core,
            "CORE_TOP": CORES[core]["top"],
            "CORE_V_FLAGS": CORES[core]["v_flags"],
            "CORE_V_FLIST": "$(rlocationpath %s:verilog_filelist)" % CORES[core]["pkg"],
        },
        # LEC on a whole core is CPU-hungry; `manual` keeps it off wildcards.
        tags = [
            "core_" + core,
            "exclusive",
            "manual",
        ],
    )
    for core in [
        "dino",
        "cva6",
        "minion",
    ]
]

# --- xiangshan/Backend: a MODULE at a time, not the whole core ----------------
#
# //xiangshan/Backend is ONE 1088-module source tree that the five synth-only
# bench cores select different --top values over. So genprp takes it a MODULE at
# a time: each target picks its own --top out of the same tree, and lhd prunes
# the compile to that top's cone.
#
# The list is (target suffix, module --top) pairs, and it is the ONLY place
# xiangshan genprp targets come from — do not route them through the CORES loop
# above. `pkg` and `v_flags` are identical for every module in this tree
# (`//xiangshan/Backend`, `--single-unit`), so a CORES lookup would buy nothing
# but a second spelling; and a NEW CORES entry, for a name that only ever needs
# to be a --top here, would spawn the entire bench scenario matrix
# (compile/synth/incremental/sim/verilator/...) with it.
#
# Where a module IS already a bench core, the suffix reuses that CORES key, so
# //verif:genprp_xs_alu, //verif:v2v_xs_alu and //bench:xs_alu_* all name the
# same module. Every target carries both `core_xs` (the whole tree) and its own
# `core_<suffix>` tag.
#
# WHICH modules, and why these: measured 2026-08-21, one at a time, as
# gen + re-read + ref + lec on this box.
_XS_TOPS = [
    # 3.5s. The instruction decoder: a 3-module cone over an 8.6k-line body of
    # wide combinational decode tables — the cheap end, and the one to run first
    # when prp_writer changes.
    ("xs_decodeunit", "DecodeUnit"),
    # 51s. Zero submodules and 20x the cost of DecodeUnit anyway: one 15.4k-line
    # body, of which lec is 21.7s. It is here BECAUSE import count is not what
    # this flow costs — body size is — so a small-cone pick alone would leave
    # that shape untested.
    ("xs_busytable", "BusyTable"),
    # 87s, and the slowest module MEASURED IN THIS SWEEP that still proves. Two
    # thirds of its cost is slang, twice (t_gen 43.0s + t_ref 43.1s); lec is
    # 0.5s. It also sits RIGHT at the front-end memory cliff below — same
    # EnqEntry family, peak 24.7 GB, and it survives — so if that blowup ever
    # worsens, this target is what catches it before the whole family goes.
    ("xs_enqentryvecmem", "EnqEntryVecMem"),
    # --- the two that FAIL. Wired up on purpose, exactly as genprp_minion is:
    # they are LiveHD gaps this check exists to surface, and the README's
    # "Known-failing scenarios" table carries the detail. Do NOT drop them from
    # this list, and do NOT reach for an `lhd` option to make them green.
    #
    # FAILS at step 1: `inou.slang` dies with std::bad_alloc, and it is a real
    # blowup rather than this box being busy — re-run on an IDLE machine it just
    # gets further before dying, 34.4 GB RSS at ~47s (under parallel load it
    # died at 17.1 GB / 55s). Siblings EnqEntry and EnqEntry_18 die the same
    # way, so the whole 15-module EnqEntry family is out. The design is NOT
    # large: 275 KB of .sv emitting ~1056 Pyrope lines. For scale, the sibling
    # that DOES survive (EnqEntryVecMem, above) peaks at 24.7 GB to emit 1038
    # lines — this family costs tens of GB either way.
    ("xs_enqentry_4", "EnqEntry_4"),
    # FAILS at step 3, and this one is the GENERATOR's own fault: lec encodes
    # the Verilog reference fine and then reports `impl encode failed: operand
    # of 'get_mask_4184' has no encodable driver (combinational cycle?)` with a
    # WORD-LEVEL CYCLE whose every hop is inside gen/TraceBuffer.prp (:333 ->
    # :417 -> :416 -> :414 -> :403 -> :389 -> :417). A false comb cycle that
    # exists only after the round trip. Single module, no imports, 2.9s — the
    # cheapest reproducer in the tree for this class, which is why it is the one
    # picked over fpsqrt_r16_block (same failure, 3.6s, but 4 files deep).
    ("xs_tracebuffer", "TraceBuffer"),
    # --- the bench cores, same flow, same rule. These are the tops //bench
    # already synthesises, checked here for generator equivalence too. They were
    # NOT part of the 2026-08-21 sweep above, so they carry no measured time;
    # the sweep's finding that big tops get expensive fast (DecodeUnitComp and
    # Dispatch both blow past 900s inside `gen` alone, SSIT goes INCONCLUSIVE
    # after 364s) says to expect ExuBlock and especially Backend — the whole
    # 1088-module hierarchy — to be the long poles of //verif:genprp, and
    # possibly to exceed the runner's cap. Run them by name when that bites.
    ("xs_alu", "Alu"),
    ("xs_div", "DivUnit"),
    ("xs_rob", "Rob"),
    ("xs_exu", "ExuBlock"),
    ("xs_backend", "Backend"),
]

[
    sh_test(
        name = "genprp_" + suffix,
        size = "medium",
        timeout = "eternal",
        srcs = ["genprp.sh"],
        data = [
            "@livehd//lhd:lhd",
            "//xiangshan/Backend:verilog",
            "//xiangshan/Backend:verilog_filelist",
        ],
        env = {
            "LHD": "$(rlocationpath @livehd//lhd:lhd)",
            "CORE": suffix,
            "CORE_TOP": top,
            "CORE_V_FLAGS": "--single-unit",
            "CORE_V_FLIST": "$(rlocationpath //xiangshan/Backend:verilog_filelist)",
        },
        tags = [
            "core_xs",
            "core_" + suffix,
            "exclusive",
            "manual",
        ],
    )
    for suffix, top in _XS_TOPS
]

test_suite(
    name = "genprp_xs",
    tags = ["manual"],
    tests = [":genprp_" + suffix for suffix, _top in _XS_TOPS],
)

test_suite(
    name = "genprp",
    tags = ["manual"],
    tests = [
        ":genprp_cva6",
        ":genprp_dino",
        ":genprp_minion",
        ":genprp_xs",
    ],
)

# End-to-end Verilog -> generated Pyrope -> generated Verilog correctness.
# Native lhd LEC must prove each top; the independent Yosys/lgcheck leg has a
# 10-minute equivalence budget (source reading is outside it), and only a real
# refutation fails. XiangShan uses Backend, the requested whole-hierarchy top;
# child-module checks are a debug fallback when that Yosys proof times out, not
# a substitute for this target.
_V2V_CORES = [
    "dino",
    "minion",
    "xs_alu",
    "xs_div",
    "xs_rob",
    "xs_exu",
    "xs_backend",
]

[
    sh_test(
        name = "v2v_" + core,
        size = "large",
        timeout = "eternal",
        srcs = ["v2v.sh"],
        data = [
            "@livehd//lhd:lhd",
            CORES[core]["pkg"] + ":verilog",
            CORES[core]["pkg"] + ":verilog_filelist",
        ],
        env = {
            "LHD": "$(rlocationpath @livehd//lhd:lhd)",
            "CORE": core,
            "CORE_TOP": CORES[core]["top"],
            "CORE_V_FLAGS": CORES[core]["v_flags"],
            "CORE_V_FLIST": "$(rlocationpath %s:verilog_filelist)" % CORES[core]["pkg"],
        },
        tags = [
            "core_" + core,
            "exclusive",
            "manual",
        ],
    )
    for core in _V2V_CORES
]

# `timeout = "eternal"` still maps to Bazel's default 3600-second test cap.
# That is not suitable for XiangShan: parsing/elaboration is intentionally
# uncapped and only lgcheck's equivalence phase has the 600-second limit. These
# `bazel run` entry points have no test-runner wall timeout and are therefore
# the canonical way to execute the large tops. The sh_tests remain useful for
# CI when invoked with an explicit `--test_timeout=999999`.
[
    sh_binary(
        name = "v2v_run_" + core,
        srcs = ["v2v.sh"],
        data = [
            "@livehd//lhd:lhd",
            CORES[core]["pkg"] + ":verilog",
            CORES[core]["pkg"] + ":verilog_filelist",
        ],
        env = {
            "LHD": "$(rlocationpath @livehd//lhd:lhd)",
            "CORE": core,
            "CORE_TOP": CORES[core]["top"],
            "CORE_V_FLAGS": CORES[core]["v_flags"],
            "CORE_V_FLIST": "$(rlocationpath %s:verilog_filelist)" % CORES[core]["pkg"],
        },
        tags = ["manual"],
    )
    for core in _V2V_CORES
]

test_suite(
    name = "v2v",
    tags = ["manual"],
    tests = [":v2v_" + core for core in _V2V_CORES],
)
