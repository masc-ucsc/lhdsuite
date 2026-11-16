#!/usr/bin/env python3
"""Compile/run the mesh or the vendored-core connectivity bench. No synthesis or PDK."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from generate_rtl import HERE, stage
from topology import TILES


def run(mode, work, verilator, jobs):
    path = work.resolve()/mode
    files = stage(path, cores=(mode == "system"))
    top = f"mixed_{mode}_tb"
    obj = path/"obj"
    cmd = [verilator, "--binary", "--timing", "--top-module", top, "--Mdir", str(obj), "-j", str(jobs),
           "-Wno-PINMISSING", "-Wno-fatal", "-DSYNTHESIS", "-I"+str(path)]
    subprocess.run(cmd + files + [HERE/"sim"/(mode+"_tb.sv")], cwd=path, check=True)
    # Older simulators may exit successfully on an unintended early $finish.
    result = subprocess.run([obj/("V"+top)], cwd=path, stdout=subprocess.PIPE, text=True)
    print(result.stdout, end="", flush=True)
    result.check_returncode()
    signature = f"{len(TILES)**2} ordered endpoint pairs" if mode=="mesh" else "16 pointers read from Gemmini"
    if not any(line.startswith("PASS:") and signature in line for line in result.stdout.splitlines()):
        raise SystemExit("missing simulation verdict")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("mesh", "system"))
    parser.add_argument("--work", type=Path, help="keep staging and reuse the simulation build")
    parser.add_argument("--verilator", default=os.environ.get("VERILATOR", "verilator"))
    parser.add_argument("-j", type=int, default=4)
    args = parser.parse_args()
    executable = shutil.which(args.verilator)
    if not executable:
        parser.error("Verilator 5 is required; set VERILATOR or --verilator")
    if args.j < 1:
        parser.error("-j must be positive")
    if args.work:
        run(args.mode, args.work, executable, args.j)
    else:
        with tempfile.TemporaryDirectory(prefix="mixed-soc-") as tmp:
            run(args.mode, Path(tmp), executable, args.j)
