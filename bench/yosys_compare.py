#!/usr/bin/env python3
"""LiveHD vs Yosys+ABC synthesis QoR under the same Liberty, SDC and STA.

For every selected core with Verilog RTL (CORES in bench/defs.bzl):

  yosys  read_slang (filelist + v_flags) -> an ORFS-like recipe: synth -flatten
         -noabc, extract_fa + the asap7 adder map, latch map, dfflibmap, abc with
         ORFS's abc_speed.script, -D <SDC clock period>, -constr (BUFx2 driver,
         ORFS load), ORFS's asap7 dont_use list, hilomap, insbuf.
  lhd    `lhd synth` from the SAME Verilog with the same Liberty and SDC
         (synth.liberty / synth.sdc, as bench/synth.sh passes them), emitting a
         Verilog netlist.
  sta    ONE OpenSTA script (inside openroad) on both netlists: asap7 tech+cell
         LEF, the Liberty, link, the core's SDC; setup WNS/TNS, mapped cell
         count, sequential cells and Liberty area. Ideal clocks, no wire load,
         no placement: a pre-placement view of both netlists.

Memories: both sides lower inferred memories to flops (yosys's memory_map,
lhd's synth.memory=flops), so area and timing are comparable. bench/synth.sh
uses synth.memory=macro, whose native memory blocks Yosys has no equivalent for.

Runs outside bazel (it takes hours on the large cores) and is resumable: a core
whose result.json exists is skipped unless --force. Results land in
<out>/<core>/result.json, <out>/summary.json and <out>/summary.md, rewritten
after every finished core.

  python3 bench/yosys_compare.py --out /path/to/yosys_cmp \
      --lhd /path/to/lhd --yosys /path/to/yosys --slang /path/to/slang.so \
      --openroad /path/to/openroad --lef tech.lef --lef cells.lef \
      --orfs /dir/with/abc_speed.script,cells_adders_R.v,cells_latch_R.v \
      [--cores dino,picorv32] [--jobs 12]
"""

import argparse
import concurrent.futures
import gzip
import io
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import tokenize
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Small first, so partial tables arrive early. cva6's verilog/ is only a cache
# tag-comparator cone (the bench synthesizes the whole core from Pyrope), so it
# has no comparable Verilog and is not listed.
ORDER = [
    "dino", "picorv32", "matched_filter", "xs_alu", "ibex", "bitcoin", "xs_div",
    "xs_renametable", "minion", "gemmini", "xs_rob", "xs_exu", "gemmini8", "rocket",
    "xs_mini16", "boom", "gemmini16", "xs_backend",
]

ORFS_DONT_USE = ["*x1p*_ASAP7*", "*xp*_ASAP7*", "SDF*", "ICG*"]
ORFS_ABC_LOAD = "3.898"  # ORFS asap7 ABC_LOAD_IN_FF

STA_TCL = r"""
foreach l [split $::env(CMP_LEF) " "] { if {$l ne ""} { read_lef $l } }
read_liberty $::env(CMP_LIB)
foreach f [split $::env(CMP_NET) " "] { if {$f ne ""} { read_verilog $f } }
link_design $::env(CMP_TOP)
read_sdc $::env(CMP_SDC)
set wns [sta::worst_slack_cmd max]
set tns [sta::total_negative_slack_cmd max]
set n 0; set area 0.0; set seq 0; set buf 0
foreach c [get_cells -hierarchical *] {
  set lc [get_lib_cells -of_objects $c -quiet]
  if {$lc eq ""} continue
  incr n
  set area [expr {$area + [get_property $lc area]}]
  set nm [get_name $lc]
  if {[regexp {^(DFF|SDF|DHL|DLL|ASYNC|ICG)} $nm]} { incr seq }
  if {[regexp {^(BUF|HB)} $nm]} { incr buf }
}
set fp [open $::env(CMP_OUT) w]
puts $fp "{\"wns_s\": $wns, \"tns_s\": $tns, \"cells\": $n, \"seq_cells\": $seq, \"buf_cells\": $buf, \"area_um2\": $area}"
close $fp
report_checks -path_delay max -fields {fanout} -digits 1
"""


