# nicesynth: what would make synthesis easier and more effective

Written while annotating the `pyrope2` cores of this suite (dino, picorv32,
matched_filter, rocket; xiangshan deliberately skipped) against livehd
`fd89c17a1`, ASAP7 merged Liberty, `lhd synth` ABC mapper, `pass.abc.memory=false`
(memories stay native, per the standing rule), 1000 ps target (the suite has no SDC).
Every synth here takes 4-52 s, so the loop below is cheap; the cost was knowing
*where to look*, not running it.

## Status log (kept current; newest findings at the bottom of each section)

| id | item | state | where |
| --- | --- | --- | --- |
| C1 | tuner explores partition granularity | **ask me later** (owner has an alternative proposal; do not start) | knob exists: `synth.partition` |
| C2 | source-attributed critical path | open | |
| C3 | memory table / small reg arrays as flops | partly done: `abc.memories` table (name, size, bits, ports, clocks, realization, reason) + `synth.memory` pin; flop-vector rule not needed under auto (>3 ports folds) | uncommitted |
| C4 | nested explicit colors worsen QoR, no warning | warning done (`synth-nested-group`, located, node/cut counts); `grow` default for the inner group still open | uncommitted |
| C5 | LEC state pairing breaks when regions merge (flop names lose instance path) | open, highest-value fix | |
| C7 | arithmetic sharing across ALU arms | `synth.partition=coarse|fine` source attribute added (livehd 5097e08d9); analysed 2026-10-10: compare/sub sharing is automatic inside one region (strash); the loss is the default fine partition (C1) and three separate shifters; LEC-proven shared-shifter/one-adder ALU measured (below); no compiler pass added | |
| C8 | timing target / SDC awareness | done: `qor.timing_target` {source,target_ps,achieved_ps,slack_ps,met,unreachable} + `synth-target-unreachable` info (>25 % over) | uncommitted |
| C9 | partition profile depends on mapper, colors do not | done (`synth.partition`) | e42544dd4 |
| C10 | profile ranks and stops early | done | e42544dd4 |
| C11 | `synth.stop_*` cut conditions as attributes | done | uncommitted |
| C12 | attribute on a callee comb disables LNAST inlining (+18-22 % cells on picorv32) | done: attributed combs are inlined like any other; policy rides `__synth_push`/`__synth_pop` markers; unused call-site pins warn | uncommitted |
| C13 | runner: attributed callee in an inline frame / bare positional actual | done | uncommitted |
| C14 | USYN synthesis quality gap on CPU logic (same partition: +14 % cells, +36 % delay on dino) | mostly closed: Brent-Kung auto adders, `pass.usyn.tmap_pre` (&dch default), carry loops unrolled; remaining: native search exhaustion on large state cones (br_arb_lru) | livehd fc7433db3, 7bac54c92, b699b33c3 |
| C15 | `auto` options that change synthesis should be source attributes (and profile pins) | mostly done: attribute registry = options, `synth.memory/delay/stop_*`, profile pins printed at the source line; open: `synth.flatten`, `synth.register` | livehd ffa53e622 |
| C16 | mapped netlist of `br_amba_axi_shrinker` failed to re-compile (`combinational loop get_mask -> eq`) | done: mapped DFF cells declare Q `loop_break`; port_reach treats body-less sequential cells as sources; lhdtrack rows now ok | livehd f943b3393 |
| C17 | lhdtrack rerun 2026-10-10/11 (asap7+sky130 x verilog+pyrope x abc+usyn) | done: 0 LEC refutations; 8 Pyrope rewrites + 22 annotations applied, see section | lhdtrack working tree (uncommitted) |
| C19 | second optimization pass over the suite (dino -3 % area / -9 % delay, picorv32 -2 %, matched_filter -1.4 %) + cprop opshare policy-loss fix | done | livehd 904dd35fd |
| C20 | minion: core_top / vpu_top / minion_top as synthesis targets; clock-net buffer tree (derived clocks always, primary port only past icg_input_min bits); per-scope synth.partition drives the coloring profile | done (livehd c6b017359, 740444cef + uncommitted icg_input_min) | minion/pyrope: 172 declarations pinned |
| C21 | critical paths via `pass.opentimer.critical=true` + `lhd tool sta paths=N`; picorv32 counters pinned prefix | done (uncommitted) | picorv32/pyrope2/picorv32.prp |
| C18 | per-region ABC optimization steps (`synth.abc_pre`), one color = one ABC run | done (livehd a9b8d95c2); 19 lhdtrack Pyrope tests pinned, abc asap7 area 0.90x | |

## What went in (the "small set")

