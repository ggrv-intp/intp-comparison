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
    p.add_argument(
        "--baseline-mode",
        choices=["auto", "idle", "min"],
        default="auto",
        help="Baseline strategy: idle row, or per-metric minimum when idle is unavailable (default: auto)",
    )
    p.add_argument("--min-delta-pct", type=float, default=20.0, help="Min change vs idle to count as varied")
    p.add_argument("--min-workloads-per-metric", type=int, default=2, help="Minimum varied workloads per metric")
    p.add_argument(
        "--readiness-mode",
        choices=["strict", "capability-aware"],
        default="capability-aware",
        help="Readiness policy: strict requires all 7 metrics; capability-aware allows SKIP for likely-unavailable metrics",
    )
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


def finite_metric_values(rows, metric: str) -> list[float]:
    vals = [to_float(r.get(metric, "nan")) for r in rows]
    return [v for v in vals if not math.isnan(v)]


def likely_unavailable_metric(values: list[float], baseline: float, eps: float = 1e-9) -> bool:
    if not values:
        return True
    if math.isnan(baseline):
        return all(abs(v) <= eps for v in values)
    return all(abs(v) <= eps for v in values) and abs(baseline) <= eps


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
    workloads = [r for r in filtered if r.get("workload") != args.idle_name]
    if not workloads:
        print("ERROR: no active workloads to validate", file=sys.stderr)
        return 2

    baseline = {}
    baseline_source = ""
    if idle_rows:
        idle = idle_rows[0]
        for m in METRICS:
            baseline[m] = to_float(idle.get(m, "nan"))
        baseline_source = f"idle:{args.idle_name}"
    elif args.baseline_mode == "idle":
        print("ERROR: idle baseline not found", file=sys.stderr)
        return 2
    else:
        for m in METRICS:
            vals = finite_metric_values(workloads, m)
            baseline[m] = min(vals) if vals else math.nan
        baseline_source = "min(workloads)"

    print(f"INFO\tbaseline_source={baseline_source}")

    varied_by_metric = defaultdict(list)
    dominant_count = defaultdict(int)
    metric_values = {m: finite_metric_values(workloads, m) for m in METRICS}
    unavailable_metrics = {
        m for m in METRICS if likely_unavailable_metric(metric_values[m], baseline[m])
    }

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
    coverage_ok_by_metric = {}
    for m in METRICS:
        ws = sorted(set(varied_by_metric[m]))
        unavailable = m in unavailable_metrics
        ok = len(ws) >= args.min_workloads_per_metric
        if args.readiness_mode == "capability-aware" and unavailable:
            status = "SKIP"
            coverage_ok_by_metric[m] = True
        else:
            status = "OK" if ok else "FAIL"
            coverage_ok_by_metric[m] = ok
            all_ok = all_ok and ok
        print(f"{status}\t{m}\tworkloads={len(ws)}\t{','.join(ws) if ws else '-'}")

    if unavailable_metrics:
        print(
            "INFO\tlikely_unavailable_metrics="
            + ",".join(sorted(unavailable_metrics))
        )

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

    workload_names = {r.get("workload", "") for r in workloads}
    has_hibench = any(w in workload_names for w in ["kmeans", "pagerank", "bayes", "terasort", "sql_nweight"])
    has_synth = any(w.startswith("app") for w in workload_names)

    llcocc_mbw_jobs = ["kmeans", "pagerank", "bayes"] if has_hibench else [
        "app01_ml_llc", "app02_ml_llc", "app03_ml_llc", "app04_streaming", "app05_streaming"
    ]
    for m in ["llcocc", "mbw"]:
        touched = [w for w in llcocc_mbw_jobs if w in set(varied_by_metric[m])]
        label = "ML/graph" if has_hibench else "LLC/memory synthetic set"
        if len(touched) >= 1:
            print(f"OK\t{m} responded in {label} ({','.join(touched)})")
        elif has_hibench or has_synth:
            print(f"WARN\t{m} without clear response in {label}")
        else:
            print(f"SKIP\t{m} methodology check (unknown workload profile)")

    net_jobs = ["terasort", "pagerank", "sql_nweight"] if has_hibench else ["app11_sort_net", "app12_sort_net"]
    net_hits = set(varied_by_metric["netp"]) | set(varied_by_metric["nets"])
    net_touched = sorted([w for w in net_jobs if w in net_hits])
    if net_touched:
        label = "shuffle-heavy" if has_hibench else "network synthetic set"
        print(f"OK\tnetp/nets sustained in {label} ({','.join(net_touched)})")
    elif has_hibench or has_synth:
        print("FAIL\tnetp/nets without a convincing high-network workload")
        all_ok = False
    else:
        print("SKIP\tnetp/nets methodology check (unknown workload profile)")

    print("\n== Readiness verdict ==")
    if args.readiness_mode == "strict":
        if all_ok:
            verdict = "READY_FULL_FIDELITY"
        else:
            verdict = "NOT_READY_FULL_FIDELITY"
    else:
        required_ok = all(coverage_ok_by_metric[m] for m in METRICS)
        if required_ok and not dominates_all and not unavailable_metrics:
            verdict = "READY_FULL_FIDELITY"
        elif required_ok and not dominates_all:
            verdict = "READY_PARTIAL_FIDELITY"
        else:
            verdict = "NOT_READY_FULL_FIDELITY"

    print(f"VERDICT\t{verdict}")

    if verdict == "READY_FULL_FIDELITY":
        return 0
    if verdict == "READY_PARTIAL_FIDELITY":
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
