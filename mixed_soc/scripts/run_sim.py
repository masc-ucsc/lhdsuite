#!/usr/bin/env python3
"""Build and time the same concurrent-core test with LiveHD and/or Verilator."""
import argparse
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import time

from generate_rtl import HERE, stage

DEFAULT_CYCLES = 36000
# Pin only after both independent simulators agree. Other lengths still run
# all architectural assertions, and compare mode checks their entire signatures.
# The single-16x16-Gemmini glue is NOT pinned yet: Verilator was unavailable when it was written, so the C++ twin is unrun.
# `lhd sim` printed sum=1691795345967856877 (12000 cycles) and sum=6893873800832869613 (36000), with mesh=8367253803954778821
# and acc=264290809912224 for both. Pin them in ORACLES once `run_sim.py compare` shows Verilator printing the same line.
ORACLES = {}
LINE = re.compile(r'(?:^|puts:)mixed_soc: cycles=(\d+) active=(\d+) sum=(\d+) mesh=(\d+) acc=(\d+)$', re.M)


def host_metrics(label, report):
    counts = {}
    for line in report.read_text().splitlines():
        fields = line.split(';')
        if len(fields) >= 3 and fields[2] in ('cycles:u', 'instructions:u'):
            try:
                counts[fields[2]] = int(fields[0])
            except ValueError:
                raise SystemExit(f'host counter unavailable: {line}')
    if set(counts) != {'cycles:u', 'instructions:u'} or not counts['cycles:u']:
        raise SystemExit(f'missing host instruction/cycle counters in {report}')
    print(f"METRIC {label}_host_instructions {counts['instructions:u']} instructions")
    print(f"METRIC {label}_host_cycles {counts['cycles:u']} cycles")
    print(f"METRIC {label}_host_ipc {counts['instructions:u'] / counts['cycles:u']:.6f} instructions/cycle")


def run(label, command, cwd, capture=False, host_perf=False):
    if host_perf:
        report = cwd/(label + '.perf.csv')
        command = ['perf', 'stat', '--no-big-num', '-x', ';', '-o', report,
                   '-e', '{cycles:u,instructions:u}', '--', *command]
    print('CMD', label + ':', shlex.join(map(str, command)), flush=True)
    start = time.monotonic_ns()
    log = cwd / (label + '.log')
    with log.open('w') as stream:
        result = subprocess.run(list(map(str, command)), cwd=cwd, stdout=stream, stderr=subprocess.STDOUT)
    ms = (time.monotonic_ns() - start) // 1_000_000
    run.last_ms = ms
    print(f'METRIC {label}_ms {ms} ms', flush=True)
    if result.returncode:
        print(log.read_text()[-16000:], end='', flush=True)
        raise SystemExit(f'{label} failed ({result.returncode}); see {log}')
    if host_perf:
        host_metrics(label, report)
    if capture:
        output = log.read_text()
        print(output, end='', flush=True)
        return output
    return None


def signature(output, cycles):
    matches = LINE.findall(output)
    if len(matches) != 1:
        raise SystemExit('missing or repeated mixed_soc data verdict')
    count, active, checksum, mesh, acc = map(int, matches[0])
    if mesh == 0:
        raise SystemExit('the host read nothing back from the Gemmini mesh registers')
    if acc == 0:
        raise SystemExit('the accumulator rows the mesh results were written to read back as zero')
    if count != cycles or active != 0x5009:
        raise SystemExit('wrong cycle count or active CPU mask')
    if cycles in ORACLES and checksum != ORACLES[cycles]:
        raise SystemExit(f'checksum mismatch: got {checksum}, expected {ORACLES[cycles]}')
    return matches[0]


