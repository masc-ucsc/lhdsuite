#!/usr/bin/env python3
"""Regenerate history.jsonl.gz from a clone of github.com/lowRISC/ibex.

Walks the newest 200 RTL commits up to PIN (first parent, oldest first),
flattens each one with flatten.py (ibex_core + Ibex's own bus assumptions,
only Ibex's built-in assertions), blanks the 4 assertions that fail in every
version, and keeps a commit only if its flattened design changed: 153
versions, 2022-01-24 .. 2026-09-05.

Each line of the output is one version: its commit, and the line edits that
turn the previous version into it (the first one against an empty file).
bench/history.py rebuilds the full files from it.
Usage: make_history.py IBEX_CLONE [-o history.jsonl.gz]
"""
import argparse, difflib, gzip, json, pathlib, re, shutil, subprocess, sys, tempfile

HERE = pathlib.Path(__file__).resolve().parent
PIN = "af456e25575013668ab56725268126f6b0feca35"  # Ibex master, 2026-10-06
COMMITS = 200
PATHS = ["rtl", "shared/rtl", "vendor/lowrisc_ip/ip/prim/rtl", "vendor/lowrisc_ip/ip/prim_generic/rtl",
         "vendor/lowrisc_ip/prim/rtl", "vendor/lowrisc_ip/prim_generic/rtl", "vendor/lowrisc_ip/dv/sv/dv_utils", "dv/fcov"]
# Refuted in every version: the bus environment leaves these inputs free, so
# they are environment gaps, not core bugs (JasperGold agrees).
ALWAYS_CEX = ["IbexBootAddrUnaligned", "IbexDontSkipExceptionReq", "IbexMulticycleEnableUnique",
              "IbexSetExceptionPCOnSpecialReqIfExpected"]


def git(src, *args):
    return subprocess.run(["git", "-C", str(src), *args], capture_output=True, text=True, check=True).stdout


def strip_cex(text):
    """Blank each `ASSERT(Name, ...) in ALWAYS_CEX, keeping its newlines (line numbers stay)."""
    for name in ALWAYS_CEX:
        for m in list(re.finditer(r"`ASSERT\(\s*" + name + r"\s*,", text))[::-1]:
            i, depth = m.end(), 1
            while depth:
                depth += {"(": 1, ")": -1}.get(text[i], 0)
                i += 1
            text = text[:m.start()] + re.sub(r"[^\n]", " ", text[m.start():i]) + text[i:]
    return text


def edits(old, new):
    """Line edits [i1, i2, lines]: replace old[i1:i2] with lines (applied in order, on old indices)."""
    sm = difflib.SequenceMatcher(None, old, new, autojunk=False)
    return [[i1, i2, new[j1:j2]] for tag, i1, i2, j1, j2 in sm.get_opcodes() if tag != "equal"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ibex", type=pathlib.Path, help="clone of github.com/lowRISC/ibex")
    ap.add_argument("-o", "--out", type=pathlib.Path, default=HERE / "history.jsonl.gz")
    a = ap.parse_args()
    src = a.ibex.resolve()
    git(src, "cat-file", "-e", PIN)  # the clone must have the pinned commit
    log = git(src, "log", "--first-parent", "--format=%H|%ad|%s", "--date=short", f"-n{COMMITS}", PIN, "--", "rtl")
    rows, prev = [], []
    with tempfile.TemporaryDirectory() as tmp:
        tree, sv = pathlib.Path(tmp) / "tree", pathlib.Path(tmp) / "v.sv"
        for line in log.splitlines()[::-1]:
            sha, date, subj = line.split("|", 2)
            shutil.rmtree(tree, ignore_errors=True)
            tree.mkdir()
            have = [p for p in PATHS if git(src, "ls-tree", "-d", sha, p).strip()]
            subprocess.run(f"git -C {src} archive {sha} {' '.join(have)} | tar -x -C {tree}", shell=True, check=True)
            f = subprocess.run([sys.executable, str(HERE / "flatten.py"), str(tree), "--env", "-o", str(sv)],
                               capture_output=True, text=True)
            if f.returncode:
                print(f"skip {sha[:8]} (flatten failed)")
                continue
            lines = strip_cex(sv.read_text()).splitlines(keepends=True)
            if lines == prev:  # this commit did not change the design
                continue
            rows.append({"idx": len(rows), "sha": sha[:10], "date": date, "subject": subj, "edits": edits(prev, lines)})
            prev = lines
            print(f"v{rows[-1]['idx']:03d} {sha[:8]} {date} {subj[:60]}", flush=True)
    with gzip.GzipFile(a.out, "wb", mtime=0) as g:  # mtime=0: same input, same bytes
        for r in rows:
            g.write((json.dumps(r) + "\n").encode())
    print(f"{len(rows)} versions -> {a.out}")


if __name__ == "__main__":
    main()
