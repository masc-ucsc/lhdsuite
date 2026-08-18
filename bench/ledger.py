#!/usr/bin/env python3
"""Append successful synthesis benchmark results to bench/ledger.jsonl."""

import hashlib
import json
import platform
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROUTINE = ("dino", "minion", "xs_rob", "xs_alu", "xs_div")


def git(repo: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()


def diff_hash(repo: Path) -> str:
    tracked = subprocess.check_output(["git", "-C", str(repo), "diff", "--binary", "HEAD"])
    names = git(repo, "status", "--porcelain").encode()
    return hashlib.sha256(tracked + b"\0" + names).hexdigest()


def metrics(log: Path) -> dict[str, float]:
    out = {}
    for line in log.read_text(errors="replace").splitlines():
        m = re.match(r"METRIC\s+(\S+)\s+(\S+)\s+(\S+)", line)
        if m:
            try:
                out[m.group(1)] = float(m.group(2))
            except ValueError:
                pass
    return out


def successful(test_dir: Path) -> bool:
    xml = test_dir / "test.xml"
    if not xml.is_file():
        return False
    text = xml.read_text(errors="replace")
    return re.search(r'failures="0"', text) is not None and re.search(r'errors="0"', text) is not None


def need(m: dict, key: str):
    if key not in m:
        raise SystemExit(f"missing metric {key}; rerun the benchmark with current harness")
    value = m[key]
    return int(value) if value.is_integer() else value


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit("usage: bazel run //bench:ledger -- CONFIG_ID [CORE ...]")
    ws = Path(sys.argv[1]).resolve()
    config_id = sys.argv[2]
    targets = sys.argv[3:] or list(ROUTINE)
    logs = ws / "bazel-testlogs" / "bench"
    ledger = ws / "bench" / "ledger.jsonl"

    existing = []
    if ledger.is_file():
        existing = [json.loads(line) for line in ledger.read_text().splitlines() if line.strip()]
    used = {(r["config_id"], r["target"]) for r in existing}
    duplicate = [t for t in targets if (config_id, t) in used]
    if duplicate:
        raise SystemExit(f"append-only ledger already has {config_id}: {', '.join(duplicate)}")

    lhd_repo = ws.parent / "livehd"
    common = {
        "date": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "host": platform.node(),
        "lhd_git_sha": git(lhd_repo, "rev-parse", "HEAD"),
        "lhdsuite_git_sha": git(ws, "rev-parse", "HEAD"),
        # The SHA fields name the base commits; these hashes distinguish the
        # intentionally uncommitted configurations used by this loop.
        "lhd_diff_sha256": diff_hash(lhd_repo),
        "lhdsuite_diff_sha256": diff_hash(ws),
        "config_id": config_id,
    }

    rows = []
    for target in targets:
        cold_dir = logs / f"{target}_synth"
        incr_dir = logs / f"{target}_synth_incremental"
        if not successful(cold_dir) or not successful(incr_dir):
            raise SystemExit(f"{target}: cold and incremental synthesis tests must both pass before collection")
        meta_path = cold_dir / "test.outputs" / "run_metadata.json"
        if not meta_path.is_file():
            raise SystemExit(f"{target}: missing run_metadata.json; rerun with current harness")
        meta = json.loads(meta_path.read_text())
        cm = metrics(cold_dir / "test.log")
        im = metrics(incr_dir / "test.log")
        row = dict(common)
        row.update({
            "pdk_version": meta.get("pdk_version"),
            "target": target,
            "compile_ms": need(cm, "compile_setup_ms"),
            "color_ms": need(cm, "synth_color_ms"),
            "abc_ms": need(cm, "synth_abc_ms"),
            "sta_ms": need(cm, "synth_sta_ms"),
            "synthesis_elapsed_ms": need(cm, "synthesis_elapsed_ms"),
            "regions": need(cm, "synth_regions"),
            "gates": need(cm, "synth_gates"),
            "area": need(cm, "synth_area"),
            "max_delay": need(cm, "synth_max_delay"),
            "sta_delay": need(cm, "synth_sta_delay"),
            "cache_hits": need(im, "pass2_cache_hits"),
            "cache_misses": need(im, "pass2_cache_misses"),
            "cache_hit_ms": need(im, "pass2_cache_hit_ms"),
            "cache_miss_ms": need(im, "pass2_cache_miss_ms"),
            "edit_cache_hits": need(im, "pass3_cache_hits"),
            "edit_cache_misses": need(im, "pass3_cache_misses"),
            "div_blackbox": need(cm, "synth_div_blackbox"),
        })
        if not row["pdk_version"] or not row["host"]:
            raise SystemExit(f"{target}: unusable row without pdk_version and host")
        rows.append(row)

    with ledger.open("a") as f:
        for row in rows:
            f.write(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n")
    print(f"appended {len(rows)} row(s) to {ledger}: {config_id}")


if __name__ == "__main__":
    main()
