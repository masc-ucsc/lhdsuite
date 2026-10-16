#!/usr/bin/env python3
"""Compare the cleaned RenameBuffer with its generated baseline using LiveHD.

Retains sources, logs, and result JSON in a fresh temporary directory. The LEC
check passes when lhd reports the two equivalent (proven or sampled):
PROVEN-full, PROVEN-bounded(n) or TESTED-sampled(N), with the bound / vector
count recorded in checks.json. lhd's TIMEOUT-time / TIMEOUT-memory pass too
(only a refute is a failure; recorded with "proof": false and printed as a
NOTE). An LEC run this script's own --timeout kills passes the same way, as
TIMEOUT-deadline, unless its partial log already shows a top-level REFUTED-*.
Any REFUTED-* returns nonzero. Simulation uses matching zero power-on fill
and never substitutes for the LEC check.
"""
import argparse
import json
from pathlib import Path
import os
import re
import shutil
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASELINE = "894526b6e47cca7a4686931cda1bfb90d8d22a39"
SOURCE = "xiangshan/Backend/pyrope2/RenameBuffer.prp"


# Accepted outcomes (owner rulings 2026-10-14: only a refute is a failure;
# timeout and bounded are okay), under lhdsuite's own (default) formal.effort.
# "Equivalent (proven or sampled)": lhd's PROVEN-full, PROVEN-bounded(n) or
# TESTED-sampled(N). TIMEOUT-time / TIMEOUT-memory also PASS -- never a proof,
# never a failure -- and are recorded with "proof": false. Any refuted-*, and
# a missing, inconsistent or pre-2026-10-14 record, is rejected (None).
def equivalence(lec):
    verdict = (lec or {}).get("verdict")
    if verdict == "proven-full" and lec.get("bounded") is False:
        return {"verdict": verdict, "proof": True}
    if verdict == "proven-bounded" and lec.get("bounded") is True:
        return {"verdict": verdict, "bound": lec.get("bound"), "proof": True}
    if verdict == "tested-sampled":
        return {"verdict": verdict, "vectors": lec.get("vectors"), "proof": False}
    if verdict in ("timeout-time", "timeout-memory"):
        return {"verdict": verdict, "proof": False}
    return None


def describe(evidence):
    if not evidence:
        return "no equivalence evidence (verdict is not proven-*, tested-sampled or timeout-*)"
    if evidence["verdict"].startswith("timeout-"):
        word = "TIMEOUT-" + evidence["verdict"][len("timeout-"):]
        return f"NOTE: equivalent? {word} (no proof, no counterexample; not a failure)"
    if "bound" in evidence:
        return f"equivalent (proven for {evidence['bound']} cycle(s): proven-bounded)"
    if "vectors" in evidence:
        return f"equivalent (sampled {evidence['vectors']} input vectors: tested-sampled)"
    return "equivalent (proven: proven-full)"


# A run THIS script's own timer/watchdog stopped writes no lhd record. "Any
# resource constraint is a timeout" (owner ruling 2026-10-14), the same as
# verif/lec_verdict.py's TIMEOUT-deadline: it passes, never as a proof --
# unless the record or the partial log already shows a top-level REFUTED-*.
TOP_REFUTED = re.compile(r"^(?:lec|formal verify): '[^']*' REFUTED-[a-z]+", re.M)


def deadline_evidence(record, log_text):
    if str((record or {}).get("verdict", "")).startswith("refuted-") or TOP_REFUTED.search(log_text or ""):
        return None
    return {"verdict": "timeout-deadline", "proof": False}


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
        evidence = None
        if name == "lec" and timed_out:
            evidence = deadline_evidence(payload.get("lec", {}),
                                         (work / f"{name}.log").read_text(errors="replace"))
            ok = evidence is not None
        elif name == "lec":
            evidence = equivalence(payload.get("lec", {}))
            ok = ok and evidence is not None
        checks.append(dict(name=name, command=command, exit_code=proc.returncode,
                           timed_out=timed_out, ok=ok, result=payload, equivalence=evidence))
        (work / "checks.json").write_text(json.dumps(checks, indent=2) + "\n")
        detail = f" -- {describe(evidence)}" if name == "lec" else ""
        print(f"{name}: {'PASS' if ok else 'INCOMPLETE OR FAILED'}{detail}", flush=True)
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
