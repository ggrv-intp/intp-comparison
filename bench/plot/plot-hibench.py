#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# plot-hibench.py — Compare IntP variants across HiBench Spark workloads.
#
# Reproduces the visual structure of the original IntP paper (Xavier et al.,
# 2022) and the IADA paper (Meyer et al., 2022) for the new HiBench
# experiment context, where the comparison axis is variant × profile.
#
# Inputs:  a directory containing one or more hibench run subdirs, each with
#          metadata.env, aggregate-means.tsv, and per-rep profiler.tsv files.
#
# Figures (paper reference in parens):
#   fig01_fingerprint.png        per-(profile,variant) panel × workload metric bars
#   fig02_sensitivity.png        Δ(netp-extreme − standard) per variant
#   fig03_metric_compare.png     per-metric variant comparison across workloads
#   fig04_per_workload_bars.png  (IntP Fig. 4)  one panel per workload, bars =
#                                              variants × metrics
#   fig05_radar_fingerprint.png  (IntP Fig. 4 alt) per-workload radar
#   fig06_pca_workloads.png      (IntP Fig. 5)  PCA of workloads per profile
#   fig07_timeseries.png         (IntP Fig. 3 / IADA Fig. 5) smoothed traces
#   fig08_idi_bars.png           (IADA Fig. 6) Δ resource per profile
#   fig00_canonical_intp_fig4.png (IntP Fig. 4 canonical) single-panel
#                                              workload×metric bar chart
#   fig09_resource_timeseries.png (IntP Fig. 8) resource-family lines
#   fig10_variant_resource_heatmap.png (new)   variants × resources summary
#
# All output PNGs are sized so neither side exceeds ~1900 px (downstream
# image readers reject ≥ 2000 px assets).
#
# Variant rename (legacy data → current):
#   v1 → v0   v2 → v0.1   v3 → v1   v4 → v2   v5 → v3.1   v6 → v3
#
# Run:
#   python3 bench/plot/plot-hibench.py results/<batch>/hibench
# -----------------------------------------------------------------------------

from __future__ import annotations

import argparse
import sys
import warnings
from pathlib import Path

import numpy as np
import pandas as pd

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
except ImportError:
    sys.exit("matplotlib is required: pip install matplotlib pandas scikit-learn")

try:
    from sklearn.decomposition import PCA
    HAS_SKLEARN = True
except ImportError:
    HAS_SKLEARN = False
    warnings.warn("scikit-learn not installed — PCA figure will be skipped")

# ---------------------------------------------------------------------------
# Constants — palette aligned with IntP/IADA paper conventions
# ---------------------------------------------------------------------------

RENAME = {"v1": "v0", "v2": "v0.1", "v3": "v1", "v4": "v2", "v5": "v3.1", "v6": "v3"}
VARIANT_ORDER = ["v0", "v0.1", "v1", "v1.1", "v2", "v3.1", "v3"]
VARIANT_LABELS = {
    "v0":   "v0 (stap classic)",
    "v0.1": "v0.1 (stap k68)",
    "v1":   "v1 (stap native)",
    "v1.1": "v1.1 (stap helper)",
    "v2":   "v2 (C99)",
    "v3.1": "v3.1 (eBPF-py)",
    "v3":   "v3 (eBPF CO-RE)",
}
PROFILE_ORDER = ["standard", "netp-extreme"]
PROFILE_LABEL = {"standard": "standard", "netp-extreme": "netp-extreme"}
WORKLOAD_ORDER = ["kmeans", "bayes", "pagerank", "terasort", "wordcount",
                  "sql", "join", "scan", "aggregation", "lr", "rf"]
METRICS = ["netp", "nets", "blk", "mbw", "llcmr", "llcocc", "cpu"]
METRIC_COLORS = {
    "netp":   "#e377c2",
    "nets":   "#9467bd",
    "blk":    "#2ca02c",
    "mbw":    "#1f77b4",
    "llcmr":  "#d62728",
    "llcocc": "#ff7f0e",
    "cpu":    "#000000",
}
METRIC_LABEL = {
    "netp":   "netp", "nets":   "nets", "blk":    "blk",
    "mbw":    "mbw",  "llcmr":  "llcmr", "llcocc": "llcocc", "cpu":    "cpu",
}
VARIANT_COLORS = {
    "v0":   "#7f7f7f",
    "v0.1": "#bcbd22",
    "v1":   "#17becf",
    "v1.1": "#aec7e8",
    "v2":   "#1f77b4",
    "v3.1": "#ff7f0e",
    "v3":   "#2ca02c",
}
PROFILE_HATCH = {"standard": "", "netp-extreme": "//"}

# Logical resource families used by IntP Fig. 8 / IADA Fig. 5 / Fig. 6
RESOURCE_FAMILY = {
    "cache":   ["llcocc", "llcmr"],
    "cpu":     ["cpu"],
    "disk":    ["blk"],
    "memory":  ["mbw"],
    "network": ["netp", "nets"],
}
RESOURCE_COLORS = {
    "cache":   "#ff7f0e",
    "cpu":     "#000000",
    "disk":    "#2ca02c",
    "memory":  "#1f77b4",
    "network": "#e377c2",
}