def load_cores():
    """CORES from bench/defs.bzl (a Starlark dict literal; comments dropped by tokenizing)."""
    s = (ROOT / "bench/defs.bzl").read_text()
    i = s.index("CORES = {") + len("CORES = ")
    out, depth = [], 0
    for t in tokenize.generate_tokens(io.StringIO(s[i:]).readline):
        if t.type == tokenize.COMMENT:
            continue
        out.append(t)
        if t.type == tokenize.OP and t.string == "{":
            depth += 1
        elif t.type == tokenize.OP and t.string == "}":
            depth -= 1
            if depth == 0:
                break
    return eval(tokenize.untokenize(out), {"True": True, "False": False})  # trusted, checked-in source


def clock_period(sdc):
    text = Path(sdc).read_text()
    m = re.search(r"^\s*set\s+clk_period\s+([0-9.]+)", text, re.M) or re.search(r"-period\s+([0-9.]+)", text)
    if not m:
        raise SystemExit("no clock period in %s" % sdc)
    return float(m.group(1))


def timed(cmd, cwd, log, timeout, env=None):
    """Run cmd; return (rc, wall_s, peak_rss_mib). /usr/bin/time gives the child's peak RSS."""
    tfile = str(log) + ".time"
    full = ["/usr/bin/time", "-f", "%e %M", "-o", tfile] + cmd
    t0 = time.time()
    with open(log, "w") as f:
        try:
            rc = subprocess.run(full, cwd=cwd, stdout=f, stderr=subprocess.STDOUT, timeout=timeout, env=env).returncode
        except subprocess.TimeoutExpired:
            rc = "timeout"
    wall = time.time() - t0
    rss = None
    try:
        parts = Path(tfile).read_text().split()
        rss = round(int(parts[-1]) / 1024.0, 1)
    except Exception:
        pass
    return rc, round(wall, 2), rss


def yosys_script(core, lib, period, a):
    flags = core["v_flags"]  # yosys passes read_slang words through verbatim (quotes would be kept)
    dont = " ".join("-dont_use %s" % c for c in ORFS_DONT_USE)
    return "\n".join([
        'read_slang -F {fl} -DSYNTHESIS {flags} --top {top}',
        'hierarchy -check -top {top}',
        'synth -top {top} -flatten -noabc',
        'chformal -remove',
        'opt -purge',
        'extract_fa',
        'techmap -map {orfs}/cells_adders_R.v',
        'techmap',
        'opt -fast -purge',
        'techmap -map {orfs}/cells_latch_R.v',
        'dfflibmap -liberty {lib} {dont}',
        'opt',
        'setundef -zero',
        'abc -script {orfs}/abc_speed.script -liberty {lib} {dont} -constr {constr} -D {period}',
        'splitnets',
        'opt_clean -purge',
        'hilomap -singleton -hicell TIEHIx1_ASAP7_75t_R H -locell TIELOx1_ASAP7_75t_R L',
        'insbuf -buf BUFx2_ASAP7_75t_R A Y',
        'opt_clean -purge',
        'check -mapped',
        'stat -liberty {lib}',
        'write_verilog -noattr -noexpr -nohex -nodec {net}',
        '',
    ]).format(fl=core["filelist"], flags=flags, top=core["top"], orfs=a.orfs, lib=lib, dont=dont,
              constr=core["dir"] / "abc.constr", period=period, net=core["dir"] / "yosys.v")


def run_yosys(core, lib, period, a):
    d = core["dir"]
    (d / "abc.constr").write_text("set_driving_cell BUFx2_ASAP7_75t_R\nset_load %s\n" % ORFS_ABC_LOAD)
    (d / "yosys.ys").write_text(yosys_script(core, lib, period, a))
    env = dict(os.environ)
    env["TMPDIR"] = str(d)  # abc temp dirs stay off /tmp
    rc, wall, rss = timed([a.yosys, "-m", a.slang, "-q", "-l", str(d / "yosys.log"), str(d / "yosys.ys")],
                          core["vdir"], d / "yosys.out", a.timeout, env)
    return dict(rc=rc, wall_s=wall, peak_rss_mib=rss, netlist=[str(d / "yosys.v")] if rc == 0 else [])


