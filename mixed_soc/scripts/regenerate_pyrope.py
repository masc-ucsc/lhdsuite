#!/usr/bin/env python3
"""Manually regenerate only mixed_soc glue; import the existing design trees."""
import argparse
from pathlib import Path
import subprocess

from generate_rtl import HERE, stage
from gen_mesh import generate


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lhd', type=Path, required=True)
    parser.add_argument('--work', type=Path, required=True)
    args = parser.parse_args()
    work = args.work.resolve()
    rtl, emitted = work/'rtl', work/'emitted'
    stage(rtl)
    subprocess.run([args.lhd.resolve(), 'compile', 'verilog', '--top', 'MixedSocTop',
                    '--emit-dir', 'pyrope:'+str(emitted), '--workdir', work/'compile',
                    '--', '-F', rtl/'files.f', '-DSYNTHESIS'], check=True)
    destination = HERE/'pyrope'
    destination.mkdir(exist_ok=True)
    for path in emitted.glob('*.prp'):
        # CPU/accelerator implementations emitted for the reference compile
        # stay in scratch. Only the glue and flat boundary enter this package.
        if not ((path.stem.startswith('mixed_') and path.stem != 'mixed_mesh'
                 and not path.stem.startswith('mixed_router'))
                or path.stem in ('MixedSocTop', 'GemminiSimTop')):
            continue
        source = path.read_text()
        for name, family in [('RocketTile', 'rocket'), ('BoomTile', 'boom'), ('GemminiTPU', 'gemmini/Mesh8')]:
            source = source.replace(f'import("{name}.{name}")',
                                    f'import("../../{family}/pyrope/{name}.{name}")')
        (destination/path.name).write_text(source)
    (destination/'mixed_mesh.prp').write_text(generate())


if __name__ == '__main__':
    main()
