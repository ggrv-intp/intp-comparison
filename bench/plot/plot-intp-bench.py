#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# plot-intp-bench.py — Publication-style figures from intp-bench results.
#
# The figure set reproduces the structure of the original IntP paper
# (Xavier et al., 2022, SBAC-PAD) and the IADA paper (Meyer et al., 2022, JSS),
# adapted to the new IntP context where multiple *variants* of the profiler
# are compared across multiple *environments* (bare/container/vm) and the
# stress-ng / app01..app15 workload set.
#
# Figures (paper reference in parens):
#   fig01_per_workload_bars.png  (IntP Fig. 4)  one panel per workload,
#                                              bars = variants × metrics
#   fig01b_per_variant_bars.png  (IntP Fig. 4 dual view) one panel per
#                                              (env,variant), bars = workloads
#   fig02_pca_kmeans.png         (IntP Fig. 5)  PCA + k-means per (env,variant)
#   fig03_timeseries.png         (IntP Fig. 3)  long mixed-load trace
#   fig04_overhead_bars.png      (Volpert-style) profiler overhead per variant
#   fig05_fidelity_matrix.png    (extended)     Pearson r vs ground truth
#   fig06_env_heatmap.png        (extended)     env degradation ratio
#   fig07_pairwise_heatmap.png   (extended)     pair × metric per variant
#   fig08_metric_availability.png (extended)    metric coverage map
#   fig09_radar_fingerprint.png  (IntP Fig. 4 alt) per-workload radar
#   fig10_workload_clustermap.png (new)          hierarchical workload cluster
#   fig11_idi_bars.png           (IADA Fig. 6)  Δ pairwise − solo per resource
#   fig12_pairwise_timeseries.png (IntP Fig. 8) multi-metric trace per pair
#   fig13_iada_segmented.png     (IADA Fig. 5)  Loess-smoothed segmented trace
#   fig14_variant_resource_heatmap.png (new)    variants × resources summary
#   fig00_canonical_intp_fig4.png (IntP Fig. 4 canonical) single panel,
#                                              x = workload, grouped bars per metric
#
# All output figures are sized so neither dimension exceeds ~1900px (compatible
# with downstream image reviewers that reject ≥2000px assets).
#
# Run:   python3 plot-intp-bench.py /path/to/results/<bench-full>
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
    from matplotlib.colors import ListedColormap
except ImportError:
    sys.exit("matplotlib is required: pip install matplotlib pandas scikit-learn scipy")

try:
    from sklearn.decomposition import PCA
    from sklearn.cluster import KMeans
    HAS_SKLEARN = True
except ImportError:
    HAS_SKLEARN = False
    warnings.warn("scikit-learn not installed — PCA/k-means figure will be skipped")

try:
    from scipy.cluster.hierarchy import linkage, leaves_list
    HAS_SCIPY = True
except ImportError:
    HAS_SCIPY = False

# ---------------------------------------------------------------------------
# Constants — palette aligned with IntP Fig. 8 / IADA Fig. 5 conventions:
#   Cache = orange, CPU = black/dark, Disk = green, Memory = blue, Network = pink.
# ---------------------------------------------------------------------------

METRICS = ["netp", "nets", "blk", "mbw", "llcmr", "llcocc", "cpu"]
METRIC_COLORS = {
    "netp":   "#e377c2",   # network physical — pink
    "nets":   "#9467bd",   # network stack — purple
    "blk":    "#2ca02c",   # block / disk — green
    "mbw":    "#1f77b4",   # memory bandwidth — blue
    "llcmr":  "#d62728",   # LLC miss rate — red
    "llcocc": "#ff7f0e",   # LLC occupancy — orange (Cache in paper)
    "cpu":    "#000000",   # cpu — black (CPU in paper)
}
METRIC_LABEL = {
    "netp":   "netp (net phys.)",
    "nets":   "nets (net stack)",
    "blk":    "blk (disk)",
    "mbw":    "mbw (memory)",
    "llcmr":  "llcmr (LLC miss)",
    "llcocc": "llcocc (cache)",
    "cpu":    "cpu",
}
# Logical resource families used by IntP Fig. 8 (4 lines: Cache/CPU/Disk/Memory)
RESOURCE_FAMILY = {
    "cache":   ["llcocc", "llcmr"],
    "cpu":     ["cpu"],
    "disk":    ["blk"],
    "memory":  ["mbw"],
    "network": ["netp", "nets"],
}
RESOURCE_COLORS = {
    "cache":   "#ff7f0e",  # orange
    "cpu":     "#000000",  # black
    "disk":    "#2ca02c",  # green
    "memory":  "#1f77b4",  # blue
    "network": "#e377c2",  # pink
}

VARIANT_ORDER = ["v0", "v0.1", "v1", "v1.1", "v2", "v3.1", "v3"]
VARIANT_COLORS = {
    "v0":   "#7f7f7f",
    "v0.1": "#bcbd22",
    "v1":   "#17becf",
    "v1.1": "#aec7e8",
    "v2":   "#1f77b4",
    "v3.1": "#ff7f0e",
    "v3":   "#2ca02c",
}
ENV_ORDER = ["bare", "container", "vm"]

# Pre-rename → current names. Applied at load time so legacy result trees
# (v1..v6 directories) are displayed with the current nomenclature.
RENAME = {"v1": "v0", "v2": "v0.1", "v3": "v1", "v4": "v2", "v5": "v3.1", "v6": "v3"}


# ---------------------------------------------------------------------------
# Style
# ---------------------------------------------------------------------------

# Hard cap on output PNG dimensions (pixels). Many downstream readers reject
# images whose long side ≥ 2000 px. We pick 1900 to leave headroom for tight
# bbox padding.
MAX_PIXELS = 1900
SAVE_DPI = 130


def setup_style() -> None:
    """Publication-friendly defaults. Call once at the start of main()."""
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


def _clamp_figsize(width: float, height: float) -> tuple[float, float]:
    """Scale (width, height) so neither side exceeds MAX_PIXELS at SAVE_DPI."""
    max_in = MAX_PIXELS / SAVE_DPI
    scale = min(1.0, max_in / max(width, 1e-9), max_in / max(height, 1e-9))
    return width * scale, height * scale


def _save(fig, path: Path, label: str) -> None:
    fig.savefig(path, bbox_inches="tight")
    plt.close(fig)
    print(f"[{label}] {path.name}")


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

def load_profiler_tsv(path: Path) -> pd.DataFrame:
    """Load one profiler.tsv. Returns DataFrame with columns ts + 7 metrics."""
    rows = []
    with path.open() as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#") or line.startswith("ts") or line.startswith("netp"):
                continue
            parts = line.split()
            # Schema: ts netp nets blk mbw llcmr llcocc cpu  (8 cols)
            # or:     netp nets blk mbw llcmr llcocc cpu     (7 cols)
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