def run_lhd(core, lib, sdc, a):
    d = core["dir"]
    vdir = d / "lhd_verilog"
    shutil.rmtree(d / "lhd_work", ignore_errors=True)
    shutil.rmtree(vdir, ignore_errors=True)
    cmd = [a.lhd, "synth", "--top", core["top"], "--workdir", str(d / "lhd_work"),
           "--emit-dir", "verilog:%s/" % vdir, "--result-json", str(d / "lhd.json"), "--stats",
           "--set", "synth.memory=flops", "--set", "synth.liberty=%s" % lib, "--set", "synth.sdc=%s" % sdc,
           # Comparison contract, like synth.memory=flops: Yosys maps a resetless register's power-on `initial`
           # value to a plain DFF and drops it (asap7 has no init pin). lhd's default keeps such a register as a
           # native flop (LEC-exact), which is not a Liberty cell, so the netlist could not be timed at all
           # (xs_renametable, xs_mini16: 5 `dff-init-kept-native` flops each).
           "--set", "synth.drop_init=true"]
    cmd += a.lhd_set_args
    cmd += ["--", "-F", core["filelist"], "-DSYNTHESIS"] + core["v_flags"].split()
    env = dict(os.environ)
    env["TMPDIR"] = str(d)
    rc, wall, rss = timed(cmd, core["vdir"], d / "lhd.log", a.timeout, env)
    nets = sorted(str(p) for p in vdir.glob("*.v")) if rc == 0 else []
    norm = {}
    if nets:
        nets, norm = normalize_lhd(core, nets, lib, a)
    diags = {}
    for line in (d / "lhd.log").read_text(errors="replace").splitlines():
        if line.startswith("{"):
            try:
                j = json.loads(line)
            except ValueError:
                continue
            if j.get("severity") in ("warning", "error"):
                key = "%s:%s" % (j["severity"], j.get("code", "?"))
                diags.setdefault(key, j.get("message", "")[:240])
    return dict(rc=rc, wall_s=wall, peak_rss_mib=rss, netlist=nets, diagnostics=diags, normalize=norm)


def normalize_lhd(core, nets, lib, a):
    """lhd's Verilog netlist spells constant wiring (bit selects, concats, constant shifts, OR with zero) as
    `always_comb` blocks, which OpenSTA's structural reader rejects. Rewrite it structurally with yosys WITHOUT any
    remapping: Liberty cells stay black boxes, `proc` + `opt_expr` fold that wiring into nets and `opt_clean`
    drops unread cells (as the Yosys side's own opt_clean does); no opt_merge, so duplicated cells stay. Any generic
    (non-Liberty) cell left over is real unmapped logic in lhd's netlist: then the netlist is not timed."""
    d = core["dir"]
    out = d / "lhd_flat.v"
    ys = "\n".join(["read_liberty -lib %s" % lib] + ["read_verilog -sv %s" % n for n in nets] + [
        "hierarchy -top %s" % core["top"], "proc", "flatten", "opt_expr -full", "opt_clean -purge",
        "tee -o %s stat" % (d / "lhd_flat.stat"), "select -assert-none t:$*",
        "write_verilog -noattr -noexpr -nohex -nodec %s" % out, ""])
    (d / "lhd_flat.ys").write_text(ys)
    rc, wall, _ = timed([a.yosys, "-q", "-l", str(d / "lhd_flat.log"), str(d / "lhd_flat.ys")], d,
                        d / "lhd_flat.out", a.timeout)
    info = dict(rc=rc, wall_s=wall)
    if rc != 0:
        generic = {}
        if (d / "lhd_flat.stat").exists():
            for line in (d / "lhd_flat.stat").read_text().splitlines():
                cell = re.search(r"(\$\w+)", line)
                num = re.search(r"\b(\d+)\b", line)
                if cell and num:
                    generic[cell.group(1)] = generic.get(cell.group(1), 0) + int(num.group(1))
        info["generic_cells"] = generic
        return [], info
    return [str(out)], info


