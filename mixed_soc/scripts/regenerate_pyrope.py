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
        header = 'const profiles = import("TileProfiles")\n'
        return header + re.sub(r'( = mixed_soc)::\[name=\w+\]\(', r'\1<profiles.selected>(', source)
    if stem == 'mixed_soc':
        header = 'const profiles = import("TileProfiles")\ncomptime const defaultTiles = profiles.uniform\n'
        source = source.replace('pub mod mixed_soc::', 'pub mod mixed_soc<Tiles=defaultTiles>::')
        def connect(match):
            tile = int(match.group(2) or 0)
            return f' = {match.group(1)}<C=Tiles.tile{tile}>('
        return header + re.sub(r' = (mixed_cpu(?:_p(\d+))?)::\[name=\w+\]\(', connect, source)
    if re.fullmatch(r'mixed_cpu(?:_p\d+)?', stem):
        tile = 'Rocket' if ' = RocketTile::' in source else 'Boom'
        preset = 'tiny' if tile == 'Rocket' else 'small'
        header = f'const configs = import("../../{tile.lower()}/pyrope2/{tile}Config")\ncomptime const defaultTile = configs.{preset}\n'
        # The generated endpoint already carries its ID and network parameters.
        source = source.replace('>::[timecheck=false]', ', C=defaultTile>::[timecheck=false]', 1)
        return header + re.sub(rf'( = {tile}Tile)::\[name=\w+\]\(', r'\1<C>(', source)
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
        source = path.read_text()
        # The imported cores come from their maintained pyrope2/ trees (the same top modules and ports as pyrope/).
        for name, family in [('RocketTile', 'rocket'), ('BoomTile', 'boom'), ('GemminiTPU', 'gemmini/Mesh16')]:
            source = source.replace(f'import("{name}.{name}")',
                                    f'import("../../{family}/pyrope2/{name}.{name}")')
        (destination/path.name).write_text(configure_tiles(path.stem, source))
    (destination/'mixed_mesh.prp').write_text(generate())


if __name__ == '__main__':
    main()
