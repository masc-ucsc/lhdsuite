#!/usr/bin/env python3
"""Exercise the mixed tile presets and a rejected per-queue width."""
import argparse
import json
import re
from pathlib import Path
import shutil
import subprocess
import tempfile

from run_sim import DEFAULT_CYCLES, signature

ROOT = Path(__file__).resolve().parents[2]


def check(lhd, work):
    for directory in ['mixed_soc/pyrope', 'chipyard/pyrope', 'rocket/pyrope2', 'gemmini/Mesh16/pyrope2']:
        shutil.copytree(ROOT / directory, work / directory)
    for package in (ROOT / 'boom4').rglob('pyrope'):
        shutil.copytree(package, work / package.relative_to(ROOT))
    tb = work / 'mixed_soc/sim/mixed_soc_tb.prp'
    tb.parent.mkdir()
    shutil.copy(ROOT / 'mixed_soc/sim' / tb.name, tb)
    top = work / 'mixed_soc/pyrope/MixedSocTop.prp'
    profiles = top.with_name('TileProfiles.prp')
    base = profiles.read_text()
    for preset in ['uniform', 'heterogeneous']:
        profiles.write_text(base.replace('pub const selected = heterogeneous', f'pub const selected = {preset}'))
        build = work / preset
        subprocess.run([lhd, 'sim', top, tb, '--setup-only', '--workdir', build, '--result-json', work / (preset + '.json'),
                        '--set', 'compile.unknown_zero=true', '--set', 'sim.init_zero=true'], check=True)
        output = subprocess.check_output([lhd.with_name('lhd_simrt'), build / 'sim', '--init-zero',
                                          f'+cycles={DEFAULT_CYCLES}'], text=True)
        print(preset, signature(output, DEFAULT_CYCLES), flush=True)
    # Exercise Chisel's smallest teaching-core resources on the writer hart.
    baseline = base.replace('const tile12=booms.small', 'const tile12=booms.cs152BaselineCore')
    profiles.write_text(baseline)
    coherent_tb = work / 'mixed_soc/sim/coherent_harts.prp'
    shutil.copy(ROOT / 'mixed_soc/sim' / coherent_tb.name, coherent_tb)
    subprocess.run([lhd, 'sim', top.with_name('CoherentMixedSoc.prp'), coherent_tb,
                    '--set', 'compile.unknown_zero=true', '--set', 'sim.init_zero=true',
                    '--workdir', work / 'cs152', '--result-json', work / 'cs152.json'], check=True)
    print('CS152 baseline core passed the coherent four-hart program', flush=True)
    profiles.write_text(base)
    cluster = top.with_name('CoherentMixedSoc.prp')
    original_cluster = cluster.read_text()
    for harts in (1, 2, 3):
        cluster.write_text(original_cluster.replace('boomHarts=4>', f'boomHarts={harts}>', 1))
        subprocess.run([lhd, 'sim', cluster, coherent_tb, f'+harts={harts}', '--set', 'compile.unknown_zero=true',
                        '--set', 'sim.init_zero=true', '--workdir', work / f'cluster{harts}',
                        '--result-json', work / f'cluster{harts}.json'], check=True)
        print(f'{harts} populated BOOM sockets fetched the program and acquired coherent data', flush=True)
    cluster.write_text(original_cluster)
    tile = work / 'boom4/pyrope/BoomTile.prp'
    small = work / 'small'
    subprocess.run([lhd, 'sim', tile, ROOT / 'boom4/sim/boom_tb.prp', '--setup-only',
                    '--set', 'compile.unknown_zero=true', '--set', 'sim.init_zero=true',
                    '--workdir', small, '--result-json', work / 'small.json'], check=True)
    output = subprocess.check_output([lhd.with_name('lhd_simrt'), small / 'sim', '--init-zero', '+cycles=100000'], text=True)
    if 'boom: cycles=100000 sum=6034797118373429972' not in output:
        raise RuntimeError(f'Small tile disagreed with the Chisel-generated Verilator reference: {output}')
    original = tile.read_text()
    for commit in (False, True):
        preset = 'const presets = import("../common/pyrope/BoomPresets")'
        cfg = (f'configs.params<B=presets.medium>(enableBranchPrintf=true, enableMemtracePrintf=true, '
               f'enableCommitLogPrintf={str(commit).lower()})')
        tile.write_text(original.replace('comptime const small = configs.small', f'{preset}\ncomptime const small = {cfg}'))
        log_work = work / ('commit-log' if commit else 'branch-log')
        subprocess.run([lhd, 'sim', tile, ROOT / 'boom4/sim/boom_tb.prp', '--setup-only',
                        '--set', 'compile.unknown_zero=true', '--set', 'sim.init_zero=true',
                        '--workdir', log_work, '--result-json', log_work.with_suffix('.json')], check=True)
        packed = subprocess.check_output([lhd.with_name('lhd_simrt'), log_work / 'sim',
                                          '--init-zero', '+cycles=1000'], text=True)
        rendered = subprocess.check_output(['python3', ROOT / 'boom4/sim/retirement_log.py'], input=packed, text=True)
        load = re.search(r'^MT [0-9a-f]+ 0 0 3 80000000 0 ([0-9a-f]+)$', rendered, re.M)
        store = re.search(r'^MT [0-9a-f]+ 0 1 3 80000008 ([0-9a-f]+) [0-9a-f]+$', rendered, re.M)
        if not load or not store or int(load[1], 16) == 0 or load[1] != store[1]:
            raise RuntimeError('memory log lost the value loaded and stored by the program')
        first = '3 0x0000000000010000 (0x00100093) x1 0x0000000000000001'
        jump = re.search(r'^[0-9a-f] 1 0 1 0 0000000000010018$', rendered, re.M)
        if (first in rendered) != commit or bool(jump) == commit:
            raise RuntimeError('commit/branch printf selection or instruction data disagreed')
        print(f'{log_work.name} and memory trace reproduced the two-wide tile program', flush=True)
    platform = 'configs.params(useNMI=true, trace=true, enableTraceCoreIngress=true)'
    tile.write_text(original.replace('comptime const small = configs.small', f'comptime const small = {platform}'))
    subprocess.run([lhd, 'sim', tile, ROOT / 'boom4/sim/platform_tb.prp', '--set', 'compile.unknown_zero=true',
                    '--set', 'sim.init_zero=true', '--workdir', work / 'platform',
                    '--result-json', work / 'platform.json'], check=True)
    print('The trace-enabled core entered the NMI handler and resumed its interrupted loop', flush=True)
    for levels, predictor in ((4, ''), (5, ''), (5, ', swBPD=true'), (4, ', fastTageBPD=true'),
                              (4, ', boom2BPD=true'), (5, ', alpha21264BPD=true')):
        config = f'configs.params(pgLevels={levels}, trace=true{predictor})'
        vm_work = work / f'vm{levels}{predictor.split("=")[0].strip(", ")}'
        tile.write_text(original.replace('comptime const small = configs.small', f'comptime const small = {config}'))
        subprocess.run([lhd, 'sim', tile, ROOT / 'boom4/sim/virtual_memory_tb.prp', f'+levels={levels}',
                        '--set', 'compile.unknown_zero=true', '--set', 'sim.init_zero=true',
                        '--workdir', vm_work, '--result-json', vm_work.with_suffix('.json')], check=True)
        print(f'{levels}-level supervisor fetch, load and dependent retirement passed', flush=True)
    accelerator = 'configs.params(usingRoCC=true, trace=true, numRXQEntries=3, numRCQEntries=5)'
    tile.write_text(original.replace('comptime const small = configs.small', f'comptime const small = {accelerator}'))
    subprocess.run([lhd, 'sim', tile, ROOT / 'boom4/sim/rocc_tb.prp', '--set', 'compile.unknown_zero=true',
                    '--set', 'sim.init_zero=true', '--workdir', work / 'rocc',
                    '--result-json', work / 'rocc.json'], check=True)
    print('The accelerator completed a delayed register write and a dependent no-destination command', flush=True)
    for profile in ('medium', 'large', 'mega', 'megaTapeout', 'giga', 'megaTapeoutCore(singlePorted=false)', 'cs152Default(numSlowAluEntries=28, fetchEntries=12)'):
        tile.write_text(original.replace('comptime const small = configs.small',
                        f'const presets = import("../common/pyrope/BoomPresets")\ncomptime const small = presets.{profile}'))
        subprocess.run([lhd, 'sim', tile, ROOT / 'boom4/sim/boom_tb.prp', '+cycles=10000', '+checkWalk=1',
                        '--set', 'compile.unknown_zero=true', '--set', 'sim.init_zero=true',
                        '--workdir', work / profile, '--result-json', work / (profile + '.json')], check=True)
        subprocess.run([lhd.with_name('lhd_simrt'), work / profile / 'sim', '--init-zero',
                        '+cycles=3000', '+checkFloat=1'], check=True)
        print(f'{profile} core fetched all 256 data lines and passed the dependent FP program', flush=True)
    fixture = Path('boom4/ifu/sim/fixtures/LastTargetBank.prp')
    (work / fixture).parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(ROOT / fixture, work / fixture)
    custom = ('const bank = import("../ifu/sim/fixtures/LastTargetBank.lastTarget")\n'
              'const presets = import("../common/pyrope/BoomPresets")\n'
              'comptime const small = configs.params<B=presets.medium>(branchPredictor=bank, bpdMaxMetaLength=3)')
    tile.write_text(original.replace('comptime const small = configs.small', custom))
    subprocess.run([lhd, 'sim', tile, ROOT / 'boom4/sim/boom_tb.prp', '+cycles=20000', '+checkWalk=1',
                    '--set', 'compile.unknown_zero=true', '--set', 'sim.init_zero=true',
                    '--workdir', work / 'custom-bank', '--result-json', work / 'custom-bank.json'], check=True)
    print('Medium with a caller-supplied predictor fetched all 256 data lines', flush=True)
    queues = ', '.join(
        f'configs.queue<B=base.{kind}>(iqType=configs.IQ_{kind.upper()}, useMatrixIssue=true, '
        f'useFullIssueSel={str(kind != "alu").lower()})' for kind in ('fp', 'alu', 'mem', 'unq'))
    matrix = ('const presets = import("../common/pyrope/BoomPresets")\ncomptime const base = presets.large\n'
              f'comptime const small = configs.params<B=base>(useCompressed=false, useDebug=false, issueParams=({queues}))')
    tile.write_text(original.replace('comptime const small = configs.small', matrix))
    subprocess.run([lhd, 'sim', tile, ROOT / 'boom4/sim/boom_tb.prp', '+cycles=20000', '+checkWalk=1',
                    '--set', 'compile.unknown_zero=true', '--set', 'sim.init_zero=true',
                    '--workdir', work / 'matrix-core', '--result-json', work / 'matrix-core.json'], check=True)
    subprocess.run([lhd.with_name('lhd_simrt'), work / 'matrix-core/sim', '--init-zero',
                    '+cycles=3000', '+checkFloat=1'], check=True)
    print('Large with four matrix queues and compressed instructions disabled passed both programs', flush=True)
    for latency, divider in [(3, 'false'), (6, 'true')]:
        fpu = f'configs.floatingPoint(sfmaLatency={latency}, dfmaLatency={latency}, divSqrt={divider})'
        tile.write_text(original.replace('comptime const small = configs.small',
                                         f'comptime const small = configs.params(fpu={fpu})'))
        subprocess.run([lhd, 'sim', tile, ROOT / 'boom4/sim/boom_tb.prp', '+cycles=3000', '+checkFloat=1',
                        '--set', 'compile.unknown_zero=true', '--set', 'sim.init_zero=true',
                        '--workdir', work / f'fp{latency}', '--result-json', work / f'fp{latency}.json'], check=True)
        print(f'{latency}-cycle FMA passed the dependent FP program', flush=True)
    for isa in (0, 1, 40, 41):
        atomics = str(bool(isa & 1)).lower()
        floating = str(bool(isa & 40)).lower()
        cfg = f'configs.params(useAtomics={atomics}, usingFPU={floating})'
        tile.write_text(original.replace('comptime const small = configs.small', f'comptime const small = {cfg}'))
        subprocess.run([lhd, 'sim', tile, ROOT / 'boom4/sim/boom_tb.prp', '+cycles=3000', '+checkISA=1',
                        f'+isaBits={isa}', '--set', 'compile.unknown_zero=true', '--set', 'sim.init_zero=true',
                        '--workdir', work / f'isa{isa}', '--result-json', work / f'isa{isa}.json'], check=True)
        print(f'useAtomics={atomics}, usingFPU={floating} passed the misa-dependent load', flush=True)
    for count, line in ((0, 3), (9, 0), (16, 15)):
        tile.write_text(original.replace('comptime const small = configs.small',
                        f'comptime const small = configs.params(nPMPs={count})'))
        subprocess.run([lhd, 'sim', tile, ROOT / 'boom4/sim/boom_tb.prp', '+cycles=3000', '+checkPMP=1',
                        f'+pmpLine={line}', '--set', 'compile.unknown_zero=true', '--set', 'sim.init_zero=true',
                        '--workdir', work / f'pmp{count}', '--result-json', work / f'pmp{count}.json'], check=True)
        print(f'{count} PMP regions passed the CSR-dependent load', flush=True)
    for triggers, line in ((0, 0), (2, 3)):
        tile.write_text(original.replace('comptime const small = configs.small',
                        f'comptime const small = configs.params(nBreakpoints={triggers}, mcontextWidth=8, scontextWidth=8)'))
        subprocess.run([lhd, 'sim', tile, ROOT / 'boom4/sim/boom_tb.prp', '+cycles=3000', '+checkTrigger=1',
                        f'+triggerLine={line}', '--set', 'compile.unknown_zero=true', '--set', 'sim.init_zero=true',
                        '--workdir', work / f'trigger{triggers}', '--result-json', work / f'trigger{triggers}.json'], check=True)
        print(f'{triggers} triggers selected the expected instruction path', flush=True)
    for io_only, writable in ((0, 0), (1, 0), (0, 1)):
        cfg = f'configs.params(useAtomicsOnlyForIO={str(bool(io_only)).lower()}, misaWritable={str(bool(writable)).lower()})'
        tile.write_text(original.replace('comptime const small = configs.small', f'comptime const small = {cfg}'))
        subprocess.run([lhd, 'sim', tile, ROOT / 'boom4/sim/boom_tb.prp', '+cycles=3000', '+checkAtomicIO=1',
                        f'+ioOnly={io_only | writable}', '--set', 'compile.unknown_zero=true', '--set', 'sim.init_zero=true',
                        '--workdir', work / f'atomic{io_only}-{writable}', '--result-json', work / f'atomic{io_only}-{writable}.json'], check=True)
        print(f'useAtomicsOnlyForIO={bool(io_only)}, misaWritable={bool(writable)} passed the LR.D program', flush=True)
    ports = ['acc.core.iregfile_io_write_ports_0_valid_REG', 'acc.core.loadWB.valid']
    pair = work / 'parallel-loads.json'
    tile.write_text(original.replace('comptime const small = configs.small',
                    'const presets = import("../common/pyrope/BoomPresets")\ncomptime const small = presets.megaTapeout'))
    subprocess.run([lhd, 'sim', tile, ROOT / 'boom4/sim/boom_tb.prp', '+cycles=4000', '+checkPair=1', '+checkAhead=1',
                    '--probe', ','.join(ports), '--set', 'compile.unknown_zero=true', '--set', 'sim.init_zero=true',
                    '--workdir', work / 'parallel-loads', '--result-json', pair], check=True)
    rows = json.loads(pair.read_text())['debug']['probe']['rows']
    simultaneous = sum(all(row[port] for port in ports) for row in rows)
    if not simultaneous:
        raise RuntimeError('Mega Tapeout serialized every cached load writeback')
    print(f'Mega Tapeout completed the four-load sum with {simultaneous} simultaneous writebacks', flush=True)
    tile.write_text(original)
    invalid, changes = re.subn(r'(twoWideMemory\s*=\s*booms\.queue\(\s*dispatchWidth\s*=\s*)2\b',
                               r'\g<1>3', base)
    if changes != 1:
        raise RuntimeError('expected one two-lane memory queue in the mixed profile')
    profiles.write_text(invalid)
    result = work / 'invalid.json'
    run = subprocess.run([lhd, 'compile', top, '--top', 'MixedSocTop', '--workdir', work / 'invalid',
                          '--emit-dir', f'lg:{work}/invalid-lg', '--result-json', result, '-q'])
    diag = json.loads(result.read_text()).get('error', {}).get('message', '')
    if not run.returncode or 'BOOM mem queue dispatchWidth' not in diag:
        raise RuntimeError(f'expected the invalid memory queue to be identified, got {diag!r}')
    print(diag)
    cases = {
        'boom4/common': ('compose', 'page_table_cache', 'page_walk_levels', 'protection', 'triggers'),
        'rocket': (
            'mul_profiles',
        ),
        'boom4/lsu': (
            'cache_banks', 'cache_metadata', 'cache_misses', 'data_tlb_levels', 'flush_permission', 'forwarding_age', 'load_latency',
            'load_to_store', 'lsq_depth', 'lsu_rows', 'queue_age', 'queue_dispatch', 'retire_queues',
            'store_search', 'tlb_sectors',
        ),
        'boom4/exe': (
            'divider_profiles', 'issue_pnr', 'matrix_issue',
            'banked_free_rows', 'branch_resolution', 'branch_rows', 'busy_rows', 'column_issue',
            'commit_fetch_target', 'csr_rows', 'decode_control', 'dispatch_hazards', 'dispatch_operands',
            'dispatch_row', 'execution_ports', 'fp_decode', 'free_rows', 'fully_ported_file',
            'immediate_decode', 'isa_decode', 'immediate_rows', 'int_to_fp_latency', 'issue_select', 'multiply_latency',
            'predicate_rows', 'predictor_counters', 'queue_profiles', 'register_file', 'register_rename',
            'rename_rows', 'rob_rows', 'trace_ingress', 'wide_issue_queues', 'wide_mem_queue',
        ),
        'boom4/ifu': (
            'custom_predictor',
            'alpha_frontend', 'alpha_training', 'banked_branch_decode', 'banked_fetch_packet',
            'banked_fetch_rows', 'banked_history', 'banked_icache', 'banked_predictor', 'bim_geometry', 'cache_profiles',
            'fast_tage', 'fetch_decode', 'fetch_prediction', 'fetch_rows', 'frontend_rows', 'ftq_depth',
            'gshare_training', 'instruction_tlb', 'local_geometry', 'ras_depth', 'short_forward_branch', 'software_training', 'tage_geometry', 'target_geometry',
        ),
    }
    for family, tests in cases.items():
        for test in tests:
            subprocess.run([lhd, 'sim', ROOT / family / 'sim' / (test + '.prp'),
                            '--workdir', work / test, '--set', 'compile.unknown_zero=true',
                            '--set', 'sim.init_zero=true', '--result-json', work / (test + '.json')], check=True)
            print(f'{family} {test} passed', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lhd', type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='mixed-profiles-') as scratch:
        try:
            check(args.lhd.resolve(), Path(scratch))
        except subprocess.CalledProcessError as exc:
            if '--result-json' in exc.cmd:
                report = Path(exc.cmd[exc.cmd.index('--result-json') + 1])
                if report.exists():
                    print(report.read_text(), flush=True)
            raise
