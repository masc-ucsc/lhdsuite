#!/usr/bin/env python3
"""Manually regenerate only mixed_soc glue; import the existing design trees."""
import argparse
from pathlib import Path
import re
import subprocess

from generate_rtl import HERE, stage
from gen_mesh import generate


def configure_tiles(stem, source):
    """Restore the compile-time tile parameters on freshly emitted boundary glue."""
    if stem == 'MixedSocTop':
        header = 'const profiles = import("TileProfiles")\ncomptime const defaultTiles = profiles.selected\n'
        source = source.replace('pub mod MixedSocTop::', 'pub mod MixedSocTop<Tiles=defaultTiles, boomHarts=4>::')
        return header + re.sub(r'( = mixed_soc)::\[name=\w+\]\(', r'\1<Tiles=Tiles, boomHarts=boomHarts>(', source)
    if stem == 'mixed_soc':
        header = 'const profiles = import("TileProfiles")\ncomptime const defaultTiles = profiles.uniform\n'
        source = source.replace('pub mod mixed_soc::', 'pub mod mixed_soc<Tiles=defaultTiles, boomHarts=4>::')
        start = source.index('\n', source.index('pub mod mixed_soc'))
        source = source[:start] + '\n  cassert(boomHarts >= 0 and boomHarts <= 4, "the mixed mesh has four BOOM sockets")' + source[start:]

        def connect(match):
            tile = int(match.group(2) or 0)
            enabled = f', enabled=(boomHarts > {tile-12})' if tile >= 12 else ''
            return f' = {match.group(1)}<C=Tiles.tile{tile}{enabled}>('
        return header + re.sub(r' = (mixed_cpu(?:_p(\d+))?)::\[name=\w+\]\(', connect, source)
    return source


def wire_interrupts(stem, source):
    """Carry each hart's MSIP, MTIP, MEIP and SEIP through generated mesh glue."""
    if stem in ('MixedSocTop', 'mixed_soc'):
        source = source.replace('core_enable:', 'interrupts:U64=0, core_enable:', 1)
        if stem == 'MixedSocTop':
            return source.replace(' = mixed_soc<Tiles=Tiles, boomHarts=boomHarts>(', ' = mixed_soc<Tiles=Tiles, boomHarts=boomHarts>(interrupts, ')
        return re.sub(r'( = mixed_cpu(?:_p\d+)?<C=Tiles.tile(\d+).*?>)\(',
                      lambda m: f'{m[1]}(irq=interrupts#[{4*int(m[2])}..+4], ', source)
    return source


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
        # The maintained CPU sockets bind the shared, parameterized TileLink endpoint.
        if path.stem == 'mixed_packet' or re.fullmatch(r'mixed_cpu(?:_p\d+)?', path.stem):
            continue
        source = path.read_text()
        # The imported cores come from their maintained pyrope2/ trees (the same top modules and ports as pyrope/).
        for name, family in [('RocketTile', 'rocket/pyrope2'), ('BoomTile', 'boom4/pyrope'), ('GemminiTPU', 'gemmini/Mesh16/pyrope2')]:
            source = source.replace(f'import("{name}.{name}")',
                                    f'import("../../{family}/{name}.{name}")')
        source = wire_interrupts(path.stem, configure_tiles(path.stem, source))
        if path.stem == 'MixedSocTop':
            (destination/'MeshFabric.prp').write_text(source.replace('pub mod MixedSocTop', 'pub mod MeshFabric'))
        else:
            (destination/path.name).write_text(source)
    (destination/'mixed_mesh.prp').write_text(generate())


if __name__ == '__main__':
    main()