# ---------------------------------------------------------------------------
# Style helpers
# ---------------------------------------------------------------------------

MAX_PIXELS = 1900
SAVE_DPI = 130


def _clamp_figsize(width: float, height: float) -> tuple[float, float]:
    max_in = MAX_PIXELS / SAVE_DPI
    scale = min(1.0, max_in / max(width, 1e-9), max_in / max(height, 1e-9))
    return width * scale, height * scale


def setup_style() -> None:
    plt.rcParams.update({
        "figure.dpi":         110,
        "savefig.dpi":        SAVE_DPI,
        "font.family":        "DejaVu Sans",
        "font.size":          9.5,
        "axes.titlesize":     10,
        "axes.labelsize":     9.5,
        "axes.spines.top":    False,
        "axes.spines.right":  False,
        "axes.grid":          True,
        "grid.linestyle":     ":",
        "grid.alpha":         0.4,
        "legend.fontsize":    8,
        "legend.frameon":     False,
        "xtick.labelsize":    8,
        "ytick.labelsize":    8,
    })


def _save(fig, path: Path, label: str) -> None:
    fig.savefig(path, bbox_inches="tight")
    plt.close(fig)
    print(f"[{label}] {path.name}")


def _ordered_variants(values) -> list[str]:
    present = set(values)
    return [v for v in VARIANT_ORDER if v in present]


def _ordered_workloads(values) -> list[str]:
    present = set(values)
    canonical = [w for w in WORKLOAD_ORDER if w in present]
    extra = sorted(present - set(canonical))
    return canonical + extra


def _ordered_profiles(values) -> list[str]:
    present = set(values)
    return [p for p in PROFILE_ORDER if p in present]


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


def load_hibench_dir(hibench_dir: Path) -> tuple[pd.DataFrame, list[Path]]:
    """Collect all aggregate-means.tsv files. Also returns the list of run
    directories so callers can locate per-rep profiler.tsv traces."""
    frames: list[pd.DataFrame] = []
    run_dirs: list[Path] = []
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
        run_dirs.append(subdir)
    if not frames:
        sys.exit(f"No aggregate-means.tsv found under {hibench_dir}")
    merged = pd.concat(frames, ignore_index=True)
    merged = merged[merged["profile"].isin(PROFILE_ORDER)]
    return merged.reset_index(drop=True), run_dirs


def load_profiler_tsv(path: Path) -> pd.DataFrame:
    rows = []
    with path.open() as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#") or line.startswith("ts") or line.startswith("netp"):
                continue
            parts = line.split()
            if len(parts) == 8:
                ts = parts[0]; vals = parts[1:]
            elif len(parts) == 7:
                ts = None; vals = parts
            else:
                continue
            rec = {"ts": float(ts) if ts else np.nan}
            for k, v in zip(METRICS, vals):
                try:
                    rec[k] = float(v)
                except (ValueError, TypeError):
                    rec[k] = np.nan
            rows.append(rec)
    return pd.DataFrame(rows)


def _smooth(arr: np.ndarray, window: int = 9) -> np.ndarray:
    if len(arr) < window:
        return arr
    kernel = np.ones(window) / window
    return np.convolve(arr, kernel, mode="same")


# ---------------------------------------------------------------------------
# Fig 01 — Fingerprint per (profile,variant)
# ---------------------------------------------------------------------------

def fig_fingerprint(df: pd.DataFrame, outdir: Path) -> None:
    profiles = _ordered_profiles(df["profile"].unique())
    variants = _ordered_variants(df["variant"].unique())
    workloads = _ordered_workloads(df["workload"].unique())

    nrows, ncols = len(profiles), len(variants)
    fig, axes = plt.subplots(nrows, ncols,
                             figsize=_clamp_figsize(4.2 * ncols, 3.2 * nrows),
                             squeeze=False, sharey="row")

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
                       label=METRIC_LABEL[m], color=METRIC_COLORS[m], alpha=0.92)
            ax.set_xticks(x)
            ax.set_xticklabels(workloads, rotation=30, ha="right", fontsize=7.5)
            ax.set_title(f"{VARIANT_LABELS.get(variant, variant)}\n({profile})", fontsize=9)
            if ci == 0:
                ax.set_ylabel("metric value (%)")
            ymax = sub[METRICS].max().max() if not sub.empty else 1.0
            ax.set_ylim(0, max(1.0, ymax * 1.18))

    handles, labels = axes[0][0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="upper center",
               bbox_to_anchor=(0.5, 1.02),
               ncol=len(METRICS), frameon=False, fontsize=8.5)
    fig.suptitle("HiBench: IntP metric fingerprint per variant × profile",
                 fontsize=11, y=1.05)
    fig.tight_layout()
    _save(fig, outdir / "fig01_fingerprint.png", "fig01")


# ---------------------------------------------------------------------------
# Fig 02 — Sensitivity Δ(netp-extreme − standard)
# ---------------------------------------------------------------------------

