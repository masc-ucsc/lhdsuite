#!/usr/bin/env python3
"""Summarize the last //bench test results from bazel-testlogs.

Reads each target's test.log (the METRIC lines) and test.xml (status +
duration). Read-only: run `bazel test //bench:all` first.
"""

import re
import sys
import time
from pathlib import Path


def load(root: Path, target: str):
    """-> (status, age, duration_s, {metric: value}, [(step, cmd)]) or None."""
    d = root / target
    log = d / "test.log"
    if not log.is_file():
        return None
    metrics = {}
    cmds = []
    for line in log.read_text(errors="replace").splitlines():
        m = re.match(r"METRIC\s+(\S+)\s+(\S+)\s+(\S+)", line)
        if m:
            try:
                metrics[m.group(1)] = float(m.group(2))
            except ValueError:
                pass
        c = re.match(r"CMD (\S+): (.*)", line)
        if c:
            cmds.append((c.group(1), c.group(2)))
    status, dur = "?", None
    xml = d / "test.xml"
    if xml.is_file():
        t = xml.read_text(errors="replace")
        fail = re.search(r'failures="(\d+)"', t)
        err = re.search(r'errors="(\d+)"', t)
        tm = re.search(r'time="([0-9.]+)"', t)
        bad = int(fail.group(1) if fail else 0) + int(err.group(1) if err else 0)
        status = "FAIL" if bad else "pass"
        dur = float(tm.group(1)) if tm else None
    age = time.time() - log.stat().st_mtime
    if age < 90:
        age_s = f"{age:.0f}s ago"
    elif age < 5400:
        age_s = f"{age / 60:.0f}m ago"
    elif age < 129600:
        age_s = f"{age / 3600:.1f}h ago"
    else:
        age_s = f"{age / 86400:.1f}d ago"
    return status, age_s, dur, metrics, cmds


def fmt(v, unit=""):
    if v is None:
        return "-"
    if unit == "ms":
        return f"{v / 1000:.2f}s" if v >= 10000 else f"{v:.0f}ms"
    if v == int(v) and abs(v) < 1e15:
        return f"{int(v):,}"
    return f"{v:,.1f}"


def speedup(cold, warm):
    if cold and warm:
        return f"{cold / warm:.1f}x"
    return "-"


SHOW_CMDS = True


class Report:
    def __init__(self, root: Path):
        self.root = root
        self.missing = []

    def tgt(self, name):
        r = load(self.root, name)
        if r is None:
            self.missing.append(name)
        return r

    def cmds(self, *pairs):
        """Print each target's executed lhd command lines (from CMD log lines)."""
        if not SHOW_CMDS:
            return
        pairs = [(n, r) for n, r in pairs if r and r[4]]
        for name, r in pairs:
            if len(pairs) > 1:
                print(f"   [{name}]")
            for _step, cmd in r[4]:
                print(f"     $ {cmd}")

    def head(self, title, *results):
        worst = "pass"
        ages = []
        for r in results:
            if r is None:
                worst = "NOT RUN"
            else:
                ages.append(r[1])
                if r[0] != "pass" and worst != "NOT RUN":
                    worst = r[0]
        tag = {"pass": "ok", "FAIL": "FAIL", "NOT RUN": "not run"}.get(worst, worst)
        when = f"  ({ages[0]})" if ages else ""
        print(f"\n== {title:<28} [{tag}]{when}")


