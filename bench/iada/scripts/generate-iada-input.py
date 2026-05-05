#!/usr/bin/env python3
"""Build the input.txt file consumed by CloudSim's util.readCsv layer.

CloudSim's xxIntExample currently scans the classpath resource folder
recursively, but our Meyer trees come from generate-iada-tree.py which
already produces a per-(variant, env) source/<workload>/<pattern>.csv tree.

This script:
  1. Walks the source/ tree, collecting every CSV
  2. Optionally filters by --workload pattern
  3. Emits the IADA input.txt format:
        app 1 <abs_path_to_csv>
        ...
        pm <count> <cpu>

Usage:
  generate-iada-input.py --tree <iada-tree>/<variant>/<env>/source \
                         --pm-count 48 --pm-cpu 100 \
                         --output input.txt
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--tree", required=True, type=Path,
                   help="path to iada-tree/<variant>/<env>/source/")
    p.add_argument("--pm-count", type=int, default=48,
                   help="number of physical machines (paper default: 48)")
    p.add_argument("--pm-cpu", type=int, default=100,
                   help="cpu capacity per pm (paper default: 100)")
    p.add_argument("--workload", action="append", default=None,
                   help="restrict to these workload subdirs (repeatable)")
    p.add_argument("--limit", type=int, default=0,
                   help="cap number of apps (0 = no cap)")
    p.add_argument("--output", required=True, type=Path)
    args = p.parse_args()

    if not args.tree.is_dir():
        print(f"FATAL: tree not found: {args.tree}", file=sys.stderr)
        return 2

    csvs: list[Path] = []
    for child in sorted(args.tree.iterdir()):
        if not child.is_dir():
            continue
        if args.workload and child.name not in args.workload:
            continue
        for csv in sorted(child.glob("*.csv")):
            csvs.append(csv.resolve())

    if not csvs:
        print(f"FATAL: no CSVs under {args.tree}", file=sys.stderr)
        return 2

    if args.limit and len(csvs) > args.limit:
        csvs = csvs[: args.limit]

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w") as f:
        for csv in csvs:
            f.write(f"app 1 {csv}\n")
        f.write(f"pm {args.pm_count} {args.pm_cpu}\n")

    print(f"wrote {len(csvs)} app entries + 1 pm entry to {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
