#!/usr/bin/env python3
# plot-hibench.py — Compare v2/v3.1/v3 across HiBench Spark workloads.
#
# Input:  a directory containing one or more hibench run subdirs, each with:
#           metadata.env          (profile=standard|netp-extreme, ...)
#           aggregate-means.tsv   (variant  workload  netp  nets  blk  mbw  llcmr  llcocc  cpu)
#
# Output: <hibench_dir>/plots/
#           fig01_fingerprint.png  -- per-profile × per-variant metric fingerprint
#           fig02_sensitivity.png  -- delta (netp-extreme − standard) per variant × workload
#           fig03_metric_compare.png -- per-metric variant comparison across workloads
#
# Variant rename (pre-rename names in data → current names in figures):
#   v4 → v2   (C99 procfs/resctrl)
#   v5 → v3.1 (eBPF Python + libbpf)
#   v6 → v3   (eBPF CO-RE)
#
# Run:
#   python3 bench/plot/plot-hibench.py results/hibench-stressng-v4v5v6/.../hibench
# or point at the parent batch dir and it will find the hibench/ subdir.

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import pandas as pd

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import matplotlib.ticker as mticker
except ImportError:
    sys.exit("matplotlib is required: pip install matplotlib pandas")

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

RENAME = {"v4": "v2", "v5": "v3.1", "v6": "v3"}
VARIANT_ORDER = ["v2", "v3.1", "v3"]
VARIANT_LABELS = {"v2": "v2 (C99)", "v3.1": "v3.1 (eBPF-py)", "v3": "v3 (eBPF CO-RE)"}
PROFILE_ORDER = ["standard", "netp-extreme"]
WORKLOAD_ORDER = ["kmeans", "bayes", "pagerank", "terasort", "wordcount"]
METRICS = ["netp", "nets", "blk", "mbw", "llcmr", "llcocc", "cpu"]
METRIC_COLORS = {
    "netp":   "#d62728",
    "nets":   "#ff7f0e",
    "blk":    "#2ca02c",
    "mbw":    "#1f77b4",
    "llcmr":  "#9467bd",
    "llcocc": "#e377c2",
    "cpu":    "#8c564b",
}
VARIANT_COLORS = {"v2": "#1f77b4", "v3.1": "#ff7f0e", "v3": "#2ca02c"}
PROFILE_HATCH = {"standard": "", "netp-extreme": "//"}


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

def _read_metadata(run_dir: Path) -> dict[str, str]:
    meta: dict[str, str] = {}
    mf = run_dir / "metadata.env"
    if mf.exists():
        for line in mf.read_text().splitlines():
            if "=" in line:
                k, _, v = line.partition("=")
                meta[k.strip()] = v.strip()
    return meta


def load_hibench_dir(hibench_dir: Path) -> pd.DataFrame:
    """Collect all aggregate-means.tsv files and return a merged DataFrame.

    Adds columns: profile, variant (renamed to current scheme).
    """
    frames: list[pd.DataFrame] = []
    for subdir in sorted(hibench_dir.iterdir()):
        tsv = subdir / "aggregate-means.tsv"
        if not subdir.is_dir() or not tsv.exists():
            continue
        meta = _read_metadata(subdir)
        profile = meta.get("profile", subdir.name.split("-large-")[0])
        df = pd.read_csv(tsv, sep="\t")
        df["variant"] = df["variant"].map(lambda v: RENAME.get(v, v))
        df["profile"] = profile
        frames.append(df)
    if not frames:
        sys.exit(f"No aggregate-means.tsv found under {hibench_dir}")
    merged = pd.concat(frames, ignore_index=True)
    # Normalise order; drop unknown variants/profiles
    merged = merged[merged["variant"].isin(VARIANT_ORDER)]
    merged = merged[merged["profile"].isin(PROFILE_ORDER)]
    merged["variant"] = pd.Categorical(merged["variant"], VARIANT_ORDER, ordered=True)
    merged["workload"] = pd.Categorical(
        merged["workload"],
        [w for w in WORKLOAD_ORDER if w in merged["workload"].unique()],
        ordered=True,
    )
    return merged.sort_values(["profile", "variant", "workload"]).reset_index(drop=True)


