#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# plot-intp-bench.py -- Generate publication-ready figures from intp-bench
# results plus the cross-variant / cross-env comparisons that the dissertation
# Phase-3 plan calls for.
#
# Inputs: a results directory produced by run-intp-bench.sh.
# Outputs: PNG figures + companion CSVs under <results>/plots/.
#
# Figures produced:
#   fig01_per_app_bars.png      -> Fig. 4 of paper: 7-metric bars per workload
#                                  (one panel per (env,variant))
#   fig02_pca_kmeans.png        -> Fig. 5 of paper: workloads in PCA space
#                                  with k=4 clustering, per (env,variant)
#   fig03_timeseries.png        -> Fig. 3 / Fig. 8 style trace
#   fig04_overhead_bars.png     -> Volpert-style overhead bars per variant
#   fig05_fidelity_matrix.png   -> Pearson correlation between profiler
#                                  output and ground-truth side channels
#   fig06_env_heatmap.png       -> degradation of each (variant,metric)
#                                  going bare -> container -> vm
#   fig07_pairwise_heatmap.png  -> interference signal for each
#                                  (variant,metric,pair)
#   fig08_metric_availability.png  binary heatmap: metric reported / missing
#
# Run:   python3 plot-intp-bench.py /path/to/results/intp-bench-<ts>
# -----------------------------------------------------------------------------

from __future__ import annotations

import argparse
import os
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
    from sklearn.cluster import KMeans
    HAS_SKLEARN = True
except ImportError:
    HAS_SKLEARN = False
    warnings.warn("scikit-learn not installed -- PCA/k-means figure will be skipped")

METRICS = ["netp", "nets", "blk", "mbw", "llcmr", "llcocc", "cpu"]
METRIC_COLORS = {
    "netp":   "#d62728",  # red
    "nets":   "#ff7f0e",  # orange
    "blk":    "#2ca02c",  # green
    "mbw":    "#1f77b4",  # blue
    "llcmr":  "#9467bd",  # purple
    "llcocc": "#e377c2",  # pink
    "cpu":    "#8c564b",  # brown
}
VARIANT_ORDER = ["v0", "v0.1", "v1", "v1.1", "v2", "v3.1", "v3"]
ENV_ORDER = ["bare", "container", "vm"]

# Pre-rename → current names. Applied at load time so legacy result trees
# (v3,v4,v5,v6 directories) are displayed with the current nomenclature.
RENAME = {"v1": "v0", "v2": "v0.1", "v3": "v1", "v4": "v2", "v5": "v3.1", "v6": "v3"}


# -----------------------------------------------------------------------------
# Loading
# -----------------------------------------------------------------------------

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


def load_index(results_dir: Path) -> pd.DataFrame:
    idx = results_dir / "index.tsv"
    if not idx.exists():
        sys.exit(f"index.tsv not found in {results_dir}")
    df = pd.read_csv(idx, sep="\t")
    return df


def _maybe_rename_variants(values) -> tuple:
    """Auto-detect legacy naming (v4/v5/v6 present) and apply RENAME if so."""
    legacy_markers = {"v4", "v5", "v6"}
    if any(v in legacy_markers for v in values):
        return tuple(RENAME.get(v, v) for v in values), True
    return tuple(values), False


def collect_means(results_dir: Path) -> pd.DataFrame:
    """Load every profiler.tsv and return a per-run mean per metric.

    Columns: env, variant, stage, workload, rep, <7 metrics>, samples.
    """
    rows = []
    for f in results_dir.rglob("profiler.tsv"):
        parts = f.parts
        # ... <env>/<variant>/<stage>/<workload>/rep<R>/profiler.tsv
        try:
            env = parts[-6]; variant = parts[-5]; stage = parts[-4]
            wl = parts[-3]; rep = int(parts[-2].replace("rep", ""))
        except (IndexError, ValueError):
            continue
        df = load_profiler_tsv(f)
        if df.empty:
            continue
        rec = dict(env=env, variant=variant, stage=stage, workload=wl, rep=rep, samples=len(df))
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


# -----------------------------------------------------------------------------
# Figures
# -----------------------------------------------------------------------------

