#!/usr/bin/env python3
"""Run suite synthesis scenarios serially under LogikBench's memory guard."""
import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

p=argparse.ArgumentParser(description=__doc__)
for name in ('suite','lhd','work','guard-root'):p.add_argument('--'+name,type=Path,required=True)
p.add_argument('--wait-pid',type=int,action='append',default=[])
p.add_argument('--wait-for-tests',action='store_true')
p.add_argument('--resume',action='store_true')
p.add_argument('--skip-finished',type=Path)
p.add_argument('--quiet-seconds',type=float,default=30)
p.add_argument('cores',nargs='+');a=p.parse_args()
a.suite,a.lhd,a.work,a.guard_root=(x.resolve() for x in (a.suite,a.lhd,a.work,a.guard_root))
a.work.mkdir(parents=True,exist_ok=True)
sys.path.insert(0,str(a.guard_root))
import psutil

waiting=[]
for pid in a.wait_pid:
    try:waiting.append(psutil.Process(pid))
    except psutil.NoSuchProcess:pass
cfgs=next(ast.literal_eval(n.value) for n in ast.parse((a.suite/'bench/defs.bzl').read_text()).body if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='CORES' for t in n.targets))
rf=a.work/'runfiles';rf.mkdir(exist_ok=True)
if not (rf/'_main').exists():(rf/'_main').symlink_to(a.suite)
sha=hashlib.sha256(a.lhd.read_bytes()).hexdigest()
metadata=dict(binary_sha256=sha,lhd=str(a.lhd),suite=str(a.suite),cores=a.cores,color_max_ge=8000,abc_memory_budget_mb=16384,abc_time_budget_ms=900000,synth_threads=1,runs=[])


if a.resume:
    prior=json.loads((a.work/'runs.json').read_text())
    if prior['binary_sha256']!=sha:raise SystemExit('Refusing to resume with a different executable')
    metadata=prior
elif (a.work/'runs.json').exists():
    raise SystemExit('Existing measurement manifest requires --resume')

def process_snapshots():
    # Read attributes inside the try: macOS can raise SystemError from
    # proc_cmdline while an unrelated process is exiting.
    for proc in psutil.process_iter():
        name=''
        try:
            name=proc.name()
            if name not in ('lhd','abc','yosys-abc','sta','opensta') and 'bazel' not in name:continue
            proc.info=proc.as_dict(attrs=['name','cmdline','status'])
            yield proc
        except (psutil.NoSuchProcess,psutil.AccessDenied,SystemError,PermissionError):
            if name in ('lhd','abc','yosys-abc','sta','opensta') or 'bazel' in name:
                # Unknown relevant processes conservatively occupy the slot.
                proc.info=dict(name=name,cmdline=['unreadable-process'],status='unknown')
                yield proc

def external_synthesis():
    hits=[]
    for proc in process_snapshots():
        try:
            cmd=proc.info['cmdline'] or [];name=proc.info['name'] or ''
            if not cmd or proc.info['status']==psutil.STATUS_ZOMBIE:continue
            if '--help' in cmd or '-h' in cmd:continue
            if cmd==['unreadable-process'] and 'bazel' not in name:
                hits.append(dict(pid=proc.pid,name=name,command=cmd));continue
            if (name=='lhd' and ('synth' in cmd[1:3] or (len(cmd)>2 and cmd[1]=='pass' and cmd[2] in ('abc','opentimer')))) or name in ('abc','yosys-abc','sta','opensta'):
                hits.append(dict(pid=proc.pid,name=name,command=cmd[:5]))
        except psutil.NoSuchProcess:pass
    return hits

def external_tests():
    if not a.wait_for_tests:return []
    hits=[]
    for proc in process_snapshots():
        try:
            cmd=proc.info['cmdline'] or []
            if not cmd or proc.info['status']==psutil.STATUS_ZOMBIE:continue
            if 'bazel' not in (proc.info['name'] or ''):continue
            if cmd==['unreadable-process']:
                hits.append(proc.pid);continue
            if 'test' not in cmd:continue
            targets=[s for s in cmd if s.startswith('//')]
            if targets and all(s.startswith('//bench:xs_rob_sim_') for s in targets):continue
            hits.append(proc.pid)
        except psutil.NoSuchProcess:pass
    return hits