# ---------------------------------------------------------------------------
# Figure 1 — Fingerprint (per-profile × per-variant)
# ---------------------------------------------------------------------------

def fig_fingerprint(df: pd.DataFrame, outdir: Path) -> None:
    """2 rows (profile) × 3 cols (variant), each panel = metric bars per workload."""
    profiles = [p for p in PROFILE_ORDER if p in df["profile"].unique()]
    variants = [v for v in VARIANT_ORDER if v in df["variant"].unique()]
    workloads = [w for w in WORKLOAD_ORDER if w in df["workload"].unique()]

    nrows, ncols = len(profiles), len(variants)
    fig, axes = plt.subplots(nrows, ncols, figsize=(5 * ncols, 3.8 * nrows),
                             squeeze=False, sharey=False)

    bar_w = 0.11
    x = np.arange(len(workloads))

    for ri, profile in enumerate(profiles):
        for ci, variant in enumerate(variants):
            ax = axes[ri][ci]
            sub = df[(df["profile"] == profile) & (df["variant"] == variant)]
            sub = sub.set_index("workload").reindex(workloads)
            for mi, m in enumerate(METRICS):
                offset = (mi - (len(METRICS) - 1) / 2) * bar_w
                vals = sub[m].fillna(0).values
                ax.bar(x + offset, vals, width=bar_w,
                       label=m, color=METRIC_COLORS[m], alpha=0.85)
            ax.set_xticks(x)
            ax.set_xticklabels(workloads, rotation=30, ha="right", fontsize=8)
            ax.set_title(f"{VARIANT_LABELS.get(variant, variant)}\n({profile})", fontsize=9)
            ax.set_ylabel("metric value")
            ax.grid(axis="y", linestyle=":", alpha=0.4)
            ymax = sub[METRICS].max().max()
            ax.set_ylim(0, max(1.0, ymax * 1.15))
            if ri == 0 and ci == ncols - 1:
                ax.legend(ncol=4, fontsize=7, loc="upper right",
                          bbox_to_anchor=(1.0, 1.55))

    fig.suptitle("HiBench: IntP metric fingerprint per variant × profile", fontsize=11)
    fig.tight_layout(rect=[0, 0, 1, 0.97])
    out = outdir / "fig01_fingerprint.png"
    fig.savefig(out, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"[fig01] {out}")


# ---------------------------------------------------------------------------
# Figure 2 — Sensitivity: delta(netp-extreme − standard)
# ---------------------------------------------------------------------------

def fig_sensitivity(df: pd.DataFrame, outdir: Path) -> None:
    """3 rows (variant), each panel = (netp-extreme − standard) per metric × workload."""
    variants = [v for v in VARIANT_ORDER if v in df["variant"].unique()]
    workloads = [w for w in WORKLOAD_ORDER if w in df["workload"].unique()]

    if not {"standard", "netp-extreme"}.issubset(df["profile"].unique()):
        print("[fig02] need both profiles for sensitivity — skip")
        return

    std_df = (df[df["profile"] == "standard"]
              .set_index(["variant", "workload"])[METRICS])
    net_df = (df[df["profile"] == "netp-extreme"]
              .set_index(["variant", "workload"])[METRICS])
    delta = (net_df - std_df).reset_index()

    nrows = len(variants)
    fig, axes = plt.subplots(nrows, 1, figsize=(9, 3.2 * nrows), squeeze=False)

    bar_w = 0.11
    x = np.arange(len(workloads))

    for ri, variant in enumerate(variants):
        ax = axes[ri][0]
        sub = delta[delta["variant"] == variant].set_index("workload").reindex(workloads)
        for mi, m in enumerate(METRICS):
            offset = (mi - (len(METRICS) - 1) / 2) * bar_w
            vals = sub[m].fillna(0).values
            ax.bar(x + offset, vals, width=bar_w,
                   label=m, color=METRIC_COLORS[m], alpha=0.85)
        ax.axhline(0, color="black", linewidth=0.7, linestyle="--")
        ax.set_xticks(x)
        ax.set_xticklabels(workloads, rotation=20, ha="right", fontsize=8)
        ax.set_title(f"{VARIANT_LABELS.get(variant, variant)}  —  Δ(netp-extreme − standard)")
        ax.set_ylabel("Δ metric value")
        ax.grid(axis="y", linestyle=":", alpha=0.4)
        if ri == 0:
            ax.legend(ncol=7, fontsize=7, loc="upper center",
                      bbox_to_anchor=(0.5, 1.5))

    fig.suptitle("HiBench: sensitivity to network interference profile", fontsize=11)
    fig.tight_layout(rect=[0, 0, 1, 0.97])
    out = outdir / "fig02_sensitivity.png"
    fig.savefig(out, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"[fig02] {out}")