def fig_per_app_bars(means: pd.DataFrame, outdir: Path) -> None:
    """Fig. 4 reproduction. One small-multiple per (env, variant)."""
    solo = means[means.stage == "solo"]
    if solo.empty:
        print("[per_app_bars] no solo data -- skip")
        return
    grouped = solo.groupby(["env", "variant", "workload"])[METRICS].mean().reset_index()

    pairs = grouped[["env", "variant"]].drop_duplicates().values.tolist()
    n = len(pairs)
    if n == 0:
        return
    cols = min(3, n)
    rows = (n + cols - 1) // cols
    fig, axes = plt.subplots(rows, cols, figsize=(6 * cols, 3.6 * rows), squeeze=False)

    for idx, (env, variant) in enumerate(pairs):
        ax = axes[idx // cols][idx % cols]
        sub = grouped[(grouped.env == env) & (grouped.variant == variant)].copy()
        sub = sub.sort_values("workload")
        x = np.arange(len(sub))
        width = 0.11
        for i, m in enumerate(METRICS):
            ax.bar(x + (i - 3) * width, sub[m].values, width=width,
                   label=m, color=METRIC_COLORS[m])
        ax.set_xticks(x)
        ax.set_xticklabels(sub["workload"].values, rotation=45, ha="right", fontsize=7)
        ax.set_ylim(0, max(1.0, sub[METRICS].max().max() * 1.1))
        ax.set_title(f"{env} / {variant}")
        ax.set_ylabel("interference (0..1 or %)")
        ax.grid(axis="y", linestyle=":", alpha=0.4)
        if idx == 0:
            ax.legend(ncol=4, fontsize=7, loc="upper center", bbox_to_anchor=(0.5, 1.4))

    for j in range(idx + 1, rows * cols):
        axes[j // cols][j % cols].axis("off")

    fig.suptitle("Per-workload interference (solo)", y=1.02)
    fig.tight_layout()
    fig.savefig(outdir / "fig01_per_app_bars.png", dpi=150, bbox_inches="tight")
    plt.close(fig)
    print("[per_app_bars] wrote fig01_per_app_bars.png")


def fig_pca_kmeans(means: pd.DataFrame, outdir: Path) -> None:
    """Fig. 5 reproduction. PCA + k-means on workload x metric matrix."""
    if not HAS_SKLEARN:
        return
    solo = means[means.stage == "solo"]
    if solo.empty:
        print("[pca] no solo data -- skip")
        return
    pairs = solo[["env", "variant"]].drop_duplicates().values.tolist()
    n = len(pairs)
    cols = min(3, n)
    rows = (n + cols - 1) // cols
    fig, axes = plt.subplots(rows, cols, figsize=(5 * cols, 4 * rows), squeeze=False)

    for idx, (env, variant) in enumerate(pairs):
        ax = axes[idx // cols][idx % cols]
        sub = (solo[(solo.env == env) & (solo.variant == variant)]
               .groupby("workload")[METRICS].mean().fillna(0))
        if len(sub) < 4:
            ax.set_title(f"{env}/{variant}: too few workloads")
            ax.axis("off")
            continue
        X = sub.values
        if X.shape[0] < 2 or X.shape[1] < 2:
            ax.axis("off"); continue
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
            ax.scatter(Y[mask, 0], Y[mask, 1], s=80, alpha=0.7, label=f"c{c}")
        for i, label in enumerate(sub.index):
            ax.annotate(label, (Y[i, 0], Y[i, 1]), fontsize=6, alpha=0.7)
        ax.set_title(f"{env}/{variant} -- PC1={pca.explained_variance_ratio_[0]*100:.1f}% "
                     f"PC2={pca.explained_variance_ratio_[1]*100:.1f}%")
        ax.set_xlabel("PC1"); ax.set_ylabel("PC2")
        ax.grid(linestyle=":", alpha=0.4)

    fig.suptitle("PCA + k-means clustering of workloads (k=4)", y=1.02)
    fig.tight_layout()
    fig.savefig(outdir / "fig02_pca_kmeans.png", dpi=150, bbox_inches="tight")
    plt.close(fig)
    print("[pca] wrote fig02_pca_kmeans.png")


def fig_timeseries(results_dir: Path, outdir: Path) -> None:
    """Fig. 3 / Fig. 8 reproduction: a long trace per (env,variant)."""
    files = list(results_dir.rglob("timeseries/**/profiler.tsv"))
    if not files:
        print("[timeseries] no timeseries data -- skip")
        return
    legacy = any(f.parts[-5] in {"v4", "v5", "v6"} for f in files)
    n = len(files)
    cols = min(2, n)
    rows = (n + cols - 1) // cols
    fig, axes = plt.subplots(rows, cols, figsize=(8 * cols, 3 * rows), squeeze=False)
    for idx, f in enumerate(files):
        ax = axes[idx // cols][idx % cols]
        env = f.parts[-6]; variant = f.parts[-5]
        if legacy:
            variant = RENAME.get(variant, variant)
        df = load_profiler_tsv(f)
        if df.empty: continue
        if "ts" in df and df["ts"].notna().any():
            t = df["ts"] - df["ts"].min()
        else:
            t = np.arange(len(df))
        for m in METRICS:
            if m in df.columns:
                ax.plot(t, df[m], label=m, color=METRIC_COLORS[m], linewidth=1.0)
        ax.set_title(f"{env}/{variant} -- mixed_long")
        ax.set_xlabel("time (s)"); ax.set_ylabel("level")
        ax.grid(linestyle=":", alpha=0.4)
        if idx == 0:
            ax.legend(ncol=7, fontsize=7, loc="upper center", bbox_to_anchor=(0.5, 1.25))
    fig.suptitle("Long-trace interference profile (timeseries stage)", y=1.02)
    fig.tight_layout()
    fig.savefig(outdir / "fig03_timeseries.png", dpi=150, bbox_inches="tight")
    plt.close(fig)
    print("[timeseries] wrote fig03_timeseries.png")


def fig_overhead_bars(results_dir: Path, outdir: Path) -> None:
    rows = []
    for elapsed_file in (results_dir / "overhead").rglob("elapsed_s"):
        # overhead/<env>/<variant_or__baseline>/<refid>/rep<R>/elapsed_s
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
        print("[overhead] no overhead data -- skip")
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
    envs = sorted(summary["env"].unique())
    fig, axes = plt.subplots(len(envs), 1, figsize=(8, 3 * len(envs)), squeeze=False)
    for i, env in enumerate(envs):
        ax = axes[i][0]
        sub = summary[summary.env == env]
        variants_present = [v for v in VARIANT_ORDER if v in sub["variant"].values]
        x = np.arange(len(refs))
        width = 0.8 / max(1, len(variants_present))
        for j, v in enumerate(variants_present):
            row = sub[sub.variant == v].set_index("ref").reindex(refs)
            ax.bar(x + (j - len(variants_present) / 2) * width, row["mean"].values,
                   yerr=row["std"].fillna(0).values, width=width, label=v)
        ax.set_xticks(x); ax.set_xticklabels(refs, rotation=20)
        ax.set_ylabel("overhead (%)"); ax.set_title(f"env={env}")
        ax.axhline(0, color="black", linewidth=0.5)
        ax.grid(axis="y", linestyle=":", alpha=0.4)
        ax.legend(ncol=len(variants_present), fontsize=7)
    fig.suptitle("Profiler runtime overhead vs. baseline (Volpert-style)", y=1.02)
    fig.tight_layout()
    fig.savefig(outdir / "fig04_overhead_bars.png", dpi=150, bbox_inches="tight")
    plt.close(fig)
    print("[overhead] wrote fig04_overhead_bars.png + overhead_summary.csv")


def fig_fidelity_matrix(results_dir: Path, outdir: Path) -> None:
    """Per-variant correlation between profiler readings and groundtruth.tsv.

    We score each (variant, metric) pair with the Pearson correlation of the
    profiler's reported value against the closest available ground-truth
    signal: cpu vs cpu_busy_pct, mbw vs resctrl_mbw_bps, llcocc vs
    resctrl_llcocc_bytes, blk vs disk_total_mb, netp vs net_total_mb.
    """
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
        print("[fidelity] no fidelity data -- skip")
        return
    df = pd.DataFrame(rows)
    _, did_rename = _maybe_rename_variants(df["variant"].unique())
    if did_rename:
        df["variant"] = df["variant"].map(lambda v: RENAME.get(v, v))
    df = df.groupby(["env", "variant", "metric"])["r"].mean().reset_index()
    df.to_csv(outdir / "fidelity_matrix.csv", index=False)

    pivot = df.pivot_table(index="variant", columns="metric", values="r", aggfunc="mean")
    pivot = pivot.reindex(index=[v for v in VARIANT_ORDER if v in pivot.index])
    fig, ax = plt.subplots(figsize=(7, 0.6 * len(pivot) + 1))
    im = ax.imshow(pivot.values, vmin=-1, vmax=1, cmap="RdBu_r", aspect="auto")
    ax.set_xticks(range(len(pivot.columns))); ax.set_xticklabels(pivot.columns)
    ax.set_yticks(range(len(pivot.index)));   ax.set_yticklabels(pivot.index)
    for (i, j), v in np.ndenumerate(pivot.values):
        if not np.isnan(v):
            ax.text(j, i, f"{v:+.2f}", ha="center", va="center",
                    fontsize=8, color="black" if abs(v) < 0.5 else "white")
    ax.set_title("Profiler vs. ground-truth Pearson r (solo)")
    fig.colorbar(im, ax=ax, fraction=0.04)
    fig.tight_layout()
    fig.savefig(outdir / "fig05_fidelity_matrix.png", dpi=150, bbox_inches="tight")
    plt.close(fig)
    print("[fidelity] wrote fig05_fidelity_matrix.png + fidelity_matrix.csv")


def fig_env_heatmap(means: pd.DataFrame, outdir: Path) -> None:
    """For each (variant, metric), how does the mean signal change going
    bare -> container -> vm? Plotted as ratio relative to bare."""
    solo = means[means.stage == "solo"]
    if solo.empty or solo["env"].nunique() < 2:
        print("[env_heatmap] need >=2 envs -- skip")
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
    envs_present = sorted(df["env"].unique())
    fig, axes = plt.subplots(1, len(envs_present), figsize=(5 * len(envs_present), 3.5), squeeze=False)
    for i, env in enumerate(envs_present):
        ax = axes[0][i]
        sub = df[df.env == env]
        pivot = sub.pivot_table(index="variant", columns="metric", values="ratio")
        pivot = pivot.reindex(index=[v for v in VARIANT_ORDER if v in pivot.index])
        im = ax.imshow(pivot.values, cmap="PiYG", vmin=0, vmax=2, aspect="auto")
        ax.set_xticks(range(len(pivot.columns))); ax.set_xticklabels(pivot.columns)
        ax.set_yticks(range(len(pivot.index)));   ax.set_yticklabels(pivot.index)
        ax.set_title(f"{env} / bare")
        for (yi, xi), v in np.ndenumerate(pivot.values):
            if not np.isnan(v):
                ax.text(xi, yi, f"{v:.2f}", ha="center", va="center", fontsize=7)
        fig.colorbar(im, ax=ax, fraction=0.04)
    fig.suptitle("Metric ratio across execution environments (1.0 = matches bare)", y=1.02)
    fig.tight_layout()
    fig.savefig(outdir / "fig06_env_heatmap.png", dpi=150, bbox_inches="tight")
    plt.close(fig)
    print("[env_heatmap] wrote fig06_env_heatmap.png + env_ratio.csv")


def fig_pairwise_heatmap(means: pd.DataFrame, outdir: Path) -> None:
    pair = means[means.stage == "pairwise"]
    solo = means[means.stage == "solo"]
    if pair.empty or solo.empty:
        print("[pairwise] missing pair or solo means -- skip")
        return
    # Pairwise workload IDs (e.g. cpu_v_cache) don't exist in solo; we use
    # the absolute pairwise reading directly as the interference signal.
    g = pair.groupby(["env", "variant", "workload"])[METRICS].mean().reset_index()
    g.to_csv(outdir / "pairwise_means.csv", index=False)
    # Heatmap: rows = (variant), cols = (workload x metric)
    workloads = sorted(g["workload"].unique())
    envs = sorted(g["env"].unique())
    for env in envs:
        sub = g[g.env == env]
        if sub.empty: continue
        pivot_rows = []
        for variant in [v for v in VARIANT_ORDER if v in sub["variant"].values]:
            row = []; labels = []
            for w in workloads:
                r = sub[(sub.variant == variant) & (sub.workload == w)]
                for m in METRICS:
                    row.append(float(r[m].iloc[0]) if not r.empty else np.nan)
                    labels.append(f"{w}.{m}")
            pivot_rows.append((variant, row, labels))
        if not pivot_rows: continue
        variants_present = [v for v, _, _ in pivot_rows]
        data = np.array([r for _, r, _ in pivot_rows], dtype=float)
        labels = pivot_rows[0][2]
        fig, ax = plt.subplots(figsize=(max(8, 0.3 * len(labels)), 0.5 * len(variants_present) + 1))
        im = ax.imshow(data, cmap="magma", aspect="auto")
        ax.set_xticks(range(len(labels))); ax.set_xticklabels(labels, rotation=90, fontsize=7)
        ax.set_yticks(range(len(variants_present))); ax.set_yticklabels(variants_present)
        fig.colorbar(im, ax=ax, fraction=0.02)
        ax.set_title(f"Pairwise interference signal -- env={env}")
        fig.tight_layout()
        fig.savefig(outdir / f"fig07_pairwise_heatmap_{env}.png", dpi=150, bbox_inches="tight")
        plt.close(fig)
        print(f"[pairwise] wrote fig07_pairwise_heatmap_{env}.png")


def fig_metric_availability(means: pd.DataFrame, outdir: Path) -> None:
    """Binary heatmap: did each (variant, metric) ever produce a non-NaN,
    non-zero reading? Documents the V0.1-llcocc=0 case and similar gaps."""
    if means.empty: return
    avail_rows = []
    for variant in [v for v in VARIANT_ORDER if v in means["variant"].values]:
        sub = means[means.variant == variant]
        for m in METRICS:
            ok = sub[m].notna().any() and (sub[m].fillna(0).abs().sum() > 0)
            avail_rows.append(dict(variant=variant, metric=m, available=int(ok)))
    df = pd.DataFrame(avail_rows)
    df.to_csv(outdir / "metric_availability.csv", index=False)
    pivot = df.pivot_table(index="variant", columns="metric", values="available")
    pivot = pivot.reindex(index=[v for v in VARIANT_ORDER if v in pivot.index])
    fig, ax = plt.subplots(figsize=(6, 0.4 * len(pivot) + 1))
    im = ax.imshow(pivot.values, cmap="Greens", vmin=0, vmax=1, aspect="auto")
    ax.set_xticks(range(len(pivot.columns))); ax.set_xticklabels(pivot.columns)
    ax.set_yticks(range(len(pivot.index)));   ax.set_yticklabels(pivot.index)
    for (i, j), v in np.ndenumerate(pivot.values):
        ax.text(j, i, "yes" if v else "no", ha="center", va="center", fontsize=8)
    ax.set_title("Metric availability per variant (any non-zero reading)")
    fig.tight_layout()
    fig.savefig(outdir / "fig08_metric_availability.png", dpi=150, bbox_inches="tight")
    plt.close(fig)
    print("[availability] wrote fig08_metric_availability.png + metric_availability.csv")


# -----------------------------------------------------------------------------
# Driver
# -----------------------------------------------------------------------------

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

    print(f"Loading runs from {args.results_dir}")
    means = collect_means(args.results_dir)
    if means.empty:
        sys.exit("No profiler.tsv files found.")
    means.to_csv(outdir / "aggregate-means.csv", index=False)
    print(f"Loaded {len(means)} runs across "
          f"{means['env'].nunique()} envs, {means['variant'].nunique()} variants, "
          f"{means['stage'].nunique()} stages")

    fig_per_app_bars(means, outdir)
    fig_pca_kmeans(means, outdir)
    fig_timeseries(args.results_dir, outdir)
    fig_overhead_bars(args.results_dir, outdir)
    fig_fidelity_matrix(args.results_dir, outdir)
    fig_env_heatmap(means, outdir)
    fig_pairwise_heatmap(means, outdir)
    fig_metric_availability(means, outdir)

    print(f"All figures written to {outdir}")


if __name__ == "__main__":
    main()
