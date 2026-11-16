"""Stage the three vendored RTL cones for simulation and emit mesh link wiring."""
from pathlib import Path
import re

from topology import COLS, GEMMINI, GEMMINIS, HOST, TILES, links

HERE = Path(__file__).absolute().parent.parent
# Preserve quoted strings, escaped names and comments in the original generated RTL.
LEX = re.compile(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|\\\S+|[a-zA-Z_$][a-zA-Z0-9_$]*')


def write(path, content):
    if not path.exists() or path.read_text() != content:
        path.write_text(content)


def stage(out, cores=True):
    out = Path(out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    n = len(TILES)
    mask = sum(1 << i for i, name in enumerate(TILES) if name.startswith("BOOM"))
    write(out/"layout.sv", f"package mixed_layout; localparam int COLS={COLS}, N={n}, HOST={HOST}, ACC={GEMMINI}, ACC_COUNT={len(GEMMINIS)}; "
          f"localparam logic [N-1:0] BOOMS={n}'h{mask:x}; endpackage\n")
    edges = {}
    for a, ap, b, bp in links():
        edges[a, ap], edges[b, bp] = (b, bp), (a, ap)
    wiring = []
    for i in range(n):
        for p in range(4):
            valid, data = "1'b0", "'0"
            if (i, p) in edges:
                j, q = edges[i, p]
                valid, data = f"send[{j}][{q}]", f"rx[{j}]"
            wiring.append(f"assign arrived[{i}][{p}]={valid}; assign neighbors[{i}][{p}]={data};")
    write(out/"wiring.svh", "\n".join(wiring)+"\n")
    rtl = HERE/"rtl"
    files = [rtl/"packet.sv", out/"layout.sv", rtl/"router.sv", rtl/"mesh.sv"]
    if cores:
        libraries = []
        for family in ("rocket", "boom", "gemmini/Mesh16"):
            lib = HERE.parent / family / "verilog"
            sources = [lib/f.strip() for f in (lib/"filelist.f").read_text().splitlines() if f.strip() and not f.startswith("#")]
            src = "\n".join(f.read_text() for f in sources)
            names = set(re.findall(r"^\s*module\s+(\w+)", src, re.M))
            libraries.append((family.split("/")[0], src, names))
        for family, src, names in libraries:
            # Chisel emits unrelated modules with the same names in Rocket and
            # BOOM. Qualify those names throughout each family, without editing the vendor RTL.
            others = set().union(*(ns for f, _, ns in libraries if f != family))
            renames = {k: family+"__"+k for k in names & others}
            if renames:
                src = LEX.sub(lambda m: renames.get(m[0], m[0]), src)
            path = out/(family+".sv")
            write(path, src)
            files.append(path)
        files.extend(rtl/name for name in ("cpu.sv", "acc.sv", "soc.sv", "MixedSocTop.sv"))
    # Exported RTL is standalone: no runfile, source checkout or Python is needed to compile it.
    for i, path in enumerate(files):
        if path.parent != out:
            write(out/path.name, path.read_text())
            files[i] = out/path.name
    write(out/"files.f", "\n".join(f.name for f in files)+"\n")
    return files


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("out", type=Path)
    stage(parser.parse_args().out)
