# Verilator as an oracle for minion

`lhd sim minion/pyrope/minion_top.prp` refuses with 19 errors. To tell "the
design is unreasonable" from "the simulator cannot do this", run the SAME RTL
under an event-driven simulator. Verilator handles minion in seconds.

## The recipe (measured 2026-08-05, Verilator 5.050)

```bash
cd minion/verilog
verilator --cc --exe --build -Wno-fatal -O1 \
  --Mdir /tmp/vmin/obj --top-module minion_top -DSYNTHESIS \
  -F filelist.f ../sim/minion_smoke_verilator.cpp
/tmp/vmin/obj/Vminion_top        # 200 cycles, ~0.26 s
```

Notes that cost time to find:

* **Nothing hierarchical to disable.** Verilator's `--hierarchical` is opt-in via
  `/*verilator hier_block*/` pragmas, and minion carries none — the default build
  is already ONE flat model. (`grep -rn hier_block` over the whole suite: no
  hits.)
* `--relax-enum-conversions` / `--allow-use-before-declare` are **slang** flags
  (`CORE_V_FLAGS`, for LiveHD's reader). Verilator rejects them; its own extra
  flags live in `verilator_flags`, empty for minion.
* Run from `minion/verilog/`, or pass `-I` for that directory: the eight
  generated `intpipe_csr_file_auto_*.svh` includes resolve relative to the
  including file, which Verilator does not do by itself.
* `--public-flat-rd` does **not** exist as a CLI flag in 5.050 (`%Error: Invalid
  option`). Use `--public-flat-rw` for a blanket tap, or a `.vlt` file with
  `public_flat_rd -module … -var …` for surgical ones.

## What it established

* **All five modules `lhd sim` refuses with `combinational-loop` verilate with
  ZERO circular-logic warnings** (`prim_mul_div`, `prim_rf_1r1w_diff_preview`,
  `vpu_tensorfma`, `vpu_ctrl`, `intpipe_mul_div_ctl`). Verilator does report
  `UNOPTFLAT` when a design really has one — it flags exactly one place in all of
  minion, `minion_dcache_top.s2_ba_write_needed` — so the silence on those five
  is evidence, not absence of checking. They are false positives.
* **`prim_rf_1r1w_diff_preview` is not even a simulator problem.** The ORIGINAL
  SystemVerilog through LiveHD's own slang reader lowers to sim C++ **clean**;
  only the GENERATED `minion/pyrope/*.prp` loops. Compare:
  ```bash
  lhd compile verilog --top prim_rf_1r1w_diff_preview --emit-dir sim:/tmp/a \
      -- -F minion/verilog/filelist.f -DSYNTHESIS          # CLEAN
  lhd sim minion/pyrope/prim_rf_1r1w_diff_preview.prp --setup-only  # combinational-loop
  ```
  Anything measured against `minion/pyrope/` is measuring the Verilog→Pyrope
  round-trip as well as the simulator. Say which one you meant.

  **But it is the ONLY one.** Both front-ends were compared module by module
  (`lhd compile verilog --top <m> --emit-dir sim:` vs
  `lhd sim minion/pyrope/<m>.prp --setup-only`) and 8 of 9 agree exactly:

  | module | SV via slang | generated .prp |
  |---|---|---|
  | prim_rf_1r1w_diff_preview | **CLEAN** | combinational-loop |
  | prim_mul_div | comb-loop, negedge | same |
  | vpu_ctrl | comb-loop-thru-inst, comb-loop, negedge | same |
  | vpu_tensorfma | combinational-loop | same |
  | intpipe_mul_div_ctl | combinational-loop | same |
  | vpu_lane | gated-clock, negedge | same |
  | txfma_top | gated-clock, negedge | same |
  | intpipe_csr_file | negedge | same |
  | minion_dcache_top | comb-loop, negedge | gated-clock, negedge |

  So the round-trip is a ONE-MODULE confound, not a systemic one: the other four
  `combinational-loop` refusals reproduce from the original SystemVerilog and are
  genuine `inou.cgen.sim` limitations. (`minion_dcache_top` differs only in WHICH
  error is reported first — cgen.sim fail-fasts, so the ordering of its probes
  decides, not the front end.)

## The faster first question

Before reaching for verilator, ask LiveHD itself:

```bash
lhd compile verilog --top minion_top --emit-dir lg:/tmp/lg_minion \
    -- -F minion/verilog/filelist.f -DSYNTHESIS
lhd pass analyze lg:/tmp/lg_minion
```

`pass analyze` (livehd/pass/analyze/README.md) surveys all 172 definitions in one
invocation and classifies every loop as REAL or FALSE, every state element's
clock, and the validity of the colouring. On minion it reports 21 loop findings
(all FALSE) and 372 clock findings (all `from_sub`) — the same conclusions this
page reaches empirically, in one command instead of a day.