def fig_sensitivity(df: pd.DataFrame, outdir: Path) -> None:
    variants = _ordered_variants(df["variant"].unique())
    workloads = _ordered_workloads(df["workload"].unique())
    if not {"standard", "netp-extreme"}.issubset(df["profile"].unique()):
        print("[fig02] need both profiles for sensitivity — skip")
        return
    std_df = (df[df["profile"] == "standard"]
              .set_index(["variant", "workload"])[METRICS])
    net_df = (df[df["profile"] == "netp-extreme"]
              .set_index(["variant", "workload"])[METRICS])
    delta = (net_df - std_df).reset_index()

    nrows = len(variants)
    fig, axes = plt.subplots(nrows, 1,
                             figsize=_clamp_figsize(8.5, 2.7 * nrows),
                             squeeze=False, sharex=True)
    bar_w = 0.11
    x = np.arange(len(workloads))
    for ri, variant in enumerate(variants):
        ax = axes[ri][0]
        sub = (delta[delta["variant"] == variant]
               .set_index("workload").reindex(workloads))
        for mi, m in enumerate(METRICS):
            offset = (mi - (len(METRICS) - 1) / 2) * bar_w
            vals = sub[m].fillna(0).values
            ax.bar(x + offset, vals, width=bar_w,
                   label=METRIC_LABEL[m], color=METRIC_COLORS[m], alpha=0.92)
        ax.axhline(0, color="black", linewidth=0.6, linestyle="--")
        ax.set_xticks(x)
        ax.set_xticklabels(workloads, rotation=20, ha="right", fontsize=8)
        ax.set_title(f"{VARIANT_LABELS.get(variant, variant)} — "
                     "Δ(netp-extreme − standard)", fontsize=9)
        ax.set_ylabel("Δ metric value")
    handles, labels = axes[0][0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="upper center",
               bbox_to_anchor=(0.5, 1.02),
               ncol=len(METRICS), frameon=False, fontsize=8.5)
    fig.suptitle("HiBench: sensitivity to network interference profile",
                 fontsize=11, y=1.05)
    fig.tight_layout()
    _save(fig, outdir / "fig02_sensitivity.png", "fig02")


# ---------------------------------------------------------------------------
# Fig 03 — Per-metric variant comparison
# ---------------------------------------------------------------------------

def fig_metric_compare(df: pd.DataFrame, outdir: Path) -> None:
    profiles = _ordered_profiles(df["profile"].unique())
    variants = _ordered_variants(df["variant"].unique())
    workloads = _ordered_workloads(df["workload"].unique())
    ncols = len(profiles)
    nrows = len(METRICS)
    fig, axes = plt.subplots(nrows, ncols,
                             figsize=_clamp_figsize(5.4 * ncols, 1.9 * nrows),
                             squeeze=False, sharey="row")
    bar_w = 0.8 / max(1, len(variants))
    x = np.arange(len(workloads))
    for mi, metric in enumerate(METRICS):
        ymax_row = df[metric].max() if metric in df.columns else 1.0
        for ci, profile in enumerate(profiles):
            ax = axes[mi][ci]
            for vi, variant in enumerate(variants):
                sub = (df[(df["profile"] == profile) & (df["variant"] == variant)]
                       .set_index("workload").reindex(workloads))
                offset = (vi - (len(variants) - 1) / 2) * bar_w
                ax.bar(x + offset, sub[metric].fillna(0).values,
                       width=bar_w,
                       label=VARIANT_LABELS.get(variant, variant),
                       color=VARIANT_COLORS.get(variant, f"C{vi}"), alpha=0.92)
            ax.set_xticks(x)
            ax.set_xticklabels(workloads, rotation=30, ha="right", fontsize=7.5)
            ax.set_title(f"{metric}  ({profile})", fontsize=9)
            if ci == 0:
                ax.set_ylabel(metric)
            ax.set_ylim(0, max(0.5, ymax_row * 1.15))
    handles, labels = axes[0][0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="upper center",
               bbox_to_anchor=(0.5, 1.01),
               ncol=len(variants), frameon=False, fontsize=8.5)
    fig.suptitle("HiBench: per-metric variant comparison", fontsize=11, y=1.02)
    fig.tight_layout()
    _save(fig, outdir / "fig03_metric_compare.png", "fig03")


# ---------------------------------------------------------------------------
# Fig 04 — IntP Fig. 4 reproduction: per-workload, bars = variant × metric
# ---------------------------------------------------------------------------

