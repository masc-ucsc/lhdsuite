# PicoRV32 simulation twins

`picorv32_prog_tb_verilator.cpp` runs the same default program and memory
handshake as `picorv32_prog_tb.prp`: store 30 to address 0x100, then loop.
The normal benchmark is `bazel test //bench:picorv32_sim_verilator`.

Run `bazel test //picorv32:sim_configs --test_output=all` to compare all four
combinations of `BARREL_SHIFTER` and `TWO_CYCLE_ALU`. For a local binary:

```sh
python3 picorv32/check_sim_configs.py --lhd ../livehd/bazel-bin/lhd/lhd \
  --workdir /tmp/picorv32-configs
```

This check uses the parameterized `pyrope2` translation. The benchmark's older
`pyrope` tree has already folded parts of the configuration to its defaults.
Only scratch copies of the Pyrope and Verilog wrappers are edited. Gray order
changes one parameter in one module per incremental run, and checks that the
compiler both reuses unchanged modules and recompiles the edited module.
Every result is compared with a separate cache-disabled build and Verilator.

The configuration program exercises immediate and register shifts, signed
right shifts, addition, subtraction, and comparison. Each combination must
store 58 without trapping, and all three flows must report the same completion
cycle. The check also requires the barrel shifter to reduce latency and the
two-cycle ALU to increase it. Per-run logs and cache counters are retained in
the work directory; `results.json` records the comparison.
