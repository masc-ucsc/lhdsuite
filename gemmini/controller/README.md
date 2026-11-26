# Gemmini gated DMA command tracker

This fixture extracts Gemmini's load-controller tracker with two outstanding commands, an eight-bit byte count and a four-bit completion tag. The reference wrapper applies the software clock-enable rule in Gemmini’s controller. The Pyrope wrapper calls the same tracker under `if running`. A gate write coincident with a new command observes busy immediately. Invalid completion payloads are masked on both public interfaces.

## Reproduce the comparison

Build `//lhd:lhd` and `//lhd:lhd_simrt` with `bazel build -c opt` in LiveHD. From lhdsuite, run the following with Yosys and its companion `yosys-abc` in the same directory.

```sh
python3 gemmini/controller/check.py \
  --lhd ../livehd/bazel-bin/lhd/lhd --yosys ../yosys/build/yosys \
  --liberty ../livehd/lhd/tests/abc_icg_q.lib
```

Pass `--work NEW_DIRECTORY` to keep the logs, simulator images, mapped netlists and proof inputs. The driver overlaps two commands, splits a DMA return, stalls completion, denies a gate write while busy, applies reset while idle and wakes the tracker.

| Local opt build, single simulation thread | Explicit Chisel gate | Guarded Pyrope call |
| --- | ---: | ---: |
| Mapped integrated clock gate | 1 × DLCLKPx2 | 1 × DLCLKPx1 |
| Flop bits downstream of the gate | 26 | 26 |
| DUT kernel evaluations executed / attempted in 32,000 cycles | 30,001 / 64,001 | 30,001 / 64,001 |
| Evaluations skipped | 34,000 | 34,000 |
| Median execution time, ns/cycle | 7.74 | 7.94 |

The netlist count follows clock buffers to flip-flop clock pins in LiveHD’s clock-gate test Liberty. Each tracker entry owns a valid bit, four tag bits and eight byte-count bits. The enable register runs on the parent clock. The per-instance counter covers edge and settle kernels dispatched for the testbench DUT. The comparison enables activity scheduling for both small models with `LHD_SIM_LNAST_GATE=1`. Timing uses separate uninstrumented images, five interleaved pairs of 320,000 and 3,200,000 cycles, and the median slope of native runtime `sim_ns`. Both implementations achieved the same evaluation savings. These measurements cover the controller fixture.

## Proof scope

The miter compares every public output on both clock phases after two reset edges. Inputs may change on each falling edge. At a returned transfer on a live tracker clock, the referenced entry must be valid and its remaining byte count must cover the return. These are the two assertions in the original DMA tracker. ABC PDR proved the miter for all subsequent cycles under those assumptions. Inverting one tag bit only on a valid completion produced a counterexample in frame 5. LiveHD's separate flat LEC gave `PROVEN-bounded(6)` under the return assumptions. The unbounded result comes from PDR.

## Chisel source and regeneration

The emitted reference uses the unmodified `generators/gemmini/src/main/scala/gemmini/DMACommandTracker.scala` at Gemmini `b82d49c`, this fixture's [Chisel wrapper](chisel/Emit.scala), and Rocket Chip's `src/main/resources/vsrc/EICG_wrapper.v` at `ece7b9a`. Gemmini's `Controller.scala` provides the clock gate and `LoadController.scala` provides the busy rule. The standalone emission used the JVM FIRRTL emitter in Chisel 3.6.1, Scala 2.13.12 and sbt 1.10.7.

To regenerate in a fresh sbt project, copy the tracker and `Emit.scala` to `src/main/scala/`, put `sbt.version=1.10.7` in `project/build.properties`, and use the following `build.sbt`.

```scala
scalaVersion := "2.13.12"
libraryDependencies += "edu.berkeley.cs" %% "chisel3" % "3.6.1"
addCompilerPlugin("edu.berkeley.cs" % "chisel3-plugin" % "3.6.1" cross CrossVersion.full)
```

Run `sbt 'runMain Emit'` and take `rtl/GatedTracker.v`. Keep the Rocket Chip gate implementation alongside it. The proof runner injects the two environment assumptions into a scratch copy of the emitted reference.
