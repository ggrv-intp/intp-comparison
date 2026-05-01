#!/usr/bin/env python3
"""
validate-intp-coverage.py

Validate representativeness criteria for the 7 IntP metrics from an aggregated TSV.

Input TSV must contain, at minimum:
- workload
- cpu, llcmr, llcocc, mbw, blk, netp, nets

Optional:
- env, variant (for filtering)

The script compares workload means against an idle baseline row (workload=idle)
and checks if each metric changes by at least `--min-delta-pct` in >= 2 workloads.
"""

from __future__ import annotations

import argparse
import csv
import math
import sys
from collections import defaultdict

METRICS = ["cpu", "llcmr", "llcocc", "mbw", "blk", "netp", "nets"]


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Validate IntP metric representativeness")
    p.add_argument("--input", required=True, help="TSV with workload-level metric means")
    p.add_argument("--env", default=None, help="Optional env filter (e.g., bare)")
    p.add_argument("--variant", default=None, help="Optional variant filter (e.g., v4)")
    p.add_argument("--idle-name", default="idle", help="Idle workload name")
    p.add_argument("--min-delta-pct", type=float, default=20.0, help="Min change vs idle to count as varied")
    p.add_argument("--min-workloads-per-metric", type=int, default=2, help="Minimum varied workloads per metric")
    return p.parse_args()


def read_rows(path: str):
    with open(path, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f, delimiter="\t")
        for row in reader:
            yield row


def to_float(value: str) -> float:
    try:
        return float(value)
    except Exception:
        return math.nan


def safe_pct_delta(value: float, baseline: float) -> float:
    if math.isnan(value) or math.isnan(baseline):
        return math.nan
    if baseline == 0.0:
        return math.inf if value != 0.0 else 0.0
    return ((value - baseline) / abs(baseline)) * 100.0


def main() -> int:
    args = parse_args()

    filtered = []
    for row in read_rows(args.input):
        if args.env is not None and row.get("env") != args.env:
            continue
        if args.variant is not None and row.get("variant") != args.variant:
            continue
        filtered.append(row)

    if not filtered:
        print("ERROR: no data after applying filters", file=sys.stderr)
        return 2

    idle_rows = [r for r in filtered if r.get("workload") == args.idle_name]
    if not idle_rows:
        print("ERROR: idle baseline not found", file=sys.stderr)
        return 2

    workloads = [r for r in filtered if r.get("workload") != args.idle_name]
    if not workloads:
        print("ERROR: no active workloads to validate", file=sys.stderr)
        return 2

    baseline = {}
    idle = idle_rows[0]
    for m in METRICS:
        baseline[m] = to_float(idle.get(m, "nan"))

    varied_by_metric = defaultdict(list)
    dominant_count = defaultdict(int)

    for r in workloads:
        w = r.get("workload", "unknown")
        top_metric = None
        top_delta = -1.0
        for m in METRICS:
            v = to_float(r.get(m, "nan"))
            d = abs(safe_pct_delta(v, baseline[m]))
            if math.isnan(d):
                continue
            if d >= args.min_delta_pct:
                varied_by_metric[m].append(w)
            if d > top_delta:
                top_delta = d
                top_metric = m
        if top_metric is not None:
            dominant_count[top_metric] += 1

    print("== Coverage by metric ==")
    all_ok = True
    for m in METRICS:
        ws = sorted(set(varied_by_metric[m]))
        ok = len(ws) >= args.min_workloads_per_metric
        all_ok = all_ok and ok
        status = "OK" if ok else "FAIL"
        print(f"{status}\t{m}\tworkloads={len(ws)}\t{','.join(ws) if ws else '-'}")

    print("\n== Metric dominance ==")
    # Criterion: no single metric should dominate all workloads.
    total_workloads = len(workloads)
    for m in METRICS:
        print(f"{m}\t{dominant_count[m]}/{total_workloads}")

    dominates_all = any(dominant_count[m] == total_workloads for m in METRICS)
    if dominates_all:
        print("FAIL\ta single metric dominates all workloads")
        all_ok = False
    else:
        print("OK\tno single metric dominates 100% of workloads")

    # Soft checks for methodology-specific expectations.
    print("\n== Methodology checks ==")

    llcocc_mbw_jobs = ["kmeans", "pagerank", "bayes"]
    for m in ["llcocc", "mbw"]:
        touched = [w for w in llcocc_mbw_jobs if w in set(varied_by_metric[m])]
        if len(touched) >= 1:
            print(f"OK\t{m} responded in ML/graph ({','.join(touched)})")
        else:
            print(f"WARN\t{m} without clear response in ML/graph")

    net_jobs = ["terasort", "pagerank", "sql_nweight"]
    net_hits = set(varied_by_metric["netp"]) | set(varied_by_metric["nets"])
    net_touched = sorted([w for w in net_jobs if w in net_hits])
    if net_touched:
        print(f"OK\tnetp/nets sustained in shuffle-heavy ({','.join(net_touched)})")
    else:
        print("FAIL\tnetp/nets without a convincing shuffle-heavy workload")
        all_ok = False

    return 0 if all_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
