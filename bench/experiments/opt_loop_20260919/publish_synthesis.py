#!/usr/bin/env python3
"""Archive completed invocations and current September 19 synthesis progress and regenerate the dashboard.

Simulation records are already in the append-only suite ledger. This importer
does not replace them or overwrite an existing measured cell.
"""
import argparse
import datetime
import importlib.util
import json
from pathlib import Path
import shutil

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--suite',type=Path,required=True)
p.add_argument('--livehd',type=Path,required=True)
p.add_argument('--sweep',action='append',required=True,help='work-directory=config-id')
a=p.parse_args();suite=a.suite.resolve();live=a.livehd.resolve()
spec=importlib.util.spec_from_file_location('ledger',suite/'bench/ledger.py')
ledger=importlib.util.module_from_spec(spec);spec.loader.exec_module(ledger)
primary='validated-eight-opt-20260919'
identity=dict(host='mascm1',lhd_git_sha='95cc7eaf753ddeae446e8e6f6b07b42058bba099',lhdsuite_git_sha='8a9336ea27bd317cf71a1b3e58badf2e730e2812',lhd_binary_sha256='5af1caf045658a4549d624e45acd3249868554be6422f78d815e5b55af718bff')
rows=[]
finished_cores=set()
for item in a.sweep:
    manifest=Path(item.rsplit('=',1)[0])/'runs.json'
    if manifest.exists():
        finished_cores.update(r['core'] for r in json.loads(manifest.read_text())['runs'] if r['exit_code']!=-2)