| core | attributes inserted | cells | area um2 | STA ps | regions |
| --- | --- | --- | --- | --- | --- |
| dino | `PipelinedDualIssueCPU synth.color="core"`, `ALU synth.adder="cla"`, `DualIssueNextPC synth.adder="brent"` | 21982 -> 18619 (-15 %) | 2154 -> 1872 (-13 %) | 2099 -> 1142 (-46 %) | 45 -> 10 |
| picorv32 | `picorv32_top synth.color="core"`, `picorv32 synth.barrel="reverse"` | 7472 -> 6093 (-18 %) | 761 -> 654 (-14 %) | 965 -> 970 (=) | 45 -> 1 |
| matched_filter | `matched_filter synth.color="core"` | 10460 -> 9767 (-7 %) | 1254 -> 1184 (-6 %) | 529 -> 568 (+7 %) | 104 -> 3 |
| rocket (LFSR) | none possible, see C3 | | | | |

Checks: `ALU` and `DualIssueNextPC` netlists are LEC-proven against the original
sources. Whole-design LEC of the annotated cores is `unknown` immediately (state
cannot be paired by name once regions merge, see C5; not a time-out). The
*unannotated* matched_filter proves. So these annotations are evidence-light on
equivalence until C5 is fixed; the attributes themselves only select
architectures and region membership.

USYN takes the same attributes and honors them, with smaller effect
(dino STA -12 %, picorv32 cells -5 %, matched_filter cells -2 %, STA +10 %).

## Top challenges and the change that would fix each

### C1. Partition granularity is the dominant lever, and nothing searches it
**Status: ask me later.** The owner has an alternative proposal; do not implement
the tuner search described below until it is discussed.

Evidence: one `synth.color` on the top module cut dino 21982 -> 17678 cells and
2099 -> 1386 ps, and picorv32 7472 -> 6153 cells. `synth.tune.profile=on` on picorv32
spent 18 arithmetic trials for +2 % cells / -7 % delay, because exploration only varies
adder/multiplier/barrel per ware region. The cut policy (ware/arith/shift boundaries,
`min_color_nodes`, `max_gate`) is applied once and never revisited.
Change: make the tuner explore partition *level* first (default cuts / flatten each
module / one region for the top when the predicted AIG fits `max_gate`), then
arithmetic. Report the result as the attribute that pins it. Cheap: a flat
whole-core synth was 10-31 s here.

### C2. No source-attributed critical path, so finding the module to annotate is manual
The STA path is a list of gate instance names (`g1656_OR5x1...n19532`). I found
that `DualIssueNextPC` alone owns a 35 % delay win by bisecting 12 single-module runs.
Change: map each timed path back to module / source line (the SourceId anchors exist),
print the top-N critical paths as `module:line -> module:line` with per-region delay and
the number of region boundaries crossed, and say which attribute families apply to the
cells on it (adder pin if a Sum is on it, barrel if a shifter, color if it crosses cuts).

