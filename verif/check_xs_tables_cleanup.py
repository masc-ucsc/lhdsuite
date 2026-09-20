#!/usr/bin/env python3
"""Stage and compare XiangShan rename/busy tables and RenameTableWrapper with LiveHD.

By default, check every external output in differential simulation. --lec also
attempts unbounded equivalence against matching checked-in RTL. Inconclusive
proofs return nonzero. Sources, logs, and JSON remain in a fresh temporary dir.
"""

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NAMES = ["RenameTable", "RenameTable_1", "RenameTable_2", "BusyTable", "BusyTable_1"]


def split(s):
    out = []
    depth = 0
    start = 0
    for i, c in enumerate(s):
        if c in "([":
            depth += 1
        if c in ")]":
            depth -= 1
        if c == "," and depth == 0:
            out.append(s[start:i].strip())
            start = i + 1
    out.append(s[start:].strip())
    return [x for x in out if x]


def flatten(fields, prefix=""):
    out = []
    for item in split(fields):
        name, typ = item.split(":", 1)
        name = prefix + name.strip()
        typ = typ.strip()
        if typ.startswith("("):
            out.extend(flatten(typ[1 : typ.rfind(")")], name + "."))
        else:
            out.append((name, int(re.match(r"u(\d+)", typ)[1])))
    return out


def wrapper_stimulus(field, bits, dst, off):
    """Drive commit/rename interactions, all 520 diff lanes, and snapshots."""
    def lanes(count, width, payload):
        return (f"  for lane in 0..<{count} {{\n"
                f"    bus#[({off} + (lane * {width}))..+{width}] = {payload}\n  }}\n")

    if field in ("io_rabCommits.info", "io_diffCommits.info"):
        # Duplicated destinations exercise last-lane priority and old-pdest
        # forwarding. Enables vary independently for all four register files.
        return lanes(bits // 20, 20,
            "(((cycle + (lane & 3)) & 31) << 14) | "
            "((((cycle * 13) + lane) & 255) << 6) | (((cycle + lane) & 15) << 2)")
    if field == "io_diffCommits.commitValid":
        return lanes(520, 1, "unsigned(((cycle + lane) & 3) != 0)")
    if field in ("io_intRenamePorts", "io_fpRenamePorts", "io_vecRenamePorts"):
        width = bits // 8
        return lanes(8, width,
            f"(unsigned(((cycle + lane) & 3) == 1) << {width - 1}) | "
            "(((cycle + (lane & 3)) & 31) << 8) | (((cycle * 7) + lane) & 255)")
    if field.endswith(".pdestVl"):
        return lanes(8, 5, "(cycle + lane) & 31")
    if field.endswith("_hold"):
        lane = int(re.search(r"_(\d+)_", field)[1])
        expr = f"cycle#[{lane % 7}]"
    elif field.endswith("_addr"):
        lane = int(re.search(r"_(\d+)_", field)[1])
        expr = f"(cycle + {lane}) & 31"
    elif "RenamePorts_" in field:
        lane = int(re.search(r"Ports_(\d+)_", field)[1])
        expr = (f"unsigned(((cycle + {lane}) & 3) == 1)" if field.endswith("_wen")
                else f"((cycle * 7) + {lane}) & 255")
    elif field.endswith(".isCommit"):
        expr = "cycle#[0]"
    elif field.endswith(".isWalk"):
        expr = "cycle#[1]"
    elif field.endswith(".commitValid"):
        expr = "(cycle * 29) & 255"
    elif field.endswith(".walkValid"):
        expr = "(cycle * 19) & 255"
    else:
        expr = {
            "io_hartId": "cycle#[0..=7]",
            "io_redirect": "unsigned(phase == 128 or phase == 192)",
            "io_snpt.snptEnq": "unsigned(phase >= 65 and phase < 69)",
            "io_snpt.snptDeq": "unsigned(phase == 224)",
            "io_snpt.useSnpt": "cycle#[6]",
            "io_snpt.snptSelect": "cycle#[8..=9]",
            "io_snpt.flushVec": "if phase == 240 { 15 } else { 0 }",
        }[field]
    return f"  {dst} = {expr}\n"


