#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# plot-aux-rerun.py — Figures from shared/intp-ebpf-checkout.sh runs.
#
# Inputs:  <run-dir> produced by shared/intp-ebpf-checkout.sh, containing
#          noise_floor/rep*/profiler.tsv and ringbuf_pidstat/<ref>/<arm>/rep*/.
#
# Outputs (in <run-dir>/plots/):
#   noise-floor-distribution.{png,pdf}   per-metric distribution across 1080 samples
#   noise-floor-timeseries.{png,pdf}     rep01 1-Hz time series, 7 metrics
#   exp5-sched-switch.{png,pdf}          sched_switch baseline vs with-V3 (+ vmstat
#                                        ground-truth column if present)
# -----------------------------------------------------------------------------
import argparse
import csv
import glob
import os
import re
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

METRICS = ["netp", "nets", "blk", "mbw", "llcmr", "llcocc", "cpu"]
METRIC_LABEL = {
    "netp":   "netp (NIC tx)",
    "nets":   "nets (NAPI poll)",
    "blk":    "blk (block I/O)",
    "mbw":    "mbw (mem BW)",
    "llcmr":  "llcmr (LLC miss rate)",
    "llcocc": "llcocc (LLC occupancy)",
    "cpu":    "cpu (sched_switch)",
}


def read_profiler_tsv(path):
    """Return a dict {metric: list[float]} from one profiler.tsv (skips '# ...' lines)."""
    out = {m: [] for m in METRICS}
    with open(path) as f:
        data = [ln for ln in f if not ln.startswith("#") and ln.strip()]
    for row in csv.DictReader(data, delimiter="\t"):
        for m in METRICS:
            try:
                out[m].append(float(row.get(m, 0) or 0))
            except (ValueError, TypeError):
                pass
    return out


def collect_noise_floor(run_dir):
    """Return {metric: 1-D np.array of all samples across all reps}."""
    pooled = {m: [] for m in METRICS}
    for rep in sorted(glob.glob(str(run_dir / "noise_floor" / "rep*" / "profiler.tsv"))):
        d = read_profiler_tsv(rep)
        for m in METRICS:
            pooled[m].extend(d[m])
    return {m: np.asarray(v, dtype=float) for m, v in pooled.items()}


def parse_perf_one(path, event):
    try:
        text = Path(path).read_text(errors="ignore")
    except (FileNotFoundError, OSError):
        return None
    for line in text.splitlines():
        m = re.search(r"([\d,]+)\s+" + re.escape(event), line)
        if m:
            try:
                return int(m.group(1).replace(",", ""))
            except ValueError:
                return None
    return None


def parse_vmstat_cs(path):
    """Sum vmstat 'cs' column over the 90-s window; returns 0 if file missing/malformed."""
    try:
        text = Path(path).read_text(errors="ignore")
    except (FileNotFoundError, OSError):
        return 0
    rows = []
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 17 and parts[0].isdigit():
            try:
                rows.append(int(parts[11]))
            except (ValueError, IndexError):
                pass
    return sum(rows[1:]) if len(rows) > 1 else 0


# --- Figure 1: noise-floor distribution -------------------------------------

def plot_noise_floor_distribution(run_dir, out_dir):
    data = collect_noise_floor(run_dir)
    n_total = sum(len(v) for v in data.values()) // len(METRICS)

    fig, ax = plt.subplots(figsize=(8.0, 4.5))
    positions = np.arange(len(METRICS))
    box_data = [data[m] for m in METRICS]

    bp = ax.boxplot(
        box_data, positions=positions, widths=0.55, patch_artist=True,
        medianprops=dict(color="black", linewidth=1.3),
        flierprops=dict(marker=".", markersize=2, alpha=0.35),
    )
    palette = plt.cm.tab10(np.linspace(0, 1, len(METRICS)))
    for patch, c in zip(bp["boxes"], palette):
        patch.set_facecolor(c)
        patch.set_alpha(0.55)

    ax.set_xticks(positions)
    ax.set_xticklabels([METRIC_LABEL[m] for m in METRICS], rotation=18, ha="right")
    ax.set_ylabel("Value (% scale, 0-100)")
    ax.set_ylim(-3, 105)
    ax.grid(axis="y", alpha=0.35)
    ax.set_title(
        f"V3 noise floor — HiBench stack UP and IDLE\n"
        f"(n={n_total} samples = 12 reps × 90 s, system-wide eBPF)",
        fontsize=10,
    )
    fig.tight_layout()
    for ext in ("png", "pdf"):
        fig.savefig(out_dir / f"noise-floor-distribution.{ext}", dpi=200, bbox_inches="tight")
    plt.close(fig)