def _maybe_rename_variants(values) -> tuple:
    legacy = {"v4", "v5", "v6"}
    if any(v in legacy for v in values):
        return tuple(RENAME.get(v, v) for v in values), True
    return tuple(values), False


def collect_means(results_dir: Path) -> pd.DataFrame:
    """Load every profiler.tsv and return per-run mean per metric."""
    rows = []
    for f in results_dir.rglob("profiler.tsv"):
        parts = f.parts
        try:
            env = parts[-6]; variant = parts[-5]; stage = parts[-4]
            wl = parts[-3]; rep = int(parts[-2].replace("rep", ""))
        except (IndexError, ValueError):
            continue
        df = load_profiler_tsv(f)
        if df.empty:
            continue
        rec = dict(env=env, variant=variant, stage=stage, workload=wl,
                   rep=rep, samples=len(df))
        for m in METRICS:
            rec[m] = df[m].mean(skipna=True)
        rows.append(rec)
    df = pd.DataFrame(rows)
    if not df.empty:
        renamed, did = _maybe_rename_variants(df["variant"].unique())
        if did:
            df["variant"] = df["variant"].map(lambda v: RENAME.get(v, v))
            print(f"  applied legacy variant rename: {RENAME}")
    return df


def _ordered_variants(values) -> list[str]:
    present = set(values)
    return [v for v in VARIANT_ORDER if v in present]


def _ordered_envs(values) -> list[str]:
    present = set(values)
    return [e for e in ENV_ORDER if e in present]


# ---------------------------------------------------------------------------
# Fig 01 — IntP Fig. 4: per-workload panel grid, variants compared
# ---------------------------------------------------------------------------

