#!/usr/bin/env python3
"""Publish completed scenarios from the guarded September 19 benchmark queues."""
import argparse
from pathlib import Path
import subprocess
import sys
import time

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--suite',required=True)
p.add_argument('--livehd',required=True)
p.add_argument('--sweep',action='append',required=True)
a=p.parse_args();seen={}
while True:
    changed=False;done=True;stamps={}
    for item in a.sweep:
        path,config=item.rsplit('=',1);work=Path(path);record=work/'runs.json'
        if record.exists():
            stamps[path]=record.stat().st_mtime_ns
            if seen.get(path)!=stamps[path]:changed=True
        log=Path(path+'.log')
        if not log.exists() or not log.read_text().rstrip().endswith('FINISHED'):done=False
    if changed:
        cmd=[sys.executable,str(Path(__file__).with_name('publish_synthesis.py')),'--suite',a.suite,'--livehd',a.livehd]
        for item in a.sweep:cmd.extend(['--sweep',item])
        result=subprocess.run(cmd)
        if result.returncode==0:seen.update(stamps)
        else:print('Publisher will retry after the next poll',flush=True)
    if done and seen==stamps:
        print('All scenarios archived and dashboard refreshed',flush=True);break
    time.sleep(30)
