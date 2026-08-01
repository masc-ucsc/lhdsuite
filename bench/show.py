#!/usr/bin/env python3
"""Summarize the last //bench test results from bazel-testlogs.

Reads each target's test.log (the METRIC lines) and test.xml (status +
duration). Read-only: run `bazel test //bench:all` first (or, for one design,
`bazel test //bench:minion`).

Targets are named <core>_<scenario>; one section is printed per core. Limit
the report with `--core <name>` (repeatable).
"""

import re
import sys
import time
from pathlib import Path

# Keep in sync with the CORES table in bench/defs.bzl.
CORES = ("dino", "minion")


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
    """Per-core view of bazel-testlogs: `G("lec")` reads <core>_lec."""

    def __init__(self, root: Path, core: str):
        self.root = root
        self.core = core
        self.missing = []

    def tgt(self, name):
        full = f"{self.core}_{name}"
        r = load(self.root, full)
        if r is None:
            self.missing.append(full)
        return r

    def cmds(self, *pairs):
        """Print each target's executed lhd command lines (from CMD lines)."""
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


def report_core(root: Path, core: str) -> list:
    """Print one core's section; return its not-run target names."""
    rep = Report(root, core)
    G = rep.tgt

    print(f"\n{'─' * 72}\n{core}\n{'─' * 72}")

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
            total = sum(m.get(s) or 0 for s in ("scan_ms", "generate_ms", "build_ms"))
            print(f"   {'pyrope-par':11} {fmt(m.get(f'{k}_loc')):>8} {fmt(m.get(f'{k}_words')):>9}"
                  f" {fmt(total, 'ms'):>8}"
                  f" {fmt(m.get(f'{k}_loc_per_s')):>9} {fmt(m.get(f'{k}_words_per_s')):>9}")
            seq = cp[3].get("compile_pyrope_ms") if cp else None
            print(f"     per-file: scan {fmt(m.get('scan_ms'), 'ms')},"
                  f" gen build.mk {fmt(m.get('generate_ms'), 'ms')},"
                  f" make -j {fmt(m.get('build_ms'), 'ms')}"
                  f"  [vs monolithic: {speedup(seq, total)}]")
            print(f"     graph: {fmt(m.get('parallel_units'))} units"
                  f" ({fmt(m.get('parallel_pruned'))} pruned by --top),"
                  f" {fmt(m.get('parallel_depth'))} levels deep,"
                  f" widest {fmt(m.get('parallel_widest'))}")
        rep.cmds(("compile_verilog", cv), ("compile_pyrope", cp),
                 ("compile_pyrope_parallel", cpp))

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
        # `remapped` (miss_ms) is the column that answers "did incremental
        # help". A hit COUNT does not: minion once showed 199 hits of 264
        # regions and a 1.0x speedup, because everything expensive sat in the
        # 65 that missed.
        print(f"   {'':22} {'compile':>8} {'color':>7} {'abc':>8} {'hits':>5} {'miss':>5} {'remapped':>9}")
        for p, what in (("pass1", "cold"), ("pass2", "comment-only"), ("pass3", "one-line edit")):
            print(f"   {p} ({what})".ljust(25)
                  + f" {fmt(m.get(f'compile_{p}_ms'), 'ms'):>8} {fmt(m.get(f'{p}_color_ms'), 'ms'):>7}"
                  f" {fmt(m.get(f'{p}_abc_ms'), 'ms'):>8} {fmt(m.get(f'{p}_cache_hits')):>5}"
                  f" {fmt(m.get(f'{p}_cache_misses')):>5} {fmt(m.get(f'{p}_cache_miss_ms'), 'ms'):>9}")
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
    rep.head("sim benchmark throughput", sp, sv)
    if sp or sv:
        # `lhd sim --setup-only` only writes the driver sources; the host C++
        # compile lives inside --run-only and is rebuilt every time, so it used
        # to swamp the simulation it was being reported as. Keep the two apart:
        # `c++` is the compile+link, `sim` the simulation of `cycles` cycles.
        print(f"   {'':10} {'transpile':>9} {'setup':>7} {'c++':>8} {'sim':>8}"
              f" {'cycles':>9} {'sim cyc/s':>10} {'+c++':>10} {'extra':>8}")

        def top_state(m):
            v = [m[k] for k in ("sim_cpu_top_ok", "sim_cpu_prog_ok") if k in m]
            if not v:
                return "-"
            if 0 in v:
                return "blocked"
            return "ok" if all(x == 1 for x in v) else "-"

        for name, r in (("pyrope", sp), ("verilog", sv)):
            if not r:
                continue
            m = r[3]
            print(f"   {name:10} {fmt(m.get('transpile_ms'), 'ms'):>9} {fmt(m.get('sim_setup_ms'), 'ms'):>7}"
                  f" {fmt(m.get('sim_cc_ms'), 'ms'):>8} {fmt(m.get('sim_exec_ms'), 'ms'):>8}"
                  f" {fmt(m.get('sim_cycles')):>9}"
                  f" {fmt(m.get('sim_cycles_per_s')):>10}"
                  f" {fmt(m.get('sim_cycles_per_s_with_cc')):>10} {top_state(m):>8}")

        # The CMD lines are the authoritative record of which driver each
        # number came from. A throughput row times sim_setup/sim_run only; the
        # additional whole-top correctness drivers run later and must not
        # inherit the benchmark's cycle count.
        def tb_for_step(r, step):
            for got_step, cmd in r[4]:
                if got_step == step:
                    tbs = re.findall(r"(?:^|/)([^ /]+\.prp)(?= |$)", cmd)
                    return tbs[-1] if tbs else None
            return None

        sample = sp or sv
        bench_tbs = {tb_for_step(r, "sim_setup") for r in (sp, sv) if r}
        bench_tbs.discard(None)
        bench = "/".join(sorted(bench_tbs)) or "simulation driver"
        print(f"   sim cyc/s: {bench}, VCD on; +c++ includes that driver's host compile")

        m = sample[3]
        whole = []
        for step, key in (("sim_cpu", "sim_cpu_top_cycles"),
                          ("sim_cpu_prog", "sim_cpu_prog_cycles")):
            tb = tb_for_step(sample, step)
            if tb:
                cycles = m.get(key)
                whole.append(f"{tb} ({fmt(cycles) + ' cycles' if cycles is not None else 'test default'})")
        if whole:
            policy = "gates this target" if m.get("sim_cpu_top_gated") == 1 else "informational only"
            print(f"   extra: {', '.join(whole)} run separately for correctness ({policy}); not timed above")
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
    rep.head("verify (unit assert/assume)", vf, vi)
    if vf:
        print(f"   proven:   {fmt(vf[3].get('verify_cold_ms'), 'ms')}")
    if vi:
        m = vi[3]
        print(f"   incr:     cold {fmt(m.get('verify_cold_ms'), 'ms')} ->"
              f" warm {fmt(m.get('verify_warm_ms'), 'ms')}"
              f" ({speedup(m.get('verify_cold_ms'), m.get('verify_warm_ms'))}),"
              f" comment-touch {fmt(m.get('verify_touch_ms'), 'ms')}")
    rep.cmds(("verify", vf), ("verify_incremental", vi))

    return rep.missing


def main():
    global SHOW_CMDS
    argv = sys.argv[2:]
    root = Path(sys.argv[1])
    if "--no-cmds" in argv:
        SHOW_CMDS = False
    cores = [c for i, a in enumerate(argv) if a == "--core" for c in argv[i + 1:i + 2]]
    for c in cores:
        if c not in CORES:
            sys.exit(f"unknown core '{c}' — known: {', '.join(CORES)}")
    cores = cores or list(CORES)

    if not root.is_dir():
        sys.exit(f"no test logs at {root} — run `bazel test //bench:all` first")

    print(f"lhdsuite bench results  (from {root})")
    missing = []
    for core in cores:
        missing += report_core(root, core)

    if missing:
        print(f"\nnot run yet: {', '.join(missing)}"
              f"\n  -> bazel test //bench:all   (or //bench:<core> for one design)")
    print()


if __name__ == "__main__":
    main()
