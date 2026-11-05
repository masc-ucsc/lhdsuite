# Ibex along its commit history: cross-version formal reuse

`//bench:ibex_verify_history` runs Ibex's own assertions on Ibex's real RTL
history and checks that reusing old results never changes an answer.

## The versions

`history.jsonl.gz` holds 153 versions of `ibex_core`, from 2022-01-24 (double
fault detection) to 2026-09-05 (a3ab21a80b, the commit `ibex/verilog/` is
vendored from). It is built from the newest 200 commits of lowRISC Ibex that
touch `rtl/`. A commit is kept only if it changes the flattened design.

Each version is one flattened `.sv` file, made by `flatten.py`:
- `ibex_core` with every module and package it uses, and the includes inlined;
- `FPV_ON` defined, as in Ibex's formal flow, so the `ASSERT` macros become
  `assert property`;
- the top is `ibex_env`, which is `ibex_core` plus Ibex's own bus assumptions,
  copied from `dv/formal/check/protocol/mem.sv` for the instruction and data
  ports.

The properties are Ibex's built-in `ASSERT`s, with none added. Four assertions
are blanked out because they fail in every version, since the environment leaves
their inputs free: `IbexBootAddrUnaligned`, `IbexDontSkipExceptionReq`,
`IbexMulticycleEnableUnique` and `IbexSetExceptionPCOnSpecialReqIfExpected`.
JasperGold reports the same four.

The file stores the first version in full, then one line per version with its
commit and the line edits from the previous version. That makes it 285 KB in
place of 300 MB. `bench/history.py expand` rebuilds the versions.

To regenerate it from a clone of `https://github.com/lowRISC/ibex`:

```bash
python3 ibex/tests/history/make_history.py /path/to/ibex   # writes ibex/tests/history/history.jsonl.gz
```

The walk is pinned to Ibex commit `af456e2557` (2026-10-06). The output is
byte-identical for the same clone.

## The three methods

| Method | `formal.reuse=` | Across versions |
| --- | --- | --- |
| cold | `none` | every version from scratch, in a fresh workdir: the reference |
| hash | `hash` | one workdir; reuse a verdict when the assertion's cone hash is unchanged (like JasperGold's ProofMaster) |
| lpr | `all` | one workdir; **Layered Proof Reuse**: try each layer in turn, first answer wins |

The LPR layers, in order:
1. same cone hash;
2. sequentially equivalent cone (ABC `dsec`);
3. the old counterexample replayed;
4. the old PDR invariant re-checked.

Every method checks with PDR (`formal.pdr=true`) and uses the settings in the
`ibex` CORES entry: bound 10, the BMC engine, the ABC pre-pass with memories.

**The gate** is that no assertion is proven by one method and refuted by another
on the same version. Proven for all cycles versus proven to the bound is
reported (`history_full_bounded_flips`), not failed: PDR stops at a wall-clock
limit, so which one you get depends on machine load.

## Running

```bash
bazel test //bench:ibex_verify_history --test_output=all            # first 10 versions, minutes
bazel test //bench:ibex_verify_history --test_env=HISTORY_VERSIONS=0-40
bazel test //bench:ibex_verify_history --test_env=HISTORY_VERSIONS=all --test_timeout=14400
```

With gcc 13+, building the pinned LiveHD may stop on `-Werror=stringop-overflow`
inside rapidjson; add `--copt=-Wno-error=stringop-overflow`.

The full chain takes about 2.5 hours on a quiet machine. The methods run one
after another and the versions one at a time.

METRICs:
- `history_{cold,hash,lpr}_s` and `history_{hash,lpr}_speedup`;
- `history_wrong_answers`, which must be 0;
- `history_full_bounded_flips`;
- one `history_<method>_vNNN_ms` per run.

Measured over all 153 versions (LiveHD f99a121, 2026-10): cold 4971 s, hash
2437 s (2.04x), lpr 1918 s (2.59x, 6.86x in solver time), with 0 wrong answers.
