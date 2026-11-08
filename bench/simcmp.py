#!/usr/bin/env python3
"""Verilator vs `lhd sim` over Verilog, Pyrope and Pyrope2: one table.

Standalone (no bazel, no runfiles): it reads the CORES table in defs.bzl and the
suite tree next to it, so it can be run with a frozen copy of lhd while the
livehd checkout is being rebuilt. Use it through bench/simcmp.sh.

What is measured, per simulator:
  build   setup (driver generation / verilation) and host C++ compile+link,
          timed separately exactly as bench/sim.sh and bench/sim_verilator.sh do
          (`lhd sim --setup-only` / `--run-only --set sim.compile_only=true`;
          `verilator --cc --exe` / `make`).
  rate    the HONEST cycles/s: a two-point fit t(N) = startup + N/rate over two
          cycle counts, best-of-REPS each. One `execve` of the built binary is
          timed, and process startup (~16-19 ms here) is ~12% of dino's 500k run
          and ~96% of minion's 100k one, so a single-count cycles/s
          under-reports every simulator and the fast ones most (AGENTS.md).
  gate    the printed marker line of each simulator at the base count, so a
          reader can see whether the four simulators agree on the workload.

Fairness rules inherited from the bench: no VCD anywhere, the same Verilog
source (-F filelist -DSYNTHESIS + the core's v_flags) for `lhd sim` Verilog and
Verilator, the same driver stimulus (the Verilator .cpp is a twin of the
Pyrope testbench), and `sim.tune.profile=off` so the lhd leg measures a pinned
tune vector.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

BENCH = Path(__file__).resolve().parent
SUITE = BENCH.parent


def load_cores():
    text = (BENCH / "defs.bzl").read_text()
    start = text.index("\nCORES = {") + len("\nCORES = ")
    end = text.index("\n}\n", start) + 2
    # Pure literals plus string concatenation: no builtins needed.
    return eval(text[start:end], {"__builtins__": {}}, {"True": True, "False": False})


def which(name, env):
    p = os.environ.get(env)
    if p:
        return p
    p = shutil.which(name)
    if p:
        return p
    for d in ("/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"):
        if os.access(f"{d}/{name}", os.X_OK):
            return f"{d}/{name}"
    return None


class Runner:
    def __init__(self, work):
        self.work = work

    def run(self, name, argv, cwd, env=None):
        """Run argv, log to <work>/<name>.log; return (rc, ms)."""
        log = self.work / f"{name}.log"
        t0 = time.perf_counter()
        with log.open("w") as f:
            f.write("CMD " + " ".join(shlex.quote(str(a)) for a in argv) + "\n")
            f.flush()
            rc = subprocess.run([str(a) for a in argv], cwd=cwd, stdout=f,
                                stderr=subprocess.STDOUT, env=env).returncode
        return rc, (time.perf_counter() - t0) * 1000.0

    def best(self, name, argv, cwd, reps):
        """Best-of-reps wall ms of one process; returns (rc, ms, output)."""
        best, rc, out = None, 0, ""
        for _ in range(reps):
            t0 = time.perf_counter()
            p = subprocess.run([str(a) for a in argv], cwd=cwd, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True, errors="replace")
            ms = (time.perf_counter() - t0) * 1000.0
            rc, out = p.returncode, p.stdout
            if rc != 0:
                break
            best = ms if best is None else min(best, ms)
        (self.work / f"{name}.log").write_text(out)
        return rc, best, out


def fit(n1, t1, n2, t2):
    """Two-point fit t = startup + N/rate. Returns (startup_ms, cycles_per_s)."""
    if t1 is None or t2 is None or t2 <= t1:
        return None, None
    rate = (n2 - n1) / ((t2 - t1) / 1000.0)
    return t1 - n1 / rate * 1000.0, rate


def marker_line(out, marker):
    for line in out.splitlines():
        if marker and marker in line:
            # `lhd sim` prefixes puts with "file.prp:LINE:puts:"; verilator does not.
            return re.sub(r"^\S+\.prp:\d+:puts:", "", line.strip())
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--core", default="minion")
    ap.add_argument("--lhd", default=os.environ.get("LHD", ""), help="lhd binary (default $LHD)")
    ap.add_argument("--work", help="work directory (kept); default: a fresh temp dir")
    ap.add_argument("--sims", default="verilator,verilog,pyrope,pyrope2",
                    help="comma list; pyrope2 is skipped when <core>/pyrope2 is absent")
    ap.add_argument("--cycles", type=int, help="base cycle count N1 (default: the core's sim_cycles)")
    ap.add_argument("--factor", type=int, default=4, help="N2 = factor * N1 for the two-point fit")
    ap.add_argument("--reps", type=int, default=5, help="best-of reps per count")
    args = ap.parse_args()

    if not args.lhd or not Path(args.lhd).exists():
        ap.error("--lhd (or $LHD) must name an lhd binary")
    lhd = str(Path(args.lhd).resolve())
    cores = load_cores()
    if args.core not in cores:
        ap.error(f"unknown core {args.core}; have {', '.join(cores)}")
    cfg = cores[args.core]
    core = SUITE / args.core
    if not cfg.get("sim_tb"):
        ap.error(f"core {args.core} has no sim_tb")
    n1 = args.cycles or int(cfg["sim_cycles"])
    n2 = n1 * args.factor
    work = Path(args.work).resolve() if args.work else Path(tempfile.mkdtemp(prefix=f"simcmp-{args.core}-"))
    work.mkdir(parents=True, exist_ok=True)
    R = Runner(work)
    marker = cfg.get("sim_marker", "")
    unit = cfg.get("sim_tb_unit") or cfg["top"]
    sets = shlex.split(cfg.get("sim_sets", ""))
    if not any(s.startswith("sim.tune.profile=") for s in sets):
        sets = ["--set", "sim.tune.profile=off"] + sets
    ninja = which("ninja", "NINJA")
    vlt = which("verilator", "VERILATOR")
    wanted = args.sims.split(",")
    rows, notes = [], []
    print(f"core={args.core} top={cfg['top']} unit={unit} N1={n1} N2={n2} reps={args.reps} work={work}", flush=True)
    print(f"lhd={lhd}", flush=True)

    # sim.init_zero configures only the run inside `lhd sim`; a re-run drv.bin
    # needs the runtime switch (see bench/sim.sh EXEC_ARGS). Verilator ignores it.
    init_zero = ["--init-zero"] if "sim.init_zero=true" in sets else []

    def exec_fit(label, binary, cwd, rows_entry):
        extra = init_zero if label != "verilator" else []
        rc1, t1, o1 = R.best(f"{label}_exec_n1", [binary, "--cycles", n1, *extra], cwd, args.reps)
        rc2, t2, o2 = R.best(f"{label}_exec_n2", [binary, "--cycles", n2, *extra], cwd, args.reps)
        rows_entry["exit"] = rc1 or rc2
        rows_entry["marker"] = marker_line(o1, marker)
        rows_entry["t_n1_ms"], rows_entry["t_n2_ms"] = t1, t2
        rows_entry["startup_ms"], rows_entry["cycles_per_s"] = fit(n1, t1, n2, t2)
        if rc1 or rc2:
            notes.append(f"{label}: driver exited non-zero (see {label}_exec_n*.log). A testbench"
                         " `cycles` parameter has a range (dino: U20 = 1,048,575): keep N2 = factor*N1 inside it")
        elif rows_entry["cycles_per_s"] is None:
            notes.append(f"{label}: t(N2) <= t(N1); the fit is noise, rerun with a larger --factor")

    # ---- lhd sim legs -------------------------------------------------------
    for label in ("verilog", "pyrope", "pyrope2"):
        if label not in wanted:
            continue
        if label == "pyrope2" and not (core / "pyrope2").is_dir():
            notes.append(f"pyrope2: {core / 'pyrope2'} does not exist; skipped")
            continue
        d = work / label
        shutil.rmtree(d, ignore_errors=True)
        (d / "tree").mkdir(parents=True)
        tb = cfg["sim_tb"]
        row = {"sim": f"lhd-{label}", "label": label}
        if label == "verilog":
            tb = cfg.get("sim_tb_v") or tb
            rc, ms = R.run(f"{label}_compile", [
                lhd, "compile", "verilog", "--top", unit, "--emit-dir", "lg:lg", "--workdir", "tw",
                "--", "-F", core / "verilog/filelist.f", "-DSYNTHESIS", *shlex.split(cfg.get("v_flags", ""))], d)
            row["front_ms"] = ms
            if rc:
                notes.append(f"verilog: slang compile failed (see {label}_compile.log)")
                rows.append(row)
                continue
            design = "lg:lg"
        else:
            for p in (core / label).glob("*.prp"):
                shutil.copy(p, d / "tree")
            design = f"tree/{unit}.prp"
        for p in (core / "sim").glob("*.prp"):
            shutil.copy(p, d / "tree")
        inputs = [design, f"tree/{tb}"]
        rc, ms = R.run(f"{label}_setup", [lhd, "sim", *inputs, "--setup-only", "--set", "sim.vcd=false",
                                          *sets, "--workdir", "SW"], d)
        row["setup_ms"] = ms
        if rc:
            notes.append(f"{label}: lhd sim --setup-only failed (see {label}_setup.log)")
            rows.append(row)
            continue
        cc = [lhd, "sim", *inputs, "--run-only", "--set", "sim.compile_only=true"]
        if ninja:
            cc += ["--set", f"sim.ninja={ninja}"]
            env_path = os.path.dirname(ninja) + os.pathsep + os.environ["PATH"]
        else:
            notes.append(f"{label}: ninja not found; host compile column includes one simulation")
            env_path = os.environ["PATH"]
        rc, ms = R.run(f"{label}_cc", [*cc, *sets, "--diag-fmt", "pretty", "--workdir", "SW"], d,
                       env={**os.environ, "PATH": env_path})
        row["cc_ms"] = ms
        drv = d / "SW/sim/drv.bin"
        if rc or not drv.exists():
            notes.append(f"{label}: host build failed (see {label}_cc.log)")
            rows.append(row)
            continue
        exec_fit(label, drv, d, row)
        rows.append(row)
        print(f"  {label}: done", flush=True)

    # ---- verilator ----------------------------------------------------------
    if "verilator" in wanted:
        row = {"sim": "verilator", "label": "verilator"}
        if not vlt:
            notes.append("verilator: not installed; skipped")
        elif not cfg.get("verilator_tb"):
            notes.append("verilator: core has no verilator_tb; skipped")
        else:
            d = work / "verilator"
            shutil.rmtree(d, ignore_errors=True)
            d.mkdir(parents=True)
            top = cfg["top"]
            rc, ms = R.run("verilator_setup", [
                vlt, "--cc", "--exe", "--Mdir", "vobj", "--top-module", top, "-Wno-fatal",
                *shlex.split(cfg.get("verilator_flags", "")), "-DSYNTHESIS", f"-I{core / 'verilog'}",
                "-F", core / "verilog/filelist.f", core / "sim" / cfg["verilator_tb"]], d)
            row["setup_ms"] = ms
            if rc == 0:
                jobs = os.cpu_count() or 4
                rc, ms = R.run("verilator_cc", ["make", "-C", "vobj", "-f", f"V{top}.mk", f"-j{jobs}", f"V{top}"], d)
                row["cc_ms"] = ms
            if rc:
                notes.append("verilator: build failed (see verilator_setup.log / verilator_cc.log)")
            else:
                exec_fit("verilator", d / "vobj" / f"V{top}", d, row)
                print("  verilator: done", flush=True)
            rows.append(row)

    # ---- report -------------------------------------------------------------
    def f(v, fmt="{:,.0f}"):
        return "-" if v is None else fmt.format(v)

    hdr = f"{'simulator':<14}{'front':>9}{'setup':>9}{'c++':>9}{'startup':>9}{'cycles/s':>13}{'vs verilator':>14}"
    print("\n" + hdr)
    print("-" * len(hdr))
    ref = next((r.get("cycles_per_s") for r in rows if r["label"] == "verilator"), None)
    for r in rows:
        rel = "-" if not (ref and r.get("cycles_per_s")) else f"{r['cycles_per_s'] / ref:.2f}x"
        print(f"{r['sim']:<14}{f(r.get('front_ms')) + ' ms' if r.get('front_ms') else '-':>9}"
              f"{f(r.get('setup_ms')):>9}{f(r.get('cc_ms')):>9}{f(r.get('startup_ms'), '{:.1f}'):>9}"
              f"{f(r.get('cycles_per_s')):>13}{rel:>14}")
    print("  (times in ms; front = slang Verilog->lg:, setup = driver gen / verilate, c++ = host compile+link;"
          f" startup/cycles-per-s = two-point fit over N1={n1}, N2={n2}, best of {args.reps})")
    print("\nmarker line at N1 (a phase offset between simulators may legitimately move numbers):")
    base = None
    for r in rows:
        m = r.get("marker")
        print(f"  {r['sim']:<14}{m or '(none; exit ' + str(r.get('exit')) + ')'}")
        base = base or m
    agree = {r.get("marker") for r in rows if r.get("marker")}
    print(f"markers agree across simulators: {'yes' if len(agree) == 1 else 'NO (' + str(len(agree)) + ' distinct)'}")
    for n in notes:
        print("NOTE:", n)
    (work / "simcmp.json").write_text(json.dumps({"core": args.core, "n1": n1, "n2": n2, "reps": args.reps,
                                                    "rows": rows, "notes": notes}, indent=2) + "\n")
    print(f"\nlogs + simcmp.json: {work}")
    bad = [r for r in rows if r.get("exit") or r.get("cycles_per_s") is None]
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