# --- Figure 2: noise-floor time series for rep01 -----------------------------

def plot_noise_floor_timeseries(run_dir, out_dir):
    rep1 = run_dir / "noise_floor" / "rep01" / "profiler.tsv"
    if not rep1.exists():
        print(f"  skip timeseries: {rep1} not found")
        return
    d = read_profiler_tsv(rep1)
    n = max(len(d[m]) for m in METRICS) or 0
    t = np.arange(n)

    fig, axes = plt.subplots(4, 2, figsize=(9.0, 7.0), sharex=True)
    axes = axes.ravel()
    for ax, m in zip(axes, METRICS):
        ax.plot(t, d[m][:n], lw=1.0)
        ax.set_title(METRIC_LABEL[m], fontsize=9)
        ax.set_ylim(-3, 105)
        ax.grid(alpha=0.3)
    # hide unused last subplot
    axes[-1].axis("off")
    axes[-1].text(
        0.05, 0.50,
        "Single rep (90 s @ 1 Hz)\n"
        "rep01 / noise_floor /\n"
        "profiler.tsv\n\n"
        "Stack: HiBench UP & IDLE\n"
        "(NN+DN+Master+Worker)",
        transform=axes[-1].transAxes, fontsize=9, va="center",
    )
    for ax in axes[-3:-1]:
        ax.set_xlabel("Sample (seconds)")
    fig.suptitle("V3 noise-floor time series (rep01)", fontsize=11)
    fig.tight_layout(rect=[0, 0, 1, 0.96])
    for ext in ("png", "pdf"):
        fig.savefig(out_dir / f"noise-floor-timeseries.{ext}", dpi=200, bbox_inches="tight")
    plt.close(fig)


# --- Figure 3: experiment-5 sched-switch comparison -------------------------