def stage(name, work):
    W = work
    d = W / name / "sim_sources"
    d.mkdir(parents=True, exist_ok=True)
    original = ROOT / "xiangshan/Backend/pyrope"
    clean = ROOT / "xiangshan/Backend/pyrope2"
    source = (original / (name + ".prp")).read_text()
    sig = next(l for l in source.splitlines() if l.startswith("pub mod"))
    args = sig[sig.index("](") + 2 : sig.index(") ->")]
    outputs = sig[sig.index(") -> (") + 6 : sig.rfind(") {")]
    ins = flatten(args)
    outs = flatten(outputs)
    (d / ("old_" + name + ".prp")).write_text(source)
    shutil.copy(clean / (name + ".prp"), d / ("new_" + name + ".prp"))
    pending = [name]
    copied = {name}
    while pending:
        s = (original / (pending.pop() + ".prp")).read_text()
        for dep in re.findall(r'import\("([^".]+)\.', s):
            if dep not in copied:
                copied.add(dep)
                pending.append(dep)
                shutil.copy(original / (dep + ".prp"), d / (dep + ".prp"))
    for helper in ["rename_table.prp", "busy_table.prp", "snapshot_queue.prp"]:
        shutil.copy(clean / helper, d / helper)
    fields = [(n, b) for n, b in ins if n not in ("clock", "reset")]
    total = sum(b for n, b in fields)
    s = f'// Differential test: all externally visible bits, including invalid data.\nconst old = import("old_{name}.{name}")\nconst new = import("new_{name}.{name}")\n\npub comb stimulus(cycle:u32) -> (bus:u{total}) {{\n  bus = 0\n  const phase:u8 = cycle#[0..=7]\n'
    off = 0
    locations = []
    for field, bits in fields:
        locations.append((field, bits, off))
        dst = f"bus#[{off}..+{bits}]"
        off += bits
        if name == "RenameTableWrapper":
            s += wrapper_stimulus(field, bits, dst, off - bits)
        elif name.startswith("Rename"):
            if field in ["io_specWritePorts", "io_archWritePorts", "io_diffWritePorts"]:
                addr = 5 if name == "RenameTable" else 6
                wb = addr + 9
                ports = bits // wb
                s += f"  for lane in 0..<{ports} {{\n    const address = (cycle + (lane & 3))#[0..<{addr}]\n    const data = ((cycle * 13) + lane)#[0..=7]\n    const valid = unsigned(((cycle + lane) & 3) != 0)\n    bus#[({off - bits} + (lane * {wb}))..+{wb}] = (valid << {wb - 1}) | (address << 8) | data\n  }}\n"
            elif field.endswith("_hold"):
                lane = int(re.search(r"_(\d+)_", field)[1])
                s += f"  {dst} = (cycle >> {lane % 7}) & 1\n"
            elif field.endswith("_addr"):
                lane = int(re.search(r"_(\d+)_", field)[1])
                s += f"  {dst} = (cycle + {lane})#[0..<{bits}]\n"
            else:
                expr = {
                    "io_redirect": "unsigned(phase == 128 or phase == 192)",
                    "io_snpt.snptEnq": "unsigned(phase >= 65 and phase < 69)",
                    "io_snpt.snptDeq": "unsigned(phase == 224)",
                    "io_snpt.useSnpt": "cycle#[6]",
                    "io_snpt.snptSelect": "cycle#[8..=9]",
                    "io_snpt.flushVec": "if phase == 240 { 15 } else { 0 }",
                }[field]
                s += f"  {dst} = {expr}\n"
        else:
            if field in ["io_allocPregs", "io_wbPregs"]:
                shift = 0 if field == "io_allocPregs" else 3
                s += f"  for lane in 0..<{bits // 9} {{\n    const address = ((cycle >> {shift}) + lane)#[0..=7]\n    const valid = unsigned(((cycle + lane) & 3) != 0)\n    bus#[({off - bits} + (lane * 9))..+9] = (valid << 8) | address\n  }}\n"
            elif field.startswith("io_read_"):
                lane = int(re.search(r"_(\d+)_", field)[1])
                s += f"  {dst} = (cycle + {lane})#[0..=7]\n"
            elif field == "io_ldCancel":
                s += f"  {dst} = (cycle >> 2)#[0..=5]\n"
            elif field == "io_og0Cancel":
                s += f"  {dst} = (cycle * 0x45d9f3)#[0..=23]\n"
            elif ".valid" in field:
                s += f"  {dst} = unsigned((cycle & 3) != 0)\n"
            elif field.endswith("Wen"):
                bit = 2 if field.endswith("rfWen") else 3
                s += f"  {dst} = cycle#[{bit}]\n"
            elif field.endswith(".pdest"):
                lane = int(re.search(r"\._(\d+)", field)[1])
                s += f"  {dst} = (cycle + {lane & 3})#[0..=7]\n"
            elif field.endswith(".loadDependency"):
                s += f"  {dst} = (cycle >> 3)#[0..=5]\n"
            elif field.endswith(".is0Lat"):
                s += f"  {dst} = cycle#[1]\n"
    s += "}\n\ntest old.compare(cycles:u20=1024) {\n  mut before = old\n  mut after = new\n  mut inputs = stimulus\n  tick cycles clocks=(clock=1) {\n    inputs.cycle = clock\n"

    def port(n):
        parts = n.split(".")
        return parts[0] + ("." + "_".join(parts[1:]) if len(parts) > 1 else "")

    for inst in ["before", "after"]:
        s += f"    {inst}.reset = clock < 2 or (clock & 255) == 250\n"
        for field, bits, off in locations:
            s += f"    {inst}.{port(field)} = inputs.bus#[{off}..={off + bits - 1}]\n"
    s += "    step\n    if clock >= 2 {\n"
    for field, bits in outs:
        s += f'      assert(before.{port(field)} == after.{port(field)}, "{field} differs at cycle {{clock}}")\n'
    s += (
        '    }\n  }\n  puts("'
        + name
        + ' differential simulation passed {cycles} cycles")\n}\n'
    )
    (d / "compare.prp").write_text(s)
    if name == "RenameTableWrapper":
        # Separate runs avoid the current LiveHD crash when both full wrapper
        # hierarchies are lowered together. Compare exact output bits each cycle.
        stimulus = s[s.index("pub comb stimulus"):s.index("\n\ntest old.compare")]
        trace = ('const dut = import("lg:RenameTableWrapper")\n\n' + stimulus
                 + f"\n\ntest dut.trace(cycles:u20=1024) {{\n  mut acc = dut\n"
                 + "  mut inputs = stimulus\n"
                 + "".join(f"  mut observed{i}:u{bits} = 0\n" for i, (_, bits) in enumerate(outs))
                 + "  tick cycles clocks=(clock=1) {\n    inputs.cycle = clock\n"
                 + "    acc.reset = (clock < 2) or ((clock & 255) == 250)\n")
        for field, bits, off in locations:
            trace += f"    acc.{port(field)} = inputs.bus#[{off}..={off + bits - 1}]\n"
        trace += "    step\n"
        for i, (field, _) in enumerate(outs):
            trace += f"    observed{i} = acc.{port(field)}\n"
        values = " ".join(f"{{observed{i}}}" for i in range(len(outs)))
        trace += '    if clock >= 2 { puts("TRACE {clock} ' + values + '") }\n  }\n}\n'
        (d / "trace.prp").write_text(trace)
    return d


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--lhd", type=Path, default=ROOT.parent / "livehd/bazel-bin/lhd/lhd"
    )
    ap.add_argument(
        "--module", choices=NAMES + ["RenameTableWrapper"], action="append", help="default: all five"
    )
    ap.add_argument("--cycles", type=int, default=1024)
    ap.add_argument("--timeout", type=float, default=240, help="seconds per invocation")
    ap.add_argument(
        "--memory-gib", type=float, default=16, help="process-tree RSS limit"
    )
    ap.add_argument("--lec", action="store_true")
    ap.add_argument(
        "--bundle",
        action="store_true",
        help="also check direct/incremental/precompiled paths",
    )
    args = ap.parse_args()
    if args.cycles <= 256:
        ap.error("--cycles must include useful work and a later one-cycle reset")
    work = Path(tempfile.mkdtemp(prefix="xs-table-cleanup-"))
    print(f"Artifacts: {work}", flush=True)
    checks = []

    def run(name, flags, proof=False):
        folder = work / name
        folder.mkdir(parents=True, exist_ok=True)
        command = [str(args.lhd.resolve()), *map(str, flags)]
        end = command.index("--") if "--" in command else len(command)
        command[end:end] = [
            "--workdir",
            str(folder / "work"),
            "--result-json",
            str(folder / "result.json"),
        ]
        print("CMD " + " ".join(command), flush=True)
        stopped = None
        peak = 0
        start = time.monotonic()
        with (folder / "log").open("w") as log:
            proc = subprocess.Popen(
                command,
                cwd=ROOT,
                stdout=log,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            try:
                while proc.poll() is None:
                    rows = [
                        list(map(int, line.split()))
                        for line in subprocess.check_output(
                            ["ps", "-axo", "pid=,ppid=,rss="], text=True
                        ).splitlines()
                    ]
                    owned = {proc.pid}
                    while True:
                        prior = len(owned)
                        owned.update(
                            pid for pid, parent, rss in rows if parent in owned
                        )
                        if len(owned) == prior:
                            break
                    peak = max(
                        peak,
                        sum(rss for pid, parent, rss in rows if pid in owned) * 1024,
                    )
                    if (
                        time.monotonic() - start > args.timeout
                        or peak > args.memory_gib * 1024**3
                    ):
                        stopped = (
                            "timeout"
                            if time.monotonic() - start > args.timeout
                            else "memory_limit"
                        )
                        break
                    time.sleep(0.5)
            finally:
                if proc.poll() is None:
                    os.killpg(proc.pid, signal.SIGTERM)
                    try:
                        proc.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        os.killpg(proc.pid, signal.SIGKILL)
                        proc.wait()
        path = folder / "result.json"
        result = json.loads(path.read_text()) if path.exists() else {}
        ok = stopped is None and proc.returncode == 0
        if proof:
            ok = (
                ok
                and result.get("lec", {}).get("verdict") == "proven"
                and result["lec"].get("bounded") is False
            )
        checks.append(
            {
                "name": name,
                "command": command,
                "seconds": time.monotonic() - start,
                "stopped": stopped,
                "peak_rss_bytes": peak,
                "exit_code": proc.returncode,
                "ok": ok,
                "result": result,
            }
        )
        (work / "checks.json").write_text(json.dumps(checks, indent=2) + "\n")
        print(f"{name}: {'PASS' if ok else 'INCOMPLETE OR FAILED'}", flush=True)
        return ok

    ok = True
    for name in args.module or NAMES:
        sources = stage(name, work)
        if name == "RenameTableWrapper":
            traces = []
            simulated = True
            for side in ("pyrope", "pyrope2"):
                passed = run(name + "/sim_" + side, [
                    "sim", ROOT / "xiangshan/Backend" / side / (name + ".prp"),
                    sources / "trace.prp", "--arg", f"cycles={args.cycles}",
                    "--set", "sim.unknown_zero=true", "--set", "sim.init_zero=true",
                     "--diag-fmt", "pretty",
                ])
                simulated = simulated and passed
                log = (work / name / ("sim_" + side) / "log").read_text()
                traces.append([line.split(":puts:", 1)[1] for line in log.splitlines() if ":puts:TRACE " in line])
            equal = simulated and len(traces[0]) == args.cycles - 2 and traces[0] == traces[1]
            checks.append({"name": name + "/trace_compare", "ok": equal,
                           "cycles": [len(t) for t in traces]})
            (work / "checks.json").write_text(json.dumps(checks, indent=2) + "\n")
            print(f"{name}/trace_compare: {'PASS' if equal else 'FAILED'}", flush=True)
            ok = equal and ok
        else:
            ok = (
                run(
                    name + "/sim",
                    [
                        "sim",
                        sources / "compare.prp",
                        "--arg",
                        f"cycles={args.cycles}",
                        "--set",
                        "sim.unknown_zero=true",
                        "--set",
                        "sim.init_zero=true",

                    ],
                )
                and ok
            )
        source = ROOT / "xiangshan/Backend/pyrope2" / (name + ".prp")
        if args.bundle:
            direct = "lg:" + str(work / name / "direct_lg")
            bundle = "ln:" + str(work / name / "ln")
            loaded = "lg:" + str(work / name / "loaded_lg")
            flags = ["compile", "pyrope", source, "--top", name, "--emit-dir", direct]
            compiled = run(name + "/direct", flags)
            compiled = run(name + "/direct", flags) and compiled
            dependencies = [
                source,
                source.parent
                / (
                    "rename_table.prp"
                    if name.startswith("Rename")
                    else "busy_table.prp"
                ),
            ]
            if name.startswith("Rename"):
                dependencies.append(source.parent / "snapshot_queue.prp")
            exported = run(
                name + "/export",
                ["compile", "pyrope", *dependencies, "--emit-dir", bundle],
            )
            loaded_ok = exported and run(
                name + "/reload",
                ["compile", bundle, "--top", name, "--emit-dir", loaded],
            )
            ok = compiled and loaded_ok and ok
            if compiled and loaded_ok:
                ok = (
                    run(
                        name + "/bundle_lec",
                        [
                            "lec",
                            "--ref",
                            direct,
                            "--impl",
                            loaded,
                            "--top",
                            name,
                            "--set",
                            "formal.engine=ind",
                        ],
                        proof=True,
                    )
                    and ok
                )
        if args.lec:
            original = ROOT / "xiangshan/Backend/pyrope"
            pending, seen = [name], {name}
            while pending:
                for dep in re.findall(
                    r'import\("([^".]+)\.',
                    (original / (pending.pop() + ".prp")).read_text(),
                ):
                    if dep not in seen:
                        seen.add(dep)
                        pending.append(dep)
            rtl = ROOT / "xiangshan/Backend/verilog"
            ref = "lg:" + str(work / name / "rtl_lg")
            compiled = run(
                name + "/rtl",
                [
                    "compile",
                    "verilog",
                    *[rtl / (n + ".sv") for n in sorted(seen)],
                    "--top",
                    name,
                    "--emit-dir",
                    ref,
                    "--",
                    "-DSYNTHESIS",
                ],
            )
            if compiled:
                ok = (
                    run(
                        name + "/lec",
                        [
                            "lec",
                            "--ref",
                            ref,
                            "--impl",
                            source,
                            "--top",
                            name,
                            "--set",
                            "formal.engine=ind",
                        ],
                        proof=True,
                    )
                    and ok
                )
            else:
                ok = False
    raise SystemExit(0 if ok else 1)


if __name__ == "__main__":
    main()