### C3. Memory classification hides state and double-counts area
Update 2026-10-10: `qor.abc.memories` lists every memory with realization
(`flops|native|inline-array`) and the rule that decided it (`pin synth.memory=...`,
`pass memory=...`, `auto: N bits > memory_max_bits`, `auto: P ports > 3`,
`multiclock write ports`, `loader-image`). Rocket's LFSR under `memory=false` now
shows as a native 16x1 memory instead of vanishing.
- `reg state:[16]U1` (rocket's LFSR) is lowered to a *35-read / 16-write memory*; with
  `pass.abc.memory=false` its 16 flops vanish from the area (70 cells -> 5), so the
  design looks 14x smaller than it is.
- With the default `memory=auto`, dino's register file is bit-blasted into 18086 gates
  (46 % of the design), which swamps every other change.
Change: (a) a register array of narrow elements with parallel access should become a
flop vector, not a memory (threshold on bits and port count); (b) `--stats` should
print a memory table (name, bits, ports, native vs lowered, area included or not);
(c) a declaration-level `reg x::[synth.memory="flops"|"macro"]`.

### C4. Nested explicit colors silently make things worse
Update 2026-10-10: `synth-nested-group` warning at the inner attribute's file:line
("explicit group [outer,inner] is nested inside [outer]: N nodes map separately and
cut M connections"). Not done: giving the inner group `grow` semantics by default.
Top color + inner `ALU`/`NextPC` colors: 23477 cells vs 17678 with the top color alone,
and slower than no annotation. There is no warning, and the group dump shows no cost.
Change: diagnose an explicit group that is split by an explicit group nested inside
it (with the cell and boundary delta), and give the inner one `grow` semantics by
default when the outer color already covers the module.

### C5. LEC cannot pair state once regions merge (a naming problem, not solver time)
Unannotated matched_filter (104 regions): LEC `proven` in 4 s. The same design with one
color (3 regions): `unknown` immediately, even with a 3000 s budget, reporting
`unpaired_state ... "no full match"`: 191 reference registers vs 1654 implementation
bits. The merged netlist's flops lost their instance path:
`t__li0.x_r` (ref) vs `x_r[0]` (impl); dino: `pipeA_if_id.reg_0.instruction` vs
`reg_0.instruction[0]`. picorv32 and dino behave the same. So every annotation that
merges regions makes the result unverifiable by name-based state pairing, though
attributes are semantics-preserving by construction.
Change: keep the full hierarchical instance path in flop names through region merging
(or pair state by SourceId / structure when names differ), and report unpaired
state as a naming mismatch rather than a bare `unknown`. A per-module proof mode
(`lhd lec --by-module`) would also let an annotated netlist be checked in the pieces
the source already has; per-module proofs for `ALU` and `DualIssueNextPC` do work.

### C7. Arithmetic sharing across the ALU's mux arms (analysed)
Option added 2026-10-11: `::[synth.partition="coarse"]` on a module, block, call or declaration is the
run-wide coarse profile for that scope only (all `stop_*` cuts off, no ware extraction);
`fine` restores them and a specific `synth.stop_*` still wins. A mux/shift/add module
goes 1661 -> 1443 gates and 9 -> 1 regions, identical to `--set synth.partition=coarse`.
Premise checked: `ALU.prp` builds sum, difference and four comparators on the same
operands. Findings (dino ALU alone, ASAP7, ABC, rca):
- Inside ONE region the compares are already free: removing the four compares changes
  3636 -> 3614 cells (coarse). ABC strash merges the compare carry chains with the
  subtractor's, because the blaster builds both with the same adder kind.
- The loss is the cut policy. Same logic, abc: default (fine) 5351 cells / 802 ps;
  `stop_mux=false` 4803; all `stop_*` off 4578; all off and no ware modules 3478 / 712 ps;
  `synth.partition=coarse` 3614. Whole dino, abc: fine 21982 vs coarse 17642 cells. This
  is C1 (not touched; on hold).
- The real structural redundancy is the shifters: sll, srl and sra are each built
  twice (word and full) = 1896 of the 3614 coarse cells (52 %).
Pyrope-level rewrite (LEC `proven` against the original, 2 s): one adder that
subtracts for everything but `add` (comparisons read its carry/sign), one logical right
shifter shared by sll (bit-reversed in and out), srl and sra (sign xor-ed in and out).
Saved as /var/tmp/renau/exp/c7/new_v1/ALU.prp (not applied to the suite):
| ALU alone | old cells / ps | new cells / ps |
| --- | --- | --- |
| abc fine | 5482 / 805 | 2460 / 972 |
| usyn | 3011 / 563 | 2182 / 666 |
Whole dino (core color): abc 18619 / 1142 ps -> 17854 / 1240 ps; usyn 17333 / 1351 ->
15783 / 1320. Area wins everywhere, delay is worse under ABC, so it was left out of the
source. Not done: an automatic version (needs mutual exclusivity of the arms, which
only the mux select proves; `onehot-deferred` is already the open item there).

### C8. The timing target is unreachable and nobody says so
Update 2026-10-10: the run envelope's `qor.timing_target` reports the source
(`abc.delay` or the SDC `create_clock -period`), target/achieved/slack in ps, `met`,
and `unreachable` (achieved > 1.25x target) with an info diagnostic. Still open: per-region
slack and switching the objective to "minimize delay" when unreachable.
There is no SDC in this suite, `abc.delay=1000` was assumed, and dino closes at
2099 ps. Delay-driven decisions in that regime are degenerate (the same STA appeared
for three different adders). `qor.json` has no "target met" and no slack.
Change: read `synth.sdc`, print target/achieved/WNS per run, and switch to
"minimize delay" with a note when the target is out of reach.

### C9. The partition profile depends on the mapper (colors do not)
Debugged: an explicit color gives the **same** partition under both mappers (dino:
10 partitions each; USYN's own region total goes 8 -> 10). My first note ("41 -> 55
regions") counted technology-mapping units, not partitions. The only things that
differ are the *defaults* that `synth.mapper` silently selects: `stop_mux`,
`stop_arith`, `stop_cmp`, `stop_shift`, `ctrl_cones`, the forward merge, and the
`ware_*` extraction switches. abc = cut everywhere and extract ware modules (dino 45
partitions); usyn = register-to-register cones, nothing extracted (dino 8).
Done: `--set synth.partition=auto|fine|coarse` picks that profile independently of the
mapper. With the same profile the partition counts are identical for abc and usyn on
every core (fine 35/35, 35/35, 102/102; coarse 8/8, 18/18, 37/37 for dino, picorv32,
matched_filter), so any remaining QoR gap is the mapper. That gap is real and
unrelated to color: on the *same* coarse partition abc gets dino 17642 cells / 1397 ps
vs usyn 20120 / 1895 ps (+14 % cells, +36 % delay) and picorv32 6144 vs 8099 cells.
Evidence for the default: `synth.partition=coarse` on abc with *no* annotation is
corpus-wide -3.3 % area / -3.5 % delay (31 wins, 16 losses, 189 designs) and matches
top-module color (ratio 0.994). I did not flip the default because coarse regions
hit the state-pairing LEC problem (C5) on every default flow.

### C10. The profile ranks and stops early (done)
`profile=on` used to try every candidate in every ware region. It now visits regions
most-critical first (stitched path over the worst path under a timing target, mapped
area share otherwise), skips regions under `synth.tune.min_share` (default 2 %) of the
mapped area, and stops a region after `synth.tune.patience` (default 3) consecutive
non-improving candidates; it prints why each region stopped and a one-line summary.
picorv32: 18 -> 11 trials and 52 -> 29 s for the identical result (7637 cells,
894 ps); a deterministic two-adder case goes 8 -> 6 trials by default (2 with
patience 1, 4 with a 50 % floor). USYN's loop got the same patience rule (20 -> 6
candidates); it has no share floor yet because its regions are explored
independently. dino still runs all 28 trials because each one improves delay.

### C11. Cut conditions as source attributes (done)
`synth.stop_arith`, `stop_cmp`, `stop_shift` and `stop_mux` (bool) override the
global `pass.color.synth.stop_*` for the cells they cover (variable, block, module,
or call), in both directions: `false` keeps a wide add out of its own region and out
of ware extraction, `true` forces a cut even under the coarse/usyn profile. They are
stamped only on the operations they govern, so `stop_arith` on a module does nothing
to its muxes. Regression: a 32-bit add told not to stop stays inline while an
untouched one is still extracted.

### C12. An attribute on a callee comb switched off its LNAST inlining (done)
Rule (owner, 2026-10-10): synthesis attributes must not affect compilation; before
color/synthesis they have no effect. The runner used to keep any comb that carried a
module-scope hint, or was called with a call-site one, as a Sub instance, so the
colorer saw a retained definition (+18 % cells on picorv32 for `stop_mux` on the
datapath modules, +22 % for `barrel="reverse"` on `shift_word`).
Now such a comb is spliced like any other. Its policy travels on two scope markers
around the spliced body (`__synth_push`/`__synth_pop`, tolg); push composes the
call-site pin with the surrounding membership (color/grow/path) exactly as graph
inlining composes instance policies, so nested explicit colors keep their
`[outer,inner]` meaning. A callee that really is a Sub (mod, pipe,
`compile.upass.inline=false`) keeps the call-site policy as before.
Measured on picorv32 (no other attributes): none 7472 cells / 45 regions, only
`barrel="reverse"` on `shift_word` 7478 / 43 (was 9115).
Loss is reported: a call-site pin that governs no cell of the inlined callee gives
`synth-attr-unused` at the call's file:line.

### C13. Attributed callee in an inline frame (done)
Found by annotating `shift_word`: `call to undefined function 'inl1_shift_word'`,
and `binds input 'amount' more than once` for `f(amount=x, flag, v=y)`. Both came
from the runner's scope-marker decline path not doing the named re-emit the other
Sub-instance paths do. A binder-level fix in tolg was tried and reverted: it broke a
Verilog -> Pyrope -> Verilog round trip, so positional-after-named semantics belong
to the runner.
Suggestion: one shared "emit instance call" helper for every decline path, so a new
path cannot forget the re-emit.

### C14. USYN versus ABC on the same partition (mostly closed)
Same regions (`synth.partition=coarse`), ASAP7, cells / ps; abc | usyn before | usyn now:
| core | abc | usyn before | usyn now |
| --- | --- | --- | --- |
| picorv32 | 6093 / 970 | 7727 / 1092 | 6345 / 942 |
| dino | 18619 / 1142 | 19878 / 1671 | 17333 / 1351 |
| matched_filter | 9767 / 568 | 9629 / 622 | 9757 / 531 |
What changed (all in livehd, each isolated by an A/B run):
1. `auto` adders were Kogge-Stone `prefix`; Brent-Kung is smaller AND as fast here
   (picorv32 7727 -> 6840). Thresholds (16 sums / 8 compares) were not the lever.
2. `pass.usyn.tmap_pre` (default `&dch -f -C 500`): structural choices before `&nf`;
   picorv32 6840 -> 6345, dino 19345 -> 17333. Heavier `&synch2 -K 6; &dch` is available
   per run for designs the native search cannot finish.
3. Carry-dependent compact loops were NOT unrolled (maps one generic body, stitches the
   carry): ordinal-dependent logic replicated per iteration. A 64-bit bit-reversal loop
   feeding a shifter was 18689 cells against 449, the shared-shifter ALU above 74874
   against 1950. `pass.usyn.unroll_carry` now defaults true, like `pass.abc`.
Open: br_arb_lru (256-bit state matrix) is 3936 cells against 818 for abc: the endpoint
search exhausts its 1.87e9 work limit and falls back to the raw blasted structure;
`tmap_pre="&synch2 -K 6 -C 500;&dch -C 500"` gives 1476. Raising `pass.usyn.work` or
sweeping before search is the next lever. USYN dino delay is still +18 % vs abc.

### C16. A mapped netlist with retained hierarchy looked combinational through its flops (done)
`br_amba_axi_shrinker` (Verilog, ABC and USYN) failed in the emit step: re-compiling
the mapped `lg:` library reported `comb-loop-through-module ... inlined` and then
`combinational loop: get_mask -> eq`. Not ABC and not the legalizer's loop removal:
the loop was an artifact of the analysis.
Cause: technology cells (`DFFHQNx1_ASAP7_75t_R`, ...) are body-less definitions. The
first-level legalize walk treats a body-less instance as a source, but the
per-definition summaries (`graph/port_reach.cpp`) treat it as combinational in every
input. A flat netlist only used the first; the new default keeps `br_counter_incr`,
`br_amba_axi_resizer_beat_tracker`, ... as definitions, so a counter definition
summarised as `beat_lane <- clk, rst, start_*`, closing a loop through the state.
Found by dumping the cycle (a debug trace: instance `br_amba_axi_resizer_beat_tracker`,
summary `out9 <- clk,rst,start_valid,start_offset,size,burst,beat_valid`).
Fix: `create_dff_io` declares Q `loop_break` (hhds stamps every instance from the
declaration), and port_reach stops at a body-less loop-break instance. Body-less
combinational cells (inverters, gates) stay combinational, so real loops through
mapped logic are still caught. Unit test: `PortReach.BodylessCellsFollowTheirLoopBreakDeclaration`.
Left alone on purpose: the first-level walk still treats body-less combinational cells
as sources (a true loop through only mapped gates would not be flagged there).

### C17. lhdtrack rerun (livehd `b699b33c3`+tree, 2026-10-10/11)
Matrix: 195 tests x {asap7, sky130} x {syn_lhd_verilog, syn_lhd_verilog_usyn,
syn_lhd_pyrope, syn_lhd_pyrope_usyn} (new flow `syn_lhd_pyrope_usyn`, opt-in through
`LHDTRACK_EXTRA_FLOWS`), plus netlist LEC for abc and for Pyrope-usyn; Verilog-usyn LEC
through `tools/run_verilog_eval.py`. Baseline/measured geomeans vs yosys+abc (higher is
better), first run of the day, before any Pyrope edit:
| flow | asap7 area / delay | sky130 area / delay |
| --- | --- | --- |
| lhd abc, Verilog | 0.879 / 1.290 | 0.922 / 1.097 |
| lhd usyn, Verilog | 0.975 / 1.130 | 0.953 / 1.122 |
| lhd abc, Pyrope | 0.862 / 1.285 | 0.905 / 1.091 |
| lhd usyn, Pyrope | 0.951 / 1.145 | 0.919 / 1.145 |
(usyn rows exclude 30 designs with preserved native state, which have no area.)
Previous ledger values for the same flows: abc Verilog 0.858 / 1.324, usyn Verilog
0.847 / 1.210 (asap7). LEC: 0 refutations in 3800+ obligations; timeouts are the
multipliers/FMAs and the large FIFOs (17 per technology).
Findings that drove Pyrope edits (all LEC proven against the original source):
- `in & -in` (br_arb_fixed, br_enc_priority_encoder) costs a 16-bit negation: prefix-OR
  scan gives area 4.58 -> 2.20 (abc), delay 257 -> 166 ps, same in usyn.
- `(in >> (select*32))#[0..<32]` (br_mux_bin, br_mux_bin_array) builds a 512-bit barrel:
  AND-OR over the decoded select gives 64.0 -> 33.8 and 127.9 -> 67.9 um2.
- br_shift_left/right: second shifter replaced by a thermometer mask of the shift
  count, 17.9 -> 9.4 and 18.1 -> 9.3 with `synth.color` (abc); usyn 8.7 -> 7.8.
- br_flow_mux_fixed / _stable: priority `if` chain -> one-hot AND-OR select; abc unchanged,
  usyn 11.2 -> 8.7 and 42.8 -> 30.3 um2.
- 22 `synth.*` annotations from `annotated/` applied to `tests/*/pyrope` after checking
  both mappers (kept only where abc improves and usyn does not get >2 % worse or >10 %
  slower; dropped: adder=cla on add_three(_sgn), br_amba_axi_shrinker, br_flow_fork,
  br_tracker_freelist, fma_sgn, fmaa, add_mul_uns, alu, and the `csa` multiplier pin
  of mul_three_sgn).
Largest remaining gaps against yosys (abc): br_demux_onehot/br_demux_bin (physical
fanout buffering of a pure-wiring replicate), br_amba_axi_isolate_sub, add_three,
br_arb_lru under usyn (C14). The default fine partition remains the dominant loss for
abc on small arithmetic (C1, on hold).

### C18. ABC optimization steps per region
`::[synth.abc_pre="dc2"]` (module, block, call, declaration; run-wide `synth.abc_pre` /
`pass.abc.pre`; per-region `pre` in region_opts) splices allow-listed steps into the
BUILT-IN flow before its mapper: AIG commands after the first `strash`, `&` commands
after `&get -n`, so buffering/sizing tails and `{D}` stay. Vocabulary is closed (dc2,
fraig, resyn*, compress*, balance/rewrite/refactor/resub, &dch, &synch2, &syn2-4, ...);
anything else is a usage/compile error. `synth.abc` (whole custom flow) still exists and
wins over `abc_pre` (info diagnostic).
Robustness rules (mapper independent, compile time): all cells of one explicit group
must agree on `abc`, `abc_pre`, `delay`, `ware` (`synth-group-conflict`, located at the
second pin); the region driver re-checks per color for non-explicit colors. usyn ignores
`abc`/`abc_pre` with `synth-abc-ignored` (warning), so one source builds under both.
Sweep on 189 lhdtrack tests (asap7, abc, run-wide): no step helps on average (geomeans
1.000-1.012), but per design the best of 7 wins >3 % on 49 (geomean 0.918 among them);
winners vary (resyn2 13, compress2rs 12, &synch2 11, dc2 5, dc2;&dch 4, &dch 3). Pinned
where area <= 0.95x and delay <= 1.05x with the pin on the top module (or on every module
for hierarchical designs): 19 tests, LEC proven/timeout, abc asap7 area 0.90x / sky130
0.97x, usyn unchanged. Per-callee modules need the same value in every file (a color
cannot carry two), so hierarchical designs pin all their modules.

### C19. Second optimization pass over the suite (asap7, abc, livehd 904dd35fd)
Same harness (`suite_syn.py`, 1000 ps, memories blackboxed). Per-core sweeps of
`synth.abc_pre` (7 variants), run-wide adder/multiplier/barrel, max_fanout, area_relax:
| core | before (cells / um2 / ps) | after | source change |
| --- | --- | --- | --- |
| dino | 18619 / 1872 / 1142 | 17786 / 1814 / 1040 | `PipelinedDualIssueCPU`: `synth.adder="cla"`, `synth.abc_pre="dc2"` |
| picorv32 | 6093 / 654 / 970 | 5967 / 643 / 980 | `picorv32_top`, `picorv32`: `synth.abc_pre="resyn2"` |
| matched_filter | 9767 / 1184 / 568 | 9627 / 1167 / 556 | `matched_filter`: `synth.abc_pre="resyn2"` |
| rocket (LFSR) | 5 cells | unchanged | nothing to gain |
Findings:
- A compiler bug hid most of the dino win: cprop's operator sharing retypes a Mux root
  into the merged Sum (`wrap io_nextpc = if taken {base+imm} else {pc+4}`) and the new
  Sum lost the module's `synth.adder` pin, so the brent/cla pins never reached the
  critical 65-bit adder (core 1111 ps). Fixed (the root takes the policy keys its arms
  agree on): core 941 ps with the source pins alone, matching `--set synth.adder=cla`.
- `synth.abc_pre`: dc2 is best for dino (resyn2 is fastest 1028 ps but +3 % area);
  gains elsewhere are 1-2 %: these cores are one big region, so there is little for a
  pre-pass to find. `&synch2` loses 6-17 % on picorv32/matched_filter.
- Not worth a source change: the shared-shifter ALU (area -1 % vs dc2dch, +3.5 % delay),
  run-wide adder variants on picorv32/matched_filter (rca best), multiplier choices on
  picorv32 (no multiplier in the region).
- Left as run options (no source spelling): `pass.abc.max_fanout=32` -1.3 % dino area.

### C20. minion (asap7, abc, 1000 ps; memories blackboxed)
Targets synthesized separately: `core_top`, `vpu_top`, and the whole `minion_top`
(workdirs /var/tmp/renau/exp/suite/minion/). Before -> after, cells / um2 / STA ps:
| target | before | after |
| --- | --- | --- |
| core_top | 400972 / 31667 / 4865 | 181829 / 16148 / 2156 (-49 % area, -56 % delay) |
| vpu_top | 357733 / 34437 / 3680 | 304532 / 29650 / 1678 (-14 % area, -54 % delay) |
| minion_top | 777037 / 67639 / 4946 | 495406 / 46764 / 2307 (-31 % area, -53 % delay) |
What each step was worth (vpu_top | core_top):
1. Clock nets: every critical path started at an unbuffered ICG output (1.5-2.5 ns
   driving thousands of flops) or the shared negedge inverter. A buffer tree on any
   clock net with more than 16 register cells (`pass.abc.icg_fanout`, default 16;
   64 left 3500 ps on core_top, 32 gave 2188): 3680 -> 2269 ps | 4865 -> ~2190 ps
   for +0.1 % area. A buffer, not an inverter pair: LEC cannot model a derived clock
   through a Not.
   POLICY (2026-10-11): the primary clock port is an ideal driver in the timer, and
   OpenTimer counts a tree's latency in every launched path, so a tree directly under
   it cost ordinary designs +17..70 % STA (picorv32 970 -> 1120 ps, br_arb_lru 315 ->
   376). A net the design's own gate/inverter/another region drives is always bounded;
   a net fed straight from the primary port only when the design has at least
   `pass.abc.icg_input_min` register bits (default 8192; vpu_top 27774, core_top
   ~25k, picorv32 ~1.7k, dino ~1k). Result: picorv32/dino/lhdtrack back at baseline,
   core_top 2156 ps and vpu_top 1678 ps kept. The bit count is hierarchical (children
   included) and part of the region-cache recipe.
2. Coarse partition: 683 -> 66 regions on core_top (-49 % area), 285 -> 64 on vpu_top
   (-10 %). The per-scope attribute only covered the stop_* cuts; the bulk of the win
   is the usyn coloring profile (flop_to_flop cones), so `synth.partition` on a module
   (or its virtual-flat view) now selects the profile for that module's coloring.
3. `synth.abc_pre="resyn2"` (-1 % area; dc2 / c2rs / dch / fraig / none within 1 %),
   `synth.adder="cla"` (-1.4 % area, -2 % delay), `pass.abc.area_relax=0` -1.9 %
   area (run option, not pinned: it trades slack back for area).
Not worth it: multiplier array/tree/csa (+5..9 % area; tdm default stays), barrel
reverse, boundary off, max_fanout 8 (+3 %) or 24/32 (-0.6 %).
Source change: every `comb`/`mod` declaration in minion/pyrope (172) gained
`synth.partition="coarse", synth.abc_pre="resyn2", synth.adder="cla"`; one color is
one ABC run, so the same value goes in every module. `--set synth.partition=coarse`
gives the same netlist without touching the source.
LEC (cvc5, 300 s, timeout = pass): trans_top proven; txfma_top and vpu_top come back
`unknown` quickly with 20 residue cones the flop-cut miter cannot pair
(`TXFMA_RTL_txfmafrac0_top_txfma0_f1_*_f2a_h`); the unpinned original source gives the
same `unknown` on txfma_top, so it is not introduced here (C5 family).

### C15. `auto` options that change synthesis should be attributes
Every `auto` / mapper-dependent option is a decision the tool makes for the whole
run. When the heuristic is wrong for one block the only remedy today is a global
`--set`, which moves every other block. The scope the user wants is the same one
`synth.adder` already has: module, `{...}` block, call, declaration. Inventory of
the synthesis-affecting `auto` options (pass.abc / pass.color / pass.usyn /
pass.partition) and the proposed spelling:

| option (global) | per-source today | proposed key | scope | note |
| --- | --- | --- | --- | --- |
| adder, multiplier, barrel, block_size | yes | `synth.adder/multiplier/barrel/block_size` | op, block, module | done |
| color, grow | yes | `synth.color/grow` | any | done |
| stop_mux/arith/cmp/shift | yes | `synth.stop_*` | op family | done (C11) |
| ware, delay, abc | yes | `synth.ware/delay/abc` | region | done |
| memory (`auto|true|false`) | **yes now** | `synth.memory=auto|flops|macro` | one `reg`/memory decl | overrides fold mode for that memory only; multiclock still forced native |
| memory_max_bits | no | `synth.memory_max_bits` | module/block | subsumed by the per-memory pin for single memories; keep global for the heuristic |
| flatten (abc/usyn/partition) | no | `synth.flatten=true|false` | module decl | ties to C12: an attributed callee must say whether it stays a unit |
| reg_margin / dff_cell / register mapping | no | `synth.register=...` | module/decl | needed for retiming-sensitive flops (DFFHQx4 vs QN, lhdtrack QoR note) |
| partition (`auto|fine|coarse`) | global only | `synth.partition` | module | C1: tuner should search it per module |
| ctrl_cones, ware_* thresholds | no | `synth.ctrl_cones`, `synth.ware_min_width` | block | width cut (8 bit) is the one users hit |
| flop_to_flop | no | `synth.flop_to_flop` | module | timing-driven partition |

Two rules to keep it coherent: (1) a source pin always beats the heuristic and
the learned profile (same `rank` machinery as `adder`); (2) a decision the
profile learns (`synth.tune.profile=on`) should be printable as the exact
attribute line that would pin it (`lhd synth --tune-export` already stores the
decisions; emitting them as `::[synth.x=...]` text is the missing step, and
makes "profile once, then freeze in source" a one-step workflow).

Implemented 2026-10-10: every source attribute now has a same-named `synth.K`
option (single registry `livehd::synth_attr::kAttributes`; `lhd describe synth.K`
shows both spellings, `lhd synth --help` says so, `--set` of a source-only one
is a usage error, and `lhd_options_test` pins the correspondence and that
`validate()` accepts only registered keys). New run-wide spellings:
`synth.memory`, `synth.delay`, `synth.stop_*`.
Left over from the old C6 (attribute diagnostics): the generics-position parse
error (`::[...]` before `<...>`) lives in the sibling tree-sitter-pyrope
`prpparse`, and `file`-level `module` aliases do not take `synth.color`.

Profile pins: with `synth.tune.profile=on`, each explored ware region emits
`synth-tune-pin` (info) at every source line of an operation it covers, e.g.
`tune.prp:3: exploration chose this for the sum here (76 cells, 31 ps); pin it with
::[synth.adder="rca"]`. Sites come from the instance srcids (a ware module body is
shared, so it has no single line); capped at 8 per module.

Earlier 2026-10-10: `synth.memory` (validated `auto|flops|macro`,
operation-aware: stamped only on Memory cells, bound by declaration name in
`apply_synth_targets`, read in `build_memory_modules`). Regression in
`lhd_synth_attributes_smoke.py`.

## Suggested order
C1 (search partition level), C2 (critical path with source), C3 (memory table and
flop vectors), C5 (module-granular LEC), then C4 diagnostics (C1 is on hold: ask first). C7 is the largest
single QoR item left on CPU-style code.

### C21. Critical-path evidence (`lhd tool sta paths=N`)
`lhd pass opentimer lg:net cells.lib design.sdc --top T --set pass.opentimer.critical=true`
then `lhd tool sta paths=5 lg:net --top T` folds equal-slack cells (slack is constant
along a path) into the N worst paths: slack, cells, launching -> capturing state,
source lines. Fixed while using it on the suites: clock resolution through clock
buffer trees and clock-gate cells (one target: assumed, with a warning), async read
ports of a native memory (timed in the memory's clock), flatten-created cells without
a source node (skipped, warned), recovery/preset/clear/directional arcs counted as
complete, non-sequential async-pin checks skipped, and the error messages now name the
node/cell. Findings:
* picorv32 (1000 ps): worst paths were the two 64-bit counters `count_cycle/count_instr
  + 1` (ripple incrementers, 914 ps). `const inc::[synth.adder="prefix"] = count + 1`
  on just those two statements: 5967 -> 6494 cells (+9 %), 642.7 -> 696.3 um2,
  STA 980 -> 817 ps (-17 %): area x delay -10 %. Module-wide `cla` was worth only
  -4 % delay for +1 % cells; module-wide `prefix` +26 % area. Next path after that is
  `mem_do_rinst -> mem_rdata_q` control (19 cells, ~825 ps), no attribute lever.
* dino (900 ps target, 1040 ps): worst path is forwarding compare (`ex_mem.instruction[7..11]`
  vs rs) -> 64-bit operand bypass mux -> ALU -> `ex_result`/`nextpc`, 37-41 cells. ALU adder
  prefix/brent were slower (1092/1105 vs 1040 ps, area -0.5 %/+0.5 %): the adder is not the
  limit; precomputing one-hot forward selects in the previous stage would be the fix
  (microarchitecture, not an attribute).
* minion core_top (1500 ps target, 2091 ps): `csr_file.minstmatch -> inst_bits_stage` through
  the thread-id dynamic shifts of `minst_match` (45 cells, intpipe_top.prp:733); candidates
  for a hand rewrite (thread id is one bit: select instead of shift).

