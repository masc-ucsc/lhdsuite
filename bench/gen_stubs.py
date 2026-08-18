#!/usr/bin/env python3
"""Generate synthesis-only Pyrope models for XiangShan DPI observers."""

from pathlib import Path
import re
import sys


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit(f"usage: {sys.argv[0]} WRAPPER_DIR OUTPUT_DIR")

    wrapper_dir = Path(sys.argv[1])
    output_dir = Path(sys.argv[2])
    output_dir.mkdir(parents=True, exist_ok=True)

    for wrapper in sorted(wrapper_dir.glob("DummyDPICWrapper_*.prp")):
        text = wrapper.read_text()
        cell_match = re.search(r'^const (DiffExt\w+) = import\(', text, re.MULTILINE)
        width_matches = re.findall(r'#\[0\.\.=([0-9]+)\]', text)
        if cell_match is None or not width_matches:
            raise ValueError(f"cannot derive DPI cell interface from {wrapper}")

        cell = cell_match.group(1)
        width = int(width_matches[-1]) + 1
        (output_dir / f"{cell}.prp").write_text(
            "// Generated synthesis model for an outputless DPI observation cell.\n"
            f"pub mod {cell}::[timecheck=false](clock:u1, enable:u1, io:u{width}) -> () {{\n"
            "}\n"
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
