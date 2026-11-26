#!/usr/bin/env python3
"""Compare explicit Chisel and guarded Pyrope clocking on the Gemmini DMA tracker."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
from statistics import median
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent


def run(args, work, name, activity=False):
    env = os.environ.copy()
    if activity:
        env["LHD_SIM_LNAST_GATE"] = "1"
    result = subprocess.run(args, cwd=work, env=env, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
    (work / (name + ".log")).write_text(result.stdout)
    if result.returncode:
        raise RuntimeError(f"{name} failed\n{result.stdout[-4000:]}")
    return result.stdout


def mapped_gates(netlist):
    cells = json.loads(netlist.read_text())["modules"]["GatedTracker"]["cells"].values()
    gates = [cell for cell in cells if cell["type"].startswith("DLCLKP")]
    gated = {bit for gate in gates for bit in gate["connections"]["GCLK"]}
    # The mapper may buffer a clock between the integrated gate and its flops.
    while True:
        branches = {cell["connections"]["Y"][0] for cell in cells
                    if cell["type"] == "BUFx1" and cell["connections"]["A"][0] in gated}
        if branches <= gated:
            break
        gated |= branches
    bits = sum(cell["connections"]["CLK"][0] in gated for cell in cells if cell["type"].startswith("DFF"))
    return [gate["type"] for gate in gates], bits


def prove(work, yosys, reference):
    original = (HERE / "verilog/GatedTracker.v").read_text()
    contract = (HERE / "verify/return_contract.sv.inc").read_text()
    (work / "contract.sv").write_text(reference.replace(original, original.replace("endmodule", contract + "\nendmodule", 1)))
    rtl = "\n".join(p.read_text() for p in sorted((work / "guarded-rtl").glob("*.v")))
    (work / "impl.sv").write_text(re.sub(r"\b(DMACommandTracker|GatedTracker)\b", r"Impl_\1", rtl))
    shutil.copy(HERE / "verify/miter.sv", work / "miter.sv")
    for name, flag in [("proof", ""), ("negative", "-DMUTATE_COMPLETION")]:
        script = (f"read_verilog -formal -sv -DSYNTHESIS {flag} contract.sv impl.sv miter.sv; "
                  "prep -top miter -flatten; clk2fflogic; chformal -lower; opt_clean; async2sync; "
                  "dffunmap; techmap; opt; abc -g AND; dffunmap; write_aiger -zinit miter.aig")
        run([yosys, "-Q", "-q", "-p", script], work, name + "-build")
        result = run([yosys.with_name("yosys-abc"), "-c", "read_aiger miter.aig; fold; pdr -T 45"], work, name)
        expected = r"Property proved\." if name == "proof" else r"Output \d+ .* was asserted"
        if not re.search(expected, result):
            raise RuntimeError(f"{name} missing required verdict\n{result}")
        print(name, result.strip().splitlines()[-1], flush=True)


def compare(work, lhd, yosys, liberty):
    reference = "\n".join((HERE / "verilog" / f).read_text() for f in ("EICG_wrapper.v", "GatedTracker.v"))
    (work / "reference.v").write_text(reference)
    shutil.copy(liberty, work / "cells.lib")
    cases = ["chisel", "guarded"]
    for name in cases:
        source = "reference.v" if name == "chisel" else HERE / "pyrope/GatedTracker.prp"
        graph = "lg:" + name + "-lg"
        compile_args = [lhd, "compile", source, "--top", "GatedTracker", "--emit-dir", graph,
                        "--workdir", name + "-compile"]
        if name == "chisel":
            compile_args += ["--", "-DSYNTHESIS"]
        else:
            compile_args += ["--emit-dir", "verilog:guarded-rtl"]
        run(compile_args, work, name + "-compile")
        run([lhd, "synth", graph, "--top", "GatedTracker", "--set", "synth.liberty=cells.lib", "--set",
             "synth.timing=false", "--emit-dir", "verilog:" + name + "-mapped", "--workdir", name + "-synth"],
            work, name + "-synth")
        script = (f"read_liberty -lib cells.lib; read_verilog {name}-mapped/*.v; "
                  f"hierarchy -check -top GatedTracker; flatten; write_json {name}-net.json")
        run([yosys, "-Q", "-q", "-p", script], work, name + "-net")
        gates, bits = mapped_gates(work / (name + "-net.json"))
        if len(gates) != 1 or bits != 26:
            raise RuntimeError(f"{name} mapped {gates}, {bits} gated bits")
        for mode in ["sim", "profile"]:
            dest = name + "-" + mode
            cmd = [lhd, "sim", graph, HERE / "sim/tracker_tb.prp", "--top", "GatedTracker",
                   "--workdir", dest, "--setup-only"]
            if mode == "profile":
                cmd += ["--set", "sim.eval_counts=true"]
            run(cmd, work, dest, activity=True)
        observations = sample(work, lhd, name, "profile", 32000)["evaluations"]
        evaluation, = observations
        if (evaluation["instance"] != "dut" or evaluation["skipped"] <= 0
                or evaluation["attempted"] != evaluation["executed"] + evaluation["skipped"]):
            raise RuntimeError(f"invalid profile: {observations}")
        print(name, gates, bits, "gated flop bits", observations, flush=True)
    prove(work, yosys, reference)
    # Report slope between two lengths, interleaving uninstrumented models.
    rates = {case: [] for case in cases}
    for trial in range(5):
        for name in (cases if trial % 2 == 0 else reversed(cases)):
            short, long = 320000, 3200000
            t1 = sample(work, lhd, name, "sim", short)["sim_ns"]
            t2 = sample(work, lhd, name, "sim", long)["sim_ns"]
            rates[name].append((t2 - t1) / (long - short))
    for name, samples in rates.items():
        print(f"{name} median {median(samples):.2f} ns/cycle; five samples", [round(v, 2) for v in samples])


def sample(work, lhd, case, mode, cycles):
    dest = case + "-" + mode
    result = dest + "-run.json"
    run([lhd.with_name("lhd_simrt"), dest + "/sim", f"+cycles={cycles}", "--result-json", result],
        work, dest + "-run")
    rows = json.loads((work / result).read_text())
    row, = rows
    if row["status"] != "pass" or row["sim_cycles"] != cycles:
        raise RuntimeError(f"driver failed: {row}")
    return row


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ["lhd", "yosys", "liberty"]:
        parser.add_argument("--" + option, type=Path, required=True)
    parser.add_argument("--work", type=Path, help="keep logs and netlists in a new directory")
    args = parser.parse_args()
    paths = (args.lhd.resolve(), args.yosys.resolve(), args.liberty.resolve())
    if args.work:
        args.work.mkdir(parents=True)
        compare(args.work.resolve(), *paths)
    else:
        with tempfile.TemporaryDirectory(prefix="gemmini-gate-") as scratch:
            compare(Path(scratch), *paths)