for core in a.cores:
    if any(r['core']==core for r in metadata['runs']):
        print('SKIP recorded result',core,flush=True);continue
    if a.skip_finished and a.skip_finished.exists():
        finished=json.loads(a.skip_finished.read_text()).get('runs',[])
        if any(r['core']==core and r['exit_code']!=-2 for r in finished):
            print('SKIP already finished',core,flush=True);continue
    cfg=cfgs[core];work=a.work/core
    if work.exists():raise SystemExit('Refusing to reuse measured directory '+str(work))
    quiet=time.monotonic();notice=0
    while True:
        busy=external_synthesis()
        pending=[x.pid for x in waiting if x.is_running() and x.status()!=psutil.STATUS_ZOMBIE]+external_tests()
        if busy or pending:quiet=time.monotonic()
        elif time.monotonic()-quiet>=a.quiet_seconds:break
        if time.monotonic()-notice>=30:
            print('WAIT synthesis slot',json.dumps(dict(active=busy,test_clients=pending)),flush=True);notice=time.monotonic()
        time.sleep(1)
    work.mkdir();env=os.environ.copy()
    for key,value in cfg.items():
        if isinstance(value,bool):value='1' if value else ''
        elif isinstance(value,list):value=' '.join(value)
        env['CORE_'+key.upper()]=str(value)
    for key,source in dict(INCR_EDIT_UNIT='incremental_edit_unit',INCR_VARIANT='incremental_variant',GENERATED_VARIANTS='generated_variants').items():
        value=cfg.get(source,'');env['CORE_'+key]=('1' if value else '') if isinstance(value,bool) else str(value)
    pkg=a.suite/cfg['pkg'][2:]
    env.update(CORE=core,MODE='incr',LHD=str(a.lhd),CORE_P_TOP=str(pkg/'pyrope'/(cfg['top']+'.prp')),CORE_V_FLIST=str(pkg/'verilog/filelist.f'),TEST_SRCDIR=str(rf),TEST_TMPDIR=str(work),BENCH_COLOR_MAX_GE='8000',BENCH_ABC_MEMORY_BUDGET_MB='16384',BENCH_ABC_TIME_BUDGET_MS='900000',BENCH_FAIL_TAIL='20',BENCH_PYROPE_SETS='synth.threads=1',PYTHONPATH=str(a.guard_root))
    command=[sys.executable,'-m','logikbench.memory_guard','--timeout','21600','--report',str(work/'memory.json'),'--','bash',str(a.suite/'bench/synth.sh')]
    print('START',core,'load',os.getloadavg(),flush=True);started=time.monotonic()
    with (work/'run.log').open('w') as log:
        proc=subprocess.Popen(command,env=env,stdout=log,stderr=subprocess.STDOUT)
        while proc.poll() is None:
            time.sleep(1);own={proc.pid}
            try:own.update(x.pid for x in psutil.Process(proc.pid).children(recursive=True))
            except psutil.NoSuchProcess:pass
            outsiders=[x for x in external_synthesis() if x['pid'] not in own]
            if outsiders:
                print('STOP for external synthesis',core,json.dumps(outsiders),flush=True)
                proc.terminate();proc.wait();break
    row=dict(core=core,exit_code=proc.returncode,wall_seconds=time.monotonic()-started,load_end=os.getloadavg(),work=str(work))
    metadata['runs'].append(row)
    temporary=a.work/'runs.json.tmp';temporary.write_text(json.dumps(metadata,indent=2)+'\n');temporary.replace(a.work/'runs.json')
    print('DONE',json.dumps(row),flush=True)
print('FINISHED',flush=True)