def fig_per_workload_bars(means: pd.DataFrame, outdir: Path) -> None:
    """Reproduces IntP paper Fig. 4. One small-multiple per workload.

    Within each panel: x-axis = metric, grouped bars = variant.
    A separate file is produced per environment so that variants are compared
    against each other (the new context: one tool, many variants).
    """
    solo = means[means.stage == "solo"]
    if solo.empty:
        print("[per_workload] no solo data — skip")
        return
    envs = _ordered_envs(solo["env"].unique())
    variants = _ordered_variants(solo["variant"].unique())
    workloads = sorted(solo["workload"].unique())
    if not (envs and variants and workloads):
        return

    grouped = (solo.groupby(["env", "variant", "workload"])[METRICS]
               .mean().reset_index())

    for env in envs:
        sub_env = grouped[grouped.env == env]
        if sub_env.empty:
            continue
        n = len(workloads)
        cols = 5 if n >= 10 else min(3, n)
        rows = (n + cols - 1) // cols
        fig, axes = plt.subplots(rows, cols,
                                 figsize=_clamp_figsize(2.6 * cols, 2.0 * rows),
                                 squeeze=False, sharey=True)
        x = np.arange(len(METRICS))
        bar_w = 0.8 / max(1, len(variants))
        for i, wl in enumerate(workloads):
            ax = axes[i // cols][i % cols]
            for vi, variant in enumerate(variants):
                row = sub_env[(sub_env.variant == variant) & (sub_env.workload == wl)]
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
            ymax = sub_env[METRICS].max().max()
            ax.set_ylim(0, max(1.0, float(ymax) * 1.10))
            ax.tick_params(axis="y", labelsize=7)
        for j in range(n, rows * cols):
            axes[j // cols][j % cols].axis("off")
        # Y label on first column only
        for r in range(rows):
            axes[r][0].set_ylabel("interference (%)", fontsize=8)
        # Single legend
        handles = [plt.Rectangle((0, 0), 1, 1, color=VARIANT_COLORS.get(v, "C0"))
                   for v in variants]
        fig.legend(handles, variants, loc="upper center",
                   bbox_to_anchor=(0.5, 1.02 if rows < 4 else 1.005),
                   ncol=len(variants), frameon=False, fontsize=8.5,
                   title="variant", title_fontsize=8.5)
        fig.suptitle(f"Per-workload variant fingerprint — env={env}  "
                     f"(IntP Fig. 4 reproduction)", y=1.04, fontsize=11)
        fig.tight_layout()
        suffix = f"_{env}" if len(envs) > 1 else ""
        _save(fig, outdir / f"fig01_per_workload_bars{suffix}.png", "fig01")


def fig_per_variant_bars(means: pd.DataFrame, outdir: Path) -> None:
    """Dual view of IntP Fig. 4: one panel per (env,variant), all workloads."""
    solo = means[means.stage == "solo"]
    if solo.empty:
        return
    grouped = solo.groupby(["env", "variant", "workload"])[METRICS].mean().reset_index()
    pairs = grouped[["env", "variant"]].drop_duplicates().values.tolist()
    n = len(pairs)
    if n == 0:
        return
    cols = min(3, n)
    rows = (n + cols - 1) // cols
    fig, axes = plt.subplots(rows, cols,
                             figsize=_clamp_figsize(6 * cols, 3.6 * rows),
                             squeeze=False)
    last_idx = -1
    for idx, (env, variant) in enumerate(pairs):
        last_idx = idx
        ax = axes[idx // cols][idx % cols]
        sub = grouped[(grouped.env == env) & (grouped.variant == variant)].copy()
        sub = sub.sort_values("workload")
        x = np.arange(len(sub))
        width = 0.11
        for i, m in enumerate(METRICS):
            ax.bar(x + (i - 3) * width, sub[m].values, width=width,
                   label=METRIC_LABEL[m], color=METRIC_COLORS[m])
        ax.set_xticks(x)
        ax.set_xticklabels(sub["workload"].values, rotation=45, ha="right", fontsize=7)
        ax.set_ylim(0, max(1.0, sub[METRICS].max().max() * 1.1))
        ax.set_title(f"{env} / {variant}")
        ax.set_ylabel("interference (%)")
    for j in range(last_idx + 1, rows * cols):
        axes[j // cols][j % cols].axis("off")
    handles, labels = axes[0][0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="upper center", bbox_to_anchor=(0.5, 1.02),
               ncol=len(METRICS), frameon=False, fontsize=8)
    fig.suptitle("Per (env,variant) workload fingerprint", y=1.05)
    fig.tight_layout()
    _save(fig, outdir / "fig01b_per_variant_bars.png", "fig01b")


# ---------------------------------------------------------------------------
# Fig 02 — IntP Fig. 5: PCA + k-means
# ---------------------------------------------------------------------------

def fig_pca_kmeans(means: pd.DataFrame, outdir: Path) -> None:
    if not HAS_SKLEARN:
        return
    solo = means[means.stage == "solo"]
    if solo.empty:
        print("[pca] no solo data — skip")
        return
    pairs = solo[["env", "variant"]].drop_duplicates().values.tolist()
    n = len(pairs)
    cols = min(3, n)
    rows = (n + cols - 1) // cols
    fig, axes = plt.subplots(rows, cols,
                             figsize=_clamp_figsize(5.6 * cols, 4.4 * rows),
                             squeeze=False)
    cluster_palette = plt.get_cmap("Set1")
    for idx, (env, variant) in enumerate(pairs):
        ax = axes[idx // cols][idx % cols]
        sub = (solo[(solo.env == env) & (solo.variant == variant)]
               .groupby("workload")[METRICS].mean().fillna(0))
        if len(sub) < 4:
            ax.set_title(f"{env} / {variant}: too few workloads")
            ax.axis("off")
            continue
        X = sub.values
        try:
            pca = PCA(n_components=2)
            Y = pca.fit_transform(X)
            k = min(4, len(sub))
            km = KMeans(n_clusters=k, n_init=10, random_state=42).fit(X)
        except Exception as e:
            ax.set_title(f"{env}/{variant}: PCA failed ({e})")
            ax.axis("off")
            continue
        for c in range(k):
            mask = km.labels_ == c
            ax.scatter(Y[mask, 0], Y[mask, 1], s=120, alpha=0.78,
                       color=cluster_palette(c), edgecolor="black",
                       linewidth=0.4, label=f"cluster {c+1}")
        for i, label in enumerate(sub.index):
            ax.annotate(label, (Y[i, 0], Y[i, 1]),
                        fontsize=7, alpha=0.85,
                        xytext=(4, 4), textcoords="offset points")
        ax.axhline(0, color="gray", linewidth=0.5, linestyle=":")
        ax.axvline(0, color="gray", linewidth=0.5, linestyle=":")
        ax.set_title(f"{env} / {variant}\nPC1={pca.explained_variance_ratio_[0]*100:.1f}%  "
                     f"PC2={pca.explained_variance_ratio_[1]*100:.1f}%", fontsize=9.5)
        ax.set_xlabel("PC1"); ax.set_ylabel("PC2")
        ax.legend(loc="best", fontsize=7)
    for j in range(idx + 1, rows * cols):
        axes[j // cols][j % cols].axis("off")
    fig.suptitle("PCA + k-means clustering of workloads (IntP Fig. 5 reproduction)",
                 y=1.01, fontsize=11)
    fig.tight_layout()
    _save(fig, outdir / "fig02_pca_kmeans.png", "fig02")


# ---------------------------------------------------------------------------
# Fig 03 — IntP Fig. 3: long mixed-load trace
# ---------------------------------------------------------------------------

def _smooth(arr: np.ndarray, window: int = 9) -> np.ndarray:
    if len(arr) < window:
        return arr
    kernel = np.ones(window) / window
    return np.convolve(arr, kernel, mode="same")


def fig_timeseries(results_dir: Path, outdir: Path) -> None:
    files = list(results_dir.rglob("timeseries/**/profiler.tsv"))
    if not files:
        print("[timeseries] no timeseries data — skip")
        return
    legacy = any(f.parts[-5] in {"v4", "v5", "v6"} for f in files)
    n = len(files)
    cols = min(2, n)
    rows = (n + cols - 1) // cols
    fig, axes = plt.subplots(rows, cols,
                             figsize=_clamp_figsize(8 * cols, 3.4 * rows),
                             squeeze=False, sharex=False)
    last_idx = -1
    for idx, f in enumerate(sorted(files)):
        last_idx = idx
        ax = axes[idx // cols][idx % cols]
        env = f.parts[-6]; variant = f.parts[-5]
        if legacy:
            variant = RENAME.get(variant, variant)
        df = load_profiler_tsv(f)
        if df.empty:
            ax.axis("off"); continue
        if "ts" in df and df["ts"].notna().any():
            t = df["ts"] - df["ts"].min()
        else:
            t = np.arange(len(df))
        for m in METRICS:
            if m in df.columns:
                y = _smooth(df[m].fillna(0).values, window=7)
                ax.plot(t, y, label=METRIC_LABEL[m],
                        color=METRIC_COLORS[m], linewidth=1.1, alpha=0.9)
        ax.set_title(f"{env} / {variant} — mixed_long")
        ax.set_xlabel("time (s)")
        ax.set_ylabel("interference level")
        ax.set_ylim(-2, 105)
    for j in range(last_idx + 1, rows * cols):
        axes[j // cols][j % cols].axis("off")
    handles, labels = axes[0][0].get_legend_handles_labels()
    if handles:
        fig.legend(handles, labels, loc="upper center",
                   bbox_to_anchor=(0.5, 1.02),
                   ncol=len(METRICS), frameon=False, fontsize=8)
    fig.suptitle("Long-trace interference profile (IntP Fig. 3 reproduction)",
                 y=1.05, fontsize=11)
    fig.tight_layout()
    _save(fig, outdir / "fig03_timeseries.png", "fig03")


# ---------------------------------------------------------------------------
# Fig 04 — Volpert-style overhead bars per variant (any env)
# ---------------------------------------------------------------------------

def fig_overhead_bars(results_dir: Path, outdir: Path) -> None:
    rows = []
    for elapsed_file in (results_dir / "overhead").rglob("elapsed_s"):
        parts = elapsed_file.parts
        try:
            env = parts[-5]; variant = parts[-4]; refid = parts[-3]
            rep = int(parts[-2].replace("rep", ""))
        except (IndexError, ValueError):
            continue
        try:
            elapsed = float(elapsed_file.read_text().strip())
        except (ValueError, OSError):
            continue
        rows.append(dict(env=env, variant=variant, ref=refid, rep=rep, elapsed=elapsed))
    if not rows:
        print("[overhead] no overhead data — skip")
        return
    df = pd.DataFrame(rows)
    _, did_rename = _maybe_rename_variants(df["variant"].unique())
    if did_rename:
        df["variant"] = df["variant"].map(lambda v: RENAME.get(v, v))
    base = (df[df.variant == "_baseline"]
            .groupby(["env", "ref"])["elapsed"].mean()
            .rename("baseline").reset_index())
    merged = df[df.variant != "_baseline"].merge(base, on=["env", "ref"], how="left")
    merged["overhead_pct"] = (merged["elapsed"] - merged["baseline"]) / merged["baseline"] * 100
    summary = (merged.groupby(["env", "variant", "ref"])["overhead_pct"]
               .agg(["mean", "std"]).reset_index())
    summary.to_csv(outdir / "overhead_summary.csv", index=False)

    refs = sorted(summary["ref"].unique())
    envs = _ordered_envs(summary["env"].unique())
    fig, axes = plt.subplots(len(envs), 1,
                             figsize=_clamp_figsize(7.5, 2.8 * len(envs) + 0.4),
                             squeeze=False, sharey=True)
    all_variants: list[str] = []
    for i, env in enumerate(envs):
        ax = axes[i][0]
        sub = summary[summary.env == env]
        variants_present = _ordered_variants(sub["variant"].unique())
        for v in variants_present:
            if v not in all_variants:
                all_variants.append(v)
        x = np.arange(len(refs))
        width = 0.8 / max(1, len(variants_present))
        for j, v in enumerate(variants_present):
            row = sub[sub.variant == v].set_index("ref").reindex(refs)
            ax.bar(x + (j - (len(variants_present) - 1) / 2) * width,
                   row["mean"].values,
                   yerr=row["std"].fillna(0).values, width=width,
                   color=VARIANT_COLORS.get(v, f"C{j}"),
                   label=v if i == 0 else None, capsize=2)
        ax.set_xticks(x); ax.set_xticklabels(refs, rotation=15)
        ax.set_ylabel("overhead (%)"); ax.set_title(f"env={env}")
        ax.axhline(0, color="black", linewidth=0.5)
    handles = [plt.Rectangle((0, 0), 1, 1, color=VARIANT_COLORS.get(v, "C0"))
               for v in all_variants]
    fig.legend(handles, all_variants, loc="upper center",
               bbox_to_anchor=(0.5, 1.04),
               ncol=max(1, len(all_variants)), frameon=False, fontsize=9,
               title="variant", title_fontsize=9)
    fig.suptitle("Profiler runtime overhead vs. baseline (Volpert-style)", y=1.10)
    fig.tight_layout()
    _save(fig, outdir / "fig04_overhead_bars.png", "fig04")


# ---------------------------------------------------------------------------
# Fig 05 — Fidelity (profiler vs ground-truth)
# ---------------------------------------------------------------------------

def fig_fidelity_matrix(results_dir: Path, outdir: Path) -> None:
    pair_map = {
        "cpu":    "cpu_busy_pct",
        "mbw":    "resctrl_mbw_bps",
        "llcocc": "resctrl_llcocc_bytes",
        "blk":    "disk_total_mb",
        "netp":   "net_total_mb",
    }
    rows = []
    for prof_path in results_dir.rglob("solo/**/profiler.tsv"):
        gt_path = prof_path.parent / "groundtruth.tsv"
        if not gt_path.exists(): continue
        try:
            prof = load_profiler_tsv(prof_path)
            gt = pd.read_csv(gt_path, sep="\t")
        except Exception:
            continue
        if prof.empty or gt.empty: continue
        gt["disk_total_mb"] = gt.get("disk_read_mb", 0).fillna(0) + gt.get("disk_write_mb", 0).fillna(0)
        gt["net_total_mb"]  = gt.get("net_rx_mb", 0).fillna(0)   + gt.get("net_tx_mb", 0).fillna(0)
        n = min(len(prof), len(gt))
        if n < 5: continue
        prof = prof.iloc[:n].reset_index(drop=True)
        gt = gt.iloc[:n].reset_index(drop=True)
        env = prof_path.parts[-6]; variant = prof_path.parts[-5]
        for metric, gt_col in pair_map.items():
            if metric not in prof or gt_col not in gt: continue
            a = pd.to_numeric(prof[metric], errors="coerce")
            b = pd.to_numeric(gt[gt_col], errors="coerce")
            mask = a.notna() & b.notna()
            if mask.sum() < 5 or a[mask].std() == 0 or b[mask].std() == 0: continue
            r = float(np.corrcoef(a[mask], b[mask])[0, 1])
            rows.append(dict(env=env, variant=variant, metric=metric, r=r))
    if not rows:
        print("[fidelity] no fidelity data — skip")
        return
    df = pd.DataFrame(rows)
    _, did_rename = _maybe_rename_variants(df["variant"].unique())
    if did_rename:
        df["variant"] = df["variant"].map(lambda v: RENAME.get(v, v))
    df = df.groupby(["env", "variant", "metric"])["r"].mean().reset_index()
    df.to_csv(outdir / "fidelity_matrix.csv", index=False)

    pivot = df.pivot_table(index="variant", columns="metric", values="r", aggfunc="mean")
    pivot = pivot.reindex(index=_ordered_variants(pivot.index),
                          columns=[m for m in pair_map if m in pivot.columns])
    fig, ax = plt.subplots(figsize=_clamp_figsize(6.5, 0.7 * len(pivot) + 1.4))
    masked = np.ma.masked_invalid(pivot.values)
    cmap = plt.get_cmap("RdBu_r").copy()
    cmap.set_bad(color="#dddddd")
    im = ax.imshow(masked, vmin=-1, vmax=1, cmap=cmap, aspect="auto")
    ax.set_xticks(range(len(pivot.columns))); ax.set_xticklabels(pivot.columns)
    ax.set_yticks(range(len(pivot.index)));   ax.set_yticklabels(pivot.index)
    for (i, j), v in np.ndenumerate(pivot.values):
        if np.isnan(v):
            ax.text(j, i, "n/a", ha="center", va="center", fontsize=8, color="#666")
        else:
            ax.text(j, i, f"{v:+.2f}", ha="center", va="center",
                    fontsize=8, color="black" if abs(v) < 0.5 else "white")
    ax.set_title("Profiler vs ground-truth Pearson r (solo)")
    cbar = fig.colorbar(im, ax=ax, fraction=0.04, label="Pearson r")
    cbar.ax.tick_params(labelsize=7)
    ax.grid(False)
    fig.tight_layout()
    _save(fig, outdir / "fig05_fidelity_matrix.png", "fig05")


# ---------------------------------------------------------------------------
# Fig 06 — Env degradation ratio heatmap
# ---------------------------------------------------------------------------

def fig_env_heatmap(means: pd.DataFrame, outdir: Path) -> None:
    solo = means[means.stage == "solo"]
    if solo.empty or solo["env"].nunique() < 2:
        print("[env_heatmap] need ≥2 envs — skip")
        return
    g = solo.groupby(["env", "variant"])[METRICS].mean().reset_index()
    bare = g[g.env == "bare"].set_index("variant")
    out_rows = []
    for env in [e for e in ENV_ORDER if e in g["env"].values and e != "bare"]:
        sub = g[g.env == env].set_index("variant")
        for variant in sub.index:
            if variant not in bare.index: continue
            for m in METRICS:
                b = bare.loc[variant, m]; o = sub.loc[variant, m]
                if pd.isna(b) or b == 0: continue
                out_rows.append(dict(env=env, variant=variant, metric=m, ratio=o / b))
    if not out_rows:
        return
    df = pd.DataFrame(out_rows)
    df.to_csv(outdir / "env_ratio.csv", index=False)
    envs_present = _ordered_envs(df["env"].unique())
    fig, axes = plt.subplots(1, len(envs_present),
                             figsize=_clamp_figsize(5.4 * len(envs_present), 3.4),
                             squeeze=False)
    for i, env in enumerate(envs_present):
        ax = axes[0][i]
        sub = df[df.env == env]
        pivot = sub.pivot_table(index="variant", columns="metric", values="ratio")
        pivot = pivot.reindex(index=_ordered_variants(pivot.index))
        im = ax.imshow(pivot.values, cmap="PiYG", vmin=0, vmax=2, aspect="auto")
        ax.set_xticks(range(len(pivot.columns))); ax.set_xticklabels(pivot.columns)
        ax.set_yticks(range(len(pivot.index)));   ax.set_yticklabels(pivot.index)
        ax.set_title(f"{env} / bare")
        for (yi, xi), v in np.ndenumerate(pivot.values):
            if not np.isnan(v):
                ax.text(xi, yi, f"{v:.2f}", ha="center", va="center", fontsize=7)
        ax.grid(False)
        fig.colorbar(im, ax=ax, fraction=0.04)
    fig.suptitle("Metric ratio across execution environments (1.0 = matches bare)", y=1.02)
    fig.tight_layout()
    _save(fig, outdir / "fig06_env_heatmap.png", "fig06")


# ---------------------------------------------------------------------------
# Fig 07 — Pairwise heatmap, per-variant panel of (workload-pair × metric)
# ---------------------------------------------------------------------------

def fig_pairwise_heatmap(means: pd.DataFrame, outdir: Path) -> None:
    pair = means[means.stage == "pairwise"]
    if pair.empty:
        print("[pairwise] no pairwise data — skip")
        return
    g = pair.groupby(["env", "variant", "workload"])[METRICS].mean().reset_index()
    g.to_csv(outdir / "pairwise_means.csv", index=False)
    envs = _ordered_envs(g["env"].unique())
    workloads = sorted(g["workload"].unique())
    for env in envs:
        sub_env = g[g.env == env]
        if sub_env.empty: continue
        variants = _ordered_variants(sub_env["variant"].unique())
        nv = len(variants)
        cols = min(3, nv)
        rows = (nv + cols - 1) // cols
        fig, axes = plt.subplots(rows, cols,
                                 figsize=_clamp_figsize(4.4 * cols, 0.30 * len(workloads) + 1.4),
                                 squeeze=False, sharey=True)
        last = -1
        for idx, variant in enumerate(variants):
            last = idx
            ax = axes[idx // cols][idx % cols]
            data = np.zeros((len(workloads), len(METRICS)))
            for wi, w in enumerate(workloads):
                row = sub_env[(sub_env.variant == variant) & (sub_env.workload == w)]
                if not row.empty:
                    data[wi] = row[METRICS].iloc[0].values
                else:
                    data[wi] = np.nan
            masked = np.ma.masked_invalid(data)
            cmap = plt.get_cmap("magma").copy()
            cmap.set_bad(color="#dddddd")
            im = ax.imshow(masked, cmap=cmap, aspect="auto", vmin=0, vmax=100)
            ax.set_xticks(range(len(METRICS))); ax.set_xticklabels(METRICS, rotation=45, ha="right", fontsize=7)
            ax.set_yticks(range(len(workloads))); ax.set_yticklabels(workloads, fontsize=7)
            ax.set_title(f"variant={variant}", fontsize=9)
            ax.grid(False)
        for j in range(last + 1, rows * cols):
            axes[j // cols][j % cols].axis("off")
        fig.colorbar(im, ax=axes.ravel().tolist(), shrink=0.8, label="interference (%)")
        fig.suptitle(f"Pairwise interference signal — env={env}", y=1.02, fontsize=11)
        _save(fig, outdir / f"fig07_pairwise_heatmap_{env}.png", f"fig07-{env}")


# ---------------------------------------------------------------------------
# Fig 08 — Metric availability
# ---------------------------------------------------------------------------

def fig_metric_availability(means: pd.DataFrame, outdir: Path) -> None:
    if means.empty: return
    avail_rows = []
    for variant in _ordered_variants(means["variant"].unique()):
        sub = means[means.variant == variant]
        for m in METRICS:
            ok = sub[m].notna().any() and (sub[m].fillna(0).abs().sum() > 0)
            avail_rows.append(dict(variant=variant, metric=m, available=int(ok)))
    df = pd.DataFrame(avail_rows)
    df.to_csv(outdir / "metric_availability.csv", index=False)
    pivot = df.pivot_table(index="variant", columns="metric", values="available")
    pivot = pivot.reindex(index=_ordered_variants(pivot.index),
                          columns=METRICS)
    fig, ax = plt.subplots(figsize=_clamp_figsize(6.2, 0.5 * len(pivot) + 1.2))
    cmap = ListedColormap(["#f4f4f4", "#2ca02c"])
    im = ax.imshow(pivot.values, cmap=cmap, vmin=0, vmax=1, aspect="auto")
    ax.set_xticks(range(len(pivot.columns))); ax.set_xticklabels(pivot.columns)
    ax.set_yticks(range(len(pivot.index)));   ax.set_yticklabels(pivot.index)
    for (i, j), v in np.ndenumerate(pivot.values):
        ax.text(j, i, "✓" if v else "—", ha="center", va="center",
                fontsize=10, color="white" if v else "#666")
    ax.set_title("Metric availability per variant (any non-zero reading)")
    ax.grid(False)
    fig.tight_layout()
    _save(fig, outdir / "fig08_metric_availability.png", "fig08")


# ---------------------------------------------------------------------------
# Fig 09 — Radar fingerprint per workload (variants overlaid)
# ---------------------------------------------------------------------------

def fig_radar_fingerprint(means: pd.DataFrame, outdir: Path) -> None:
    """Per-workload radar chart, one polygon per variant.

    Inspired by IntP Fig. 4 but emphasising shape comparison rather than bar
    height. Uses the bare environment when available.
    """
    solo = means[means.stage == "solo"]
    if solo.empty:
        return
    env = "bare" if "bare" in solo["env"].values else solo["env"].iloc[0]
    sub = solo[solo.env == env]
    workloads = sorted(sub["workload"].unique())
    variants = _ordered_variants(sub["variant"].unique())
    if not workloads or not variants:
        return
    # Normalise each metric across all (workload,variant) so radar shapes are
    # comparable. Avoid division by zero.
    grouped = sub.groupby(["workload", "variant"])[METRICS].mean().reset_index()
    norms = {m: max(1e-9, grouped[m].max()) for m in METRICS}

    n = len(workloads)
    # Cap panel grid to 4 cols so each polar plot has room for tick labels.
    cols = 4 if n >= 8 else min(3, n)
    rows = (n + cols - 1) // cols
    fig, axes = plt.subplots(rows, cols,
                             figsize=_clamp_figsize(3.2 * cols, 3.0 * rows),
                             subplot_kw=dict(polar=True), squeeze=False)
    angles = np.linspace(0, 2 * np.pi, len(METRICS), endpoint=False).tolist()
    angles += angles[:1]
    for i, wl in enumerate(workloads):
        ax = axes[i // cols][i % cols]
        for variant in variants:
            row = grouped[(grouped.workload == wl) & (grouped.variant == variant)]
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
        # Show ring values only on the first panel to keep others uncluttered.
        if i == 0:
            ax.set_yticklabels(["0.25", "0.50", "0.75", "1.00"], fontsize=6,
                               color="#555")
        else:
            ax.set_yticklabels(["", "", "", ""])
        ax.set_ylim(0, 1.05)
        ax.set_title(wl, fontsize=9, pad=10)
        ax.tick_params(axis="x", pad=2)
        ax.grid(linewidth=0.4, alpha=0.5)
    for j in range(n, rows * cols):
        axes[j // cols][j % cols].axis("off")
    handles = [plt.Line2D([0], [0], color=VARIANT_COLORS.get(v, "C0"),
                          linewidth=2.4, label=v) for v in variants]
    fig.legend(handles=handles, loc="upper center",
               bbox_to_anchor=(0.5, 1.02),
               ncol=len(variants), frameon=False, fontsize=9.5,
               title="variant", title_fontsize=9.5)
    fig.suptitle(f"Per-workload radar fingerprint — env={env}  "
                 f"(metrics scaled to per-metric maximum)",
                 y=1.06, fontsize=10.5)
    fig.tight_layout()
    _save(fig, outdir / "fig09_radar_fingerprint.png", "fig09")


# ---------------------------------------------------------------------------
# Fig 10 — Workload clustermap (hierarchical) per variant
# ---------------------------------------------------------------------------

def fig_workload_clustermap(means: pd.DataFrame, outdir: Path) -> None:
    if not HAS_SCIPY:
        return
    solo = means[means.stage == "solo"]
    if solo.empty:
        return
    env = "bare" if "bare" in solo["env"].values else solo["env"].iloc[0]
    sub = solo[solo.env == env]
    variants = _ordered_variants(sub["variant"].unique())
    if not variants:
        return
    cols = min(3, len(variants))
    rows = (len(variants) + cols - 1) // cols
    fig, axes = plt.subplots(rows, cols,
                             figsize=_clamp_figsize(4.5 * cols, 0.32 * sub["workload"].nunique() + 1.4),
                             squeeze=False)
    last = -1
    for idx, variant in enumerate(variants):
        last = idx
        ax = axes[idx // cols][idx % cols]
        m = (sub[sub.variant == variant]
             .groupby("workload")[METRICS].mean().fillna(0))
        if m.shape[0] < 2:
            ax.set_title(f"variant={variant} — too few"); ax.axis("off"); continue
        # Row order via hierarchical clustering on workload axis
        try:
            Z = linkage(m.values, method="ward")
            order = leaves_list(Z)
        except Exception:
            order = np.arange(len(m))
        m = m.iloc[order]
        im = ax.imshow(m.values, aspect="auto", cmap="viridis", vmin=0, vmax=100)
        ax.set_xticks(range(len(METRICS))); ax.set_xticklabels(METRICS, rotation=45, ha="right", fontsize=7)
        ax.set_yticks(range(len(m.index))); ax.set_yticklabels(m.index, fontsize=7)
        ax.set_title(f"variant={variant} (Ward linkage)", fontsize=9)
        ax.grid(False)
    for j in range(last + 1, rows * cols):
        axes[j // cols][j % cols].axis("off")
    fig.colorbar(im, ax=axes.ravel().tolist(), shrink=0.7, label="interference (%)")
    fig.suptitle(f"Hierarchical workload clustermap — env={env}", y=1.02, fontsize=11)
    _save(fig, outdir / "fig10_workload_clustermap.png", "fig10")


# ---------------------------------------------------------------------------
# Fig 11 — IADA Fig. 6 inspired: Δ pairwise − solo per resource
# ---------------------------------------------------------------------------

def fig_idi_bars(means: pd.DataFrame, outdir: Path) -> None:
    """Resource-level interference degradation: (pairwise mean) − (solo mean).

    Mirrors IADA Fig. 6 where each resource has bars per intensity level. Here
    the levels are the variants, and the resource families are the IntP groups
    {cpu, memory, disk, cache, network}.
    """
    if {"solo", "pairwise"} - set(means["stage"].unique()):
        print("[idi] need both solo and pairwise — skip")
        return
    env = "bare" if "bare" in means["env"].values else means["env"].iloc[0]
    sub = means[means.env == env]
    variants = _ordered_variants(sub["variant"].unique())
    if not variants:
        return
    rows = []
    for variant in variants:
        s = sub[(sub.variant == variant) & (sub.stage == "solo")]
        p = sub[(sub.variant == variant) & (sub.stage == "pairwise")]
        if s.empty or p.empty: continue
        for fam, members in RESOURCE_FAMILY.items():
            members = [m for m in members if m in s.columns]
            if not members: continue
            s_v = s[members].mean().mean()
            p_v = p[members].mean().mean()
            if pd.isna(s_v) or pd.isna(p_v): continue
            rows.append(dict(variant=variant, resource=fam,
                             solo=s_v, pair=p_v, delta=p_v - s_v))
    if not rows:
        return
    df = pd.DataFrame(rows)
    df.to_csv(outdir / "idi_resource.csv", index=False)
    resources = list(RESOURCE_FAMILY.keys())
    fig, ax = plt.subplots(figsize=_clamp_figsize(7.2, 3.6))
    x = np.arange(len(resources))
    width = 0.8 / max(1, len(variants))
    for vi, variant in enumerate(variants):
        offsets = (vi - (len(variants) - 1) / 2) * width
        vals = [df[(df.variant == variant) & (df.resource == r)]["delta"].mean()
                for r in resources]
        ax.bar(x + offsets, vals, width=width,
               color=VARIANT_COLORS.get(variant, f"C{vi}"),
               edgecolor="white", linewidth=0.4, label=variant)
    ax.set_xticks(x); ax.set_xticklabels(resources)
    ax.axhline(0, color="black", linewidth=0.5)
    ax.set_ylabel("Δ interference (pairwise − solo, %)")
    ax.set_title(f"Interference degradation by resource — env={env}\n"
                 f"(IADA Fig. 6 reproduction)", fontsize=10)
    ax.legend(ncol=len(variants), fontsize=8.5, loc="upper center",
              bbox_to_anchor=(0.5, -0.12))
    fig.tight_layout()
    _save(fig, outdir / "fig11_idi_bars.png", "fig11")


# ---------------------------------------------------------------------------
# Fig 12 — IntP Fig. 8 style multi-resource trace per pair (timeseries)
# ---------------------------------------------------------------------------

def fig_pairwise_timeseries(results_dir: Path, outdir: Path) -> None:
    """For each (env, variant) overlay 4 resource-family lines (Cache/CPU/
    Disk/Memory) over the long mixed-load trace. Reproduces the look of
    IntP Fig. 8 (4-line interference levels per node)."""
    files = list(results_dir.rglob("timeseries/**/profiler.tsv"))
    if not files:
        return
    legacy = any(f.parts[-5] in {"v4", "v5", "v6"} for f in files)
    n = len(files)
    cols = min(2, n)
    rows = (n + cols - 1) // cols
    fig, axes = plt.subplots(rows, cols,
                             figsize=_clamp_figsize(8 * cols, 3.4 * rows),
                             squeeze=False, sharex=False)
    last = -1
    for idx, f in enumerate(sorted(files)):
        last = idx
        ax = axes[idx // cols][idx % cols]
        env = f.parts[-6]; variant = f.parts[-5]
        if legacy:
            variant = RENAME.get(variant, variant)
        df = load_profiler_tsv(f)
        if df.empty:
            ax.axis("off"); continue
        if "ts" in df and df["ts"].notna().any():
            t = df["ts"] - df["ts"].min()
        else:
            t = np.arange(len(df))
        for fam, members in RESOURCE_FAMILY.items():
            members = [m for m in members if m in df.columns]
            if not members: continue
            mean_series = df[members].mean(axis=1).fillna(0).values
            y = _smooth(mean_series, window=11)
            ax.plot(t, y, color=RESOURCE_COLORS[fam], linewidth=1.3,
                    label=fam.capitalize(), alpha=0.95)
        ax.set_title(f"{env} / {variant}")
        ax.set_xlabel("time (s)")
        ax.set_ylabel("interference (%)")
        ax.set_ylim(-2, 105)
    for j in range(last + 1, rows * cols):
        axes[j // cols][j % cols].axis("off")
    handles, labels = axes[0][0].get_legend_handles_labels()
    if handles:
        fig.legend(handles, labels, loc="upper center",
                   bbox_to_anchor=(0.5, 1.02),
                   ncol=len(handles), frameon=False, fontsize=9)
    fig.suptitle("Resource-family trace over the mixed-load timeseries "
                 "(IntP Fig. 8 reproduction)", y=1.05, fontsize=11)
    fig.tight_layout()
    _save(fig, outdir / "fig12_pairwise_timeseries.png", "fig12")


# ---------------------------------------------------------------------------
# Fig 13 — IADA Fig. 5 reproduction: Loess-smoothed segmented timeseries.
# Splits each (env,variant) trace into N equal segments and overlays the
# resource-family interference levels (Cache/CPU/Disk/Memory/Network) with
# vertical phase markers — same visual idiom as IADA Fig. 5 (segmented
# TPC-H interference classification with smoothed lines per resource).
# ---------------------------------------------------------------------------

def _loess_smooth(y: np.ndarray, frac: float = 0.20) -> np.ndarray:
    """Cheap 1-D loess substitute: rolling window mean. Avoids the statsmodels
    dependency. ``frac`` is the window fraction relative to len(y)."""
    n = len(y)
    if n < 5:
        return y
    win = max(5, int(n * frac))
    if win % 2 == 0:
        win += 1
    pad = win // 2
    padded = np.pad(y, pad, mode="edge")
    kernel = np.ones(win) / win
    return np.convolve(padded, kernel, mode="valid")


def fig_iada_segmented(results_dir: Path, outdir: Path, n_segments: int = 4) -> None:
    files = list(results_dir.rglob("timeseries/**/profiler.tsv"))
    if not files:
        print("[iada_segmented] no timeseries data — skip")
        return
    legacy = any(f.parts[-5] in {"v4", "v5", "v6"} for f in files)
    n = len(files)
    cols = min(2, n)
    rows = (n + cols - 1) // cols
    fig, axes = plt.subplots(rows, cols,
                             figsize=_clamp_figsize(7.6 * cols, 3.0 * rows),
                             squeeze=False, sharex=False)
    last = -1
    for idx, f in enumerate(sorted(files)):
        last = idx
        ax = axes[idx // cols][idx % cols]
        env = f.parts[-6]; variant = f.parts[-5]
        if legacy:
            variant = RENAME.get(variant, variant)
        df = load_profiler_tsv(f)
        if df.empty:
            ax.axis("off"); continue
        if "ts" in df and df["ts"].notna().any():
            t = (df["ts"] - df["ts"].min()).values
        else:
            t = np.arange(len(df), dtype=float)
        for fam, members in RESOURCE_FAMILY.items():
            members = [m for m in members if m in df.columns]
            if not members: continue
            mean_series = df[members].mean(axis=1).fillna(0).values
            ys = _loess_smooth(mean_series, frac=0.18)
            ax.plot(t, ys, color=RESOURCE_COLORS[fam], linewidth=1.5,
                    label=fam.capitalize(), alpha=0.95)
        # Segment dividers
        if len(t) > 1:
            tmax = float(t[-1])
            for s in range(1, n_segments):
                ax.axvline(tmax * s / n_segments, color="#444", linewidth=0.7,
                           linestyle="--", alpha=0.55)
            # Segment labels (top)
            for s in range(n_segments):
                xpos = tmax * (s + 0.5) / n_segments
                ax.text(xpos, 102, f"seg {s+1}", ha="center", va="bottom",
                        fontsize=7, color="#333")
        ax.set_title(f"{env} / {variant}")
        ax.set_xlabel("time (s)")
        ax.set_ylabel("interference (%)")
        ax.set_ylim(-2, 110)
    for j in range(last + 1, rows * cols):
        axes[j // cols][j % cols].axis("off")
    handles, labels = axes[0][0].get_legend_handles_labels()
    if handles:
        fig.legend(handles, labels, loc="upper center",
                   bbox_to_anchor=(0.5, 1.02),
                   ncol=len(handles), frameon=False, fontsize=9)
    fig.suptitle("Segmented Loess-smoothed interference trace "
                 "(IADA Fig. 5 reproduction)", y=1.05, fontsize=11)
    fig.tight_layout()
    _save(fig, outdir / "fig13_iada_segmented.png", "fig13")


# ---------------------------------------------------------------------------
# Fig 14 — Variant × resource summary (NEW visualisation).
# A single compact heatmap making it easy to compare which variants surface
# which resource families. Useful when the experimental matrix grows.
# ---------------------------------------------------------------------------

def fig_variant_resource_heatmap(means: pd.DataFrame, outdir: Path) -> None:
    if means.empty:
        return
    rows: list[dict] = []
    for env in _ordered_envs(means["env"].unique()):
        sub_e = means[means.env == env]
        for variant in _ordered_variants(sub_e["variant"].unique()):
            sub = sub_e[sub_e.variant == variant]
            for fam, members in RESOURCE_FAMILY.items():
                members = [m for m in members if m in sub.columns]
                if not members: continue
                v = sub[members].mean(axis=1).mean()
                if pd.isna(v):
                    continue
                rows.append(dict(env=env, variant=variant,
                                 resource=fam, mean=float(v)))
    if not rows:
        return
    df = pd.DataFrame(rows)
    df.to_csv(outdir / "variant_resource_summary.csv", index=False)
    envs = _ordered_envs(df["env"].unique())
    fig, axes = plt.subplots(
        1, len(envs),
        figsize=_clamp_figsize(3.0 + 2.6 * len(envs), 0.42 * df["variant"].nunique() + 1.7),
        squeeze=False, sharey=True,
    )
    resources = list(RESOURCE_FAMILY.keys())
    for i, env in enumerate(envs):
        ax = axes[0][i]
        sub = df[df.env == env]
        pivot = sub.pivot_table(index="variant", columns="resource", values="mean")
        pivot = pivot.reindex(index=_ordered_variants(pivot.index), columns=resources)
        masked = np.ma.masked_invalid(pivot.values)
        cmap = plt.get_cmap("viridis").copy()
        cmap.set_bad(color="#dddddd")
        im = ax.imshow(masked, cmap=cmap, vmin=0, vmax=100, aspect="auto")
        ax.set_xticks(range(len(resources))); ax.set_xticklabels(resources)
        ax.set_yticks(range(len(pivot.index))); ax.set_yticklabels(pivot.index)
        ax.set_title(f"env={env}", fontsize=9.5)
        for (yi, xi), v in np.ndenumerate(pivot.values):
            if not np.isnan(v):
                ax.text(xi, yi, f"{v:.0f}", ha="center", va="center",
                        fontsize=7,
                        color="white" if v > 50 else "black")
        ax.grid(False)
    fig.colorbar(im, ax=axes.ravel().tolist(), fraction=0.04, shrink=0.8,
                 label="mean interference (%)")
    fig.suptitle("Variant × resource family — solo+pairwise mean interference",
                 y=1.02, fontsize=11)
    _save(fig, outdir / "fig14_variant_resource_heatmap.png", "fig14")


# ---------------------------------------------------------------------------
# Fig 00 — Canonical IntP Fig. 4 reproduction.
# A single chart per (env,variant): x-axis = workloads, grouped bars per
# metric (5–7 bars per workload). Color scheme matches the original IntP
# paper caption: cache=red, cpu=brown, disk=green, memory=blue, network=pink.
# ---------------------------------------------------------------------------

CANONICAL_METRIC_COLORS = {
    "llcocc": "#d62728",  # cache — red (IntP Fig. 4)
    "llcmr":  "#ff9896",  # cache miss — light red
    "cpu":    "#8c564b",  # cpu — brown
    "blk":    "#2ca02c",  # disk — green
    "mbw":    "#1f77b4",  # memory bus — blue
    "nets":   "#e377c2",  # network stack — pink
    "netp":   "#c4448a",  # network phys — darker pink
}


def fig_canonical_intp_fig4(means: pd.DataFrame, outdir: Path) -> None:
    """Canonical IntP Fig. 4 reproduction: one panel per (env,variant), bars
    grouped by workload with the original paper color caption."""
    solo = means[means.stage == "solo"]
    if solo.empty:
        return
    grouped = solo.groupby(["env", "variant", "workload"])[METRICS].mean().reset_index()
    pairs = grouped[["env", "variant"]].drop_duplicates().values.tolist()
    if not pairs:
        return
    n = len(pairs)
    cols = min(2, n)
    rows = (n + cols - 1) // cols
    fig, axes = plt.subplots(rows, cols,
                             figsize=_clamp_figsize(7.5 * cols, 3.4 * rows),
                             squeeze=False, sharey=True)
    last = -1
    for idx, (env, variant) in enumerate(pairs):
        last = idx
        ax = axes[idx // cols][idx % cols]
        sub = (grouped[(grouped.env == env) & (grouped.variant == variant)]
               .sort_values("workload"))
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
        ax.set_xticklabels(sub["workload"].values, rotation=35, ha="right",
                           fontsize=7)
        ax.set_title(f"env={env} · variant={variant}", fontsize=9.5)
        ax.set_ylabel("interference (%)")
        ax.set_ylim(0, max(1.0, sub[METRICS].max().max() * 1.10))
    for j in range(last + 1, rows * cols):
        axes[j // cols][j % cols].axis("off")
    handles, labels = axes[0][0].get_legend_handles_labels()
    if handles:
        fig.legend(handles, labels, loc="upper center",
                   bbox_to_anchor=(0.5, 1.02),
                   ncol=len(METRICS), frameon=False, fontsize=8.5)
    fig.suptitle("IntP Fig. 4 (canonical view) — per-application interference "
                 "ratios", y=1.06, fontsize=11)
    fig.tight_layout()
    _save(fig, outdir / "fig00_canonical_intp_fig4.png", "fig00")


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

def main() -> None:
    p = argparse.ArgumentParser(description="Plot intp-bench results")
    p.add_argument("results_dir", type=Path)
    p.add_argument("--out", type=Path, default=None,
                   help="Output directory (default: <results_dir>/plots)")
    args = p.parse_args()
    if not args.results_dir.exists():
        sys.exit(f"results_dir does not exist: {args.results_dir}")
    outdir = args.out or (args.results_dir / "plots")
    outdir.mkdir(parents=True, exist_ok=True)

    setup_style()

    print(f"Loading runs from {args.results_dir}")
    means = collect_means(args.results_dir)
    if means.empty:
        sys.exit("No profiler.tsv files found.")
    means.to_csv(outdir / "aggregate-means.csv", index=False)
    print(f"Loaded {len(means)} runs across "
          f"{means['env'].nunique()} envs, {means['variant'].nunique()} variants, "
          f"{means['stage'].nunique()} stages")

    fig_canonical_intp_fig4(means, outdir)       # fig00  IntP Fig.4 canonical
    fig_per_workload_bars(means, outdir)         # fig01  IntP Fig.4 panel grid
    fig_per_variant_bars(means, outdir)          # fig01b dual view
    fig_pca_kmeans(means, outdir)                # fig02  IntP Fig.5
    fig_timeseries(args.results_dir, outdir)     # fig03  IntP Fig.3
    fig_overhead_bars(args.results_dir, outdir)  # fig04
    fig_fidelity_matrix(args.results_dir, outdir)  # fig05
    fig_env_heatmap(means, outdir)               # fig06
    fig_pairwise_heatmap(means, outdir)          # fig07
    fig_metric_availability(means, outdir)       # fig08
    fig_radar_fingerprint(means, outdir)         # fig09  new
    fig_workload_clustermap(means, outdir)       # fig10  new
    fig_idi_bars(means, outdir)                  # fig11  IADA Fig.6
    fig_pairwise_timeseries(args.results_dir, outdir)  # fig12 IntP Fig.8
    fig_iada_segmented(args.results_dir, outdir)       # fig13 IADA Fig.5
    fig_variant_resource_heatmap(means, outdir)        # fig14 new summary

    print(f"All figures written to {outdir}")


if __name__ == "__main__":
    main()
