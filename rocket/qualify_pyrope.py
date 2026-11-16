#!/usr/bin/env python3
"""Qualify Rocket files that would collide with BOOM in a shared import closure.

Run after deliberately regenerating rocket/pyrope (or editing rocket/pyrope2: keep new colliding files qualified);
changes filenames/imports only. Optional arguments name the trees (default: pyrope pyrope2).
"""
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent


def qualify(tree):
    root = HERE/tree
    boom = HERE.parent/'boom'/tree
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


def main():
    # pyrope/ is the generated baseline, pyrope2/ the maintained tree; both are imported next to BOOM's by mixed_soc.
    for tree in sys.argv[1:] or ('pyrope', 'pyrope2'):
        qualify(tree)


if __name__ == '__main__':
    main()
