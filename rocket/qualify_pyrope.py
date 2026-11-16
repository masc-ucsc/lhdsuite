#!/usr/bin/env python3
"""Qualify Rocket files that would collide with BOOM in a shared import closure.

Run after deliberately regenerating rocket/pyrope; changes filenames/imports only.
"""
from pathlib import Path

HERE = Path(__file__).resolve().parent


def main():
    root = HERE/'pyrope'
    boom = HERE.parent/'boom/pyrope'
    names = {p.stem.removeprefix('rocket_') for p in root.glob('*.prp')} & {p.stem for p in boom.glob('*.prp')}
    for path in root.glob('*.prp'):
        source = path.read_text()
        for name in names:
            source = source.replace(f'import("{name}.{name}")', f'import("rocket_{name}.{name}")')
        if source != path.read_text():
            path.write_text(source)
    for name in names:
        old, new = root/(name+'.prp'), root/('rocket_'+name+'.prp')
        if old.exists():
            if new.exists():
                raise SystemExit(f'both {old} and {new} exist; regenerate into a clean tree')
            old.rename(new)
    manifest = root/'manifest.json'
    if manifest.exists():
        source = manifest.read_text()
        for name in names:
            source = source.replace('"file":"'+name+'.prp"', '"file":"rocket_'+name+'.prp"')
        if source != manifest.read_text():
            manifest.write_text(source)


if __name__ == '__main__':
    main()
