#!/usr/bin/env python3
"""The shared result ledger for the two optimization loops.

`bench/ledger.jsonl` is one append-only file, shared by `docs/opt_loop_synth.md`
(flow="synth") and `docs/opt_loop_incr.md` (flow="incr"). Every row carries a
full identity block — host, lhd sha, lhdsuite sha, PDK version — because the ONE
thing this file must never allow is a comparison across hosts or across a
library change. A number from another box is not evidence; only a delta within
one host's ledger is (I11).

ROW SHAPE, flow="incr" — one row per (target, phase, MODE):

    {"date","host","lhd_git_sha","lhdsuite_git_sha","pdk_version",
     "flow":"incr", "target":"dino",
     "phase":"compile|synth|sim_slop|sim_llvm|sim_verilator|lec",
     "mode":"full|cold|incremental|edit", "config_id":"...", "passed":true,
     "wall_ms": 12244.0,                     // end-to-end for this phase+mode
     "phases": {"inou.prp":41234.5, ...},    // per-pass ms, from --result-json
     ...optional extras: sim_exec_ms, sim_cc_ms, abc_hits, workdir_bytes, ...}

ROW SHAPE, flow="synth" — one row per (target, config): the QoR block of
`docs/opt_loop_synth.md` M0.4 (`regions gates area max_delay sta_delay
cache_hits cache_misses cache_hit_ms cache_miss_ms div_blackbox compile_ms
color_ms abc_ms`), with no mode axis.

The four incr modes are not interchangeable, and the page says so in prose:

  full         every cache that has an off switch is off, every output dir
               fresh: what the flow costs with no incremental machinery at all.
  cold         caches on, dirs still fresh: the same work as `full` PLUS the
               cost of POPULATING the caches. `(cold-full)/full` is the price of
               admission for incrementality and is flagged past +5%.
  incremental  the identical command again over that workdir after a
               comment-only source touch. Every content-keyed cache must hit.
  edit         one small semantic edit over the same warm workdir. Only the
               work affected by that file should be redone.

Subcommands:

  add [PATH]          read json-lines (or one JSON array) of PARTIAL rows —
                      target/phase/mode/wall_ms/phases/passed — from a file or
                      stdin, stamp the identity block, append. This is the path
                      `bench/matrix.sh` feeds.
  append CFG TARGET…  scrape the most recent bazel-testlogs run and append rows
                      in the SAME shape. Scenario passes map to full / cold /
                      incremental / edit as applicable to each phase.
  render              re-derive the scoreboard HTML from the ledger.

The HTML is a pure rendering of the JSONL and is regenerated on land AND on
revert, so a measured negative result is visible rather than silently retried.
Nothing may be recorded only in the HTML.

THE RULE THIS FILE IS BUILT AROUND: a number the page cannot interpret is
rendered WITHOUT a verdict, never with a guessed one. Every silent-green path
found in review came from a two-state answer to a three-state question — is
this metric better up or down (`direction()`), did this measurement happen at
all (`verdict()` on a zero or absent reference), and is this measurement
evidence (`usable()` on a run that did not pass).
"""

import argparse
import hashlib
import html
import json
import math
import os
import re
import socket
import subprocess
import sys
import time
import traceback
from pathlib import Path

LEDGER = "bench/ledger.jsonl"

# The three columns the page is built around, in reading order, plus the two
# modes that exist but are not part of the triptych: `edit` (a real one-line
# edit — the old scraper's pass 3) and `control` (the T12 drift probe, rendered
# in the header rather than as a data row).
MODE_COLS = ("full", "cold", "incremental")
SUMMARY_MODES = MODE_COLS + ("edit",)
KNOWN_MODES = MODE_COLS + ("edit", "control")
PHASE_ORDER = (
    "compile", "synth", "sim", "sim_slop", "sim_llvm", "sim_verilator",
    "lec", "formal",
)

# `(cold-full)/full` past this is a warning: a cache that costs this much on
# every clean build has to earn it back before it is worth having.
CACHE_COST_WARN = 0.05

# Run-queue length past which a row's ABSOLUTE milliseconds stop being
# trustworthy. Deliberately low relative to the core count: the damage starts
# well before the machine is saturated, because the phases that dominate here
# (the host C++ build, ABC, the solver workers) are already parallel and are
# competing for the same cores.
LOAD_WARN = 4.0

# `drift` (the T12 control probe) this far from 1.00 invalidates the sitting.
DRIFT_WARN = 0.10

# `area` regressing past this is a guardrail breach, not a note
# (docs/opt_loop_synth.md M0.4b).
AREA_GUARDRAIL = 0.01

# The I3 guardrail columns. A regression here fails the gate no matter how good
# the compile-side columns look, which is the entire point of the scoreboard.
# A PREFIX match, so it catches both the per-mode `sim_exec_ms` of the new rows
# and the `sim_exec_ms_cold` of the old scraper's flat metrics.
GUARDRAIL_RE = re.compile(r"^(sim_exec_ms|sim_cycles_per_s)")

# Below this, a guardrail reference is process startup rather than the
# simulator, and a percentage taken against it is arithmetic on noise (trap T1):
# `xs_alu`/sim_llvm read 33 ms then 34 ms and the flat 3% epsilon called one
# millisecond an I3 VIOLATION. Such a row is reported as UNMEASURED — shown, not
# judged — which is deliberately not the same as passing. The fix is to raise
# that target's `sim_perf_cycles` until the sample clears the floor.
GUARDRAIL_FLOOR_MS = 50

# Phases with no cache off-switch: `full` and `cold` run the IDENTICAL command,
# so their difference is not an effect, it is this row's own noise sample. Using
# it as the row's epsilon is the only noise floor this page can measure rather
# than assume (H6), and it stops the page reporting its own control measurement
# as a violation.
NO_OFF_SWITCH_PHASES = ("sim", "sim_slop", "sim_llvm")


def _tokens(*words):
    """A metric name is `_`-separated tokens: `abc_max_delay_cold` is prefixed
    by its tool and suffixed by its pass. Match on whole tokens so a rule
    written for `delay` fires on `abc_max_delay_cold` and never on `delayed`."""
    return re.compile(r"(?:^|_)(?:%s)(?:_|$)" % "|".join(words))


# WHICH DIRECTION IS GOOD — and, crucially, a third answer. These two tables are
# deliberately NOT exhaustive-by-fallback: a name matching neither is UNKNOWN
# and its delta renders with no verdict (see `direction`). The bug this replaces
# was a two-way classifier whose else-branch was "higher is better", which
# rendered a 98k -> 151k `area` regression as bold green.
LOWER_IS_BETTER = _tokens(
    # time, size, work redone
    "ms", "bytes", "misses", "miss", "redone", "refused", "rewritten",
    "store_failed", "failed", "errors", "budget",
    # synthesis QoR (docs/opt_loop_synth.md M0.4) — named explicitly, because
    # every one of them is a regression when it RISES and none of them carries a
    # suffix that says so.
    "area", "gates", "cells", "regions", "delay", "max_delay", "sta_delay",
    "div_blackbox", "blackbox", "wirelength", "depth", "levels",
)
HIGHER_IS_BETTER = _tokens(
    "cycles_per_s", "speedup", "hits", "coverage", "proven",
)

# Reported, never trended: a percentage delta on a boolean or on a configured
# constant is meaningless. These still RENDER (see `section_gates` and the
# non-trend rows of the gate table) — a cycle count that CHANGED between two
# configs invalidates every exec-time comparison on the page, so it is shown and
# flagged rather than dropped.
# `cycles(?!_per_s)`: a raw cycle COUNT is a configured constant, but
# `sim_cycles_per_s` is a RATE and the second half of the I3 guardrail. Treating
# them as one token silently dropped half of I3 from the gate.
NOT_A_TREND = re.compile(
    r"(?:^|_)(?:cycles(?!_per_s)|ok|gated|present|passed|drift|equals)(?:_|$)")


def not_a_trend(m):
    """...and a guardrail column is ALWAYS a trend, whatever else it matches.
    This is the belt to the lookahead's braces: the one thing the page may never
    do is stop trending `sim_exec_ms` / `sim_cycles_per_s`."""
    return bool(NOT_A_TREND.search(m)) and not GUARDRAIL_RE.match(m)


# ...with one exception: a `*_ok` that was 1 and is now 0 is the correctness
# gate (§8 rule 5) going red. It is not a trend, but it IS a rejection.
CORRECTNESS = _tokens("ok", "equals", "proven")

# Keys that describe the row rather than measure anything.
STRUCTURAL = {
    "date", "host", "lhd_git_sha", "lhdsuite_git_sha", "pdk_version", "flow",
    "target", "phase", "mode", "config_id", "passed", "phases",
    "control_start_ms", "control_end_ms", "loadavg",
}

# A baseline/current delta is evidence only when it describes the same build
# universe.  Host partitioning happens outside the per-config gate; these are
# the remaining identity fields that must match before two numeric cells may be
# compared.  The optional diff hashes are included when either row carries one.
IDENTITY_KEYS = ("lhd_git_sha", "lhdsuite_git_sha", "pdk_version")
OPTIONAL_IDENTITY_KEYS = ("lhd_diff_sha256", "lhdsuite_diff_sha256")


def same_build_identity(a, b):
    if any(a.get(k) != b.get(k) for k in IDENTITY_KEYS):
        return False
    return all(a.get(k) == b.get(k) for k in OPTIONAL_IDENTITY_KEYS
               if k in a or k in b)

# Preferred reading order for metric rows: the two contracts' column lists
# (docs/opt_loop_incr.md H6, docs/opt_loop_synth.md M0.4), then everything else
# alphabetically. A name is matched by whole-token containment, so `abc_area`
# and `synth_area` sort where `area` does.
METRIC_ORDER = (
    "wall_ms", "cold_ms", "warm_ms", "edit_ms",
    "warm_speedup", "edit_speedup",
    "hits", "misses", "redone_ms", "refused", "store_failed",
    "sim_setup_ms", "sim_cc_ms", "sim_run_ms", "sim_exec_ms",
    "sim_cycles", "sim_perf_cycles",
    "sim_cycles_per_s", "sim_cycles_per_s_with_cc", "sim_rewritten",
    "workdir_bytes",
    "compile_ms", "color_ms", "abc_ms", "sta_ms",
    "regions", "gates", "area", "max_delay", "sta_delay",
    "cache_hits", "cache_misses", "cache_hit_ms", "cache_miss_ms",
    "div_blackbox",
)

# The QoR quartet a `div_blackbox` row may not report as numbers (T1): a design
# whose dividers were blackboxed has not been fully mapped, so its area/delay
# are not the design's.
QOR_INVALIDATED = ("area", "gates", "max_delay", "sta_delay", "regions")

# ---------------------------------------------------------------- scraping ---
# Which scenario target feeds which ledger phase, and how that scenario's flat
# `METRIC` lines split into per-mode rows. `{p}` is the pass token; the stored
# key is the template with `{p}` deleted and any orphan `_` collapsed, so
# `sim_cc_ms_cold` lands as `sim_cc_ms` and `pass1_color_ms` as `color_ms` — one
# name across modes, and the same names the two contracts use.
#
# `wall` is a LIST of templates, SUMMED. A phase is rarely one command: a sim
# rebuild is `--setup-only` plus the generated host build. Synthesis is the one-shot
# `lhd synth` flow, so its wall is the reported `*_synth_ms` rather than the old
# color+abc subtotal (which omitted compile and STA).
PASS_TOKENS = {
    "full": "_full", "cold": "_cold",
    "incremental": "_comment", "edit": "_edit",
}
NUMBERED_TOKENS = {
    "full": "full", "cold": "pass1",
    "incremental": "pass2", "edit": "pass3",
}
WARM_TOKENS = {
    "full": "_full", "cold": "_cold",
    "incremental": "_warm", "edit": "_touch",
}

