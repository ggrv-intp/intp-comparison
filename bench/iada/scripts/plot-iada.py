#!/usr/bin/env python3
"""
plot-iada.py — Render IDI / migrations / overhead figures from an IADA campaign.

Consumes the manifest.tsv emitted by run-iada-campaign.sh:

    variant  env  workload_mix  idi_avg  idi_sum  idi_max
    migrations_total  migrations_avg  cloudletcost_avg  cloudletcost_sum
    interference_avg  interference_sum  interference_max
    sim_wallclock_min  classifier_calls

Produces, under <out_dir>/figures/:
    fig01-idi-by-variant.png      bar chart, IDI mean ± stderr per variant
    fig02-idi-by-env.png          grouped bar, variant × env
    fig03-idi-vs-migrations.png   scatter, points colored by variant
    fig04-overhead-vs-idi.png     scatter, classifier_calls vs idi_avg
    fig05-rank.tsv                ranking table (variant by lower idi_avg)
"""
from __future__ import annotations
import argparse
import os
import sys
from pathlib import Path

import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


VARIANT_ORDER = ["v0", "v0.1", "v1", "v1.1", "v2", "v3", "v3.1"]
ENV_ORDER = [
    "bare",
    "container", "container-guest", "container-full",
    "vm", "vm-guest", "vm-full",
]


def load_manifest(path: Path) -> pd.DataFrame:
    df = pd.read_csv(path, sep="\t")
    required = {"variant", "env", "idi_avg"}
    missing = required - set(df.columns)
    if missing:
        sys.exit(f"manifest missing columns: {missing}")
    df["variant"] = pd.Categorical(df["variant"],
                                    categories=[v for v in VARIANT_ORDER if v in df["variant"].unique()],
                                    ordered=True)
    if "env" in df.columns:
        df["env"] = pd.Categorical(df["env"],
                                    categories=[e for e in ENV_ORDER if e in df["env"].unique()],
                                    ordered=True)
    return df


def fig_idi_by_variant(df: pd.DataFrame, out: Path):
    grouped = df.groupby("variant", observed=True)["idi_avg"].agg(["mean", "sem", "count"])
    fig, ax = plt.subplots(figsize=(7, 4))
    x = np.arange(len(grouped))
    ax.bar(x, grouped["mean"], yerr=grouped["sem"].fillna(0),
           capsize=4, color="#3a7", edgecolor="black")
    ax.set_xticks(x)
    ax.set_xticklabels(grouped.index)
    ax.set_ylabel("IDI (avg per simulation)")
    ax.set_title("Lower is better — interference + migration cost in CloudSim")
    for i, n in enumerate(grouped["count"]):
        ax.text(i, grouped["mean"].iloc[i], f"n={int(n)}",
                ha="center", va="bottom", fontsize=8)
    fig.tight_layout()
    fig.savefig(out, dpi=140)
    plt.close(fig)


def fig_idi_by_env(df: pd.DataFrame, out: Path):
    if "env" not in df.columns:
        return
    pivot = df.pivot_table(index="variant", columns="env",
                            values="idi_avg", aggfunc="mean", observed=True)
    err = df.pivot_table(index="variant", columns="env",
                          values="idi_avg", aggfunc="sem", observed=True).fillna(0)
    fig, ax = plt.subplots(figsize=(8, 4))
    width = 0.8 / max(len(pivot.columns), 1)
    x = np.arange(len(pivot))
    for i, e in enumerate(pivot.columns):
        ax.bar(x + i * width, pivot[e], width=width, yerr=err[e],
               capsize=3, label=str(e))
    ax.set_xticks(x + (len(pivot.columns) - 1) * width / 2)
    ax.set_xticklabels(pivot.index)
    ax.set_ylabel("IDI (avg)")
    ax.set_title("IDI by deployment environment")
    ax.legend(title="env")
    fig.tight_layout()
    fig.savefig(out, dpi=140)
    plt.close(fig)


def fig_idi_vs_migrations(df: pd.DataFrame, out: Path):
    if "migrations_total" not in df.columns:
        return
    fig, ax = plt.subplots(figsize=(7, 5))
    for v in df["variant"].cat.categories:
        sub = df[df["variant"] == v]
        if sub.empty:
            continue
        ax.scatter(sub["migrations_total"], sub["idi_avg"],
                    label=v, alpha=0.7, s=40)
    ax.set_xlabel("Total migrations")
    ax.set_ylabel("IDI (avg)")
    ax.set_title("Trade-off: migration count vs. interference cost")
    ax.legend(title="variant", fontsize=8)
    ax.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(out, dpi=140)
    plt.close(fig)


def fig_overhead_vs_idi(df: pd.DataFrame, out: Path):
    if "classifier_calls" not in df.columns:
        return
    fig, ax = plt.subplots(figsize=(7, 5))
    for v in df["variant"].cat.categories:
        sub = df[df["variant"] == v]
        if sub.empty:
            continue
        ax.scatter(sub["classifier_calls"], sub["idi_avg"],
                    label=v, alpha=0.7, s=40)
    ax.set_xlabel("Classifier invocations (proxy for sim overhead)")
    ax.set_ylabel("IDI (avg)")
    ax.set_title("Sanity: more classifier calls correlates with finer-grained scheduling")
    ax.legend(title="variant", fontsize=8)
    ax.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(out, dpi=140)
    plt.close(fig)


def write_rank(df: pd.DataFrame, out: Path):
    rank = df.groupby("variant", observed=True).agg(
        idi_avg_mean=("idi_avg", "mean"),
        idi_avg_sem=("idi_avg", "sem"),
        n_runs=("idi_avg", "count"),
    ).sort_values("idi_avg_mean")
    rank.to_csv(out, sep="\t", index=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("manifest", type=Path,
                    help="Path to manifest.tsv produced by run-iada-campaign.sh")
    ap.add_argument("--out-dir", type=Path, default=None,
                    help="Output directory (default: <manifest_parent>/figures)")
    args = ap.parse_args()

    if not args.manifest.exists():
        sys.exit(f"manifest not found: {args.manifest}")

    out_dir = args.out_dir or args.manifest.parent / "figures"
    out_dir.mkdir(parents=True, exist_ok=True)

    df = load_manifest(args.manifest)
    print(f"loaded {len(df)} rows; variants={list(df['variant'].cat.categories)}; "
          f"envs={list(df['env'].cat.categories) if 'env' in df.columns else 'n/a'}")

    fig_idi_by_variant(df, out_dir / "fig01-idi-by-variant.png")
    fig_idi_by_env(df, out_dir / "fig02-idi-by-env.png")
    fig_idi_vs_migrations(df, out_dir / "fig03-idi-vs-migrations.png")
    fig_overhead_vs_idi(df, out_dir / "fig04-overhead-vs-idi.png")
    write_rank(df, out_dir / "fig05-rank.tsv")

    print(f"figures written to {out_dir}/")


if __name__ == "__main__":
    main()
