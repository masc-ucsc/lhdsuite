# `matched_filter`

A streaming one-dimensional SAR matched filter, implemented independently in
Pyrope and SystemVerilog.

The input return stream `x:s8` advances through every tap on every cycle. The
reference stream `ref_in:s8` advances only while `ref_load` is asserted and is
otherwise held. Reference loading flushes the result-valid pipeline; no
convolution result is promised during that window.

For each operating cycle the design computes the dot product between the held
reference and the current 64-sample x window. A balanced registered add tree
accepts one new dot product per cycle and produces `y` after `LOG2_SIZE` adder
cycles. `y_valid` identifies those results. When `y_valid` is false, `y` is
driven to zero.

## Compile-time configuration

The defaults in `pyrope/matched_filter.prp` and the parameters in
`verilog/matched_filter.sv` are:

| name | default | contract |
| --- | ---: | --- |
| `SIZE` | 64 | power of two |
| `LOG2_SIZE` | 6 | positive; `SIZE == 2**LOG2_SIZE` |
| `MULT_WIDTH` | 4 | retained signed product width, 1 through 16 |

Both inputs always remain signed 8-bit samples. Precision retains the MSB side:

- `MULT_WIDTH < 8`: retain the upper `MULT_WIDTH` bits of each input, multiply
  those signed values, then retain the upper `MULT_WIDTH` product bits. At
  width 4 this is the bit selection
  `(x#[4..=7] * ref#[4..=7])#[4..=7]`.
- `MULT_WIDTH >= 8`: multiply the complete signed 8-bit operands into `s16`,
  then retain its upper `MULT_WIDTH` bits.

Pyrope uses `#sext[...]` for these selections. It chooses exactly the same bits
as `#[...]`, while explicitly reinterpreting the selected MSB as the sign bit;
a plain bit slice is otherwise unsigned. The sum width is
`MULT_WIDTH + LOG2_SIZE`, enough for all `SIZE` retained products.

## Source structure

- `pyrope/tap.prp`: independent x/reference storage. x always shifts;
  reference shifts only under `ref_load`.
- `pyrope/add_node.prp`: one generic registered add node.
- `pyrope/matched_filter.prp`: product quantization and a registered tree in
  which each iteration reads `current`, fills a fresh `next` vector from
  adjacent pairs, then advances `current = next`.
- `verilog/*.sv`: independent generate-loop implementation of the same public
  contract; it is a comparison implementation, not the source of truth.
- `verif/tap.verify.prp`: proves x advance, reference load, and reference hold.
- `tests/bug1/tap.prp`: corrupts loaded reference bytes and must refute.
- `sim/matched_filter_tb.prp`: common xorshift64 checksum driver for both lhd
  simulation paths.
- `sim/matched_filter_tb_verilator.cpp`: the Verilator twin; for its first
  4096 cycles it also checks `y_valid`, latency, and every result against a
  direct software dot-product model.

The default 64-tap implementation has 64 tap registers, 63 registered add
nodes, and six result-valid registers. Reference loading never pauses the x
stream.

## Running

```bash
bazel test //bench:matched_filter
bazel test //bench:matched_filter_compile_pyrope --test_output=all
bazel test //bench:matched_filter_sim_pyrope --test_output=all
bazel test //bench:matched_filter_sim_verilog --test_output=all
bazel test //bench:matched_filter_sim_verilator --test_output=all
```

To use the sibling LiveHD checkout while developing compiler changes, append
`--override_module=livehd=../livehd`.

## Pyrope compiler notes

The derived-width and type-alias fixes allow
`SUM_WIDTH = MULT_WIDTH + LOG2_SIZE` to define a named `Sum_T` used directly in
the output port and array elements. The design likewise uses `Product_T` for
its retained multiplier values.

Two generic cases remain unsupported. Passing `Sum_T` as the `add_node` type
argument loses the `a.[bits]` metadata used inside that generic, so the call
keeps the equivalent structural type. A non-type generic bound computed from
the surrounding loop index (for example
`add_level<N=(SIZE >> (lvl + 1))>`) also does not elaborate. The tree therefore
keeps the node loop directly in the top module.
