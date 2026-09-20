#!/usr/bin/env python3
"""Compare PicoRV32's shift/ALU configurations with Verilator and fresh builds."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lhd', default='../livehd/bazel-bin/lhd/lhd')
    parser.add_argument('--workdir')
    args = parser.parse_args()
    runfiles = Path(os.environ['TEST_SRCDIR']) if 'TEST_SRCDIR' in os.environ else None
    source = runfiles / os.environ.get('TEST_WORKSPACE', '_main') / 'picorv32' if runfiles else Path(__file__).absolute().parent
    lhd_path = Path(args.lhd)
    if runfiles and not lhd_path.is_absolute():
        lhd_path = runfiles / lhd_path
    lhd = str(lhd_path.absolute())
    verilator = os.environ.get('VERILATOR') or shutil.which('verilator')
    if not verilator:
        for candidate in ('/opt/homebrew/bin/verilator', '/usr/local/bin/verilator'):
            if Path(candidate).is_file():
                verilator = candidate
                break
    if not verilator:
        print('SKIP: Verilator is not installed')
        return
    default_work = str(Path(os.environ['TEST_TMPDIR']) / 'picorv32-configs') if 'TEST_TMPDIR' in os.environ else None
    work = Path(args.workdir or default_work or tempfile.mkdtemp(prefix='picorv32-sim-configs-')).absolute()
    work.mkdir(parents=True, exist_ok=True)
    src = work / 'src'
    src.mkdir(exist_ok=True)
    for path in (source / 'pyrope2').glob('*.prp'):
        shutil.copy2(path, src / path.name)
    shutil.copy2(source / 'sim/picorv32_config_tb.prp', src / 'tb.prp')
    prp_top = (source / 'pyrope2/picorv32_top.prp').read_text()
    v_top = (source / 'verilog/picorv32_top.v').read_text()
    rows = []

    def run(cmd, label):
        log = work / (label + '.log')
        with log.open('w') as output:
            result = subprocess.run([str(x) for x in cmd], stdout=output, stderr=subprocess.STDOUT)
        if result.returncode:
            raise RuntimeError(f'{label} exited {result.returncode}: {log}\n{log.read_text()[-6000:]}')
        return log.read_text()

    def read_result(output):
        match = re.search(r'picorv32 prog: stored=(\d+) at cycle (\d+) of (\d+)', output)
        if not match:
            raise RuntimeError('missing program result:\n' + output[-2000:])
        result = tuple(map(int, match.groups()))
        if result[0] != 58 or result[1] == 0 or result[2] != 2000:
            raise RuntimeError(f'invalid program result {result}')
        return result

    # Gray order changes ONE parameter and ONE source module on each warm run.
    for index, (barrel, two_cycle) in enumerate(((0, 0), (0, 1), (1, 1), (1, 0))):
        label = f'barrel{barrel}-alu{two_cycle}'
        print(f'RUN {label}', flush=True)
        needle = 'mut cpu = picorv32('
        assert prp_top.count(needle) == 1
        (src / 'picorv32_top.prp').write_text(prp_top.replace(
            needle, f'mut cpu = picorv32<BARREL_SHIFTER={str(bool(barrel)).lower()}, TWO_CYCLE_ALU={str(bool(two_cycle)).lower()}>('))
        needle = '.BARREL_SHIFTER (1),'
        assert v_top.count(needle) == 1
        rtl = work / (label + '.v')
        rtl.write_text(v_top.replace(needle, f'.BARREL_SHIFTER ({barrel}),\n\t\t.TWO_CYCLE_ALU ({two_cycle}),'))
        obj = work / ('vobj-' + label)
        run([verilator, '--cc', '--exe', '--build', '-j', '4', '-Wno-fatal', '-DSYNTHESIS',
             '-Dassert(assert_expr)=', '--top-module', 'picorv32_top', '--Mdir', obj,
             source / 'verilog/picorv32.v', rtl, source / 'sim/picorv32_prog_tb_verilator.cpp'], label + '-vbuild')
        reference = read_result(run([obj / 'Vpicorv32_top', '--config-test', '--cycles', '2000'], label + '-verilator'))
        for mode in ('incremental', 'fresh'):
            wd = work / ('shared' if mode == 'incremental' else label + '-fresh')
            result_path = work / (label + '-' + mode + '.json')
            command = [lhd, 'sim', src / 'picorv32_top.prp', src / 'tb.prp', '--workdir', wd,
                       '--arg', 'cycles=2000', '--set', 'sim.tune.profile=off', '--set', 'sim.vcd=false',
                       '--diag-fmt', 'pretty', '--result-json', result_path]
            if mode == 'fresh':
                command += ['--set', 'lhd.incremental=false']
            actual = read_result(run(command, label + '-' + mode))
            if actual != reference:
                raise RuntimeError(f'{label} {mode}: {actual} != Verilator {reference}')
            result = json.loads(result_path.read_text())
            cache = result['incremental']['compile']
            if mode == 'incremental' and index:
                if not (cache['hits'] > 0 and cache['misses'] > 0 and cache['refused'] == 0):
                    raise RuntimeError(f'{label} did not exercise partial reuse: {cache}')
            rows.append(dict(barrel_shifter=barrel, two_cycle_alu=two_cycle, mode=mode,
                             stored=actual[0], done_cycle=actual[1], cache=cache))
        print(f'PASS {label}: stored=58 at cycle {reference[1]}; incremental=fresh=Verilator', flush=True)
    # This must exercise the changed configurations, not merely compile them.
    by_config = {(r['barrel_shifter'], r['two_cycle_alu']): r['done_cycle'] for r in rows}
    for barrel in (0, 1):
        assert by_config[barrel, 1] > by_config[barrel, 0], by_config
    for two_cycle in (0, 1):
        assert by_config[0, two_cycle] > by_config[1, two_cycle], by_config
    (work / 'results.json').write_text(json.dumps(rows, indent=2) + '\n')
    print(f'PASS: four PicoRV32 configurations; artifacts: {work}')


if __name__ == '__main__':
    main()
