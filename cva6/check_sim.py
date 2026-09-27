#!/usr/bin/env python3
"""Generate fresh Pyrope and compare the whole core with the external CVA6 RTL."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

p = argparse.ArgumentParser()
p.add_argument('--lhd', required=True, type=Path)
p.add_argument('--rtl', required=True, type=Path)
p.add_argument('--suite', required=True, type=Path)
p.add_argument('--work', required=True, type=Path)
p.add_argument('--cycles', type=int, default=50000)
a = p.parse_args()
a.lhd, a.rtl, a.suite, a.work = (x.resolve() for x in (a.lhd, a.rtl, a.suite, a.work))
a.work.mkdir(parents=True, exist_ok=False)
assets = Path(__file__).resolve().parent
if (assets/'sim/cva6_oracle.sv').exists(): assets = assets/'sim'
env = dict(os.environ, CVA6_REPO_DIR=str(a.rtl), HPDCACHE_DIR=str(a.rtl/'core/cache_subsystem/hpdcache'), TARGET_CFG='cv64a6_imafdc_sv39_wb')
rows = []

def run(cmd, name, allow_failure=False):
    start = time.perf_counter()
    r = subprocess.run(list(map(str, cmd)), env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    ms = (time.perf_counter()-start)*1000
    (a.work/(name+'.log')).write_text(r.stdout)
    records = []
    for line in r.stdout.splitlines():
        try:
            obj = json.loads(line)
            if isinstance(obj, dict) and obj.get('tool') == 'lhd': records.append(obj)
        except ValueError: pass
    row = dict(name=name, command=list(map(str, cmd)), wall_ms=ms, exit_code=r.returncode)
    if records:
        row['report'] = records[-1]
        row['phase_ms'] = {x['name']: x['ms'] for x in records[-1].get('phases', [])}
    rows.append(row)
    (a.work/'statistics.json').write_text(json.dumps(dict(cycles=a.cycles, binary_sha256=hashlib.sha256(a.lhd.read_bytes()).hexdigest(), runs=rows), indent=2)+'\n')
    print(name, r.returncode, round(ms, 1), flush=True)
    if r.returncode and not allow_failure: raise RuntimeError(name)
    return r.stdout, row

flags = ['--allow-use-before-declare', '-DSYNTHESIS', '--translate-off-format=pragma,translate_off,translate_on', a.rtl/'core/include/cv64a6_imafdc_sv39_wb_config_pkg.sv', '-F', a.rtl/'core/Flist.cva6']
run([a.lhd, 'compile', '--top', 'cva6', '--emit-dir', f'lg:{a.work}/lg', '--workdir', a.work/'import', '--set', 'lhd.incremental=false', '--', *flags], 'rtl-import')
# Match the documented source-generation flow (before graph optimization).
run([a.lhd, 'compile', '--top', 'cva6', '--emit-dir', f'pyrope:{a.work}/tree', '--workdir', a.work/'generate', '--set', 'lhd.incremental=false', '--', *flags], 'pyrope-generate')
# Use the writer output directly: no checked-in Pyrope or post-generation fixes.
assert (a.work/'tree/cva6.prp').is_file(), 'generation did not emit the whole-core top'
tb = a.suite/'cva6/sim/cva6_prog_tb.prp'
common = ['--set', 'sim.tune.profile=off', '--set', 'sim.vcd=false', '--arg', f'cycles={a.cycles}']

def lhd_run(name, source, work, incremental=True, allow_failure=False):
    cmd = [a.lhd, 'sim', source, tb, '--workdir', work, '--set', f'lhd.incremental={str(incremental).lower()}', *common]
    _, setup = run([*cmd, '--setup-only'], name+'-setup')
    out, host = run([*cmd, '--run-only'], name+'-host-and-run', allow_failure)
    samples = []
    for i in range(3):
        out, row = run([work/'sim/drv.bin', '--cycles', str(a.cycles)], name+f'-exec-{i}', allow_failure)
        samples.append((row['exit_code'], out))
    assert samples[0] == samples[1] == samples[2], name+' is nondeterministic'
    return samples[0], setup, host

expected = 'x2=100 -x3=100 marker=1445, retired=43443, done at cycle 738'
baseline = None
for mode, source in [('verilog', f'lg:{a.work}/lg'), ('pyrope', a.work/'tree/cva6.prp')]:
    result, _, _ = lhd_run(mode, source, a.work/mode, incremental=False)
    match = re.search(r'x2=(-?\d+) -x3=(-?\d+) marker=(\d+), retired=(\d+), done at cycle (\d+)', result[1])
    assert match, result[1]
    summary = tuple(map(int, match.groups()))
    if baseline is None: baseline = summary
    assert summary == baseline, (mode, summary, baseline)
    if a.cycles == 50000: assert expected in result[1], result[1]

vobj = a.work/'vobj'
run(['verilator', '--cc', '--exe', '--top-module', 'cva6_oracle', '--Mdir', vobj, '-Wno-fatal', '-DSYNTHESIS', '-f', a.rtl/'core/Flist.cva6', assets/'cva6_oracle.sv', assets/'cva6_prog_tb_verilator.cpp'], 'verilator-setup')
run(['make', '-C', vobj, '-f', 'Vcva6_oracle.mk', '-j4'], 'verilator-host')
for i in range(3):
    out, _ = run([vobj/'Vcva6_oracle', '--cycles', str(a.cycles)], f'verilator-exec-{i}')
    match = re.search(r'got=7 st0=(-?\d+) st8=(-?\d+) st16=(\d+) retired=(\d+) exceptions=0 done=(\d+)', out)
    assert match, out
    x2, x3, marker, retired, done = map(int, match.groups())
    assert (x2, -x3, marker, retired, done) == baseline, (out, baseline)
    if a.cycles == 50000: assert 'retired=43443 exceptions=0 done=738' in out, out

source = a.work/'tree/cva6.prp'
result, cold, _ = lhd_run('incremental-cold', source, a.work/'incremental')
warm, warm_row, _ = lhd_run('incremental-warm', source, a.work/'incremental')
assert result == warm
assert warm_row['report']['incremental']['compile']['misses'] == 0
# A one-module behavioral edit; compare its status and output with a fresh run.
# The existing suite mutant changes ALU addition to subtraction. Keep the
# architectural asserts live: both runs must fail identically and then restore.
alu = a.work/'tree/alu.prp'
original = alu.read_text()
needle = '    in (ariane_pkg.ADD, ariane_pkg.SUB, ariane_pkg.ADDUW, ariane_pkg.SH1ADD, ariane_pkg.SH2ADD, ariane_pkg.SH3ADD) {\n      result_o = adder_result__w1\n'
assert needle in original
alu.write_text(original.replace(needle, needle.replace('adder_result__w1', 'operand_a__w1 - operand_b__w1'), 1))
try:
    edited, edit, _ = lhd_run('incremental-edit', source, a.work/'incremental', allow_failure=True)
    fresh, _, _ = lhd_run('edited-fresh', source, a.work/'edited-fresh', incremental=False, allow_failure=True)
    assert edited == fresh, (edited, fresh)
    assert edited[0] != 0, 'ALU mutant should violate the live program assertions'
    reuse = edit['report']['incremental']['compile']
    assert reuse['hits'] > 0 and 0 < reuse['misses'] < cold['report']['incremental']['compile']['misses'], reuse
finally:
    alu.write_text(original)
restored, _, _ = lhd_run('incremental-restored', source, a.work/'incremental')
assert restored == result
print('PASS: original RTL, generated Pyrope, Verilator, and one-module incremental edit', flush=True)