def main():
    global SHOW_CMDS
    root = Path(sys.argv[1])
    if "--no-cmds" in sys.argv[2:]:
        SHOW_CMDS = False
    if not root.is_dir():
        sys.exit(f"no test logs at {root} — run `bazel test //bench:all` first")
    rep = Report(root)
    G = rep.tgt

    print(f"lhdsuite bench results  (from {root})")

    # ---- compile ----------------------------------------------------------
    cv, cp, cpp = G("compile_verilog"), G("compile_pyrope"), G("compile_pyrope_parallel")
    rep.head("compile (source -> lg:)", cv, cp, cpp)
    if cv or cp or cpp:
        print(f"   {'':11} {'LoC':>8} {'words':>9} {'time':>8} {'LoC/s':>9} {'words/s':>9}")
        for name, r in (("verilog", cv), ("pyrope", cp)):
            if not r:
                continue
            m = r[3]
            print(f"   {name:11} {fmt(m.get(f'{name}_loc')):>8} {fmt(m.get(f'{name}_words')):>9}"
                  f" {fmt(m.get(f'compile_{name}_ms'), 'ms'):>8}"
                  f" {fmt(m.get(f'{name}_loc_per_s')):>9} {fmt(m.get(f'{name}_words_per_s')):>9}")
        if cpp:
            m = cpp[3]
            k = "pyrope_parallel"
            total = (m.get("leaves_parallel_ms") or 0) + (m.get("deps_reuse_ms") or 0)
            print(f"   {'pyrope-par':11} {fmt(m.get(f'{k}_loc')):>8} {fmt(m.get(f'{k}_words')):>9}"
                  f" {fmt(total, 'ms'):>8}"
                  f" {fmt(m.get(f'{k}_loc_per_s')):>9} {fmt(m.get(f'{k}_words_per_s')):>9}")
            seq = cp[3].get("compile_pyrope_ms") if cp else None
            print(f"     per-file: scan {fmt(m.get('scan_ms'), 'ms')},"
                  f" leaves parallel {fmt(m.get('leaves_parallel_ms'), 'ms')},"
                  f" dependents (--in-dir reuse) {fmt(m.get('deps_reuse_ms'), 'ms')}"
                  f"  [vs monolithic: {speedup(seq, total)}]")
        rep.cmds(("compile_verilog", cv), ("compile_pyrope", cp), ("compile_pyrope_parallel", cpp))

    # ---- synth: flat vs synth coloring -----------------------------------
    sy = G("synth")
    rep.head("synth (color flat vs synth)", sy)
    if sy:
        m = sy[3]
        print(f"   {'':7} {'color':>7} {'abc':>8} {'regions':>8} {'gates':>8} {'area um2':>11} {'delay':>7}")
        for alg in ("flat", "synth"):
            print(f"   {alg:7} {fmt(m.get(f'{alg}_color_ms'), 'ms'):>7} {fmt(m.get(f'{alg}_abc_ms'), 'ms'):>8}"
                  f" {fmt(m.get(f'{alg}_regions')):>8} {fmt(m.get(f'{alg}_gates')):>8}"
                  f" {fmt(m.get(f'{alg}_area')):>11} {fmt(m.get(f'{alg}_max_delay')):>7}")
        rep.cmds(("synth", sy))

    # ---- synth incremental ------------------------------------------------
    si = G("synth_incremental")
    rep.head("synth incremental (3 passes)", si)
    if si:
        m = si[3]
        print(f"   {'':22} {'compile':>8} {'color':>7} {'abc':>8} {'hits':>5} {'miss':>5}")
        for p, what in (("pass1", "cold"), ("pass2", "comment-only"), ("pass3", "one-line edit")):
            print(f"   {p} ({what})".ljust(25)
                  + f" {fmt(m.get(f'compile_{p}_ms'), 'ms'):>8} {fmt(m.get(f'{p}_color_ms'), 'ms'):>7}"
                  f" {fmt(m.get(f'{p}_abc_ms'), 'ms'):>8} {fmt(m.get(f'{p}_cache_hits')):>5}"
                  f" {fmt(m.get(f'{p}_cache_misses')):>5}")
        print(f"   abc warm speedup (pass2 vs pass1): "
              f"{speedup(m.get('pass1_abc_ms'), m.get('pass2_abc_ms'))}")
        rep.cmds(("synth_incremental", si))

    # ---- netlist lec: 2nd-run netlist proven against the design ------------
    nf, ns = G("synth_lec_flat"), G("synth_lec_synth")
    rep.head("netlist lec (2nd run vs design)", nf, ns)
    if nf or ns:
        for name, r in (("flat", nf), ("synth", ns)):
            if not r:
                continue
            m = r[3]
            print(f"   {name:7} gensim {fmt(m.get('gensim_ms'), 'ms')},"
                  f" lec {fmt(m.get('netlist_lec_ms'), 'ms')}"
                  f"  (pass-2 netlist PROVEN vs compiled design)")
        rep.cmds(("synth_lec_flat", nf), ("synth_lec_synth", ns))

    # ---- sim --------------------------------------------------------------
    sp, sv = G("sim_pyrope"), G("sim_verilog")
    rep.head("sim (StageReg hello world)", sp, sv)
    if sp or sv:
        # the run phase includes the generated driver's host C++ compile
        print(f"   {'':10} {'transpile':>9} {'setup':>8} {'run(+cc)':>8} {'cycles/s':>9} {'cpu-top':>8}")
        def cpu_state(m):
            v = m.get("sim_cpu_top_ok"), m.get("sim_cpu_prog_ok")
            if 0 in v:
                return "blocked"
            if v == (1, 1):
                return "ok"
            return "-"

        for name, r in (("pyrope", sp), ("verilog", sv)):
            if not r:
                continue
            m = r[3]
            print(f"   {name:10} {fmt(m.get('transpile_ms'), 'ms'):>9} {fmt(m.get('sim_setup_ms'), 'ms'):>8}"
                  f" {fmt(m.get('sim_run_ms'), 'ms'):>8} {fmt(m.get('sim_cycles_per_s')):>9}"
                  f" {cpu_state(m):>8}")
        print("   cpu-top: NOP smoke (dino_tb) + RISC-V counter program w/ IPC"
              " (dino_prog_tb) — informational until the comb-loop fix lands")
        rep.cmds(("sim_pyrope", sp), ("sim_verilog", sv))

    # ---- lec --------------------------------------------------------------
    lc, lb, li = G("lec"), G("lec_bug"), G("lec_incremental")
    rep.head("lec (pyrope impl vs verilog ref)", lc, lb, li)
    if lc:
        m = lc[3]
        print(f"   proven:   compile ref {fmt(m.get('compile_ref_ms'), 'ms')},"
              f" impl {fmt(m.get('compile_impl_ms'), 'ms')}, lec {fmt(m.get('lec_pass_ms'), 'ms')}")
    if lb:
        m = lb[3]
        print(f"   bug1:     refuted in {fmt(m.get('lec_bug_ms'), 'ms')}"
              f" (compile {fmt(m.get('compile_bug_ms'), 'ms')})")
    if li:
        m = li[3]
        print(f"   incr:     cold {fmt(m.get('lec_cold_ms'), 'ms')} ->"
              f" warm {fmt(m.get('lec_warm_ms'), 'ms')}"
              f" ({speedup(m.get('lec_cold_ms'), m.get('lec_warm_ms'))}),"
              f" comment-touch {fmt(m.get('lec_touch_ms'), 'ms')}")
    rep.cmds(("lec", lc), ("lec_bug", lb), ("lec_incremental", li))

    # ---- verify ------------------------------------------------------------
    vf, vi = G("verify"), G("verify_incremental")
    rep.head("verify (ALU assert/assume)", vf, vi)
    if vf:
        print(f"   proven:   {fmt(vf[3].get('verify_cold_ms'), 'ms')}")
    if vi:
        m = vi[3]
        print(f"   incr:     cold {fmt(m.get('verify_cold_ms'), 'ms')} ->"
              f" warm {fmt(m.get('verify_warm_ms'), 'ms')}"
              f" ({speedup(m.get('verify_cold_ms'), m.get('verify_warm_ms'))}),"
              f" comment-touch {fmt(m.get('verify_touch_ms'), 'ms')}")
    rep.cmds(("verify", vf), ("verify_incremental", vi))

    if rep.missing:
        print(f"\nnot run yet: {', '.join(rep.missing)}   -> bazel test //bench:all")
    print()


if __name__ == "__main__":
    main()