def plot_exp5_sched_switch(run_dir, out_dir):
    base = run_dir / "ringbuf_pidstat"
    if not base.exists():
        print("  skip exp5: no ringbuf_pidstat dir")
        return

    refs = ["ref_cpu", "ref_disk", "ref_stream"]
    perf_base, perf_v3, vm_base, vm_v3 = {}, {}, {}, {}
    have_vmstat = False
    for ref in refs:
        perf_base[ref] = [parse_perf_one(p, "sched:sched_switch")
                          for p in sorted(glob.glob(str(base / ref / "baseline" / "rep*" / "perf_system.txt")))]
        perf_v3[ref]   = [parse_perf_one(p, "sched:sched_switch")
                          for p in sorted(glob.glob(str(base / ref / "with_profiler" / "rep*" / "perf_system.txt")))]
        perf_base[ref] = [v for v in perf_base[ref] if v]
        perf_v3[ref]   = [v for v in perf_v3[ref]   if v]
        vb = [parse_vmstat_cs(p) for p in sorted(glob.glob(str(base / ref / "baseline" / "rep*" / "vmstat.txt")))]
        vw = [parse_vmstat_cs(p) for p in sorted(glob.glob(str(base / ref / "with_profiler" / "rep*" / "vmstat.txt")))]
        vm_base[ref] = [v for v in vb if v]
        vm_v3[ref]   = [v for v in vw if v]
        if vm_base[ref] or vm_v3[ref]:
            have_vmstat = True

    x = np.arange(len(refs))
    if have_vmstat:
        # 4 bars per ref: perf-base, perf-v3, vmstat-base, vmstat-v3
        w = 0.20
        fig, ax = plt.subplots(figsize=(8.5, 4.2))
        ax.bar(x - 1.5*w, [np.mean(perf_base[r]) if perf_base[r] else 0 for r in refs], w,
               yerr=[np.std(perf_base[r]) if len(perf_base[r])>1 else 0 for r in refs],
               capsize=3, label="perf  · baseline", color="#1f77b4")
        ax.bar(x - 0.5*w, [np.mean(perf_v3[r]) if perf_v3[r] else 0 for r in refs], w,
               yerr=[np.std(perf_v3[r]) if len(perf_v3[r])>1 else 0 for r in refs],
               capsize=3, label="perf  · with V3", color="#1f77b4", alpha=0.55, hatch="//")
        ax.bar(x + 0.5*w, [np.mean(vm_base[r]) if vm_base[r] else 0 for r in refs], w,
               yerr=[np.std(vm_base[r]) if len(vm_base[r])>1 else 0 for r in refs],
               capsize=3, label="vmstat · baseline", color="#d62728")
        ax.bar(x + 1.5*w, [np.mean(vm_v3[r]) if vm_v3[r] else 0 for r in refs], w,
               yerr=[np.std(vm_v3[r]) if len(vm_v3[r])>1 else 0 for r in refs],
               capsize=3, label="vmstat · with V3", color="#d62728", alpha=0.55, hatch="//")
        ax.set_title("ctx-switches over 90 s window — perf counter vs vmstat ground-truth", fontsize=10)
    else:
        w = 0.32
        fig, ax = plt.subplots(figsize=(7.5, 4.0))
        ax.bar(x - w/2, [np.mean(perf_base[r]) if perf_base[r] else 0 for r in refs], w,
               yerr=[np.std(perf_base[r]) if len(perf_base[r])>1 else 0 for r in refs],
               capsize=3, label="baseline", color="#1f77b4")
        ax.bar(x + w/2, [np.mean(perf_v3[r]) if perf_v3[r] else 0 for r in refs], w,
               yerr=[np.std(perf_v3[r]) if len(perf_v3[r])>1 else 0 for r in refs],
               capsize=3, label="with V3", color="#1f77b4", alpha=0.55, hatch="//")
        ax.set_title(
            "sched:sched_switch over 90 s — perf counter only\n"
            "⚠ vmstat ground-truth not captured in this run; counter drop may be artefactual",
            fontsize=9.5)

    ax.set_xticks(x)
    ax.set_xticklabels(refs)
    ax.set_ylabel("Events (count over 90 s)")
    ax.set_yscale("log")
    ax.grid(axis="y", which="both", alpha=0.3)
    ax.legend(fontsize=8, loc="upper right")
    fig.tight_layout()
    for ext in ("png", "pdf"):
        fig.savefig(out_dir / f"exp5-sched-switch.{ext}", dpi=200, bbox_inches="tight")
    plt.close(fig)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run_dir", type=Path, help="run dir produced by intp-ebpf-checkout.sh")
    ap.add_argument("--out", type=Path, default=None, help="output dir (default: <run_dir>/plots)")
    args = ap.parse_args()

    run_dir = args.run_dir.resolve()
    if not run_dir.is_dir():
        print(f"error: not a directory: {run_dir}", file=sys.stderr)
        sys.exit(2)
    out_dir = args.out or (run_dir / "plots")
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"run_dir: {run_dir}")
    print(f"out_dir: {out_dir}")
    plot_noise_floor_distribution(run_dir, out_dir)
    plot_noise_floor_timeseries(run_dir, out_dir)
    plot_exp5_sched_switch(run_dir, out_dir)
    print("done.")
    for f in sorted(out_dir.iterdir()):
        print(f"  {f.relative_to(run_dir)}")


if __name__ == "__main__":
    main()
