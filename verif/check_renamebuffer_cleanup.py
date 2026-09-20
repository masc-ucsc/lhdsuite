#!/usr/bin/env python3
"""Compare the cleaned RenameBuffer with its generated baseline using LiveHD.

Retains sources, logs, and result JSON in a fresh temporary directory. A timeout
is inconclusive and returns nonzero. Simulation uses matching zero power-on
fill and never substitutes for an unbounded proof.
"""
import argparse
import json
from pathlib import Path
import os
import shutil
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASELINE = "894526b6e47cca7a4686931cda1bfb90d8d22a39"
SOURCE = "xiangshan/Backend/pyrope2/RenameBuffer.prp"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--lhd", type=Path, default=ROOT.parent / "livehd/bazel-bin/lhd/lhd")
    ap.add_argument("--timeout", type=int, default=180)
    ap.add_argument("--cycles", type=int, default=2048)
    ap.add_argument("--lec", action="store_true", help="also attempt top-level LEC against RTL")
    args = ap.parse_args()
    work = Path(tempfile.mkdtemp(prefix="renamebuffer-check-"))
    print(f"Artifacts: {work}", flush=True)
    sources = work / "sources"
    sources.mkdir()
    (sources / "RenameBuffer_original.prp").write_bytes(subprocess.check_output(
        ["git", "show", f"{BASELINE}:{SOURCE}"], cwd=ROOT))
    shutil.copy2(ROOT / SOURCE, sources / "RenameBuffer_clean.prp")
    for name in ("SnapshotGenerator.prp", "snapshot_queue.prp"):
        shutil.copy2((ROOT / SOURCE).parent / name, sources / name)
    shutil.copy2(Path(__file__).with_name("renamebuffer_cleanup_tb.prp"), sources / "compare.prp")
    checks = []

    def run(name, flags):
        command = [str(args.lhd.resolve()), *map(str, flags), "--workdir", str(work / name),
                   "--result-json", str(work / f"{name}.json")]
        print("CMD " + " ".join(command), flush=True)
        with (work / f"{name}.log").open("w") as log:
            proc = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                    start_new_session=True)
            timed_out = False
            try:
                proc.wait(timeout=args.timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(proc.pid, signal.SIGTERM)
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()
        result = work / f"{name}.json"
        payload = json.loads(result.read_text()) if result.exists() else {}
        ok = not timed_out and proc.returncode == 0
        if name == "lec":
            ok = ok and payload.get("lec", {}).get("verdict") == "proven" and payload["lec"].get("bounded") is False
        checks.append(dict(name=name, command=command, exit_code=proc.returncode,
                           timed_out=timed_out, ok=ok, result=payload))
        (work / "checks.json").write_text(json.dumps(checks, indent=2) + "\n")
        print(f"{name}: {'PASS' if ok else 'INCOMPLETE OR FAILED'}", flush=True)
        return ok

    ok = run("sim", ["sim", sources / "compare.prp", "--arg", f"cycles={args.cycles}",
                     "--set", "sim.unknown_zero=true", "--set", "sim.init_zero=true",
                     ])
    if args.lec:
        rtl = ROOT / "xiangshan/Backend/verilog"
        compiled = run("rtl", ["compile", "verilog", rtl / "RenameBuffer.sv", rtl / "SnapshotGenerator.sv",
                               "--top", "RenameBuffer", "--emit-dir", "lg:" + str(work / "rtl_lg")])
        if compiled:
            ok = run("lec", ["lec", "--impl", ROOT / SOURCE, "--ref", "lg:" + str(work / "rtl_lg"),
                             "--top", "RenameBuffer", "--set", "formal.engine=ind"]) and ok
        else:
            ok = False
    raise SystemExit(0 if ok else 1)


if __name__ == "__main__":
    main()