def simulate(args, work):
    work.mkdir(parents=True, exist_ok=True)
    signatures = []
    if args.mode in ('pyrope', 'compare'):
        if not args.lhd:
            raise SystemExit('--lhd must name the source-built LiveHD executable')
        lhd = Path(args.lhd).resolve()
        design = HERE/'pyrope/MixedSocTop.prp'
        driver = HERE/'sim/mixed_soc_tb.prp'
        common = [lhd, 'sim', design, driver, '--workdir', work/'lhd',
                  '--set', 'sim.vcd=false', '--set', 'compile.unknown_zero=true',
                  '--set', 'sim.init_zero=true', '--set', 'sim.tune.profile=off',
                  '--set', f'lhd.jobs={args.jobs}']
        run('sim_setup', common + ['--setup-only'], work)
        run('sim_cc', common + ['--run-only', '--set', 'sim.compile_only=true'], work)
        output = run('sim_exec', [work/'lhd/sim/drv.bin', '--cycles', args.cycles,
                     '--set', 'compile.unknown_zero=true', '--set', 'sim.init_zero=true'], work, True, args.host_perf)
        signatures.append(signature(output, args.cycles))
        print(f'METRIC sim_cycles_per_s {args.cycles * 1000 // max(1, run.last_ms)} cycles/s')
    if args.mode in ('verilator', 'compare'):
        verilator = shutil.which(args.verilator)
        if not verilator:
            print('SKIP: Verilator unavailable\nMETRIC verilator_present 0 bool')
            return
        print('METRIC verilator_present 1 bool')
        rtl = work/'verilog'
        stage(rtl)
        obj = work/'obj'
        obj.mkdir(exist_ok=True)
        run('verilator_cc', [verilator, '--cc', '--exe', '--build', '--top-module', 'MixedSocTop',
            '--Mdir', obj, '-j', args.jobs, '-Wno-PINMISSING', '-Wno-fatal', '-DSYNTHESIS',
            '-I'+str(rtl), '-F', rtl/'files.f', HERE/'sim/mixed_soc_tb_verilator.cpp'], work)
        print(f'METRIC sim_cc_ms {run.last_ms} ms')
        output = run('verilator_exec', [obj/'VMixedSocTop', '--cycles', args.cycles], work, True, args.host_perf)
        signatures.append(signature(output, args.cycles))
        print(f'METRIC sim_exec_ms {run.last_ms} ms')
        print(f'METRIC sim_cycles_per_s {args.cycles * 1000 // max(1, run.last_ms)} cycles/s')
    if len(signatures) == 2 and signatures[0] != signatures[1]:
        raise SystemExit(f'LiveHD / Verilator disagree: {signatures}')
    print(f'METRIC sim_cycles {args.cycles} cycles')
    print('PASS: four concurrent CPUs branched via their own Gemmini pointers')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['pyrope', 'verilator', 'compare'])
    parser.add_argument('--lhd', help='source-built lhd (Bazel supplies its dependency)')
    parser.add_argument('--verilator', default=os.environ.get('VERILATOR', 'verilator'))
    parser.add_argument('--host-perf', action='store_true',
                        help='count user-space host instructions/cycles and IPC during execution only (requires perf access)')
    parser.add_argument('--cycles', type=int, default=DEFAULT_CYCLES)
    parser.add_argument('-j', '--jobs', type=int, default=int(os.environ.get('LHD_BENCH_JOBS', '8')))
    parser.add_argument('--work', type=Path, help='retain logs and reuse simulator builds')
    args = parser.parse_args()
    if args.cycles < 1 or args.jobs < 1:
        parser.error('cycles and jobs must be positive')
    if args.host_perf:
        if not shutil.which('perf'):
            parser.error('--host-perf requires perf on PATH')
        probe = subprocess.run(['perf', 'stat', '-e', '{cycles:u,instructions:u}', '--', 'true'],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if probe.returncode:
            raise SystemExit('Host hardware counters are unavailable; no IPC can be measured.\n' + probe.stderr)
    if args.work:
        simulate(args, args.work.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix='mixed-soc-sim-') as tmp:
            simulate(args, Path(tmp))