PHASES = {
    "compile": {
        "target": "{core}_compile_incremental",
        "tokens": PASS_TOKENS,
        "wall": ["compile{p}_ms"],
        "extra": [
            "hits{p}", "misses{p}", "redone_ms{p}", "refused{p}",
            "store_failed{p}", "workdir_bytes{p}",
        ],
        "scenario": ["compile_warm_equals_cold", "compile_edit_changes_cold"],
    },
    "sim": {
        "target": "{core}_sim_incremental",
        "tokens": PASS_TOKENS,
        "wall": ["sim_setup{p}_ms", "sim_cc{p}_ms"],
        "extra": [
            "sim_setup{p}_ms", "sim_cc{p}_ms", "sim_rewritten{p}",
            "workdir_bytes{p}",
        ],
        "scenario": ["sim_warm_equals_cold", "sim_ninja_present"],
    },
    "sim_llvm": {
        "target": "{core}_sim_incremental_llvm",
        "tokens": PASS_TOKENS,
        "wall": ["sim_setup{p}_ms", "sim_cc{p}_ms"],
        "extra": [
            "sim_setup{p}_ms", "sim_cc{p}_ms", "sim_rewritten{p}",
            "workdir_bytes{p}",
        ],
        "scenario": ["sim_warm_equals_cold", "sim_ninja_present"],
    },
    # The outside reference has one clean-build sample rather than an
    # incremental mode sequence.  Keep its front end, host compile/link, and
    # execution split beside the LiveHD rows: a total alone cannot distinguish
    # a simulator problem from a generated-C++ compilation problem.
    "sim_verilator": {
        "target": "{core}_sim_verilator",
        "tokens": {"full": ""},
        "wall": ["sim_setup{p}_ms", "sim_cc{p}_ms", "sim_exec{p}_ms"],
        "extra": [
            "sim_setup{p}_ms", "sim_cc{p}_ms", "sim_exec{p}_ms",
            "sim_setup_warm_ms", "sim_cc_warm_ms",
            "sim_cycles{p}", "sim_cycles_per_s{p}",
            "sim_cycles_per_s_with_cc{p}", "sim_long_exec{p}_ms",
            "sim_long_cycles{p}", "sim_long_cycles_per_s{p}",
            "verilator_present",
        ],
        "scenario": [],
    },
    "synth": {
        "target": "{core}_synth_incremental",
        "tokens": NUMBERED_TOKENS,
        "wall": ["{p}_synth_ms"],
        "extra": [
            "compile_{p}_ms", "{p}_color_ms", "{p}_abc_ms",
            "{p}_sta_ms", "{p}_sta_delay",
            "{p}_cache_hits", "{p}_cache_misses",
            "{p}_cache_hit_ms", "{p}_cache_miss_ms",
            "{p}_synth_peak_rss_kb", "{p}_max_region_ms",
            "{p}_abc_peak_rss_kb",
            "{p}_regions", "{p}_gates", "{p}_area",
            "{p}_max_delay", "{p}_div_blackbox",
            *[
                "{p}_color_%s_%s" % (bucket, field)
                for bucket in ("all", "lt_1k", "1k_5k", "5k_15k",
                               "15k_25k", "ge_25k")
                for field in ("count", "ge_sum", "ms_sum")
            ],
        ],
        "scenario": ["abc_warm_speedup"],
    },
    "lec": {
        "target": "{core}_lec_incremental",
        "tokens": WARM_TOKENS,
        "wall": ["lec{p}_ms"],
        "extra": [],
        "scenario": [],
    },
    "formal": {
        "target": "{core}_verify_incremental",
        "tokens": WARM_TOKENS,
        "wall": ["verify{p}_ms"],
        "extra": [],
        "scenario": [],
    },
}


def stored_key(tmpl):
    """`sim_cc_ms{p}` -> `sim_cc_ms`; `{p}_cache_hits` -> `cache_hits`."""
    return re.sub(r"__+", "_", tmpl.format(p="")).strip("_")


def sh(*cmd, cwd=None):
    try:
        return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                              check=True).stdout.strip()
    except Exception:
        return ""


def tracked_diff_sha256(repo: Path, excludes=()):
    """Hash source/harness changes, excluding generated measurement artifacts."""
    try:
        cmd = ["git", "diff", "--binary", "HEAD", "--", "."]
        cmd.extend(":(exclude)%s" % path for path in excludes)
        diff = subprocess.run(
            cmd, cwd=repo,
            capture_output=True, check=True,
        ).stdout
    except Exception:
        return ""
    return hashlib.sha256(diff).hexdigest() if diff else ""


def identity(root: Path):
    """The block that makes a row comparable — or refuses to."""
    livehd = root.parent / "livehd"
    pdk = os.environ.get("PDK_VERSION", "")
    if not pdk:
        # Same resolution bench/common.sh uses; absent is recorded as absent,
        # never as a guess. A synthesis row without it is unusable (H6).
        # `Path(tech).name` alone recorded the literal string "lib", because the
        # tech dir ends `.../sky130_fd_sc_hd/lib/` — a value that looks like data
        # and is not. The version is the component after `versions/`.
        parts = [p for p in os.environ.get("HAGENT_TECH_DIR", "").split("/") if p]
        if "versions" in parts and parts.index("versions") + 1 < len(parts):
            pdk = parts[parts.index("versions") + 1]
        elif parts:
            pdk = next((p for p in reversed(parts) if p not in ("lib", "libs.ref")), "")
    out = {
        "host": socket.gethostname().split(".")[0],
        "lhd_git_sha": sh("git", "rev-parse", "--short", "HEAD", cwd=livehd),
        "lhdsuite_git_sha": sh("git", "rev-parse", "--short", "HEAD", cwd=root),
        "pdk_version": pdk,
    }
    for key, repo, excludes in (
            ("lhd_diff_sha256", livehd,
             ("docs/current_opt_loop_incr.html", "docs/current_opt_loop_synth.html")),
            ("lhdsuite_diff_sha256", root, (str(LEDGER),))):
        digest = tracked_diff_sha256(repo, excludes)
        if digest:
            out[key] = digest
    return out


def norm_phases(v):
    """Accept either shape of `phases` and return {name: ms}, dups summed.

    `lhd --result-json` emits the ARRAY form (ordered, one entry per executed
    step, names repeatable); the ledger row stores the MAP. Taking both here
    means a driver can paste the tool's own member straight through.
    """
    out = {}
    if isinstance(v, dict):
        items = list(v.items())
    elif isinstance(v, list):
        items = [(d.get("name"), d.get("ms")) for d in v if isinstance(d, dict)]
    else:
        return {}
    for name, ms in items:
        if name is None or ms is None:
            continue
        try:
            out[str(name)] = round(out.get(str(name), 0.0) + float(ms), 3)
        except (TypeError, ValueError):
            continue
    return out


# --------------------------------------------------------------------- add ---
def merge_rows(rows):
    """Fold rows that share (config_id, target, phase, mode) into the one row the
    contract promises. `bench/matrix.sh` deliberately times a phase as two
    commands — synth is color+abc, sim is setup+run — because what an edit costs
    is their sum; the per-pass breakdown separates them again by name.

    `config_id` IS PART OF THE IDENTITY. Without it, concatenating two sittings'
    `matrix_rows.jsonl` (an anticipated workflow) summed the baseline's wall time
    into the new config's row and then dropped the baseline row entirely: the
    measurement the whole loop is gated against, destroyed by the default path.
    """
    order, merged = [], {}
    for r in rows:
        key = (r.get("config_id"), r.get("target"), r.get("phase"), r.get("mode"))
        if key not in merged:
            merged[key] = dict(r)
            order.append(key)
            continue
        a = merged[key]
        for k, v in r.items():
            if k == "wall_ms":
                a[k] = (a.get(k) or 0.0) + (v or 0.0)
            elif k == "phases":
                p = a.setdefault("phases", {})
                for n, ms in (v or {}).items():
                    p[n] = round(p.get(n, 0.0) + ms, 3)
            elif k == "passed":
                a[k] = bool(a.get(k, True)) and bool(v)
            else:
                a[k] = v
    return [merged[k] for k in order]


