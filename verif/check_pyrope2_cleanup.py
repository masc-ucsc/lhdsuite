#!/usr/bin/env python3
"""Check Verilog -> generated Pyrope -> cleaned Pyrope2 at the same external top.

Only unbounded top-level LEC is accepted. The same driver runs on all three
languages. Intermediate module names and interfaces are not acceptance gates.
Missing reference configurations and incomplete proofs keep the run red.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
ENTRIES = {
    "dino": ("PipelinedDualIssueCPU",),
    "matched_filter": ("matched_filter",),
    "picorv32": ("picorv32_top",),
    "rocket": ("MaxPeriodFibonacciLFSR",),
    "xiangshan/Backend": ("AgeDetector", "Arbiter16_LqPtr", "FreeList_3", "FreeList_5",
        "RenameBuffer", "RobEnqPtrWrapper", "RobEnqPtrWrapper_N32", "SnapshotGenerator",
        "SnapshotGenerator_1", "SnapshotGenerator_2", "SnapshotGenerator_3"),
}
PICO_CONFIGS = {
    "no_rvc": {"COMPRESSED_ISA": False},
    "no_counters": {"ENABLE_COUNTERS": False, "ENABLE_COUNTERS64": False},
    "counter32": {"ENABLE_COUNTERS64": False},
    "iterative_shift": {"BARREL_SHIFTER": False, "TWO_STAGE_SHIFT": False},
    "single_port": {"ENABLE_REGS_DUALPORT": False},
    "two_cycle": {"TWO_CYCLE_ALU": True, "TWO_CYCLE_COMPARE": True},
    "multiply": {"ENABLE_MUL": True},
    "fast_multiply": {"ENABLE_FAST_MUL": True},
    "divide": {"ENABLE_DIV": True},
    "rv32m": {"ENABLE_MUL": True, "ENABLE_DIV": True, "COMPRESSED_ISA": False},
    "rv32m_fast": {"ENABLE_FAST_MUL": True, "ENABLE_DIV": True, "COMPRESSED_ISA": False},
}


def filter_mapping(size, levels):
    rows = ["# RTL instance = Pyrope2 loop instance. LEC proves the paired next states."]
    for i in range(size):
        for reg in ("x_r", "ref_r"):
            rows.append(f"taps_{i}_t.{reg}=t__li{i}.{reg}")
    for level in range(levels):
        for node in range(size >> (level + 1)):
            rows.append(f"levels_{level}_nodes_{node}_n.s_r=node__li{size+level}__li{node}.s_r")
    return "\n".join(rows) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lhd", type=Path, default=ROOT.parent / "livehd/bazel-bin/lhd/lhd")
    parser.add_argument("--workdir", type=Path)
    parser.add_argument("--only", default="", help="substring of the relative entry path")
    parser.add_argument("--skip", default="", help="comma-separated entries checked in a separate run")
    parser.add_argument("--configurations", action="store_true")
    parser.add_argument("--simulations", action="store_true")
    parser.add_argument("--precompiled", action="store_true", help="also prove complete precompiled DINO, filter, and PicoRV32 bundles")
    parser.add_argument("--timeout", type=int, default=360)
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    work = (args.workdir or Path(tempfile.mkdtemp(prefix="pyrope2-compatible-"))).resolve()
    work.mkdir(parents=True, exist_ok=True)
    lhd = args.lhd.resolve(strict=True)
    report = {"reference": "matching Verilog configuration", "lhd": str(lhd),
              "binary_sha256": hashlib.sha256(lhd.read_bytes()).hexdigest(),
              "checks": [], "source_sha256": {}}

    def save():
        (work / "results.json").write_text(json.dumps(report, indent=2) + "\n")

    def run(name, argv, proof=False, shared=None, trailing=()):
        path = work / name
        path.parent.mkdir(parents=True, exist_ok=True)
        result = path.with_suffix(".json")
        command = [str(lhd), *map(str, argv), "--workdir", str(shared or path),
                   "--result-json", str(result), *map(str, trailing)]
        start = time.monotonic()
        with path.with_suffix(".log").open("w") as log:
            process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            try:
                rc = process.wait(timeout=args.timeout)
            except subprocess.TimeoutExpired:
                # LEC can fork solver workers. Reap the entire owned group.
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait()
                rc = 124
        payload = json.loads(result.read_text()) if result.exists() else {}
        lec = payload.get("lec", {})
        ok = rc == 0 and (not proof or (lec.get("verdict") == "proven" and lec.get("bounded") is False))
        row = {"name": name, "command": command, "exit_code": rc, "ok": ok,
               "seconds": round(time.monotonic() - start, 3), "lec": lec,
               "error": payload.get("error"), "log": str(path.with_suffix('.log'))}
        report["checks"].append(row)
        save()
        print(f"{'PASS' if ok else 'FAIL'} {name}: {lec or rc}", flush=True)
        return ok

    def simulate(label, sources, tb, sim_args=(), checksum=False):
        ok = run(label, ["sim", *sources, tb, *sim_args])
        if checksum and ok:
            # lhd JSON output does not forward puts. Check the generated driver,
            # just as bench/sim.sh does; it remains a LiveHD simulation.
            cmd = [str(work / label / "sim/drv.bin"), "--cycles", "5000000"]
            r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=args.timeout)
            (work / label).with_suffix(".stdout").write_text(r.stdout + r.stderr)
            report["checks"][-1].update(driver_command=cmd,
                ok=r.returncode == 0 and "sum=6209346479474330016" in r.stdout)
            save()

    def interface(label, library, top):
        destination = work / label / "interface"
        if not run(label + "/interface_emit", ["compile", library, "--top", top,
                "--emit-dir", "sim:" + str(destination)]):
            return None
        candidates = [p for p in destination.glob("*.iface.json")
                      if p.name.removesuffix(".iface.json").split(".")[-1] == top]
        if len(candidates) != 1:
            report["checks"].append({"name": label + "/interface", "ok": False,
                "error": "Cannot identify the emitted top interface"})
            save()
            return None
        ports = json.loads(candidates[0].read_text())["io"]
        return sorted((p["name"], p["dir"], p["declared_bits"], p["signed"], p.get("clock", False)) for p in ports)

    def check(core, entry, config=None, label=None):
        top = "MaxPeriodFibonacciLFSR" if entry.endswith("LFSR2") else "RobEnqPtrWrapper" if entry.endswith("_N32") else entry
        label = label or (core + "/" + entry).replace("/", "_")
        base = ROOT / core
        impl = base / "pyrope2" / (entry + ".prp")
        checked = base / "pyrope" / (top + ".prp")
        target = work / label
        target.mkdir(exist_ok=True)
        vfiles = [base / "verilog" / (top + ".sv")]
        # Rocket contributes one vendored LFSR leaf, not the entire stale
        # Rocket-system filelist. Its matching top RTL is self-contained.
        if core not in ("xiangshan/Backend", "rocket") and (base / "verilog/filelist.f").exists():
            vfiles = [base / "verilog" / line.strip() for line in
                      (base / "verilog/filelist.f").read_text().splitlines()
                      if line.strip() and not line.lstrip().startswith(("//", "#"))]
        if top == "RenameBuffer":
            vfiles.append(base / "verilog/SnapshotGenerator.sv")
        if entry.endswith("_N32") or any(not p.exists() for p in vfiles):
            report["checks"].append({"name": label + "/reference", "ok": False,
                "error": "Matching elaborated Verilog is missing; an old Pyrope2 baseline is not an external reference."})
            save()
            print(f"MISSING {label}: matching Verilog", flush=True)
            return
        if config:
            src = target / "configuration"
            shutil.copytree(base / "pyrope2", src / "pyrope2", dirs_exist_ok=True)
            shutil.copytree(base / "verilog", src / "verilog", dirs_exist_ok=True)
            impl = src / "pyrope2" / (entry + ".prp")
            vfiles = [src / "verilog" / p.name for p in vfiles]
            if core == "picorv32":
                bindings = ", ".join(f"{key}={str(val).lower()}" for key, val in config.items())
                impl.write_text(impl.read_text().replace("cpu = picorv32(", f"cpu = picorv32<{bindings}>("))
                wrapper = src / "verilog/picorv32_top.v"
                settings = {"COMPRESSED_ISA": 1, "BARREL_SHIFTER": 1, "ENABLE_MUL": 0, "ENABLE_DIV": 0, "ENABLE_IRQ": 0, **config}
                params = ",\n".join(f"        .{key}({int(val)})" for key, val in settings.items())
                wrapper.write_text(re.sub(r"picorv32 #\(.*?\) cpu \(", "picorv32 #(\n" + params + "\n    ) cpu (", wrapper.read_text(), flags=re.S))
            else:
                for key, val in config.items():
                    impl.write_text(re.sub(rf"(comptime const {key}\s*=\s*)\d+", rf"\g<1>{val}", impl.read_text()))
                    rtl = src / "verilog/matched_filter.sv"
                    rtl.write_text(re.sub(rf"(parameter integer {key}\s*=\s*)\d+", rf"\g<1>{val}", rtl.read_text()))
        generated = target / "generated"
        library = target / "rtl_lg"
        for p in [impl, *vfiles]:
            report["source_sha256"][str(p)] = hashlib.sha256(p.read_bytes()).hexdigest()
        if not run(label + "/generate", ["compile", *vfiles, "--top", top,
                "--emit-dir", "pyrope:" + str(generated), "--emit-dir", "lg:" + str(library)],
                trailing=["--", "-DSYNTHESIS"]):
            return
        ref = "lg:" + str(library)
        reference_interface = interface(label + "/verilog", ref, top)
        sides = [("generated", generated / (top + ".prp")), ("pyrope2", impl)]
        if not config:
            sides.insert(1, ("pyrope", checked))
        mapping = None
        if core == "picorv32":
            mapping = ROOT / "verif/pyrope2/picorv32.match"
        elif core == "matched_filter":
            size, levels = (config.get("SIZE", 64), config.get("LOG2_SIZE", 6)) if config else (64, 6)
            mapping = target / "state.match"
            mapping.write_text(filter_mapping(size, levels))
        for side, source in sides:
            cache = target / (side + "_cache")
            run(label + "/" + side + "_compile", ["compile", source, "--top", top,
                "--emit-dir", "lg:" + str(target / (side + "_lg"))], shared=cache)
            run(label + "/" + side + "_incremental", ["compile", source, "--top", top], shared=cache)
            signature = interface(label + "/" + side, "lg:" + str(target / (side + "_lg")), top)
            report["checks"].append({"name": label + "/" + side + "_interface",
                "ok": signature is not None and signature == reference_interface,
                "reference_ports": reference_interface, "ports": signature})
            save()
            opts = ["--set", "formal.lec.hier=false"]
            if side == "pyrope2" and mapping:
                opts += ["--set", "formal.lec.match=@" + str(mapping)]
            # RenameBuffer's child premise is discharged; only the top verdict
            # is required. Other cases use a single flat top-level miter.
            if top == "RenameBuffer":
                opts = ["--set", "formal.engine=ind"]
            for attempt in range(2 if side == "pyrope2" else 1):
                run(label + f"/{side}_lec{attempt+1}", ["lec", "--impl", source,
                    "--ref", ref, "--top", top, *opts], proof=True)
            if args.precompiled and side == "pyrope2" and core in ("dino", "matched_filter", "picorv32"):
                # Generic templates and file-scope exports must travel with the
                # concrete top. A top-filtered export is an incomplete bundle.
                bundle = "ln:" + str(target / "pyrope2_ln")
                if run(label + "/ln_export", ["compile", *sorted(source.parent.glob("*.prp")),
                        "--emit-dir", bundle]):
                    run(label + "/ln_reload", ["compile", bundle, "--top", top])
                    run(label + "/ln_lec", ["lec", "--impl", bundle, "--ref", ref,
                        "--top", top, *opts], proof=True)
        if args.simulations and (not config or label in ("pico_rv32m", "pico_rv32m_fast")):
            tb = None
            sim_args = []
            if core in ("dino", "picorv32"):
                tb = base / "sim" / (core + "_prog_tb.prp")
                sim_args = ["--arg", "cycles=2000"]
                if config:
                    tb = ROOT / "verif/pyrope2/picorv32_m_tb.prp"
            elif core == "matched_filter":
                tb = base / "sim/matched_filter_tb.prp"
                sim_args = ["--arg", "cycles=5000000"]
            elif core == "rocket":
                tb = ROOT / "verif/pyrope2/lfsr_tb.prp"
            elif top.startswith("SnapshotGenerator"):
                tb = ROOT / "verif/pyrope2" / (top + "_tb.prp")
            elif top == "RobEnqPtrWrapper":
                tb = ROOT / "verif/pyrope2/RobEnqPtrWrapper_tb.prp"
            if tb and tb.exists():
                # Exactly the same file, arguments and top for each side.
                for side, source in [("verilog", ref), *[(side, "lg:" + str(target / (side + "_lg"))) for side, _ in sides]]:
                    simulate(label + "/sim_" + side, [source], tb, sim_args, core == "matched_filter")

    print(f"Artifacts: {work}", flush=True)
    skipped = set(args.skip.split(","))

    def selected(core, entry):
        return entry not in skipped and args.only in core + "/pyrope2/" + entry

    for core, entries in ENTRIES.items():
        for entry in entries:
            if selected(core, entry):
                check(core, entry)
    if args.configurations:
        if selected("picorv32", "picorv32_top"):
            for name, config in PICO_CONFIGS.items():
                check("picorv32", "picorv32_top", config, "pico_" + name)
        if selected("matched_filter", "matched_filter"):
            for size, levels, width in ((2, 1, 1), (8, 3, 4), (8, 3, 8), (8, 3, 16)):
                check("matched_filter", "matched_filter", {"SIZE": size, "LOG2_SIZE": levels, "MULT_WIDTH": width}, f"filter_{size}_{width}")
    # Include all checked-in implementation dependencies in the evidence.
    for core in ENTRIES:
        for tree in ("pyrope", "pyrope2"):
            for p in (ROOT / core / tree).glob("*.prp"):
                report["source_sha256"][str(p.relative_to(ROOT))] = hashlib.sha256(p.read_bytes()).hexdigest()
    save()
    failed = sum(not row["ok"] for row in report["checks"])
    print(f"{len(report['checks'])-failed}/{len(report['checks'])} passed; {work / 'results.json'}")
    raise SystemExit(bool(failed))


if __name__ == "__main__":
    main()