for item in a.sweep:
    path,config=item.rsplit('=',1);work=Path(path)
    if not (work/'runs.json').exists():continue
    manifest=json.loads((work/'runs.json').read_text())
    completed=manifest['runs']
    recorded={r['core'] for r in completed}
    pending=[dict(core=core,exit_code=None,wall_seconds=None,pending=True)
             for core in manifest.get('cores',[]) if core not in recorded and core not in finished_cores]
    sweep_archive=live/'repros/opt_loop_refresh_20260919/synthesis'
    if config!=primary:sweep_archive/=config
    sweep_archive.mkdir(parents=True,exist_ok=True)
    shutil.copy2(work/'runs.json',sweep_archive/'runs.json')
    runner_log=Path(str(work)+'.log')
    if runner_log.exists():shutil.copy2(runner_log,sweep_archive/'runner.log')
    for scenario in completed+pending:
        core=scenario['core'];d=work/core
        archive=live/'repros/opt_loop_refresh_20260919/synthesis'
        if config!=primary:archive/=config
        archive/=core;archive.mkdir(parents=True,exist_ok=True)
        for pattern in ('run.log','metrics.jsonl','run_metadata.json','memory.json','*_result.json','*_qor.json','*_timing.json','*_synth.log','rusage_*.txt'):
            for source in d.glob(pattern):shutil.copy2(source,archive/source.name)
        (archive/'scenario.json').write_text(json.dumps(scenario,indent=2)+'\n')
        meta=json.loads((d/'run_metadata.json').read_text()) if (d/'run_metadata.json').exists() else {}
        guard=json.loads((d/'memory.json').read_text()) if (d/'memory.json').exists() else {}
        metrics={}
        for line in ((d/'metrics.jsonl').read_text().splitlines() if (d/'metrics.jsonl').exists() else []):
            try:
                m=json.loads(line);metrics[m['name']]=m['value']
            except (ValueError,KeyError):pass
        interrupted=scenario['exit_code']==-2
        run_lines=(d/'run.log').read_text().splitlines() if (d/'run.log').exists() else []
        gate_failures=[line for line in run_lines if line.startswith('FAIL:')]
        failures=list(gate_failures)
        commands=[line.split(':',1)[0][4:] for line in run_lines if line.startswith('CMD ')]
        last_command=commands[-1] if commands else ''
        if guard.get('reason') and not interrupted:failures.append('guard: '+guard['reason'])
        if interrupted:
            failure=('interrupted by monitor on external --help command (monitor fixed); no design failure or timing sample'
                     if work.name.endswith('synth2') and core=='minion' else
                     'interrupted to yield to external synthesis; no design failure or timing sample')
        else:
            failure='; '.join(failures) or ('scenario exit '+str(scenario['exit_code']) if scenario['exit_code'] else '')
        if scenario.get('interruption_reason'):failure=scenario['interruption_reason']
        if scenario.get('timing_note'):failure+='; '+scenario['timing_note']
        stamp=d.stat() if d.exists() else work.stat()
        started=datetime.datetime.fromtimestamp(getattr(stamp,'st_birthtime',stamp.st_mtime)).astimezone().isoformat()
        base=dict(identity,date=started,flow='incr',config_id=config,target=core,pdk_version=meta.get('pdk_version',''))
        tokens=[tok for tok in ledger.NUMBERED_TOKENS.values() if tok+'_synth_ms' in metrics]
        if guard and not scenario.get('pending'):
            rows.append(dict(base,phase='synth_resources',mode='full',phases={},wall_ms=scenario['wall_seconds']*1000,
                             passed=scenario['exit_code']==0,peak_tree_bytes=guard.get('peak_tree_bytes'),
                             limit_bytes=guard.get('limit_bytes'),reserve_bytes=guard.get('reserve_bytes'),
                             memory_measurement=guard.get('measurement',''),guard_reason=guard.get('reason','')))
        if not scenario.get('pending'):
            rows.append(dict(base,phase='synth_validation',mode='full',phases={},wall_ms=scenario['wall_seconds']*1000,passed=scenario['exit_code']==0,
                         measurement_status='interrupted' if interrupted else ('passed' if scenario['exit_code']==0 else 'failed'),
                         scenario_status='all four modes passed' if scenario['exit_code']==0 else failure,completed_modes=', '.join(tokens),
                         evidence_path='../'+str((archive/'run.log').relative_to(live))))
        if scenario.get('pending'):
            status=('running '+last_command if last_command else 'queued; not started')
            rows.append(dict(base,phase='synth_progress',mode='full',phases={},passed=None,
                             measurement_status='running' if last_command else 'queued',
                             scenario_status=status,completed_modes=', '.join(tokens),
                             observed_at=datetime.datetime.now().astimezone().isoformat(),
                             evidence_path='../'+str((archive/'run.log' if run_lines else sweep_archive/'runner.log').relative_to(live))))
        if interrupted:continue
        for mode,tok in ledger.NUMBERED_TOKENS.items():
            result=d/(tok+'_result.json');wall=metrics.get(tok+'_synth_ms')
            if not result.exists() or wall is None:continue
            result=json.loads(result.read_text())
            values={ledger.stored_key(t):metrics[t.format(p=tok)] for t in ledger.PHASES['synth']['extra'] if t.format(p=tok) in metrics}
            invocation_ok=result.get('status')=='pass'
            # A later killed command must not invalidate an earlier completed mode.
            gate_failed=invocation_ok and bool(gate_failures) and last_command==tok+'_synth'
            passed=invocation_ok and not gate_failed
            rows.append(dict(base,phase='synth',mode=mode,wall_ms=wall,passed=passed,phases=ledger.norm_phases(result.get('phases')),
                             color_max_ge=8000,synth_threads=1,measurement_status='completed' if passed else ('suite gate failed' if gate_failed else 'failed'),
                             failure_reason='' if passed else failure,
                             measurement_note='one process tree at a time; max(RSS, physical footprint) guard; Sky130; netlist LEC not established by mapping',**values))
existing=[json.loads(s) for s in (suite/'bench/ledger.jsonl').read_text().splitlines() if s.strip()]
key=lambda row:tuple(row.get(k) for k in ('config_id','host','target','phase','mode'))
seen={key(r) for r in existing if r.get('phase')!='synth_progress'}
progress={key(r):r for r in existing if r.get('phase')=='synth_progress'}
fresh=[r for r in rows if (key(r) not in seen and
       (r.get('phase')!='synth_progress' or
        any(r.get(k)!=progress.get(key(r),{}).get(k) for k in ('scenario_status','completed_modes'))))]
if fresh:ledger.write_rows(suite,fresh)
args=argparse.Namespace(flow='incr',out=str(live/'docs/current_opt_loop_incr.html'),title='Incremental rebuilds, simulation validation and synthesis',baseline='',current=primary,also_current=['synthesis-completion-opt-20260919','simulation-validation-opt-20260919','incremental-full-flow-opt-20260903'],previous='',host='',epsilon=3.0,fail_on_regression=False)
ledger.cmd_render(args,suite)
print('Published',len(fresh),'new cells; prior measurements retained')