def parse_json_lines(text, where):
    text = text.strip()
    if not text:
        sys.exit("FAIL: %s is empty — nothing to add" % where)
    try:  # a whole-file JSON array or a single object is accepted too
        whole = json.loads(text)
        return whole if isinstance(whole, list) else [whole]
    except json.JSONDecodeError:
        pass
    rows = []
    for n, line in enumerate(text.splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError as e:
            sys.exit("FAIL: %s line %d is not JSON: %s" % (where, n, e))
    return rows


def cmd_add(args, root: Path):
    if args.path in ("", "-", None):
        raw, where = sys.stdin.read(), "<stdin>"
    else:
        p = Path(args.path)
        if not p.is_file():
            p = root / args.path
        if not p.is_file():
            sys.exit("FAIL: no such file: %s" % args.path)
        raw, where = p.read_text(), str(p)

    ident = identity(root)
    stamp_date = time.strftime("%Y-%m-%dT%H:%M:%S")
    rows = []
    for i, r in enumerate(parse_json_lines(raw, where), 1):
        if not isinstance(r, dict):
            sys.exit("FAIL: %s row %d is not a JSON object" % (where, i))
        row = dict(r)
        for miss in ("target", "phase", "mode"):
            if not row.get(miss):
                sys.exit("FAIL: %s row %d has no `%s`" % (where, i, miss))
        if row["mode"] not in KNOWN_MODES:
            sys.exit("FAIL: %s row %d mode=%r — expected one of %s (a typo here "
                     "would silently grow a column)"
                     % (where, i, row["mode"], ", ".join(KNOWN_MODES)))
        if row.get("wall_ms") is None:
            sys.exit("FAIL: %s row %d (%s/%s/%s) has no `wall_ms`"
                     % (where, i, row["target"], row["phase"], row["mode"]))
        row["wall_ms"] = float(row["wall_ms"])
        row["phases"] = norm_phases(row.get("phases"))
        row["passed"] = bool(row.get("passed", True))
        # The identity block is stamped HERE, never taken from the driver: a
        # measurement must not be able to claim it ran on another host.
        row.update(ident)
        row["flow"] = args.flow
        row.setdefault("date", stamp_date)
        cid = row.get("config_id") or args.config_id
        if not cid:
            sys.exit("FAIL: %s row %d has no config_id and none was given "
                     "(--config-id ID)" % (where, i))
        row["config_id"] = cid
        rows.append(row)

    if args.merge:
        before = len(rows)
        rows = merge_rows(rows)
        if before != len(rows):
            print("merged %d row(s) into %d by (config_id, target, phase, mode)"
                  % (before, len(rows)))
    write_rows(root, rows, dry_run=args.dry_run)


def write_rows(root: Path, rows, dry_run=False):
    if not rows:
        sys.exit("FAIL: no rows to append")
    if dry_run:
        for r in rows:
            print(json.dumps(r, sort_keys=True))
        print("dry run — %s untouched" % LEDGER, file=sys.stderr)
        return
    dest = root / LEDGER
    dest.parent.mkdir(parents=True, exist_ok=True)
    with dest.open("a") as f:
        for r in rows:
            f.write(json.dumps(r, sort_keys=True) + "\n")
    print("appended %d row(s) to %s" % (len(rows), LEDGER))
    for r in rows:
        print("  %-10s %-8s %-12s %-14s wall=%s ms  passes=%d"
              % (r.get("target"), r.get("phase"), r.get("mode"),
                 r.get("config_id"), r.get("wall_ms"), len(r.get("phases") or {})))


# ------------------------------------------------------------------ append ---
def read_metrics(logdir: Path, target: str):
    """-> (metrics, passed, duration_ms, failed_step, reason), or None."""
    log = logdir / target / "test.log"
    if not log.is_file():
        return None
    metrics = {}
    log_text = log.read_text(errors="replace")
    errors, fail_lines = [], []
    for line in log_text.splitlines():
        stripped = line.strip()
        m = re.match(r"METRIC\s+(\S+)\s+(\S+)\s+(\S+)", line)
        if m:
            try:
                metrics[m.group(1)] = float(m.group(2))
            except ValueError:
                pass
        if line.startswith("{") and ('"severity":"error"' in line
                                      or '"status":"fail"' in line):
            try:
                event = json.loads(line)
                message = event.get("message")
                if not message and isinstance(event.get("error"), dict):
                    message = event["error"].get("message")
                if message:
                    errors.append(str(message))
            except ValueError:
                pass
        if line.startswith("FAIL:") and not line.startswith("FAIL: step '"):
            fail_lines.append(line.removeprefix("FAIL:").strip())
        elif "assert fail:" in stripped:
            fail_lines.append(stripped)
        elif " REFUTED (not equivalent)" in stripped:
            fail_lines.append(stripped.split('{"schema_version"', 1)[0].strip())
    ok = True
    duration_ms = None
    xml = logdir / target / "test.xml"
    if xml.is_file():
        t = xml.read_text(errors="replace")
        bad = int((re.search(r'failures="(\d+)"', t) or ["", "0"])[1]) + \
            int((re.search(r'errors="(\d+)"', t) or ["", "0"])[1])
        ok = bad == 0
        tm = re.search(r'<testcase\b[^>]*\btime="([0-9.]+)"', t)
        if tm:
            duration_ms = float(tm.group(1)) * 1000.0
    fm = re.search(r"FAIL: step '([^']+)' exited", log_text)
    reason = errors[-1] if errors else (fail_lines[-1] if fail_lines else "")
    return metrics, ok, duration_ms, (fm.group(1) if fm else ""), reason


def failed_step_result(logdir: Path, target: str, step: str):
    """Recover lhd's result envelope from an archived failing step log.

    A benchmark copies successful result JSON files, but a failed command used
    to exit before that copy. lhd still prints the same one-line envelope in
    the step log, so retain its phase breakdown instead of reducing a failed
    synth row to one opaque testcase duration.
    """
    path = logdir / target / "test.outputs" / ("step_%s.log" % step)
    if not path.is_file():
        return {}
    for line in reversed(path.read_text(errors="replace").splitlines()):
        line = line.strip()
        if not line.startswith("{") or '"tool":"lhd"' not in line:
            continue
        try:
            value = json.loads(line)
        except ValueError:
            continue
        if isinstance(value, dict):
            return value
    return {}


def failed_step_reason(logdir: Path, target: str, step: str):
    """Most specific diagnostic archived for one failed timed command."""
    path = logdir / target / "test.outputs" / ("step_%s.log" % step)
    if not path.is_file():
        return ""
    errors, fails = [], []
    for line in path.read_text(errors="replace").splitlines():
        line = line.strip()
        if line.startswith("{") and '"severity":"error"' in line:
            try:
                message = json.loads(line).get("message")
                if message:
                    errors.append(str(message))
            except ValueError:
                pass
        elif line.startswith("FAIL:"):
            fails.append(line.removeprefix("FAIL:").strip())
    return errors[-1] if errors else (fails[-1] if fails else "")


def qor_color_metrics(path: Path):
    """Aggregate raw QoR regions into mergeable histogram sum fields."""
    try:
        regions = (json.loads(path.read_text()).get("regions") or [])
    except (OSError, ValueError):
        return {}
    samples = []
    for region in regions:
        if not region.get("resynth", 1):
            continue
        try:
            samples.append((float(region["input_ge"]), float(region["ms"])))
        except (KeyError, TypeError, ValueError):
            continue
    bins = (
        ("all", 0, None), ("lt_1k", 0, 1_000),
        ("1k_5k", 1_000, 5_000), ("5k_15k", 5_000, 15_000),
        ("15k_25k", 15_000, 25_000),
        ("ge_25k", 25_000, None),
    )
    out = {}
    for tag, lo, hi in bins:
        selected = [(ge, ms_) for ge, ms_ in samples
                    if ge >= lo and (hi is None or ge < hi)]
        out["color_%s_count" % tag] = len(selected)
        out["color_%s_ge_sum" % tag] = sum(ge for ge, _ in selected)
        out["color_%s_ms_sum" % tag] = sum(ms_ for _, ms_ in selected)
    return out


def cmd_append(args, root: Path):
    """The bazel-testlogs scraper, emitting the NEW per-mode row shape.

    Scenario passes map to full / cold / incremental / edit as applicable to
    the phase.
    """
    logdir = root / "bazel-testlogs" / "bench"
    if not logdir.is_dir():
        sys.exit("FAIL: no bazel-testlogs/bench — run `bazel test //bench:...` first")
    ident = identity(root)
    # Synthesis resolves the PDK inside the Bazel test sandbox, where the
    # renderer's process environment cannot see it. Trust the benchmark's own
    # emitted metadata, and reject a mixed-PDK scrape instead of stamping every
    # row with a stale inherited HAGENT_TECH_DIR basename.
    pdks = set()
    for core in args.targets:
        target_name = PHASES["synth"]["target"].format(core=core)
        meta = logdir / target_name / "test.outputs" / "run_metadata.json"
        if meta.is_file():
            try:
                pdk = json.loads(meta.read_text()).get("pdk_version")
                if pdk:
                    pdks.add(pdk)
            except (OSError, ValueError):
                pass
    if len(pdks) > 1:
        sys.exit("FAIL: selected benchmark results span multiple PDKs: %s"
                 % ", ".join(sorted(pdks)))
    if pdks:
        ident["pdk_version"] = next(iter(pdks))
    now = time.strftime("%Y-%m-%dT%H:%M:%S")
    rows = []
    selected = set(args.phase or PHASES)
    for core in args.targets:
        for phase, spec in PHASES.items():
            if phase not in selected:
                continue
            target_name = spec["target"].format(core=core)
            got = read_metrics(logdir, target_name)
            if got is None:
                continue
            metrics, ok, duration_ms, failed_step, failure_reason = got
            failed_mode = None
            # The timed-command marker is authoritative even when an
            # interrupted Bazel invocation did not get to write test.xml.
            if failed_step:
                for candidate, tok in spec["tokens"].items():
                    if tok.strip("_") in failed_step:
                        failed_mode = candidate
                        break
            emitted_modes = set()
            stored_phase = phase
            if phase == "sim" and "sim_backend_llvm" in metrics:
                stored_phase = ("sim_llvm" if metrics["sim_backend_llvm"]
                                else "sim_slop")
            for mode, tok in spec["tokens"].items():
                parts = [metrics.get(t.format(p=tok)) for t in spec["wall"]]
                if all(v is None for v in parts):
                    continue
                # The contracted `wall_ms` is the SUM of the commands the phase
                # takes, matching what bench/matrix.sh writes for the same cell.
                wall = sum(v for v in parts if v is not None)
                row = dict(ident)
                row.update({
                    "date": now, "flow": args.flow, "target": core,
                    "phase": stored_phase, "mode": mode, "config_id": args.config_id,
                    # A scenario-level gate can fail after every timed mode
                    # completed (for example an incremental-vs-cold structural
                    # diff). Keep those timings usable and let its recorded
                    # correctness metric carry the hard failure. Only a named
                    # timed step invalidates its mode and the modes after it.
                    "passed": (True if failed_mode is None
                               else mode_key(mode) < mode_key(failed_mode)),
                    "wall_ms": wall, "phases": {},
                })
                if mode == failed_mode:
                    row["failed_step"] = failed_step
                    if failure_reason:
                        row["failure_reason"] = failure_reason
                if phase == "compile":
                    result_name = "compile_%s.json" % tok.removeprefix("_")
                    result_path = logdir / target_name / "test.outputs" / result_name
                    if result_path.is_file():
                        try:
                            result = json.loads(result_path.read_text())
                            row["phases"] = norm_phases(result.get("phases"))
                        except (OSError, ValueError):
                            pass
                elif phase == "synth":
                    phase_metrics = (
                        ("compile", "compile_{p}_ms"),
                        ("pass.color", "{p}_color_ms"),
                        ("pass.abc", "{p}_abc_ms"),
                        ("pass.opentimer", "{p}_sta_ms"),
                    )
                    row["phases"] = {
                        name: metrics[tmpl.format(p=tok)]
                        for name, tmpl in phase_metrics
                        if tmpl.format(p=tok) in metrics
                    }
                    # Current harnesses emit scalar histogram sums as METRIC
                    # lines. Backfill the same fields from archived QoR JSON so
                    # older completed ABC runs immediately gain the new page
                    # diagnostics without being rerun just for presentation.
                    qor = logdir / target_name / "test.outputs" / ("%s_qor.json" % tok)
                    for key, value in qor_color_metrics(qor).items():
                        row.setdefault(key, value)
                    # A scenario deliberately continues after downstream STA
                    # failures so full/cold/warm ABC evidence is not lost.
                    # Mark each invocation from its own archived result instead
                    # of invalidating every mode after the first red step.
                    result_path = logdir / target_name / "test.outputs" / ("%s_result.json" % tok)
                    if result_path.is_file():
                        try:
                            mode_result = json.loads(result_path.read_text())
                        except (OSError, ValueError):
                            mode_result = {}
                        if mode_result.get("status") == "fail":
                            step = "%s_synth" % tok
                            row["passed"] = False
                            row["failed_step"] = step
                            reason = failed_step_reason(logdir, target_name, step)
                            if reason:
                                row["failure_reason"] = reason
                for tmpl in spec["extra"]:
                    v = metrics.get(tmpl.format(p=tok))
                    if v is not None:
                        row[stored_key(tmpl)] = v
                if mode == "cold":  # scenario-wide, not per-pass
                    for k in spec["scenario"]:
                        if k in metrics:
                            row[k] = metrics[k]
                rows.append(row)
                emitted_modes.add(mode)
            # A failed timed command emits no METRIC line, but disappearing it
            # would make an unsupported full/cold pass look like a benchmark
            # that was never requested. Preserve an explicit failed cell. Its
            # duration is the test's time-to-failure and is intentionally never
            # used in a speedup or cache-cost calculation.
            if not ok and failed_mode and failed_mode not in emitted_modes:
                result = failed_step_result(logdir, target_name, failed_step)
                row = dict(ident)
                row.update({
                    "date": now, "flow": args.flow, "target": core,
                    "phase": phase, "mode": failed_mode,
                    "config_id": args.config_id, "passed": False,
                    "wall_ms": duration_ms or 0.0,
                    "phases": norm_phases(result.get("phases")),
                    "failed_step": failed_step,
                })
                if failure_reason:
                    row["failure_reason"] = failure_reason
                rows.append(row)
    if not rows:
        sys.exit("FAIL: none of the requested targets have results in bazel-testlogs")
    write_rows(root, rows, dry_run=args.dry_run)


# ------------------------------------------------------------------ render ---
def load_rows(root: Path, flow: str):
    path = root / LEDGER
    if not path.is_file():
        return []
    rows = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(r, dict) and r.get("flow") == flow:
            # Before the backend metric existed, every `sim` benchmark used
            # the default Slop engine.  Preserve the append-only ledger bytes,
            # but render that historical identity explicitly so a generic
            # `sim` row can never be mistaken for an LLVM measurement.
            if r.get("phase") == "sim":
                r = dict(r)
                r["phase"] = "sim_slop"
            rows.append(r)
    return rows


def esc(v):
    return html.escape(str(v), quote=True)


def ms(v):
    return "-" if v is None else "{:,.1f}".format(v)


def pct(v):
    return "-" if v is None else "{:+.1f}%".format(v * 100)


def num(v):
    if v is None:
        return "-"
    if isinstance(v, bool):
        return "yes" if v else "no"
    if isinstance(v, (int, float)):
        # `%g` turned a workdir byte count into `4.4e+08`, which is unreadable
        # and, worse, hides a doubling. Group instead of exponent — from four
        # digits up, so a `10,000` never sits in a column next to a `6000`.
        return "{:,.0f}".format(v) if abs(v) >= 1000 else "{:g}".format(v)
    return esc(v)


def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def direction(metric):
    """-1 lower-is-better, +1 higher-is-better, 0 UNKNOWN.

    The third state is the point. A metric this page has no rule for gets its
    delta shown and NO verdict; guessing produced a bold-green "better" on an
    `area` regression, which is the worst thing a scoreboard can do.
    """
    lo = bool(LOWER_IS_BETTER.search(metric))
    hi = bool(HIGHER_IS_BETTER.search(metric))
    if lo == hi:          # neither rule, or (impossibly) both — say so
        return 0
    return -1 if lo else 1


DIRECTION_WORD = {-1: "lower is better", 1: "higher is better",
                  0: "direction unknown"}

# verdict token -> CSS class. `unclassified` is deliberately grey, not green.
V_CLASS = {
    "better": "better", "worse": "worse", "noise": "noise",
    "I3 VIOLATION": "worse", "AREA GUARDRAIL": "worse",
    "unclassified": "unknown", "not passed": "warn",
    "not comparable": "warn",
    "CHANGED": "warn", "same": "noise", "CORRECTNESS": "worse",
    "": "miss",
}


def vcell(verd):
    return cell(verd or "-", V_CLASS.get(verd, ""))


def verdict(base, cur, dirn, eps):
    """The §8 gate, computed rather than eyeballed. Three inputs, four answers.

    A ZERO reference is not an absent one. `base=0, cur=9999` is an infinite
    regression — the old code returned ("","") for it, so an `sim_exec_ms` that
    went from 0 to 9999 rendered as a blank cell, raised no I3 breach and exited
    0. Only a genuinely missing number gets the empty verdict now.
    """
    if base is None or cur is None:
        return "", ""
    if base == 0:
        if cur == 0:
            return "+0.0%", "noise"
        d = "+&infin;%" if cur > 0 else "&minus;&infin;%"
        if dirn == 0:
            return d, "unclassified"
        return d, ("better" if ((cur < 0) if dirn < 0 else (cur > 0)) else "worse")
    delta = (cur - base) / abs(base)
    txt = "%+.1f%%" % (delta * 100)
    if abs(delta) <= eps:
        return txt, "noise"
    if dirn == 0:
        return txt, "unclassified"
    return txt, ("better" if (delta < 0 if dirn < 0 else delta > 0) else "worse")


def cell(text, cls=""):
    return '<td class="%s">%s</td>' % (cls, text)


def phase_key(p):
    p = "" if p is None else str(p)
    return (PHASE_ORDER.index(p) if p in PHASE_ORDER else len(PHASE_ORDER), p)


def mode_key(m):
    m = "" if m is None else str(m)
    return (MODE_COLS.index(m) if m in MODE_COLS else len(MODE_COLS), m)


def metric_key(m):
    for i, o in enumerate(METRIC_ORDER):
        if m == o or m.startswith(o + "_") or m.endswith("_" + o) \
                or ("_" + o + "_") in m:
            return (i, m)
    return (len(METRIC_ORDER), m)


def metrics_of(*rows):
    """Every numeric measurement on these rows, in contract order.

    A WHITELIST used to stand here (`^(wall_ms|sim_|abc_|workdir_bytes)`), and
    it silently dropped `refused`, `redone_ms`, `hits`, `misses`,
    `warm_speedup`, `edit_speedup` — all named in the H6 contract — plus every
    unprefixed synthesis QoR column. The ledger is the source of truth: if a
    number is in it, it appears on the page.
    """
    names = set()
    for r in rows:
        for k, v in (r or {}).items():
            if k not in STRUCTURAL and is_num(v):
                names.add(k)
    return sorted(names, key=metric_key)


def usable(r):
    """Is this row EVIDENCE? A run that crashed after 300 ms has a `wall_ms`,
    and reading it produced a bold-green 340x speedup on the same line that said
    FAILED. A non-passing measurement is excluded from every derived number."""
    return bool(r) and bool(r.get("passed", True))


def uwall(cells, mode):
    """`wall_ms` of a mode, or None if that mode is missing, did not pass, or
    recorded something that is not a number."""
    r = cells.get(mode)
    if not usable(r):
        return None
    v = r.get("wall_ms")
    return v if is_num(v) else None


def uval(cells, mode, key):
    r = cells.get(mode)
    if not usable(r):
        return None
    v = r.get(key)
    return v if is_num(v) else None


def index_modes(rows, cid):
    """(target, phase) -> {mode: row} for one config. A later line supersedes an
    earlier one: a re-run of the same cell replaces it rather than averaging.

    Rows with NO `mode` are skipped, not crashed on: the ledger is append-only
    and shared, so one pre-mode row in a host that also has moded rows used to
    raise `KeyError` and leave the page unwritten for EVERY host.
    """
    data = {}
    for r in rows:
        if r.get("config_id") != cid or r.get("phase") == "control":
            continue
        mode = r.get("mode")
        if not mode:
            continue
        data.setdefault((r.get("target", "?"), r.get("phase", "?")), {})[mode] = r
    return data


def any_of(cells, key):
    """The scenario-wide gates are recorded on whichever mode row carried them."""
    for mode in sorted(cells, key=mode_key):
        if key in cells[mode]:
            return cells[mode][key]
    return None


def section_wall(out, data, modes, eps, previous=None, previous_label=""):
    out.append("<h3>1. Wall clock — full vs cold vs incremental</h3>")
    out.append("<p><b>incr speedup</b> = cold / incremental: what the machinery "
               "buys on a rebuild. <b>cache cost</b> = (cold &minus; full) / full: "
               "what it charges on a first run — flagged past "
               "<b>+%.0f%%</b>. A cell reading &quot;-&quot; is a mode that was "
               "not run; it is never a zero. <b>A mode that did not pass is "
               "shown but never used</b>: its wall clock is the time to a crash, "
               "not the time to an answer, so both derived columns read "
               "&quot;-&quot;.</p>" % (CACHE_COST_WARN * 100))
    if previous:
        out.append("<p><b>previous speedup (%s)</b> is the earlier cold / "
                   "incremental ratio only. It is historical context, not a "
                   "cross-host timing comparison and never participates in a "
                   "verdict.</p>" % esc(previous_label))
    out.append("<p><b>load</b> is the 1-minute run queue while the three modes ran, "
               "highest of the three. It is not a result — it is how much to trust "
               "the row. The control probe is single-threaded and cannot see this: "
               "one desktop app pinning one core leaves the control at 36&nbsp;ms "
               "while tripling a parallel host C++ build, which is exactly what "
               "happened during the first sitting of this page. A load well above "
               "the core count means the absolute milliseconds are inflated; the "
               "<i>ratio</i> columns, measured back to back, survive it better than "
               "the raw cells do.</p>")
    out.append("<table><tr><th>target</th><th>phase</th>"
               + "".join("<th>%s (ms)</th>" % esc(m) for m in modes)
               + (("<th>previous speedup<br><small>%s</small></th>"
                   % esc(previous_label)) if previous else "")
               + "<th>incr speedup</th><th>cache cost</th><th>load</th></tr>")
    warned = []
    for target, phase in sorted(data, key=lambda k: (k[0], phase_key(k[1]))):
        cells = data[(target, phase)]
        tds = []
        for m in modes:
            r = cells.get(m)
            if r is None:
                tds.append(cell("-", "miss"))
            elif not r.get("passed", True):
                tds.append(cell("not run" if r.get("not_run") else
                                ms(r.get("wall_ms")) + " FAILED", "worse"))
            else:
                tds.append(cell(ms(r.get("wall_ms"))))
        cold, incr, full = (uwall(cells, "cold"), uwall(cells, "incremental"),
                            uwall(cells, "full"))
        if previous:
            old = previous.get((target, phase))
            tds.append(cell("-" if old is None else "%.2f&times;" % old,
                            "miss" if old is None else "una"))
        if cold is None or incr is None:
            tds.append(cell("-", "miss"))
        elif incr <= 0:
            tds.append(cell("incremental measured %s ms — not a speedup" % num(incr),
                            "warn"))
        else:
            sp = cold / incr
            tds.append(cell("%.2f&times;" % sp,
                            "better" if sp > 1 + eps else
                            ("worse" if sp < 1 - eps else "noise")))
        if full is None or cold is None:
            tds.append(cell("-", "miss"))
        elif full == 0:
            tds.append(cell("full measured 0 ms", "warn"))
        else:
            cc = (cold - full) / full
            if cc > CACHE_COST_WARN:
                warned.append("%s/%s %+.1f%%" % (target, phase, cc * 100))
                tds.append(cell(pct(cc) + " WARN", "warn"))
            else:
                tds.append(cell(pct(cc), "noise" if abs(cc) <= eps else ""))
        # How contended the box was, worst of the three modes. Shown last so it
        # reads as a qualifier on the row rather than as one of its results.
        loads = [r.get("loadavg") for r in cells.values() if is_num(r.get("loadavg"))]
        if loads:
            hi = max(loads)
            tds.append(cell("%.1f" % hi, "warn" if hi >= LOAD_WARN else ""))
        else:
            tds.append(cell("-", "miss"))
        out.append("<tr><td>%s</td><td>%s</td>%s</tr>"
                   % (esc(target), esc(phase), "".join(tds)))
    out.append("</table>")
    if warned:
        out.append('<p class="warn">cache cost over +%.0f%% on: %s — the '
                   'incremental machinery is charging a first build more than it '
                   'should.</p>' % (CACHE_COST_WARN * 100, esc(", ".join(warned))))
    return warned


def section_failures(out, data):
    """Make every red cell actionable without requiring ledger archaeology."""
    failed = []
    for (target, phase), cells in sorted(
            data.items(), key=lambda item: (item[0][0], phase_key(item[0][1]))):
        for mode, row in sorted(cells.items(), key=lambda item: mode_key(item[0])):
            if row.get("passed", True):
                continue
            reason = row.get("failure_reason") or (
                "failed step %s" % row["failed_step"] if row.get("failed_step")
                else "scenario did not pass; inspect its archived test log")
            failed.append((target, phase, mode, reason))
    if not failed:
        return
    out.append("<h3>Failed and incomplete cells</h3>")
    out.append("<p>These rows remain in the tables but are excluded from every "
               "speedup and verdict calculation.</p><ul>")
    for target, phase, mode, reason in failed:
        out.append('<li><code>%s/%s/%s</code>: %s</li>'
                   % (esc(target), esc(phase), esc(mode), esc(reason)))
    out.append("</ul>")


def section_guardrail(out, data, modes, eps):
    """I3, measured within one sitting: the mode a design was BUILT in must not
    change how fast the built thing RUNS."""
    rows_html, breached, notes = [], [], []
    for target, phase in sorted(data, key=lambda k: (k[0], phase_key(k[1]))):
        cells = data[(target, phase)]
        keys = sorted({k for r in cells.values() for k in r if GUARDRAIL_RE.match(k)})
        for k in keys:
            ref_mode = "full" if uval(cells, "full", k) is not None else "cold"
            ref = uval(cells, ref_mode, k)
            # This row's own epsilon. `full` vs `cold` on a phase with no cache
            # off-switch is the same command twice, so it measures this row's
            # noise; nothing inside it can be a verdict in either direction.
            row_eps, eps_note = eps, ""
            twin = uval(cells, "cold" if ref_mode == "full" else "full", k)
            if (phase in NO_OFF_SWITCH_PHASES and ref not in (None, 0)
                    and twin is not None):
                measured = abs(twin - ref) / abs(ref)
                if measured > row_eps:
                    row_eps = measured
                    eps_note = "%.1f%% measured" % (measured * 100)
            below_floor = (k.startswith("sim_exec_ms") and ref is not None
                           and ref < GUARDRAIL_FLOOR_MS)
            tds, verds = [], []
            for m in modes:
                r = cells.get(m)
                v = (r or {}).get(k)
                if r is None or not is_num(v):
                    tds.append(cell("-", "miss"))
                elif not usable(r):
                    tds.append(cell(num(v) + " FAILED", "worse"))
                else:
                    tds.append(cell(num(v)))
            for m in modes:
                if m == ref_mode:
                    verds.append(cell("ref", "noise"))
                    continue
                if not usable(cells.get(m)):
                    verds.append(cell("-" if cells.get(m) is None else "not passed",
                                      "miss" if cells.get(m) is None else "warn"))
                    continue
                v = uval(cells, m, k)
                if v is None or ref is None:
                    verds.append(cell("-", "miss"))
                    continue
                d, verd = verdict(ref, v, direction(k), row_eps)
                if below_floor:
                    # Shown, never judged: see GUARDRAIL_FLOOR_MS.
                    verds.append(cell("%s below floor" % (d or "-"), "una"))
                    continue
                if verd == "worse":
                    verd = "I3 VIOLATION"
                    breached.append("%s/%s %s (%s)" % (target, phase, k, m))
                verds.append(cell("%s %s%s" % (d or "-", verd or "-",
                                               " [eps %s]" % eps_note if eps_note and verd == "noise" else ""),
                                  V_CLASS.get(verd, "")))
            if ref is None:
                notes.append("%s/%s %s (no usable %s-mode reference)"
                             % (target, phase, k, ref_mode))
            elif below_floor:
                notes.append("%s/%s %s (reference %s ms is under the %d ms floor "
                             "— raise sim_perf_cycles, trap T1)"
                             % (target, phase, k, num(ref), GUARDRAIL_FLOOR_MS))
            rows_html.append('<tr class="guard"><td>%s</td><td>%s</td><td>%s</td>'
                             '%s%s</tr>' % (esc(target), esc(phase), esc(k),
                                            "".join(tds), "".join(verds)))
    out.append("<h3>2. I3 guardrail — the built thing's own speed</h3>")
    if not rows_html:
        out.append("<p>no <code>sim_exec_ms</code> / <code>sim_cycles_per_s</code> "
                   "rows in this config — the guardrail is unmeasured, which is "
                   "not the same as held.</p>")
        return []
    out.append("<p>Each mode against the <b>reference</b> mode (full, or cold "
               "when full was not run). Incremental reuse must not produce a "
               "slower binary: a regression here rejects the change regardless "
               "of net wall time (&sect;8.3). A reference of <b>0</b> with a "
               "non-zero mode is an infinite regression, not an absent one. "
               "Two floors keep this column honest rather than merely strict: "
               "on <code>sim</code>/<code>sim_slop</code>/<code>sim_llvm</code> the <code>full</code> "
               "vs <code>cold</code> pair is the SAME command run twice, so its "
               "spread is this row's measured epsilon (shown as "
               "<code>[eps N%% measured]</code>) and the page never reports its "
               "own noise sample as a violation; and a reference under %d&nbsp;ms "
               "is process startup rather than the simulator (T1), so those "
               "rows read <i>below floor</i> &mdash; unmeasured, which is not "
               "the same as passing.</p>" % GUARDRAIL_FLOOR_MS)
    out.append("<table><tr><th>target</th><th>phase</th><th>metric</th>"
               + "".join("<th>%s</th>" % esc(m) for m in modes)
               + "".join("<th>%s vs ref</th>" % esc(m) for m in modes) + "</tr>")
    out.extend(rows_html)
    out.append("</table>")
    if notes:
        out.append('<p class="warn">UNMEASURED guardrail — nothing in these rows '
                   'is cleared, and an absent guardrail is not a held one: %s</p>'
                   % esc("; ".join(notes)))
    if breached:
        out.append('<p class="worse">I3 GUARDRAIL BREACHED on: %s</p>'
                   % esc(", ".join(breached)))
    return breached


# Metrics §3 owns as named columns; they are not repeated in §4.
GATE_KEYS = ("sim_warm_equals_cold", "compile_warm_equals_cold", "compile_edit_changes_cold", "sim_rewritten", "abc_store_failed",
             "store_failed", "abc_refused", "refused", "workdir_bytes",
             "sim_ninja_present")


def section_gates(out, data):
    out.append("<h3>3. Non-time gates</h3>")
    out.append("<p>The gates a time-only scoreboard tempts you to forget (&sect;8.4): "
               "<code>store_failed</code> must be 0, <code>refused</code> must be "
               "<i>attributed</i> (a principled refusal is data, an unexplained "
               "one is a bug), warm must equal cold (structurally for compile, "
               "byte for byte for generated simulation), a compile edit fixture "
               "must actually change the graph, and cache size "
               "is a cost.</p>")
    out.append("<table><tr><th>target</th><th>phase</th><th>passed (per mode)</th>"
               "<th>warm==cold</th><th>edit changed</th><th>rewritten</th><th>store_failed</th>"
               "<th>refused</th><th>workdir bytes</th></tr>")
    breached = []
    for target, phase in sorted(data, key=lambda k: (k[0], phase_key(k[1]))):
        cells = data[(target, phase)]
        marks = []
        for m in sorted(cells, key=mode_key):
            ok = cells[m].get("passed", True)
            marks.append("%s=%s" % (m, "yes" if ok else "NO"))
        bad = any(not c.get("passed", True) for c in cells.values())
        wec = any_of(cells, "compile_warm_equals_cold")
        if wec is None:
            wec = any_of(cells, "sim_warm_equals_cold")
        changed = any_of(cells, "compile_edit_changes_cold")
        sf = any_of(cells, "abc_store_failed")
        if sf is None:
            sf = any_of(cells, "store_failed")
        ref = any_of(cells, "refused")
        if ref is None:
            ref = any_of(cells, "abc_refused")
        wb = any_of(cells, "workdir_bytes")
        if wec not in (None, True, 1, 1.0):
            breached.append("%s/%s warm != cold" % (target, phase))
        if changed not in (None, True, 1, 1.0):
            breached.append("%s/%s edit fixture did not change the graph" %
                            (target, phase))
        if sf:
            breached.append("%s/%s store_failed=%s" % (target, phase, num(sf)))
        out.append("<tr><td>%s</td><td>%s</td>%s<td class='%s'>%s</td><td class='%s'>%s</td>"
                   "<td>%s</td><td class='%s'>%s</td><td class='%s'>%s</td>"
                   "<td>%s</td></tr>"
                   % (esc(target), esc(phase),
                      cell(esc(" ".join(marks)), "worse" if bad else ""),
                      "" if wec in (None, True, 1, 1.0) else "worse",
                      "-" if wec is None else ("yes" if wec else "NO"),
                      "" if changed in (None, True, 1, 1.0) else "worse",
                      "-" if changed is None else ("yes" if changed else "NO"),
                      num(any_of(cells, "sim_rewritten")),
                      "worse" if sf else "", num(sf),
                      "warn" if ref else "", num(ref), num(wb)))
    out.append("</table>")
    if breached:
        out.append('<p class="worse">NON-TIME GATE FAILED on: %s</p>'
                   % esc(", ".join(breached)))
    return breached


def section_other(out, data, modes):
    """Everything else the ledger recorded, per mode. No verdict is invented
    here: the baseline-to-current gate below is where deltas are judged. The
    point of this table is that NOTHING in the ledger is silently dropped."""
    body = []
    for target, phase in sorted(data, key=lambda k: (k[0], phase_key(k[1]))):
        cells = data[(target, phase)]
        names = [m for m in metrics_of(*cells.values())
                 if m != "wall_ms" and not GUARDRAIL_RE.match(m)
                 and m not in GATE_KEYS]
        for m in names:
            tds = "".join(cell(num((cells.get(k) or {}).get(m)),
                               "" if (cells.get(k) or {}).get(m) is not None
                               else "miss") for k in modes)
            if not_a_trend(m):
                word, cls = "reported, not trended", "noise"
            else:
                dirn = direction(m)
                word, cls = DIRECTION_WORD[dirn], "noise" if dirn else "unknown"
            body.append("<tr><td>%s</td><td>%s</td><td><code>%s</code></td>%s%s</tr>"
                        % (esc(target), esc(phase), esc(m), tds,
                           cell(word, cls)))
    out.append("<h3>4. Other recorded metrics</h3>")
    if not body:
        out.append("<p>no further metrics on these rows.</p>")
        return
    out.append("<p>Every remaining number on the rows, per mode — the contract's "
               "cache columns (<code>hits</code>, <code>misses</code>, "
               "<code>redone_ms</code> &mdash; the I4 number), the synthesis QoR "
               "block, and anything a driver added since. The last column is "
               "what this page knows about the metric: a "
               "<span class=\"unknown\">direction unknown</span> metric is "
               "reported and never given a verdict.</p>")
    out.append("<table><tr><th>target</th><th>phase</th><th>metric</th>"
               + "".join("<th>%s</th>" % esc(m) for m in modes)
               + "<th>direction</th></tr>")
    out.extend(body)
    out.append("</table>")


def section_breakdown(out, data, modes):
    out.append("<h3>5. Where the time goes — per-pass breakdown</h3>")
    out.append("<p>One table per (target, phase). <b>Sorted by cold-mode ms, "
               "descending</b>, so the pass that owns the rebuild is the first "
               "row. Each mode's percent column is that pass's share of that "
               "mode's wall clock; <b>(unattributed)</b> is wall minus the sum "
               "of the reported passes, so the column adds to 100%.</p>")
    empty = []
    for target, phase in sorted(data, key=lambda k: (k[0], phase_key(k[1]))):
        cells = data[(target, phase)]
        maps = {m: norm_phases(cells[m].get("phases")) for m in cells}
        if not any(maps.values()):
            empty.append("%s/%s" % (target, phase))
            continue
        names = sorted({n for mm in maps.values() for n in mm})

        def sortkey(n):
            cold = maps.get("cold", {}).get(n)
            best = max([mm.get(n, 0.0) for mm in maps.values()] or [0.0])
            return (0 if cold is not None else 1, -(cold or 0.0), -best, n)

        names.sort(key=sortkey)
        out.append("<h4>%s / %s</h4>" % (esc(target), esc(phase)))
        out.append("<table><tr><th>pass</th>"
                   + "".join("<th>%s ms</th><th>%s %%</th>" % (esc(m), esc(m))
                             for m in modes) + "</tr>")

        def emit(label, values, cls=""):
            tds = []
            for m in modes:
                r, v = cells.get(m), values.get(m)
                wall = (r or {}).get("wall_ms")
                if r is None:
                    tds.append(cell("-", "miss") + cell("-", "miss"))
                    continue
                tds.append(cell(ms(v)))
                tds.append(cell("-" if (v is None or not wall)
                                else "%.1f%%" % (100.0 * v / wall)))
            out.append('<tr class="%s"><td>%s</td>%s</tr>'
                       % (cls, label, "".join(tds)))

        for n in names:
            emit("<code>%s</code>" % esc(n),
                 {m: maps.get(m, {}).get(n) for m in modes})
        una, tot = {}, {}
        for m in modes:
            r = cells.get(m)
            if r is None:
                continue
            wall = r.get("wall_ms")
            s = sum(maps.get(m, {}).values())
            tot[m] = wall
            if wall is not None:
                una[m] = round(wall - s, 3)
        emit("(unattributed)", una, "una")
        emit("<b>total (wall)</b>", tot, "total")
        out.append("</table>")
    if empty:
        out.append("<p><i>no per-pass data recorded for: %s</i> — the command "
                   "ran without <code>--result-json</code>, so only its wall "
                   "clock is known.</p>" % esc(", ".join(empty)))


COLOR_HIST_BINS = (
    ("lt_1k", "&lt;1k"),
    ("1k_5k", "1k–5k"),
    ("5k_15k", "5k–15k"),
    ("15k_25k", "15k–25k"),
    ("ge_25k", "&ge;25k"),
)


def section_color_hist(out, data):
    """Mapped color size/time distribution; cache hits are not synth samples."""
    rows = []
    by_target = {}
    for (target, phase), cells in data.items():
        if phase != "synth":
            continue
        for mode, row in cells.items():
            count = row.get("color_all_count")
            if count is None:
                continue
            rows.append(row)
            by_target.setdefault(target, {})[mode] = row

    out.append("<h3>6. ABC color-size / synthesis-time histogram</h3>")
    if not rows:
        out.append("<p>No per-color samples were recorded by this configuration. "
                   "Re-run synthesis with the current harness; failed STA rows still "
                   "contribute when ABC completed.</p>")
        return

    out.append("<p>All <b>resynthesized</b> colors recorded across full, cold, and "
               "incremental runs. Cache hits are excluded because their milliseconds "
               "measure snapshot loading, not ABC synthesis. A failed downstream STA "
               "run remains useful here when its QoR file is complete.</p>")

    totals = {}
    for key, _ in COLOR_HIST_BINS:
        count = sum(float(r.get("color_%s_count" % key, 0) or 0) for r in rows)
        ge_sum = sum(float(r.get("color_%s_ge_sum" % key, 0) or 0) for r in rows)
        ms_sum = sum(float(r.get("color_%s_ms_sum" % key, 0) or 0) for r in rows)
        totals[key] = (count, ge_sum, ms_sum)
    peak = max([v[0] for v in totals.values()] or [0])
    out.append("<table><tr><th>input GE bucket</th><th>histogram</th>"
               "<th>mapped colors</th><th>avg input GE</th><th>avg ABC ms</th></tr>")
    for key, label in COLOR_HIST_BINS:
        count, ge_sum, ms_sum = totals[key]
        width = 0 if peak <= 0 else max(1, round(28 * count / peak))
        bar = "&#9608;" * width
        out.append("<tr><td>%s</td><td class='bar'>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>"
                   % (label, bar, num(count),
                      "-" if count <= 0 else num(ge_sum / count),
                      "-" if count <= 0 else ms(ms_sum / count)))
    out.append("</table>")

    out.append("<h4>Per-design color summary</h4>")
    out.append("<table><tr><th rowspan='2'>target</th>"
               "<th colspan='3'>full (incrementality off)</th>"
               "<th colspan='3'>cold (cache population)</th>"
               "<th colspan='3'>warm incremental (remapped only)</th></tr>"
               "<tr><th>colors</th><th>avg GE</th><th>avg ABC ms</th>"
               "<th>colors</th><th>avg GE</th><th>avg ABC ms</th>"
               "<th>colors</th><th>avg GE</th><th>avg ABC ms</th></tr>")
    for target, cells in sorted(by_target.items()):
        def mode_cells(mode):
            row = cells.get(mode)
            if row is None or row.get("color_all_count") is None:
                return ("-", "-", "-")
            count = float(row.get("color_all_count", 0) or 0)
            ge_sum = float(row.get("color_all_ge_sum", 0) or 0)
            ms_sum = float(row.get("color_all_ms_sum", 0) or 0)
            return (num(count), "-" if count <= 0 else num(ge_sum / count),
                    "-" if count <= 0 else ms(ms_sum / count))
        values = mode_cells("full") + mode_cells("cold") + mode_cells("incremental")
        out.append("<tr><td>%s</td>%s</tr>" %
                   (esc(target), "".join("<td>%s</td>" % value for value in values)))
    out.append("</table>")


def plain(d):
    """The delta strings carry HTML entities (`+&infin;%`) because they are
    written into the page; the same string also reaches a stderr banner, where
    an entity is noise."""
    return (d or "-").replace("&infin;", "inf").replace("&minus;", "-")


def brief(items, n=6, sep=", "):
    """A banner names the first few and counts the rest: an unbounded list in a
    stderr line is as unreadable as no line."""
    items = list(items)
    if len(items) <= n:
        return sep.join(items)
    return sep.join(items[:n]) + " (+%d more)" % (len(items) - n)


def missing_config_note(out, which, cid, here, everywhere):
    """A typo'd --baseline used to render a header and an empty table, which
    reads exactly like a gate that ran and found nothing wrong."""
    known = ", ".join(sorted(c for c in everywhere if c)) or "(none)"
    mine = ", ".join(sorted(c for c in here if c)) or "(none)"
    if cid not in everywhere:
        out.append('<p class="worse">NO SUCH CONFIG: <code>%s</code> was given '
                   'as the %s but appears on <b>no row in the ledger</b> — the '
                   '&sect;8 gate did not run. config_ids in this flow: <b>%s</b>.'
                   '</p>' % (esc(cid), esc(which), esc(known)))
        return True
    out.append('<p class="warn">%s <code>%s</code> was not measured on this host, '
               'so the &sect;8 gate cannot run here (I11 — a number from another '
               'box is not a baseline). config_ids on this host: <b>%s</b>.</p>'
               % (esc(which), esc(cid), esc(mine)))
    return False


def section_config_delta(out, hrows, base_id, cur_id, eps):
    """The §8 accept/reject gate: this config against the loop's baseline, in
    the SAME mode and build identity. Never across hosts, modes, revisions, or
    PDK snapshots."""
    base, cur = index_modes(hrows, base_id), index_modes(hrows, cur_id)
    out.append("<h3>7. &sect;8 gate — baseline <code>%s</code> &rarr; current "
               "<code>%s</code></h3>" % (esc(base_id), esc(cur_id)))
    if base_id == cur_id:
        out.append("<p>only one config_id on this host yet — nothing to gate "
                   "against. The baseline column does not move once set "
                   "(&sect;9.6).</p>")
        return [], [], []
    out.append("<table><tr><th>target</th><th>phase</th><th>mode</th><th>metric</th>"
               "<th>baseline</th><th>current</th><th>&Delta;</th><th>verdict</th></tr>")
    breached, regressed, incomparable = [], [], []
    for key in sorted(set(base) | set(cur), key=lambda k: (k[0], phase_key(k[1]))):
        bm, cm = base.get(key, {}), cur.get(key, {})
        for mode in sorted(set(bm) | set(cm), key=mode_key):
            b, c = bm.get(mode, {}), cm.get(mode, {})
            ok = usable(b) and usable(c)
            same_identity = bool(b) and bool(c) and same_build_identity(b, c)
            for m in metrics_of(b, c):
                bv, cv = b.get(m), c.get(m)
                if not is_num(bv) and not is_num(cv):
                    continue
                if not (is_num(bv) and is_num(cv)):
                    d, verd = "", ""   # one side simply was not measured
                elif not same_identity:
                    d, verd = "identity changed", "not comparable"
                    incomparable.append("%s/%s (%s)" % (key[0], key[1], mode))
                elif not_a_trend(m):
                    # Shown, not trended — and a CHANGE here invalidates the
                    # time columns above it rather than being a regression.
                    verd = "same" if bv == cv else "CHANGED"
                    d = "-" if bv == cv else "not comparable"
                    if CORRECTNESS.search(m) and bv and not cv:
                        verd, d = "CORRECTNESS", "1 &rarr; 0"
                        regressed.append("%s/%s %s (%s) went 1 -> 0"
                                         % (key[0], key[1], m, mode))
                elif not ok:
                    verd, d = "not passed", "-"
                else:
                    d, verd = verdict(bv if is_num(bv) else None,
                                      cv if is_num(cv) else None,
                                      direction(m), eps)
                    if verd == "worse":
                        if GUARDRAIL_RE.match(m):
                            verd = "I3 VIOLATION"
                            breached.append("%s/%s %s (%s)"
                                            % (key[0], key[1], m, mode))
                        else:
                            # §8 rule 2: no number regresses past the noise
                            # floor. Rendering that red and exiting 0 leaves the
                            # gate to be eyeballed, which is what the page is for.
                            regressed.append("%s/%s %s (%s) %s"
                                             % (key[0], key[1], m, mode,
                                                plain(d)))
                out.append('<tr class="%s"><td>%s</td><td>%s</td><td>%s</td>'
                           '<td>%s</td><td>%s</td><td>%s</td><td>%s</td>%s</tr>'
                           % ("guard" if GUARDRAIL_RE.match(m) else "",
                              esc(key[0]), esc(key[1]), esc(mode), esc(m),
                              num(bv), num(cv), d or "-", vcell(verd)))
    out.append("</table>")
    if breached:
        out.append('<p class="worse">I3 GUARDRAIL BREACHED vs baseline on: %s</p>'
                   % esc(", ".join(breached)))
    if regressed:
        out.append('<p class="worse">REJECTED by the &sect;8 gate — a number '
                   'regressed past the %.1f%% noise floor (rule 2: a lever must '
                   'not pay for one column with another), or a correctness '
                   'metric flipped (rule 5): %s</p>'
                   % (eps * 100, esc(", ".join(regressed))))
    if incomparable:
        out.append('<p class="warn">NOT COMPARED across build identities (LiveHD, '
                   'lhdsuite, PDK, or recorded dirty diff): %s. Re-measure the '
                   'baseline with the same identity before treating these cells '
                   'as an accept/reject gate.</p>'
                   % esc(brief(sorted(set(incomparable)), 10)))
    return breached, regressed, sorted(set(incomparable))


# ------------------------------------------------------- flat / synth shape ---
def flat_index(hrows, cid):
    """(target, phase, mode) -> row, for rows that have no mode axis (every
    flow=synth row, and anything written before the axis existed)."""
    got = {}
    for r in hrows:
        if r.get("config_id") != cid or r.get("phase") == "control":
            continue
        got[(str(r.get("target", "?")), r.get("phase") or "",
             r.get("mode") or "")] = r
    return got


def render_flat_host(out, hrows, base_id, cur_id, eps, synth):
    """Rows with no full/cold/incremental axis: one baseline-vs-current table.

    Returns (hard, warn) — and it MUST return them. The previous version
    computed a `breached` list, dropped it on the floor and left the caller's
    `hard_any` empty, so a legacy I3 breach printed inside the page and still
    exited 0 with no banner: the one machine-readable signal, lost.
    """
    base, cur = flat_index(hrows, base_id), flat_index(hrows, cur_id)
    hard, warn, identity_mismatch = [], [], []
    if synth:
        out.append("<p>The synthesis QoR gate (docs/opt_loop_synth.md M0.4b). "
                   "<code>sta_delay</code> is the authority and "
                   "<code>max_delay</code> the cheap signal (R3); the two moving "
                   "in <b>opposite directions</b> stops a land until it is "
                   "explained. <code>area</code> regressing past <b>%.0f%%</b> is "
                   "a guardrail breach, and a non-zero <code>div_blackbox</code> "
                   "makes that row's QoR cells <b>invalid</b> rather than "
                   "numbers (T1).</p>" % (AREA_GUARDRAIL * 100))
    else:
        out.append("<p><i>These rows predate the full/cold/incremental axis: "
                   "rendered in the older baseline-vs-current shape.</i></p>")
    keys = sorted(set(base) | set(cur),
                  key=lambda k: (k[0], phase_key(k[1]), mode_key(k[2])))
    show_phase = any(k[1] for k in keys)
    show_mode = any(k[2] for k in keys)
    head = "<th>target</th>"
    if show_phase:
        head += "<th>phase</th>"
    if show_mode:
        head += "<th>mode</th>"
    out.append("<table><tr>" + head + "<th>metric</th><th>baseline</th>"
               "<th>current</th><th>&Delta;</th><th>verdict</th></tr>")
    for key in keys:
        b, c = base.get(key, {}), cur.get(key, {})
        ok = usable(b) and usable(c)
        same_identity = bool(b) and bool(c) and same_build_identity(b, c)
        # T1: a blackboxed divider means the design was not fully mapped, so its
        # QoR numbers are not the design's. Do not let them average into a "no
        # regression" claim.
        blackboxed = any(is_num(r.get(k)) and r.get(k)
                         for r in (b, c) for k in r if "div_blackbox" in k)
        moved = {}
        for m in metrics_of(b, c):
            bv, cv = b.get(m), c.get(m)
            if not is_num(bv) and not is_num(cv):
                continue
            invalid = blackboxed and any(q in m for q in QOR_INVALIDATED)
            if not (is_num(bv) and is_num(cv)):
                d, verd = "", ""   # one side simply was not measured
            elif not same_identity:
                d, verd = "identity changed", "not comparable"
                identity_mismatch.append("/".join(x for x in key if x))
            elif not_a_trend(m):
                verd = "same" if bv == cv else "CHANGED"
                d = "-" if bv == cv else "not comparable"
                if CORRECTNESS.search(m) and bv and not cv:
                    verd, d = "CORRECTNESS", "1 &rarr; 0"
                    hard.append("correctness gate (§8 rule 5): %s %s went 1 -> 0"
                                % ("/".join(x for x in key if x), m))
            elif invalid:
                verd, d = "", "invalid (div_blackbox)"
            elif not ok:
                verd, d = "not passed", "-"
            else:
                d, verd = verdict(bv if is_num(bv) else None,
                                  cv if is_num(cv) else None,
                                  direction(m), eps)
                where = "/".join(x for x in key if x)
                if GUARDRAIL_RE.match(m) and verd == "worse":
                    verd = "I3 VIOLATION"
                    hard.append("I3 guardrail breached: %s %s %s"
                                % (where, m, plain(d)))
                else:
                    if verd in ("better", "worse", "noise") \
                            and is_num(bv) and is_num(cv) and bv:
                        rel = (cv - bv) / abs(bv)
                        # `area` past +1% is a guardrail breach, not a note
                        # (docs/opt_loop_synth.md M0.4b).
                        if synth and "area" in m and rel > AREA_GUARDRAIL:
                            verd = "AREA GUARDRAIL"
                            hard.append("area guardrail (>+%.0f%%): %s %s %+.1f%%"
                                        % (AREA_GUARDRAIL * 100, where, m,
                                           rel * 100))
                        if "sta_delay" in m:
                            moved["sta"] = rel
                        elif "max_delay" in m:
                            moved["max"] = rel
                    if verd == "worse":
                        hard.append("regressed (§8 rule 2): %s %s %s"
                                    % (where, m, plain(d)))
            cols = "<td>%s</td>" % esc(key[0])
            if show_phase:
                cols += "<td>%s</td>" % esc(key[1])
            if show_mode:
                cols += "<td>%s</td>" % esc(key[2])
            out.append('<tr class="%s">%s<td><code>%s</code></td><td>%s</td>'
                       '<td>%s</td><td>%s</td>%s</tr>'
                       % ("guard" if GUARDRAIL_RE.match(m) else "", cols,
                          esc(m), num(bv), num(cv), d or "-", vcell(verd)))
        if blackboxed:
            warn.append("%s div_blackbox non-zero — QoR cells invalid"
                        % "/".join(x for x in key if x))
        if len(moved) == 2 and moved["sta"] * moved["max"] < 0 \
                and max(abs(moved["sta"]), abs(moved["max"])) > eps:
            warn.append("%s max_delay %+.1f%% and sta_delay %+.1f%% moved in "
                        "OPPOSITE directions (§4.4 rule 3 — stop and explain)"
                        % ("/".join(x for x in key if x),
                           moved["max"] * 100, moved["sta"] * 100))
    out.append("</table>")
    if identity_mismatch:
        warn.append("not compared across build identities: %s"
                    % brief(sorted(set(identity_mismatch)), 10))
    if warn:
        out.append('<p class="warn">%s</p>' % esc("; ".join(warn)))
    if hard:
        out.append('<p class="worse">HARD: %s</p>' % esc(", ".join(hard)))
    return hard, warn


STYLE = """
body{font:14px/1.5 -apple-system,Segoe UI,Roboto,sans-serif;margin:2rem;max-width:82rem}
table{border-collapse:collapse;margin:1rem 0;width:100%}
th,td{border:1px solid #bbb;padding:.25rem .5rem;text-align:right}
th:first-child,td:first-child,th:nth-child(2),td:nth-child(2){text-align:left}
th{background:#eee}
th.sortable{cursor:pointer;user-select:none;white-space:nowrap}
th.sortable::after{content:" ⇅";color:#888;font-size:.8em}
th.sortable[aria-sort="ascending"]::after{content:" ↑";color:#111}
th.sortable[aria-sort="descending"]::after{content:" ↓";color:#111}
h2{border-top:3px solid #333;padding-top:.6rem;margin-top:2.5rem}
h4{margin:1.2rem 0 0}
.better{color:#0a0;font-weight:bold}.worse{color:#c00;font-weight:bold}
.warn{color:#a60;font-weight:bold}.noise{color:#888}.miss{color:#999}
.unknown{color:#66c;font-style:italic}
.guard{background:#fff6f6}.una{color:#666}.total{background:#f7f7f7;font-weight:bold}
.geomean td{background:#f7f7f7;font-weight:bold;border-top:2px solid #777}
code{background:#f4f4f4;padding:0 .2rem}
dt{font-weight:bold;margin-top:.4rem}
"""

SORTABLE_TABLES_JS = r"""
<script>
(function () {
  var collator = typeof Intl !== 'undefined' && Intl.Collator
    ? new Intl.Collator(undefined, {numeric: true})
    : {compare: function (a, b) { return a < b ? -1 : a > b ? 1 : 0; }};

  function key(cell) {
    if (!cell || cell.classList.contains('miss') || /FAILED/.test(cell.textContent || '')) return null;
    var raw = cell.getAttribute('data-sort');
    if (raw !== null && raw !== '') return {number: true, value: Number(raw)};
    var text = (cell.textContent || '').replace(/\s+/g, ' ').trim();
    return text && text !== '-' ? {number: false, value: text} : null;
  }

  document.querySelectorAll('table.sortable-table').forEach(function (table) {
    var body = table.tBodies[0];
    if (!body || body.rows.length < 2) return;
    var headers = table.tHead ? table.tHead.rows[0].cells : [];
    var original = Array.prototype.slice.call(body.rows);
    var state = null;

    Array.prototype.forEach.call(headers, function (th, column) {
      th.classList.add('sortable');
      th.tabIndex = 0;
      th.title = 'Sort by ' + (th.textContent || 'this column').trim();
      function activate() {
        if (!state || state.column !== column) state = {column: column, dir: 1};
        else if (state.dir === 1) state.dir = -1;
        else state = null;

        Array.prototype.forEach.call(headers, function (other) {
          other.removeAttribute('aria-sort');
        });
        var rows = Array.prototype.slice.call(body.rows);
        if (!state) rows = original.slice();
        else {
          th.setAttribute('aria-sort', state.dir === 1 ? 'ascending' : 'descending');
          rows = rows.map(function (row, index) {
            return {row: row, index: index, key: key(row.cells[column])};
          }).sort(function (a, b) {
            if (a.key === null || b.key === null) {
              if (a.key === null && b.key === null) return a.index - b.index;
              return a.key === null ? 1 : -1;
            }
            var d = a.key.number && b.key.number
              ? a.key.value - b.key.value
              : collator.compare(String(a.key.value), String(b.key.value));
            return d ? state.dir * d : a.index - b.index;
          }).map(function (entry) { return entry.row; });
        }
        rows.forEach(function (row) { body.appendChild(row); });
      }
      th.addEventListener('click', activate);
      th.addEventListener('keydown', function (event) {
        if (event.key === 'Enter' || event.key === ' ') {
          event.preventDefault();
          activate();
        }
      });
    });
  });
})();
</script>
"""

VERDICT_PROSE = """
<p><b>The verdict column has four states, not two.</b>
<span class="better">better</span> / <span class="worse">worse</span> is a move
past the epsilon in the direction this page knows the metric runs;
<span class="noise">noise</span> is inside it; and
<span class="unknown">unclassified</span> means <b>this page has no direction
rule for that metric</b> — the delta is shown and deliberately NOT judged,
because a guessed direction paints a regression green. Add the name to
<code>LOWER_IS_BETTER</code> / <code>HIGHER_IS_BETTER</code> in
<code>bench/ledger.py</code> to give it a verdict.</p>
"""

MODE_PROSE = """
<h2>What the four timing columns mean</h2>
<dl>
<dt>full</dt><dd>&mdash; Every cache is <b>off</b> (the one switch
<code>lhd.incremental=false</code> covers the compile, pass.abc, pass.opentimer,
and formal caches), every output
directory fresh. This is what the flow costs with <b>no incremental machinery at
all</b>: the honest denominator.</dd>
<dt>cold</dt><dd>&mdash; Caches <b>on</b>, every directory still fresh: the same
work as <code>full</code> <b>plus the cost of populating the caches</b>. The
difference is the price of admission for incrementality, charged on every clean
build.</dd>
<dt>no-change incremental</dt><dd>&mdash; The <b>identical command again</b> over that
workdir, after a comment-only touch to the source. Nothing semantic changed, so
every content-keyed cache must hit. This is the number the loop exists to
move.</dd>
<dt>one-file edit</dt><dd>&mdash; One small semantic edit, built over the same
warm workdir. Only work affected by that file should be redone.</dd>
</dl>
<p>Both speedups use <code>full</code> as their denominator:
<code>full / no-change</code> and <code>full / edit</code>. The cold incremental
sample is shown to expose cache-population cost, but it is never the denominator
of a displayed speedup.</p>
<p>The <b>Compile only</b> table is the dedicated <code>lhd compile</code>
incremental benchmark. <b>Synthesis &minus; STA</b> is compile + color + ABC and
excludes OpenTimer. In the edit-only <b>colors changed</b> column, simulation
uses the number of rewritten simulator units and synthesis uses ABC cache
misses (the colors resynthesized).</p>
<p>Where a phase has no cache off-switch today, <code>full</code> and
<code>cold</code> run the same command and are expected to match within noise —
that is a measurement, not redundancy.</p>
"""


def render_host(out, host, hrows, args, eps, all_configs):
    """Everything for one host. Returns the list of hard-failure strings.

    The banner slot is reserved BEFORE any section runs and filled afterwards
    WHATEVER happens, including a renderer bug: a host section that ends without
    a verdict line reads as a section that found nothing wrong. The page is
    written first and always — this file is append-only and shared, so one bad
    row must cost that row its section, never every host's page.
    """
    configs = []
    for r in hrows:
        if r.get("config_id") not in configs:
            configs.append(r.get("config_id"))
    base_id = args.baseline or configs[0]
    cur_id = args.current or configs[-1]
    current_rows = [r for r in hrows if r.get("config_id") == cur_id]
    newest = max(current_rows or hrows, key=lambda r: str(r.get("date") or ""))
    heading = "h3" if getattr(args, "_multi_current", False) else "h2"
    out.append("<%s>host: %s</%s>" % (heading, esc(host), heading))
    out.append(
        "<p>lhd <code>%s</code> &middot; lhdsuite <code>%s</code> &middot; "
        "pdk <code>%s</code><br>baseline <b>%s</b> &rarr; current <b>%s</b> "
        "(latest row %s)</p>"
        % (esc(newest.get("lhd_git_sha", "?")),
           esc(newest.get("lhdsuite_git_sha", "?")),
           esc(newest.get("pdk_version", "")) or "<i>unset</i>",
           esc(base_id), esc(cur_id), esc(newest.get("date", "?"))))

    banner_at = len(out)
    out.append("")            # reserved before anything else can throw
    try:
        hard, warned, measured = host_sections(
            out, hrows, args, eps, all_configs, configs, base_id, cur_id)
    except Exception:
        hard, warned, measured = (
            ["renderer crashed on this host's rows"], [], True)
        out.append('<p class="worse">RENDERER ERROR on host %s — the rows below '
                   'this point were not rendered. This is a bug in '
                   'bench/ledger.py, not a result.</p><pre>%s</pre>'
                   % (esc(host), esc(traceback.format_exc())))
    fill_banner(out, banner_at, hard, warned, measured, cur_id)
    return hard


def host_sections(out, hrows, args, eps, all_configs, configs, base_id, cur_id):
    """Every table for one host, below its banner."""
    hard, warned = [], []

    # A named config that is not here at all is a TYPO, and a typo must not
    # render as a gate that ran and passed.
    for which, cid in (("baseline", base_id), ("current", cur_id)):
        if cid not in configs:
            if missing_config_note(out, which, cid, configs, all_configs):
                hard.append("%s config_id %r does not exist in the ledger"
                            % (which, cid))
            else:
                warned.append("%s %s not measured on this host" % (which, cid))

    drifts = [r for r in hrows
              if r.get("phase") == "control" and r.get("config_id") == cur_id]
    if drifts:
        out.append("<p>control probe (trap T12 — this class of box throttles "
                   "mid-session): %s. A drift far from 1.00 means no absolute "
                   "number in this sitting compares to another's.</p>"
                   % "; ".join(
                       "%s %s ms &rarr; %s ms (%s&times;)"
                       % (esc(r.get("target", "?")), num(r.get("control_start_ms")),
                          num(r.get("control_end_ms")), num(r.get("drift")))
                       for r in drifts))
        # The error bar on the whole sitting. Past this, the numbers below are
        # the box changing speed, not the change under test.
        bad = ["%s %sx" % (r.get("target", "?"), num(r.get("drift")))
               for r in drifts
               if is_num(r.get("drift")) and abs(r["drift"] - 1.0) > DRIFT_WARN]
        if bad:
            warned.append("control drift past %.0f%% (T12 — this sitting's "
                          "absolute numbers are not comparable): %s"
                          % (DRIFT_WARN * 100, ", ".join(bad)))

    moded = [r for r in hrows if r.get("mode") and r.get("phase") != "control"]
    flat = [r for r in hrows if not r.get("mode") and r.get("phase") != "control"]
    data = index_modes(hrows, cur_id) if args.flow != "synth" else {}
    measured = bool(data) or bool(flat_index(hrows, base_id)) \
        or bool(flat_index(hrows, cur_id))

    if args.flow == "synth":
        # The synthesis loop has no mode axis: every row is one measured
        # configuration of one target (docs/opt_loop_synth.md M0.4).
        h, w = render_flat_host(out, hrows, base_id, cur_id, eps, synth=True)
        hard += h
        warned += w
    elif data:
        present = {m for cells in data.values() for m in cells}
        modes = list(MODE_COLS) + sorted(present - set(MODE_COLS), key=mode_key)
        warned += section_wall(out, data, modes, eps,
                               getattr(args, "_previous_speedups", None),
                               getattr(args, "_previous_label", ""))
        section_failures(out, data)
        breach = section_guardrail(out, data, modes, eps)
        non_time_breach = section_gates(out, data)
        section_other(out, data, modes)
        section_breakdown(out, data, modes)
        section_color_hist(out, data)
        gate_breach, regressed, incomparable = section_config_delta(
            out, hrows, base_id, cur_id, eps)
        breach += gate_breach
        if incomparable:
            warned.append("baseline identity differs on %s"
                          % brief(incomparable, 6))
        if breach:
            hard.append("I3 guardrail breached (%d): %s"
                        % (len(breach), ", ".join(breach)))
        if non_time_breach:
            hard.append("non-time gate failed (%d): %s"
                        % (len(non_time_breach), ", ".join(non_time_breach)))
        if regressed:
            hard.append("rejected by the §8 gate (%d): %s"
                        % (len(regressed), brief(regressed)))
        failed = sorted({"%s/%s (%s)" % (t, p, m)
                         for (t, p), cs in data.items() for m, r in cs.items()
                         if not r.get("passed", True)})
        stored = sorted({"%s/%s" % (t, p) for (t, p), cs in data.items()
                         if any_of(cs, "abc_store_failed") or any_of(cs, "store_failed")})
        if failed:
            hard.append("did not pass: " + ", ".join(failed))
        if stored:
            hard.append("store_failed non-zero on: " + ", ".join(stored))
        if flat:
            out.append("<h3>8. Rows with no mode axis</h3>")
            h, w = render_flat_host(out, flat, base_id, cur_id, eps, synth=False)
            hard += h
            warned += w
    else:
        if moded:
            out.append("<p>no <b>moded</b> data rows for config <b>%s</b> on this "
                       "host.</p>" % esc(cur_id))
        if flat:
            h, w = render_flat_host(out, flat, base_id, cur_id, eps, synth=False)
            hard += h
            warned += w
        elif not moded:
            out.append("<p>no data rows for config <b>%s</b> on this host.</p>"
                       % esc(cur_id))

    return hard, warned, measured


def fill_banner(out, banner_at, hard, warned, measured, cur_id):
    if hard:
        out[banner_at] = ('<p class="worse">HARD FAILURE &mdash; %s</p>'
                          % esc(brief(hard, 8, "; ")))
    elif not measured:
        # "no hard failure" over an empty section reads as a pass. It is not one.
        out[banner_at] = ('<p class="warn">NOTHING MEASURED for config <b>%s</b> '
                          'on this host — this section clears nothing.%s</p>'
                          % (esc(cur_id),
                             " " + esc(brief(warned, 8, "; ")) if warned else ""))
    elif warned:
        out[banner_at] = ('<p class="warn">no hard failure; %s</p>'
                          % esc(brief(warned, 8, "; ")))
    else:
        out[banner_at] = '<p class="better">no hard failure on this host.</p>'



def glance_rows(hrows, cid):
    """(target, phase) -> {mode: row} for one config, ready for the summary."""
    data = {}
    for r in hrows:
        if r.get("config_id") != cid or r.get("phase") == "control":
            continue
        if r.get("mode") not in SUMMARY_MODES:
            continue
        # A config_id names one immutable experiment.  If an accidental rerun
        # is appended under the same id, preserve the original cell instead of
        # silently changing the published result; intentional reruns need a
        # new config_id.
        data.setdefault((r.get("target"), r.get("phase")), {}).setdefault(
            r["mode"], r)
    return data


def glance_takeaway(data):
    """The one sentence a reader should leave with, COMPUTED not authored.

    Splits the phases into those the machinery does nothing for and those it
    does, because that split is the actual state of the loop and it is the first
    thing anyone wants. Deriving it means it cannot drift from the table under
    it — the moment `compile` starts reusing, this sentence changes by itself.
    """
    per_phase = {}
    for (target, phase), cells in data.items():
        cold, incr = uwall(cells, "cold"), uwall(cells, "incremental")
        if cold and incr and incr > 0:
            per_phase.setdefault(phase, []).append(cold / incr)
    if not per_phase:
        return ""
    flat = sorted(p for p, v in per_phase.items() if max(v) < 1.1)
    live = {p: v for p, v in per_phase.items() if max(v) >= 1.1}
    bits = []
    if flat:
        n = max(len(per_phase[p]) for p in flat)
        bits.append("<b>%s</b> gets nothing from the incremental machinery "
                    "(&le;1.1&times; on all %d target(s) measured)"
                    % (esc(", ".join(flat)), n))
    if live:
        lo = min(min(v) for v in live.values())
        hi = max(max(v) for v in live.values())
        best = max(((max(v), p) for p, v in live.items()))
        bits.append("%s reuse at <b>%.1f&times;&ndash;%.0f&times;</b> (best: %s)"
                    % (esc(", ".join(sorted(live))), lo, hi, esc(best[1])))
    return "; ".join(bits) + "."


SUMMARY_TABLES = (
    ("Simulation compile — SLOP", ("sim_slop",), "wall", "sim_rewritten"),
    ("Simulation compile — LLVM", ("sim_llvm",), "wall", "sim_rewritten"),
    ("Compile only", ("compile",), "wall", None),
    ("Synthesis − STA", ("synth",), "synth_no_sta", "cache_misses"),
    ("Synthesis", ("synth",), "wall", None),
    ("LEC", ("lec",), "wall", None),
)

SUMMARY_PHASE_LABELS = {
    "sim_slop": "SLOP",
    "sim_llvm": "LLVM",
    "compile": "",
    "synth": "",
    "lec": "",
}


def sortable_cell(text, value=None, cls=""):
    attr = (' data-sort="%.12g"' % value) if is_num(value) else ""
    return '<td class="%s"%s>%s</td>' % (cls, attr, text)


def timing_value(cells, mode, metric):
    row = cells.get(mode)
    if row is None or not usable(row):
        return None
    if metric == "wall":
        return row.get("wall_ms")
    if metric == "compile":
        return row.get("compile_ms")
    if metric == "synth_no_sta":
        values = [row.get(key) for key in ("compile_ms", "color_ms", "abc_ms")]
        return sum(values) if all(is_num(value) for value in values) else None
    raise ValueError("unknown summary timing metric: %s" % metric)


def timing_cell(cells, mode, metric):
    row = cells.get(mode)
    if row is None:
        return sortable_cell("-", cls="miss")
    value = timing_value(cells, mode, metric)
    if not usable(row):
        failed_value = row.get("wall_ms") if metric == "wall" else None
        text = (ms(failed_value) + " " if is_num(failed_value) else "") + "FAILED"
        return sortable_cell(text, cls="worse")
    if not is_num(value):
        return sortable_cell("-", cls="miss")
    return sortable_cell(ms(value), value=value)


def colors_changed_cell(cells, changed_metric):
    row = cells.get("edit")
    value = row.get(changed_metric) if usable(row) else None
    if not is_num(value):
        return sortable_cell("-", cls="miss")
    return sortable_cell("%g" % value, value=value)


def speedup_cell(full, rebuilt):
    if not is_num(full) or not is_num(rebuilt) or rebuilt <= 0:
        return sortable_cell("-", cls="miss"), None
    value = full / rebuilt
    cls = speedup_class(value)
    return sortable_cell("%.2f&times;" % value, value=value, cls=cls), value


def speedup_class(value):
    return "better" if value >= 1.1 else "worse" if value < 0.95 else "noise"


def geometric_mean(values):
    values = [v for v in values if is_num(v) and v > 0]
    if not values:
        return None
    return math.exp(sum(math.log(v) for v in values) / len(values))


def section_glance(out, data, show_host=None, previous=None, previous_label=""):
    """The incremental dashboard: one sortable table per requested flow.

    `previous` is intentionally ignored here. This report has one reference
    internal to every row: the same run's full, cache-disabled build.
    """
    del previous, previous_label
    if not data:
        return
    if show_host:
        out.append("<h3>host: %s</h3>" % esc(show_host))

    for title, phases, metric, changed_metric in SUMMARY_TABLES:
        keys = sorted((key for key in data if key[1] in phases),
                      key=lambda key: (key[0], phase_key(key[1])))
        show_backend = len(phases) > 1
        out.append("<h2>%s</h2>" % esc(title))
        if not keys:
            out.append('<p class="warn">No %s incremental measurements in this '
                       'configuration.</p>' % esc(title.lower()))
            continue
        out.append("<table class=\"sortable-table\"><thead><tr>"
                   "<th>design</th>" + ("<th>backend</th>" if show_backend else "") +
                   "<th>full<br><small>caches off (ms)</small></th>"
                   "<th>cold incremental<br><small>fresh cache (ms)</small></th>"
                   "<th>no-change incremental<br><small>comment edit (ms)</small></th>"
                   "<th>no-change speedup<br><small>full / no-change</small></th>"
                   "<th>one-file edit<br><small>warm cache (ms)</small></th>"
                   "<th>edit speedup<br><small>full / edit</small></th>"
                   + ("<th>colors changed<br><small>one-file edit %s</small></th>"
                      % ("rewritten sim units" if changed_metric == "sim_rewritten"
                         else "ABC misses") if changed_metric else "") +
                   "</tr></thead><tbody>")
        nochange_speedups, edit_speedups = [], []
        for target, phase in keys:
            cells = data[(target, phase)]
            full = timing_value(cells, "full", metric)
            nochange = timing_value(cells, "incremental", metric)
            edit = timing_value(cells, "edit", metric)
            nochange_cell, nochange_speedup = speedup_cell(full, nochange)
            edit_cell, edit_speedup = speedup_cell(full, edit)
            if nochange_speedup is not None:
                nochange_speedups.append(nochange_speedup)
            if edit_speedup is not None:
                edit_speedups.append(edit_speedup)
            out.append("<tr><td>%s</td>%s%s%s%s%s%s%s%s</tr>" % (
                esc(target),
                ("<td>%s</td>" % esc(SUMMARY_PHASE_LABELS.get(phase, phase)))
                if show_backend else "",
                timing_cell(cells, "full", metric),
                timing_cell(cells, "cold", metric),
                timing_cell(cells, "incremental", metric), nochange_cell,
                timing_cell(cells, "edit", metric), edit_cell,
                colors_changed_cell(cells, changed_metric) if changed_metric else "",
            ))
        out.append("</tbody><tfoot><tr class=\"geomean\"><td%s>geomean</td>"
                   % (" colspan=\"2\"" if show_backend else ""))
        out.append(sortable_cell("-", cls="miss") * 3)
        gm_nochange = geometric_mean(nochange_speedups)
        nochange_text = ("-" if gm_nochange is None else
                         "%.2f&times; <small>(n=%d)</small>" %
                         (gm_nochange, len(nochange_speedups)))
        out.append(sortable_cell(nochange_text, value=gm_nochange,
                                 cls="miss" if gm_nochange is None else
                                 speedup_class(gm_nochange)))
        out.append(sortable_cell("-", cls="miss"))
        gm_edit = geometric_mean(edit_speedups)
        edit_text = ("-" if gm_edit is None else
                     "%.2f&times; <small>(n=%d)</small>" %
                     (gm_edit, len(edit_speedups)))
        out.append(sortable_cell(edit_text, value=gm_edit,
                                 cls="miss" if gm_edit is None else
                                 speedup_class(gm_edit)))
        if changed_metric:
            out.append(sortable_cell("-", cls="miss"))
        out.append("</tr></tfoot></table>")


def cmd_render(args, root: Path):
    rows = load_rows(root, args.flow)
    if not rows:
        sys.exit("FAIL: %s holds no flow=%s rows yet" % (LEDGER, args.flow))
    eps = args.epsilon / 100.0

    # A previous ratio is the one explicitly permitted historical column: it
    # carries no delta or verdict. Keep its source host out of the current
    # section and retain only cold/incremental, a dimensionless within-run
    # ratio.
    args._previous_speedups = {}
    args._previous_label = ""
    if args.previous:
        previous_rows = [r for r in rows if r.get("config_id") == args.previous]
        previous_data = index_modes(previous_rows, args.previous)
        for key, cells in previous_data.items():
            cold, incr = uwall(cells, "cold"), uwall(cells, "incremental")
            if cold is not None and incr is not None and incr > 0:
                args._previous_speedups[key] = cold / incr
        dates = sorted(str(r.get("date") or "")[:10] for r in previous_rows
                       if r.get("date"))
        args._previous_label = dates[-1] if dates else args.previous

    # One section per host. Never a cross-host diff (I11): different boxes are
    # different experiments that happen to share a file.
    by_host = {}
    for r in rows:
        by_host.setdefault(r.get("host", "?"), []).append(r)
    if args.host:
        if args.host not in by_host:
            sys.exit("FAIL: host %r has no flow=%s rows" % (args.host, args.flow))
        by_host = {args.host: by_host[args.host]}
    all_configs = {r.get("config_id") for r in rows}

    also_current = getattr(args, "also_current", [])
    requested_currents = ([args.current] if args.current else []) + also_current
    if not requested_currents:
        requested_currents = [""]

    # An incremental report is a snapshot of the explicitly selected run(s),
    # not every historical host preserved in the append-only ledger.  Keep the
    # host count and host headings scoped to those selections as well.
    if args.flow == "incr":
        selected_ids = {cid for cid in requested_currents if cid}
        if selected_ids:
            selected_hosts = {
                r.get("host", "?") for r in rows
                if r.get("config_id") in selected_ids
            }
            by_host = {
                host: hrows for host, hrows in by_host.items()
                if host in selected_hosts
            }

    render_cmd = ["bazel run -c opt //bench:ledger -- render", "--flow", args.flow]
    for flag, value in (("--out", args.out), ("--baseline", args.baseline),
                        ("--current", args.current), ("--previous", args.previous),
                        ("--host", args.host)):
        if value:
            render_cmd.extend((flag, value))
    for value in also_current:
        render_cmd.extend(("--also-current", value))
    if args.epsilon != 3.0:
        render_cmd.extend(("--epsilon", str(args.epsilon)))

    report_rule = (
        "Every speedup is computed within one row against that row's "
        "<b>full, caches-off build</b>; cold incremental is displayed but is "
        "not a speedup denominator."
        if args.flow == "incr" else
        "Verdicts use an epsilon of <b>%.1f%%</b>; anything inside it is not a win."
        % args.epsilon
    )
    out = [
        "<title>%s</title>" % esc(args.title),
        "<style>%s</style>" % STYLE,
        "<h1>%s</h1>" % esc(args.title),
        "<p>Generated from <code>%s</code> at %s. Derived, never authored — "
        "re-run <code>%s</code> to refresh. %s "
        "<b>%d host section(s) — never compare a number across them</b> "
        "(I11).</p>"
        % (LEDGER, time.strftime("%Y-%m-%d %H:%M"), esc(" ".join(render_cmd)),
           report_rule, len(by_host)),
    ]
    if args.flow == "incr":
        out.append("<p>Synthesis resource policy: one shared color sizing for "
                   "every design; ABC uses soft per-color guards of "
                   "<b>16 GiB peak RSS</b> and <b>15 minutes</b>. "
                   "<code>abc_peak_rss_kb</code> is the maximum conservative per-color RSS growth before STA; "
                   "<code>synth_peak_rss_kb</code> is the conservative whole-process "
                   "diagnostic and is <b>not</b> a benchmark rejection threshold. "
                   "Whole-process RSS may exceed 16 GiB during STA; only an actual "
                   "tool failure marks the run failed. Incremental simulation stops "
                   "after compiling and linking <code>drv.bin</code>; it does not run "
                   "the testbench. Its wall clock is setup/codegen plus the generated "
                   "host build.</p>")

    # THE HEADLINE, before any methodology. One block per host, because a
    # cross-host summary is exactly the comparison I11 forbids; with a single
    # host this is simply the top of the page.
    if args.flow != "synth":
        out.append("<h2>At a glance</h2>")
        for selected in requested_currents:
            if args.flow == "incr" or len(requested_currents) > 1:
                out.append("<h3>configuration: <code>%s</code></h3>" % esc(selected))
            for host, hrows in sorted(by_host.items()):
                cid = selected or (
                    [r.get("config_id") for r in hrows if r.get("config_id")] or [""])[-1]
                data = glance_rows(hrows, cid)
                fallback_keys = []
                if args.flow == "incr" and args.previous and cid != args.previous:
                    for key, cells in glance_rows(hrows, args.previous).items():
                        if key not in data:
                            data[key] = cells
                            fallback_keys.append(key)
                if fallback_keys:
                    fallback_phases = sorted({phase for _, phase in fallback_keys}, key=phase_key)
                    out.append("<p>Fresh measurements come from <code>%s</code>. "
                               "Unrerun %s tables retain <code>%s</code>; every "
                               "speedup remains within one configuration row.</p>" %
                               (esc(cid), esc(", ".join(fallback_phases)), esc(args.previous)))
                section_glance(out, data,
                               show_host=host if args.flow == "incr" or len(by_host) > 1 else None,
                               previous=args._previous_speedups,
                               previous_label=args._previous_label)

    # ...and the methodology below it, collapsed. It is load-bearing (a reader
    # who does not know what `full` means will misread every number above) but
    # it is reference material, and a status page must open on status.
    if args.flow == "incr":
        out.append("<details><summary><b>How to read this page</b> — full, cold, "
                   "no-change, edit, and the speedup denominator</summary>")
        out.append(MODE_PROSE)
        out.append("</details>")
        out.append(SORTABLE_TABLES_JS.strip())
        dest = Path(args.out)
        if not dest.is_absolute():
            dest = root.parent / "livehd" / args.out
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text("\n".join(out) + "\n")
        print("wrote %s (%d row(s), %d host(s))" %
              (dest, len(rows), len(by_host)))
        return

    out.append("<details><summary><b>How to read this page</b> — verdict "
               "states</summary>")
    out.append(VERDICT_PROSE)
    out.append("</details>")

    hard_any = []
    for selected in requested_currents:
        section_args = argparse.Namespace(**vars(args))
        section_args.current = selected
        section_args._multi_current = len(requested_currents) > 1
        if section_args._multi_current:
            out.append("<h2>Detailed results — configuration: <code>%s</code></h2>"
                       % esc(selected))
        for host, hrows in sorted(by_host.items()):
            try:
                hard = render_host(out, host, hrows, section_args, eps, all_configs)
            except Exception:
                # `render_host` already contains the per-section guard; this is the
                # last resort for its own header. Either way the page still gets
                # written — the ledger is append-only and shared, and an unwritable
                # page is a one-way trap.
                hard = ["renderer crashed before this host's header"]
                out.append('<p class="worse">RENDERER ERROR on host %s.</p>'
                           '<pre>%s</pre>'
                           % (esc(host), esc(traceback.format_exc())))
            if hard:
                hard_any.append("%s/%s: %s"
                                % (host, selected or "latest", brief(hard, 8, "; ")))

    dest = Path(args.out)
    if not dest.is_absolute():
        dest = root.parent / "livehd" / args.out
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text("\n".join(out) + "\n")
    print("wrote %s (%d row(s), %d host(s))" % (dest, len(rows), len(by_host)))
    # §9.5 regenerates the page on land and on revert, so a non-zero exit must
    # never cost you the rendering.
    if hard_any:
        for h in hard_any:
            print("HARD FAILURE %s" % h, file=sys.stderr)
        if args.fail_on_regression:
            sys.exit(1)


def main():
    root = Path(os.environ.get("BUILD_WORKSPACE_DIRECTORY", ".")).resolve()
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    d = sub.add_parser("add", help="append driver-produced json-lines rows")
    d.add_argument("path", nargs="?", default="-",
                   help="json-lines file of partial rows, or - for stdin")
    d.add_argument("--config-id", default="",
                   help="config_id for rows that do not carry their own")
    d.add_argument("--flow", default="incr", choices=["incr", "synth"])
    d.add_argument("--no-merge", dest="merge", action="store_false",
                   help="keep rows that share (config_id, target, phase, mode) "
                        "separate instead of summing them into the one "
                        "contracted row")
    d.add_argument("--dry-run", action="store_true",
                   help="print the stamped rows, do not touch the ledger")
    d.set_defaults(fn=cmd_add, merge=True)

    a = sub.add_parser("append", help="scrape bazel-testlogs into the ledger")
    a.add_argument("config_id")
    a.add_argument("targets", nargs="+")
    a.add_argument("--flow", default="incr", choices=["incr", "synth"])
    a.add_argument("--phase", action="append", choices=sorted(PHASES),
                   help="append only this phase (repeatable)")
    a.add_argument("--dry-run", action="store_true")
    a.set_defaults(fn=cmd_append)

    r = sub.add_parser("render", help="regenerate the scoreboard HTML")
    r.add_argument("--flow", default="incr", choices=["incr", "synth"])
    r.add_argument("--out", default="")
    r.add_argument("--title", default="")
    r.add_argument("--baseline", default="", help="config_id of the baseline column")
    r.add_argument("--current", default="", help="config_id of the current column")
    r.add_argument("--also-current", action="append", default=[], metavar="CONFIG_ID",
                   help="render another at-a-glance table and detailed section; "
                        "repeat for additional measurement configurations")
    r.add_argument("--previous", default="",
                   help="config_id supplying historical speedups and, on the incremental dashboard, phases absent from --current")
    r.add_argument("--host", default="",
                   help="render only this host (historical speedup may still come from --previous)")
    r.add_argument("--epsilon", type=float, default=3.0,
                   help="noise floor, in percent (H6); a delta inside it is not a win")
    r.add_argument("--fail-on-regression", action="store_true",
                   help="exit 1 if any host has a hard failure (I3 breach, a "
                        "non-passing mode, store_failed). The page is written "
                        "either way.")
    r.set_defaults(fn=cmd_render)

    args = ap.parse_args()
    if args.cmd == "render":
        args.out = args.out or "current_opt_loop_%s.html" % args.flow
        args.title = args.title or ("Incremental rebuild speedup — full vs "
                                    "no-change and one-file edit" if args.flow == "incr"
                                    else "Synthesis QoR loop")
    args.fn(args, root)


if __name__ == "__main__":
    main()
