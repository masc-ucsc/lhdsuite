#!/usr/bin/env python3
"""Helpers for bench/verify_history.sh: a design's checked-in version history.

  history.py expand HISTORY.jsonl.gz OUT_DIR RANGE
      rebuild the versions in RANGE ("all" or "lo-hi") as OUT_DIR/vNNN.sv and
      print their indices, one per line
  history.py verdicts REPORT.json
      print the report's assert verdicts as JSON {name: verdict}
  history.py judge OUT_DIR METHOD...
      compare each METHOD's verdicts with cold's, version by version, print a
      summary and the METRIC lines, exit 1 on a proven/refuted mismatch

A history line holds one version's commit and the line edits that turn the
previous version into it (see <core>/history/make_history.py).
"""
import gzip, json, pathlib, sys


def expand(hist, out, rng):
    out = pathlib.Path(out)
    out.mkdir(parents=True, exist_ok=True)
    lo, hi = (0, 10**9) if rng == "all" else (int(x) for x in rng.split("-"))
    lines, meta = [], []
    with gzip.open(hist, "rt") as f:
        for row in map(json.loads, f):
            for i1, i2, new in reversed(row["edits"]):  # back to front: earlier indices stay valid
                lines[i1:i2] = new
            if lo <= row["idx"] <= hi:
                (out / f"v{row['idx']:03d}.sv").write_text("".join(lines))
                meta.append({k: row[k] for k in ("idx", "sha", "date", "subject")})
                print(row["idx"])
            if row["idx"] >= hi:
                break
    (out / "versions.json").write_text(json.dumps(meta, indent=1))


def verdicts(report):
    """{name: verdict} over assert obligations; a repeated name gets @instance."""
    out = {}
    for o in json.load(open(report))["obligations"]:
        if o["kind"] != "assert":
            continue
        name = (o.get("msg") or "").strip("'") or f"line{o.get('line')}"
        if name in out:
            name = f"{name}@{o.get('instance', '')}#{o.get('line')}"
        out[name] = {"v": o["verdict"], "by": o.get("reuse_by", "")}
    return out


def judge(out, methods):
    """Every method's verdicts against cold, per version; timings from times.jsonl."""
    out = pathlib.Path(out)
    t = {}
    for r in map(json.loads, open(out / "times.jsonl")):
        t[(r["method"], r["idx"])] = r
    idxs = sorted({i for m, i in t if m == "cold"})
    proven = ("proven-full", "proven-bounded")
    wrong, flips = 0, 0
    total = {m: 0.0 for m in ["cold", *methods]}
    for m in ["cold", *methods]:
        by = {}
        for i in idxs:
            r = t.get((m, i))
            if r is None or r["props"] is None:
                continue
            total[m] += r["s"]
            for p in r["props"].values():
                by[p["by"] or "solved"] = by.get(p["by"] or "solved", 0) + 1
            if m == "cold":
                continue
            base = t[("cold", i)]["props"] or {}
            for name, p in r["props"].items():
                q = base.get(name)
                if q is None or q["v"] == p["v"] or "unknown" in (q["v"], p["v"]) or "timeout" in q["v"] + p["v"]:
                    continue
                if q["v"] in proven and p["v"] in proven:
                    flips += 1  # PDR finished in one run, not the other (wall-clock limit)
                else:
                    wrong += 1
                    print(f"WRONG v{i:03d} {m}: {name} is {p['v']}, cold says {q['v']}")
        loaded = sum(1 for i in idxs if t.get((m, i)) and t[(m, i)]["props"] is not None)
        print(f"{m:5s} {loaded}/{len(idxs)} versions loaded  {total[m]:8.1f} s  settled by {by}")
    print(f"METRICLINE history_versions {len(idxs)} count")
    for m in ["cold", *methods]:
        print(f"METRICLINE history_{m}_s {total[m]:.2f} s")
        if m != "cold" and total[m]:
            print(f"METRICLINE history_{m}_speedup {total['cold'] / total[m]:.2f} x")
    print(f"METRICLINE history_full_bounded_flips {flips} count")
    print(f"METRICLINE history_wrong_answers {wrong} count")
    sys.exit(1 if wrong else 0)


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "expand":
        expand(*sys.argv[2:5])
    elif cmd == "verdicts":
        print(json.dumps(verdicts(sys.argv[2])))
    elif cmd == "judge":
        judge(sys.argv[2], sys.argv[3:])
    else:
        sys.exit(f"unknown command {cmd}")
