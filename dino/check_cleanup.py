#!/usr/bin/env python3
"""Validate the hand-maintained Dino against its original Verilog using LiveHD."""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import time

SUITE = Path(__file__).resolve().parents[1]
DINO = SUITE / "dino"
TOP = "PipelinedDualIssueCPU"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lhd", type=Path, default=SUITE.parent / "livehd/bazel-bin/lhd/lhd")
    parser.add_argument("--workdir", type=Path, help="parent for a fresh run directory; logs are retained")
    parser.add_argument("--top-bug", action="store_true", help="also check the injected bug through the whole CPU (can be slow)")
    args = parser.parse_args()
    lhd = args.lhd.resolve(strict=True)
    if args.workdir:
        args.workdir.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="dino-cleanup-", dir=args.workdir)).resolve()
    report = {"lhd": str(lhd), "binary_sha256": hashlib.sha256(lhd.read_bytes()).hexdigest(),
              "sources_sha256": {str(p.relative_to(SUITE)): hashlib.sha256(p.read_bytes()).hexdigest()
                                 for p in sorted((DINO / "pyrope").glob("*.prp"))}, "reference_sha256": {str(p.relative_to(SUITE)): hashlib.sha256(p.read_bytes()).hexdigest()
                                    for p in sorted((DINO / "verilog").iterdir()) if p.is_file()},
              "checks": []}
    print(f"Artifacts: {work}", flush=True)

    def run(name, arguments, verdict=None):
        result = work / f"{name}.json"
        command = [str(lhd), *map(str, arguments), "--workdir", str(work / name),
                   "--result-json", str(result)]
        print(f"CMD {name}: {shlex.join(command)}", flush=True)
        started = time.monotonic()
        with (work / f"{name}.log").open("w") as log:
            proc = subprocess.run(command, cwd=SUITE, stdout=log, stderr=subprocess.STDOUT)
        payload = json.loads(result.read_text())
        lec = payload.get("lec", {})
        ok = proc.returncode == 0
        if verdict == "proven":
            ok = ok and lec.get("verdict") == "proven" and lec.get("bounded") is False
        elif verdict == "refuted":
            ok = proc.returncode != 0 and lec.get("verdict") == "refuted"
        report["checks"].append({"name": name, "command": command, "ok": ok,
                                  "seconds": round(time.monotonic() - started, 3),
                                  "exit_code": proc.returncode, "lec": lec})
        (work / "results.json").write_text(json.dumps(report, indent=2) + "\n")
        if not ok:
            raise SystemExit(f"FAIL {name}: see {work / (name + '.log')}")
        print(f"PASS {name}" + (f" ({verdict})" if verdict else ""), flush=True)

    ref = "lg:" + str(work / "reference.lg")
    # Slang resolves filelist entries relative to the list itself.
    # Put generic CLI options before the '--' delimiter for slang arguments.
    ref_command = [str(lhd), "compile", "verilog", "--top", TOP, "--emit-dir", ref,
                   "--workdir", str(work / "compile_reference"), "--", "-F",
                   str(DINO / "verilog/filelist.f"), "-DSYNTHESIS"]
    print("CMD reference: " + shlex.join(ref_command), flush=True)
    with (work / "reference.log").open("w") as log:
        subprocess.run(ref_command, cwd=SUITE, stdout=log, stderr=subprocess.STDOUT, check=True)
    implementation = DINO / "pyrope" / f"{TOP}.prp"
    lec_args = ["lec", "--impl", implementation, "--ref", ref, "--top", TOP]
    # Independent workdirs prove repeatability without reusing a verdict cache.
    run("lec_first", lec_args, "proven")
    run("lec_repeat", lec_args, "proven")

    variants = work / "variants"
    shutil.copytree(DINO / "pyrope", variants)
    shutil.copy2(DINO / "tests/comment1/ALU.prp", variants / "ALU.prp")
    run("lec_comment", ["lec", "--impl", variants / f"{TOP}.prp", "--ref", ref, "--top", TOP], "proven")
    shutil.copy2(DINO / "tests/bug1/ALU.prp", variants / "ALU.prp")
    run("lec_bug_alu", ["lec", "--impl", variants / "ALU.prp", "--ref", DINO / "verilog/ALU.sv", "--top", "ALU"], "refuted")
    if args.top_bug:
        run("lec_bug_top", ["lec", "--impl", variants / f"{TOP}.prp", "--ref", ref, "--top", TOP], "refuted")
    run("verify_alu", ["formal", "verify", DINO / "pyrope/ALU.prp", DINO / "verif/ALU.verify.prp",
                       "--top", "ALU", "--set", "formal.bound=2"])
    run("verify_stage", ["formal", "verify", DINO / "pyrope/StageReg.prp", DINO / "verif/StageReg.verify.prp",
                         "--top", "StageReg", "--set", "formal.bound=8"])
    for seed in (1, 37):
        run(f"program_seed{seed}", ["sim", implementation, DINO / "sim/dino_prog_tb.prp",
                                   "--arg", "cycles=2000", "--seed", seed])
    run("alu_shift_edge", ["sim", DINO / "pyrope/ALU.prp", DINO / "repros/alu_array/alu_edges_tb.prp"])
    stages = work / "stage_driver"
    shutil.copytree(DINO / "pyrope", stages)
    shutil.copy2(DINO / "sim/stagereg_tb.prp", stages / "stagereg_tb.prp")
    run("stage_capture", ["sim", stages / "StageReg.prp", stages / "stagereg_tb.prp", "--arg", "cycles=16"])
    print(f"All cleanup checks passed. Results: {work / 'results.json'}")


if __name__ == "__main__":
    main()
