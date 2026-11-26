#!/usr/bin/env python3
"""Exercise the mixed tile presets and a rejected per-queue width."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

from run_sim import DEFAULT_CYCLES, signature

ROOT = Path(__file__).resolve().parents[2]


def check(lhd, work):
    for directory in ['mixed_soc/pyrope', 'rocket/pyrope2', 'boom/pyrope2', 'gemmini/Mesh16/pyrope2']:
        shutil.copytree(ROOT / directory, work / directory)
    tb = work / 'mixed_soc/sim/mixed_soc_tb.prp'
    tb.parent.mkdir()
    shutil.copy(ROOT / 'mixed_soc/sim' / tb.name, tb)
    top = work / 'mixed_soc/pyrope/MixedSocTop.prp'
    profiles = top.with_name('TileProfiles.prp')
    base = profiles.read_text()
    for preset in ['uniform', 'heterogeneous']:
        profiles.write_text(base.replace('pub const selected = uniform', f'pub const selected = {preset}'))
        build = work / preset
        subprocess.run([lhd, 'sim', top, tb, '--setup-only', '--workdir', build, '--result-json', work / (preset + '.json'),
                        '--set', 'compile.unknown_zero=true', '--set', 'sim.init_zero=true'], check=True)
        output = subprocess.check_output([lhd.with_name('lhd_simrt'), build / 'sim', '--init-zero',
                                          f'+cycles={DEFAULT_CYCLES}'], text=True)
        print(preset, signature(output, DEFAULT_CYCLES), flush=True)
    options = work / 'boom/pyrope2/BoomConfig.prp'
    text = options.read_text().replace('pub const mixedQueues', 'pub const bad = (const dispatchWidth=2, const numSlowEntries=0)\npub const mixedQueues')
    options.write_text(text.replace('const mem=halfSlow', 'const mem=bad'))
    result = work / 'invalid.json'
    run = subprocess.run([lhd, 'compile', top, '--top', 'MixedSocTop', '--workdir', work / 'invalid',
                          '--emit-dir', f'lg:{work}/invalid-lg', '--result-json', result, '-q'])
    diag = json.loads(result.read_text()).get('error', {}).get('message', '')
    if not run.returncode or 'BOOM mem queue dispatchWidth' not in diag:
        raise RuntimeError(f'expected the invalid memory queue to be identified, got {diag!r}')
    print(diag)
    for family, test in [('rocket', 'mul_profiles'), ('boom', 'queue_profiles')]:
        subprocess.run([lhd, 'sim', ROOT / family / 'sim' / (test + '.prp'), '--top', test,
                        '--workdir', work / test, '--set', 'compile.unknown_zero=true',
                        '--set', 'sim.init_zero=true', '--result-json', work / (test + '.json')], check=True)
        print(f'{family} {test} passed', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lhd', type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='mixed-profiles-') as scratch:
        check(args.lhd.resolve(), Path(scratch))