def fig_per_workload_bars(df: pd.DataFrame, outdir: Path) -> None:
    profiles = _ordered_profiles(df["profile"].unique())
    variants = _ordered_variants(df["variant"].unique())
    workloads = _ordered_workloads(df["workload"].unique())
    if not (profiles and variants and workloads):
        return
    for profile in profiles:
        sub_p = df[df.profile == profile]
        n = len(workloads)
        cols = min(5, n)
        rows = (n + cols - 1) // cols
        fig, axes = plt.subplots(rows, cols,
                                 figsize=_clamp_figsize(2.7 * cols, 2.0 * rows),
                                 squeeze=False, sharey=True)
        x = np.arange(len(METRICS))
        bar_w = 0.8 / max(1, len(variants))
        for i, wl in enumerate(workloads):
            ax = axes[i // cols][i % cols]
            for vi, variant in enumerate(variants):
                row = sub_p[(sub_p.workload == wl) & (sub_p.variant == variant)]
                vals = (row[METRICS].iloc[0].values if not row.empty
                        else np.full(len(METRICS), np.nan))
                offset = (vi - (len(variants) - 1) / 2) * bar_w
                ax.bar(x + offset, np.nan_to_num(vals), width=bar_w,
                       color=VARIANT_COLORS.get(variant, f"C{vi}"),
                       edgecolor="white", linewidth=0.3,
                       label=variant if i == 0 else None)
            ax.set_xticks(x)
            ax.set_xticklabels(METRICS, rotation=45, ha="right", fontsize=7)
            ax.set_title(wl, fontsize=8.5)
            ymax = sub_p[METRICS].max().max()
            ax.set_ylim(0, max(1.0, float(ymax) * 1.10))
            ax.tick_params(axis="y", labelsize=7)
        for j in range(n, rows * cols):
            axes[j // cols][j % cols].axis("off")
        for r in range(rows):
            axes[r][0].set_ylabel("metric value (%)", fontsize=8)
        handles = [plt.Rectangle((0, 0), 1, 1, color=VARIANT_COLORS.get(v, "C0"))
                   for v in variants]
        fig.legend(handles, variants, loc="upper center",
                   bbox_to_anchor=(0.5, 1.02),
                   ncol=len(variants), frameon=False, fontsize=8.5,
                   title="variant", title_fontsize=8.5)
        fig.suptitle(f"Per-workload variant fingerprint — profile={profile}  "
                     f"(IntP Fig. 4 reproduction)", y=1.04, fontsize=11)
        fig.tight_layout()
        suffix = f"_{profile}" if len(profiles) > 1 else ""
        _save(fig, outdir / f"fig04_per_workload_bars{suffix}.png", f"fig04-{profile}")


# ---------------------------------------------------------------------------
# Fig 05 — Radar fingerprint (one polygon per variant per workload)
# ---------------------------------------------------------------------------

def fig_radar(df: pd.DataFrame, outdir: Path) -> None:
    profiles = _ordered_profiles(df["profile"].unique())
    variants = _ordered_variants(df["variant"].unique())
    workloads = _ordered_workloads(df["workload"].unique())
    if not (profiles and variants and workloads):
        return
    # Normalise per metric over the entire dataset so shapes are comparable
    norms = {m: max(1e-9, df[m].max()) for m in METRICS}
    profile = "standard" if "standard" in profiles else profiles[0]
    sub_p = df[df.profile == profile]
    n = len(workloads)
    cols = 4 if n >= 4 else n
    rows = (n + cols - 1) // cols
    fig, axes = plt.subplots(rows, cols,
                             figsize=_clamp_figsize(3.2 * cols, 3.0 * rows),
                             subplot_kw=dict(polar=True), squeeze=False)
    angles = np.linspace(0, 2 * np.pi, len(METRICS), endpoint=False).tolist()
    angles += angles[:1]
    for i, wl in enumerate(workloads):
        ax = axes[i // cols][i % cols]
        for variant in variants:
            row = sub_p[(sub_p.workload == wl) & (sub_p.variant == variant)]
            if row.empty: continue
            vals = [row[m].iloc[0] / norms[m] for m in METRICS]
            vals += vals[:1]
            color = VARIANT_COLORS.get(variant, "C0")
            ax.plot(angles, vals, color=color, linewidth=1.9, alpha=0.95,
                    label=variant)
            ax.fill(angles, vals, color=color, alpha=0.06)
        ax.set_xticks(angles[:-1])
        ax.set_xticklabels(METRICS, fontsize=7.5)
        ax.set_yticks([0.25, 0.5, 0.75, 1.0])
        if i == 0:
            ax.set_yticklabels(["0.25", "0.50", "0.75", "1.00"], fontsize=6,
                               color="#555")
        else:
            ax.set_yticklabels(["", "", "", ""])
        ax.set_ylim(0, 1.05)
        ax.set_title(wl, fontsize=9, pad=10)
        ax.grid(linewidth=0.4, alpha=0.5)
    for j in range(n, rows * cols):
        axes[j // cols][j % cols].axis("off")
    handles = [plt.Line2D([0], [0], color=VARIANT_COLORS.get(v, "C0"),
                          linewidth=2.4, label=v) for v in variants]
    fig.legend(handles=handles, loc="upper center",
               bbox_to_anchor=(0.5, 1.02),
               ncol=len(variants), frameon=False, fontsize=9.5,
               title="variant", title_fontsize=9.5)
    fig.suptitle(f"HiBench: per-workload radar fingerprint — profile={profile}  "
                 f"(metrics scaled to per-metric maximum)",
                 y=1.06, fontsize=10.5)
    fig.tight_layout()
    _save(fig, outdir / "fig05_radar_fingerprint.png", "fig05")


# ---------------------------------------------------------------------------
# Fig 06 — IntP Fig. 5: PCA of HiBench workloads (per profile × variant)
# ---------------------------------------------------------------------------

def fig_pca(df: pd.DataFrame, outdir: Path) -> None:
    if not HAS_SKLEARN:
        return
    profiles = _ordered_profiles(df["profile"].unique())
    variants = _ordered_variants(df["variant"].unique())
    pairs = [(p, v) for p in profiles for v in variants]
    n = len(pairs)
    if n == 0:
        return
    cols = min(3, n)
    rows = (n + cols - 1) // cols
    fig, axes = plt.subplots(rows, cols, figsize=_clamp_figsize(5 * cols, 4 * rows), squeeze=False)
    last = -1
    for idx, (profile, variant) in enumerate(pairs):
        last = idx
        ax = axes[idx // cols][idx % cols]
        sub = (df[(df.profile == profile) & (df.variant == variant)]
               .groupby("workload")[METRICS].mean().fillna(0))
        if len(sub) < 3:
            ax.set_title(f"{profile}/{variant}: too few"); ax.axis("off"); continue
        try:
            pca = PCA(n_components=2)
            Y = pca.fit_transform(sub.values)
        except Exception as e:
            ax.set_title(f"{profile}/{variant}: PCA failed"); ax.axis("off"); continue
        ax.scatter(Y[:, 0], Y[:, 1], s=120, alpha=0.78,
                   color=VARIANT_COLORS.get(variant, "C0"),
                   edgecolor="black", linewidth=0.4)
        for i, label in enumerate(sub.index):
            ax.annotate(label, (Y[i, 0], Y[i, 1]),
                        fontsize=7, alpha=0.85,
                        xytext=(4, 4), textcoords="offset points")
        ax.axhline(0, color="gray", linewidth=0.5, linestyle=":")
        ax.axvline(0, color="gray", linewidth=0.5, linestyle=":")
        ax.set_title(f"{variant} / {profile}\n"
                     f"PC1={pca.explained_variance_ratio_[0]*100:.1f}%  "
                     f"PC2={pca.explained_variance_ratio_[1]*100:.1f}%", fontsize=9.5)
        ax.set_xlabel("PC1"); ax.set_ylabel("PC2")
    for j in range(last + 1, rows * cols):
        axes[j // cols][j % cols].axis("off")
    fig.suptitle("HiBench workloads in PCA space (IntP Fig. 5 reproduction)",
                 y=1.02, fontsize=11)
    fig.tight_layout()
    _save(fig, outdir / "fig06_pca_workloads.png", "fig06")


# ---------------------------------------------------------------------------
# Fig 07 — IntP Fig. 3 / IADA Fig. 5: smoothed trace per (variant,workload)
# ---------------------------------------------------------------------------

def fig_timeseries(run_dirs: list[Path], outdir: Path) -> None:
    """Pick one representative rep per (profile,variant,workload) and plot
    a multi-metric smoothed trace."""
    traces = []  # list of (profile, variant, workload, df)
    for run_dir in run_dirs:
        meta = _read_metadata(run_dir)
        profile = meta.get("profile", run_dir.name.split("-large-")[0])
        for prof_path in run_dir.rglob("profiler.tsv"):
            parts = prof_path.parts
            try:
                variant = parts[-4]; workload = parts[-3]
            except IndexError:
                continue
            variant = RENAME.get(variant, variant)
            df_t = load_profiler_tsv(prof_path)
            if df_t.empty: continue
            traces.append((profile, variant, workload, prof_path, df_t))
    if not traces:
        print("[fig07] no profiler.tsv traces — skip")
        return

    # Choose: one trace per (profile,variant,workload), prefer rep1
    chosen: dict[tuple, tuple] = {}
    for profile, variant, workload, path, df_t in traces:
        key = (profile, variant, workload)
        is_rep1 = path.parts[-2] == "rep1"
        if key not in chosen or (is_rep1 and chosen[key][0].parts[-2] != "rep1"):
            chosen[key] = (path, df_t)

    profiles = _ordered_profiles({k[0] for k in chosen})
    variants = _ordered_variants({k[1] for k in chosen})
    workloads = _ordered_workloads({k[2] for k in chosen})
    if not workloads or not variants:
        return

    # One figure per profile: rows = variants, cols = workloads
    for profile in profiles:
        nrows = len(variants); ncols = len(workloads)
        fig, axes = plt.subplots(nrows, ncols,
                                 figsize=_clamp_figsize(2.6 * ncols, 1.7 * nrows),
                                 squeeze=False, sharex=False, sharey=True)
        for ri, variant in enumerate(variants):
            for ci, wl in enumerate(workloads):
                ax = axes[ri][ci]
                key = (profile, variant, wl)
                if key not in chosen:
                    ax.axis("off"); continue
                _, df_t = chosen[key]
                if "ts" in df_t and df_t["ts"].notna().any():
                    t = df_t["ts"] - df_t["ts"].min()
                else:
                    t = np.arange(len(df_t))
                for m in METRICS:
                    if m in df_t.columns:
                        y = _smooth(df_t[m].fillna(0).values, window=15)
                        ax.plot(t, y, color=METRIC_COLORS[m],
                                linewidth=1.0, alpha=0.92, label=METRIC_LABEL[m])
                if ri == 0:
                    ax.set_title(wl, fontsize=8.5)
                if ci == 0:
                    ax.set_ylabel(f"{variant}\nlevel", fontsize=8)
                if ri == nrows - 1:
                    ax.set_xlabel("time (s)", fontsize=8)
                ax.tick_params(labelsize=7)
        handles, labels = [], []
        for r in range(nrows):
            for c in range(ncols):
                hh, ll = axes[r][c].get_legend_handles_labels()
                if hh:
                    handles, labels = hh, ll; break
            if handles: break
        if handles:
            fig.legend(handles, labels, loc="upper center",
                       bbox_to_anchor=(0.5, 1.02),
                       ncol=len(METRICS), frameon=False, fontsize=8.5)
        fig.suptitle(f"HiBench timeseries — profile={profile}  "
                     f"(IntP Fig. 3 / IADA Fig. 5 reproduction)",
                     y=1.06, fontsize=11)
        fig.tight_layout()
        suffix = f"_{profile}" if len(profiles) > 1 else ""
        _save(fig, outdir / f"fig07_timeseries{suffix}.png", f"fig07-{profile}")


# ---------------------------------------------------------------------------
# Fig 08 — IADA Fig. 6: Δ resource (netp-extreme − standard) per variant
# ---------------------------------------------------------------------------

def fig_idi_bars(df: pd.DataFrame, outdir: Path) -> None:
    profiles = _ordered_profiles(df["profile"].unique())
    if "standard" not in profiles or "netp-extreme" not in profiles:
        print("[fig08] need both profiles — skip")
        return
    variants = _ordered_variants(df["variant"].unique())
    rows = []
    for variant in variants:
        s = df[(df.variant == variant) & (df.profile == "standard")]
        p = df[(df.variant == variant) & (df.profile == "netp-extreme")]
        if s.empty or p.empty: continue
        for fam, members in RESOURCE_FAMILY.items():
            members = [m for m in members if m in df.columns]
            if not members: continue
            s_v = s[members].mean().mean()
            p_v = p[members].mean().mean()
            if pd.isna(s_v) or pd.isna(p_v): continue
            rows.append(dict(variant=variant, resource=fam,
                             standard=s_v, netp_extreme=p_v,
                             delta=p_v - s_v))
    if not rows:
        return
    rdf = pd.DataFrame(rows)
    rdf.to_csv(outdir / "idi_resource.csv", index=False)
    resources = list(RESOURCE_FAMILY.keys())
    fig, ax = plt.subplots(figsize=_clamp_figsize(7.4, 3.6))
    x = np.arange(len(resources))
    bar_w = 0.8 / max(1, len(variants))
    for vi, variant in enumerate(variants):
        offsets = (vi - (len(variants) - 1) / 2) * bar_w
        vals = [rdf[(rdf.variant == variant) & (rdf.resource == r)]["delta"].mean()
                for r in resources]
        ax.bar(x + offsets, vals, width=bar_w,
               color=VARIANT_COLORS.get(variant, f"C{vi}"),
               edgecolor="white", linewidth=0.4,
               label=VARIANT_LABELS.get(variant, variant))
    ax.set_xticks(x); ax.set_xticklabels(resources)
    ax.axhline(0, color="black", linewidth=0.5)
    ax.set_ylabel("Δ interference (netp-extreme − standard, %)")
    ax.set_title("Resource-level sensitivity to network interference profile\n"
                 "(IADA Fig. 6 reproduction)", fontsize=10)
    ax.legend(ncol=len(variants), fontsize=8.5,
              loc="upper center", bbox_to_anchor=(0.5, -0.13))
    fig.tight_layout()
    _save(fig, outdir / "fig08_idi_bars.png", "fig08")


# ---------------------------------------------------------------------------
# Fig 00 — Canonical IntP Fig. 4 (single panel per (profile,variant)).
# Bars grouped per workload, colored by metric using the original IntP paper
# caption: cache=red, cpu=brown, disk=green, memory=blue, network=pink.
# ---------------------------------------------------------------------------

CANONICAL_METRIC_COLORS = {
    "llcocc": "#d62728",  # cache — red
    "llcmr":  "#ff9896",  # cache miss — light red
    "cpu":    "#8c564b",  # cpu — brown
    "blk":    "#2ca02c",  # disk — green
    "mbw":    "#1f77b4",  # memory bus — blue
    "nets":   "#e377c2",  # network stack — pink
    "netp":   "#c4448a",  # network phys — darker pink
}


def fig_canonical_intp_fig4(df: pd.DataFrame, outdir: Path) -> None:
    profiles = _ordered_profiles(df["profile"].unique())
    variants = _ordered_variants(df["variant"].unique())
    workloads = _ordered_workloads(df["workload"].unique())
    if not (profiles and variants and workloads):
        return
    pairs = [(p, v) for p in profiles for v in variants]
    n = len(pairs)
    cols = min(2, n)
    rows = (n + cols - 1) // cols
    fig, axes = plt.subplots(rows, cols,
                             figsize=_clamp_figsize(7.4 * cols, 3.4 * rows),
                             squeeze=False, sharey=True)
    last = -1
    for idx, (profile, variant) in enumerate(pairs):
        last = idx
        ax = axes[idx // cols][idx % cols]
        sub = (df[(df.profile == profile) & (df.variant == variant)]
               .set_index("workload").reindex(workloads))
        x = np.arange(len(sub))
        bar_w = 0.8 / max(1, len(METRICS))
        for mi, m in enumerate(METRICS):
            offset = (mi - (len(METRICS) - 1) / 2) * bar_w
            vals = sub[m].fillna(0).values
            ax.bar(x + offset, vals, width=bar_w,
                   color=CANONICAL_METRIC_COLORS.get(m, METRIC_COLORS[m]),
                   edgecolor="white", linewidth=0.25,
                   label=METRIC_LABEL[m] if idx == 0 else None)
        ax.set_xticks(x)
        ax.set_xticklabels(workloads, rotation=30, ha="right", fontsize=7.5)
        ax.set_title(f"{VARIANT_LABELS.get(variant, variant)} · profile={profile}",
                     fontsize=9.5)
        ax.set_ylabel("interference (%)")
    for j in range(last + 1, rows * cols):
        axes[j // cols][j % cols].axis("off")
    handles, labels = axes[0][0].get_legend_handles_labels()
    if handles:
        fig.legend(handles, labels, loc="upper center",
                   bbox_to_anchor=(0.5, 1.02),
                   ncol=len(METRICS), frameon=False, fontsize=8.5)
    fig.suptitle("HiBench: IntP Fig. 4 (canonical view) — interference ratios "
                 "per workload", y=1.05, fontsize=11)
    fig.tight_layout()
    _save(fig, outdir / "fig00_canonical_intp_fig4.png", "fig00")


# ---------------------------------------------------------------------------
# Fig 09 — IntP Fig. 8 reproduction: resource-family time series.
# Per (profile,variant,workload) trace, overlaying mean of each resource
# family (cache/cpu/disk/memory/network) with smoothed lines. Mirrors the
# 4-line interference time series of IntP Fig. 8.
# ---------------------------------------------------------------------------

def fig_resource_timeseries(run_dirs: list[Path], outdir: Path) -> None:
    traces: list[tuple] = []
    for run_dir in run_dirs:
        meta = _read_metadata(run_dir)
        profile = meta.get("profile", run_dir.name.split("-large-")[0])
        for prof_path in run_dir.rglob("profiler.tsv"):
            parts = prof_path.parts
            try:
                variant = parts[-4]; workload = parts[-3]
            except IndexError:
                continue
            variant = RENAME.get(variant, variant)
            df_t = load_profiler_tsv(prof_path)
            if df_t.empty: continue
            traces.append((profile, variant, workload, prof_path, df_t))
    if not traces:
        print("[fig09] no profiler.tsv traces — skip")
        return
    chosen: dict[tuple, tuple] = {}
    for profile, variant, workload, path, df_t in traces:
        key = (profile, variant, workload)
        is_rep1 = path.parts[-2] == "rep1"
        if key not in chosen or (is_rep1 and chosen[key][0].parts[-2] != "rep1"):
            chosen[key] = (path, df_t)
    profiles = _ordered_profiles({k[0] for k in chosen})
    variants = _ordered_variants({k[1] for k in chosen})
    workloads = _ordered_workloads({k[2] for k in chosen})
    if not workloads or not variants:
        return
    for profile in profiles:
        nrows = len(variants); ncols = len(workloads)
        fig, axes = plt.subplots(
            nrows, ncols,
            figsize=_clamp_figsize(2.2 * ncols, 1.7 * nrows),
            squeeze=False, sharex=False, sharey=True,
        )
        for ri, variant in enumerate(variants):
            for ci, wl in enumerate(workloads):
                ax = axes[ri][ci]
                key = (profile, variant, wl)
                if key not in chosen:
                    ax.axis("off"); continue
                _, df_t = chosen[key]
                if "ts" in df_t and df_t["ts"].notna().any():
                    t = (df_t["ts"] - df_t["ts"].min()).values
                else:
                    t = np.arange(len(df_t), dtype=float)
                for fam, members in RESOURCE_FAMILY.items():
                    members = [m for m in members if m in df_t.columns]
                    if not members: continue
                    series = df_t[members].mean(axis=1).fillna(0).values
                    y = _smooth(series, window=21)
                    ax.plot(t, y, color=RESOURCE_COLORS[fam], linewidth=1.2,
                            alpha=0.95, label=fam.capitalize())
                ax.set_ylim(-2, 105)
                if ri == 0:
                    ax.set_title(wl, fontsize=8.5)
                if ci == 0:
                    ax.set_ylabel(f"{variant}\nlevel (%)", fontsize=8)
                if ri == nrows - 1:
                    ax.set_xlabel("time (s)", fontsize=8)
                ax.tick_params(labelsize=7)
        handles, labels = [], []
        for r in range(nrows):
            for c in range(ncols):
                hh, ll = axes[r][c].get_legend_handles_labels()
                if hh:
                    handles, labels = hh, ll; break
            if handles: break
        if handles:
            fig.legend(handles, labels, loc="upper center",
                       bbox_to_anchor=(0.5, 1.02),
                       ncol=len(handles), frameon=False, fontsize=9)
        fig.suptitle(f"HiBench resource-family timeseries — profile={profile}  "
                     f"(IntP Fig. 8 reproduction)", y=1.06, fontsize=11)
        fig.tight_layout()
        suffix = f"_{profile}" if len(profiles) > 1 else ""
        _save(fig, outdir / f"fig09_resource_timeseries{suffix}.png",
              f"fig09-{profile}")


# ---------------------------------------------------------------------------
# Fig 10 — Variant × resource summary (NEW visualisation).
# Compact heatmap suitable for the ever-growing experiment matrix.
# ---------------------------------------------------------------------------

def fig_variant_resource_heatmap(df: pd.DataFrame, outdir: Path) -> None:
    if df.empty:
        return
    rows: list[dict] = []
    for profile in _ordered_profiles(df["profile"].unique()):
        sub_p = df[df.profile == profile]
        for variant in _ordered_variants(sub_p["variant"].unique()):
            sub = sub_p[sub_p.variant == variant]
            for fam, members in RESOURCE_FAMILY.items():
                members = [m for m in members if m in sub.columns]
                if not members: continue
                v = sub[members].mean(axis=1).mean()
                if pd.isna(v):
                    continue
                rows.append(dict(profile=profile, variant=variant,
                                 resource=fam, mean=float(v)))
    if not rows:
        return
    rdf = pd.DataFrame(rows)
    rdf.to_csv(outdir / "variant_resource_summary.csv", index=False)
    profiles = _ordered_profiles(rdf["profile"].unique())
    fig, axes = plt.subplots(
        1, len(profiles),
        figsize=_clamp_figsize(3.0 + 2.6 * len(profiles),
                               0.42 * rdf["variant"].nunique() + 1.7),
        squeeze=False, sharey=True,
    )
    resources = list(RESOURCE_FAMILY.keys())
    im = None
    for i, profile in enumerate(profiles):
        ax = axes[0][i]
        sub = rdf[rdf.profile == profile]
        pivot = sub.pivot_table(index="variant", columns="resource", values="mean")
        pivot = pivot.reindex(index=_ordered_variants(pivot.index), columns=resources)
        masked = np.ma.masked_invalid(pivot.values)
        cmap = plt.get_cmap("viridis").copy()
        cmap.set_bad(color="#dddddd")
        im = ax.imshow(masked, cmap=cmap, vmin=0, vmax=100, aspect="auto")
        ax.set_xticks(range(len(resources))); ax.set_xticklabels(resources)
        ax.set_yticks(range(len(pivot.index))); ax.set_yticklabels(pivot.index)
        ax.set_title(f"profile={profile}", fontsize=9.5)
        for (yi, xi), v in np.ndenumerate(pivot.values):
            if not np.isnan(v):
                ax.text(xi, yi, f"{v:.0f}", ha="center", va="center",
                        fontsize=7,
                        color="white" if v > 50 else "black")
        ax.grid(False)
    if im is not None:
        fig.colorbar(im, ax=axes.ravel().tolist(), fraction=0.04, shrink=0.85,
                     label="mean interference (%)")
    fig.suptitle("HiBench variant × resource family — mean interference",
                 y=1.02, fontsize=11)
    _save(fig, outdir / "fig10_variant_resource_heatmap.png", "fig10")


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

def main() -> None:
    p = argparse.ArgumentParser(description="Plot HiBench IntP results")
    p.add_argument("hibench_dir", type=Path,
                   help="Directory containing hibench run subdirs")
    p.add_argument("--out", type=Path, default=None,
                   help="Output directory (default: <hibench_dir>/plots)")
    args = p.parse_args()

    hdir = args.hibench_dir
    if (hdir / "hibench").is_dir():
        hdir = hdir / "hibench"
    if not hdir.is_dir():
        sys.exit(f"Not a directory: {hdir}")

    outdir = args.out or (hdir / "plots")
    outdir.mkdir(parents=True, exist_ok=True)

    setup_style()

    print(f"Loading hibench results from {hdir}")
    df, run_dirs = load_hibench_dir(hdir)
    print(f"  variants : {sorted(df['variant'].unique())}")
    print(f"  profiles : {sorted(df['profile'].unique())}")
    print(f"  workloads: {sorted(df['workload'].unique())}")
    df.to_csv(outdir / "combined-means.csv", index=False)

    fig_canonical_intp_fig4(df, outdir)        # fig00  IntP Fig.4 canonical
    fig_fingerprint(df, outdir)                # fig01
    fig_sensitivity(df, outdir)                # fig02
    fig_metric_compare(df, outdir)             # fig03
    fig_per_workload_bars(df, outdir)          # fig04  IntP Fig.4 panels
    fig_radar(df, outdir)                      # fig05  IntP Fig.4 alt
    fig_pca(df, outdir)                        # fig06  IntP Fig.5
    fig_timeseries(run_dirs, outdir)           # fig07  IntP Fig.3 / IADA Fig.5
    fig_idi_bars(df, outdir)                   # fig08  IADA Fig.6
    fig_resource_timeseries(run_dirs, outdir)  # fig09  IntP Fig.8
    fig_variant_resource_heatmap(df, outdir)   # fig10  new summary

    print(f"Done. Figures in {outdir}")


if __name__ == "__main__":
    main()