# ---------------------------------------------------------------------------
# Figure 3 — Per-metric variant comparison
# ---------------------------------------------------------------------------

def fig_metric_compare(df: pd.DataFrame, outdir: Path) -> None:
    """7 rows (metric) × 2 cols (profile): grouped bars v2/v3.1/v3 per workload."""
    profiles = [p for p in PROFILE_ORDER if p in df["profile"].unique()]
    variants = [v for v in VARIANT_ORDER if v in df["variant"].unique()]
    workloads = [w for w in WORKLOAD_ORDER if w in df["workload"].unique()]

    ncols = len(profiles)
    nrows = len(METRICS)
    fig, axes = plt.subplots(nrows, ncols, figsize=(5.5 * ncols, 2.6 * nrows),
                             squeeze=False, sharey="row")

    bar_w = 0.25
    x = np.arange(len(workloads))

    for mi, metric in enumerate(METRICS):
        ymax_row = df[metric].max()
        for ci, profile in enumerate(profiles):
            ax = axes[mi][ci]
            for vi, variant in enumerate(variants):
                sub = (df[(df["profile"] == profile) & (df["variant"] == variant)]
                       .set_index("workload").reindex(workloads))
                offset = (vi - (len(variants) - 1) / 2) * bar_w
                ax.bar(x + offset, sub[metric].fillna(0).values,
                       width=bar_w, label=VARIANT_LABELS.get(variant, variant),
                       color=VARIANT_COLORS[variant], alpha=0.85)
            ax.set_xticks(x)
            ax.set_xticklabels(workloads, rotation=30, ha="right", fontsize=8)
            ax.set_title(f"{metric}  ({profile})", fontsize=9)
            ax.set_ylabel(metric)
            ax.set_ylim(0, max(0.5, ymax_row * 1.15))
            ax.grid(axis="y", linestyle=":", alpha=0.4)
            if mi == 0 and ci == ncols - 1:
                ax.legend(fontsize=8, loc="upper right",
                          bbox_to_anchor=(1.0, 1.6))

    fig.suptitle("HiBench: per-metric variant comparison (v2 / v3.1 / v3)", fontsize=11)
    fig.tight_layout(rect=[0, 0, 1, 0.98])
    out = outdir / "fig03_metric_compare.png"
    fig.savefig(out, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"[fig03] {out}")


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

def main() -> None:
    p = argparse.ArgumentParser(description="Plot HiBench IntP results (v4/v5/v6 → v2/v3.1/v3)")
    p.add_argument("hibench_dir", type=Path,
                   help="Directory containing hibench run subdirs")
    p.add_argument("--out", type=Path, default=None,
                   help="Output directory (default: <hibench_dir>/plots)")
    args = p.parse_args()

    # Accept both the hibench/ dir and a parent batch dir that contains it
    hdir = args.hibench_dir
    if (hdir / "hibench").is_dir():
        hdir = hdir / "hibench"

    if not hdir.is_dir():
        sys.exit(f"Not a directory: {hdir}")

    outdir = args.out or (hdir / "plots")
    outdir.mkdir(parents=True, exist_ok=True)

    print(f"Loading hibench results from {hdir}")
    df = load_hibench_dir(hdir)
    print(f"  variants : {sorted(df['variant'].unique())}")
    print(f"  profiles : {sorted(df['profile'].unique())}")
    print(f"  workloads: {sorted(df['workload'].unique())}")
    df.to_csv(outdir / "combined-means.csv", index=False)

    fig_fingerprint(df, outdir)
    fig_sensitivity(df, outdir)
    fig_metric_compare(df, outdir)

    print(f"Done. Figures in {outdir}")


if __name__ == "__main__":
    main()