def run_sta(core, side, nets, lib, sdc, a):
    d = core["dir"]
    out = d / ("sta_%s.json" % side)
    env = dict(os.environ, CMP_LEF=" ".join(a.lef), CMP_LIB=lib, CMP_TOP=core["top"], CMP_NET=" ".join(nets),
               CMP_SDC=str(sdc), CMP_OUT=str(out))
    rc, wall, _ = timed([a.openroad, "-no_init", "-exit", str(a.out / "sta.tcl")], d, d / ("sta_%s.log" % side),
                        a.timeout, env)
    if rc != 0 or not out.exists():
        return dict(rc=rc)
    r = json.loads(out.read_text())
    return dict(rc=0, wns_ps=round(min(r["wns_s"], 0.0) * 1e12, 2), slack_ps=round(r["wns_s"] * 1e12, 2),
                tns_ps=round(r["tns_s"] * 1e12, 1), cells=r["cells"], seq_cells=r["seq_cells"],
                buf_cells=r["buf_cells"], area_um2=round(r["area_um2"], 3), sta_s=wall)


LOCK = threading.Lock()


def write_summary(a, results):
    with LOCK:
        (a.out / "summary.json").write_text(json.dumps(results, indent=1, sort_keys=True))
        rows = ["| core | clk ps | side | slack ps | TNS ps | cells | seq | area um2 | synth s | peak MiB |",
                "|---|---:|---|---:|---:|---:|---:|---:|---:|---:|"]
        for name in [c for c in ORDER if c in results] + sorted(set(results) - set(ORDER)):
            r = results[name]
            for side in ("lhd", "yosys"):
                s, t = r.get(side, {}), r.get("sta_" + side, {})
                if t.get("rc") == 0:
                    rows.append("| %s | %g | %s | %.1f | %.0f | %d | %d | %.1f | %s | %s |" % (
                        name, r["period_ps"], side, t["slack_ps"], t["tns_ps"], t["cells"], t["seq_cells"],
                        t["area_um2"], s.get("wall_s"), s.get("peak_rss_mib")))
                else:
                    rows.append("| %s | %g | %s | FAIL (synth rc=%s, sta rc=%s) | | | | | %s | %s |" % (
                        name, r.get("period_ps", 0), side, s.get("rc"), t.get("rc"), s.get("wall_s"),
                        s.get("peak_rss_mib")))
        (a.out / "summary.md").write_text("\n".join(rows) + "\n")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--out", required=True, type=Path)
    p.add_argument("--lhd", required=True)
    p.add_argument("--yosys", required=True)
    p.add_argument("--slang", required=True, help="yosys-slang plugin (slang.so)")
    p.add_argument("--openroad", required=True)
    p.add_argument("--lef", action="append", required=True, help="asap7 tech LEF, then the cell LEF")
    p.add_argument("--orfs", required=True, help="dir with ORFS abc_speed.script, cells_adders_R.v, cells_latch_R.v")
    p.add_argument("--cores", default=",".join(ORDER))
    p.add_argument("--jobs", type=int, default=12, help="concurrent synthesis runs (each core runs 2)")
    p.add_argument("--timeout", type=int, default=6 * 3600)
    p.add_argument("--lhd-set", action="append", default=[], help="extra lhd --set k=v")
    p.add_argument("--force", action="store_true")
    p.add_argument("--lhd-only", action="store_true",
                   help="re-run only lhd (and its STA) on cores whose Yosys side already finished in --out")
    p.add_argument("--resta", action="store_true",
                   help="re-run only lhd netlist normalization and both STAs on finished cores (no synthesis)")
    a = p.parse_args()
    a.out = a.out.resolve()
    a.out.mkdir(parents=True, exist_ok=True)
    a.lhd_set_args = [x for kv in a.lhd_set for x in ("--set", kv)]
    (a.out / "sta.tcl").write_text(STA_TCL)

    lib = a.out / "tech/asap7-rvt-ff.lib"
    if not lib.exists():
        lib.parent.mkdir(parents=True, exist_ok=True)
        with gzip.open(ROOT / "tech/asap7/asap7-rvt-ff.lib.gz") as src, open(str(lib) + ".tmp", "wb") as dst:
            shutil.copyfileobj(src, dst)
        os.replace(str(lib) + ".tmp", lib)
    lib = str(lib)

    cores = load_cores()
    results = {}
    if (a.out / "summary.json").exists():
        results = json.loads((a.out / "summary.json").read_text())
    todo = []
    for name in a.cores.split(","):
        cfg = cores.get(name)
        if cfg is None:
            print("skip %s: not in CORES" % name)
            continue
        pkg = ROOT / cfg["pkg"].lstrip("/")
        fl = pkg / "verilog/filelist.f"
        if not fl.exists():
            print("skip %s: no %s" % (name, fl))
            continue
        d = a.out / name
        sdc = pkg / cfg["sdc"]
        core = dict(name=name, top=cfg["top"], v_flags=cfg.get("v_flags", ""), filelist=str(fl),
                    vdir=str(fl.parent), dir=d, sdc=sdc, period=clock_period(sdc))
        if (d / "result.json").exists() and a.lhd_only:
            prior = json.loads((d / "result.json").read_text())
            if prior.get("yosys", {}).get("rc") == 0 and prior.get("sta_yosys", {}).get("rc") == 0:
                core["prior"] = prior
                todo.append(core)
                continue
        if (d / "result.json").exists() and not a.force:
            r = json.loads((d / "result.json").read_text())
            if a.resta:
                if r["yosys"].get("rc") == 0:
                    r["sta_yosys"] = run_sta(core, "yosys", [str(d / "yosys.v")], lib, sdc, a)
                nets = sorted(str(p) for p in (d / "lhd_verilog").glob("*.v")) if r["lhd"].get("rc") == 0 else []
                if nets:
                    nets, r["lhd"]["normalize"] = normalize_lhd(core, nets, lib, a)
                r["sta_lhd"] = run_sta(core, "lhd", nets, lib, sdc, a) if nets else dict(rc=None)
                (d / "result.json").write_text(json.dumps(r, indent=1, sort_keys=True))
            results[name] = r
            continue
        d.mkdir(parents=True, exist_ok=True)
        todo.append(core)
    write_summary(a, results)

    def one(core):
        prior = core.pop("prior", None)
        if prior:  # --lhd-only: keep the finished Yosys side, re-run only lhd
            y, l = prior["yosys"], run_lhd(core, lib, core["sdc"], a)
        else:
            with concurrent.futures.ThreadPoolExecutor(2) as ex:
                fy = ex.submit(run_yosys, core, lib, core["period"], a)
                fl = ex.submit(run_lhd, core, lib, core["sdc"], a)
                y, l = fy.result(), fl.result()
        r = dict(core=core["name"], top=core["top"], period_ps=core["period"], sdc=str(core["sdc"]), yosys=y, lhd=l)
        for side, s in (("yosys", y), ("lhd", l)):
            if side == "yosys" and prior:
                r["sta_yosys"] = prior["sta_yosys"]
                continue
            r["sta_" + side] = run_sta(core, side, s["netlist"], lib, core["sdc"], a) if s["netlist"] else dict(rc=None)
        (core["dir"] / "result.json").write_text(json.dumps(r, indent=1, sort_keys=True))
        results[core["name"]] = r
        write_summary(a, results)
        ly, ll = r["sta_yosys"], r["sta_lhd"]
        print("%-15s lhd slack %s area %s | yosys slack %s area %s" % (
            core["name"], ll.get("slack_ps"), ll.get("area_um2"), ly.get("slack_ps"), ly.get("area_um2")), flush=True)

    with concurrent.futures.ThreadPoolExecutor(max(1, a.jobs // 2)) as ex:
        for f in concurrent.futures.as_completed([ex.submit(one, c) for c in todo]):
            f.result()


if __name__ == "__main__":
    main()
