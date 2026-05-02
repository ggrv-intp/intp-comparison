#!/usr/bin/env python3

from __future__ import annotations

import argparse
import csv
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


METRICS = ("netp", "nets", "blk", "mbw", "llcmr", "llcocc", "cpu")


@dataclass
class ConversionResult:
    source: Path
    output: Path
    rows: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Convert IntP profiler.tsv files into Meyer/IADA CSV format "
            "(semicolon-separated, 7 columns, no header)."
        )
    )
    parser.add_argument(
        "inputs",
        nargs="+",
        help="One or more profiler.tsv files or result directories to scan recursively.",
    )
    parser.add_argument(
        "--output-root",
        type=Path,
        help=(
            "Mirror converted files under this directory instead of writing "
            "<profiler>.meyer.csv alongside each profiler.tsv."
        ),
    )
    parser.add_argument(
        "--stage",
        action="append",
        default=[],
        help=(
            "Keep only profiler.tsv paths whose stage component matches this value. "
            "May be passed multiple times, e.g. --stage solo --stage timeseries."
        ),
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        help="Write a TSV manifest with source/output path and run metadata.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite existing output files.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print planned conversions without writing files.",
    )
    return parser.parse_args()


def iter_profiler_paths(inputs: Iterable[str]) -> list[Path]:
    results: list[Path] = []
    for raw in inputs:
        path = Path(raw)
        if path.is_file():
            if path.name != "profiler.tsv":
                raise SystemExit(f"Expected a profiler.tsv file, got: {path}")
            results.append(path)
            continue
        if path.is_dir():
            results.extend(sorted(path.rglob("profiler.tsv")))
            continue
        raise SystemExit(f"Input path does not exist: {path}")
    if not results:
        raise SystemExit("No profiler.tsv files found.")
    return dedupe_preserve_order(results)


def dedupe_preserve_order(paths: Iterable[Path]) -> list[Path]:
    seen: set[Path] = set()
    out: list[Path] = []
    for path in paths:
        resolved = path.resolve()
        if resolved in seen:
            continue
        seen.add(resolved)
        out.append(path)
    return out


def stage_from_path(path: Path) -> str | None:
    parts = path.parts
    if len(parts) < 5:
        return None
    try:
        idx = parts.index("bare")
    except ValueError:
        try:
            idx = parts.index("container")
        except ValueError:
            try:
                idx = parts.index("vm")
            except ValueError:
                return None
    if idx + 2 >= len(parts):
        return None
    return parts[idx + 2]


def filter_by_stage(paths: list[Path], stages: list[str]) -> list[Path]:
    if not stages:
        return paths
    allowed = {stage.strip() for stage in stages if stage.strip()}
    return [path for path in paths if stage_from_path(path) in allowed]


def split_fields(line: str) -> list[str]:
    if "\t" in line:
        return [field.strip() for field in line.split("\t") if field.strip()]
    return line.split()


def parse_metric_row(line: str, line_no: int, source: Path) -> list[int] | None:
    stripped = line.strip()
    if not stripped:
        return None
    if stripped.startswith("#") or stripped.startswith("ts") or stripped.startswith("netp"):
        return None

    fields = split_fields(stripped)
    if len(fields) < 7:
        return None

    tail = fields[-7:]
    try:
        values = [round(float(field)) for field in tail]
    except ValueError as exc:
        raise ValueError(f"{source}:{line_no}: could not parse metrics from {tail}") from exc

    return [clamp_percent(value) for value in values]


def clamp_percent(value: int) -> int:
    if value < 0:
        return 0
    if value > 100:
        return 100
    return value


def output_path_for(source: Path, output_root: Path | None) -> Path:
    if output_root is None:
        return source.with_suffix(".meyer.csv")

    resolved_root = output_root.resolve()
    resolved_source = source.resolve()
    anchor = resolved_source.anchor
    relative = Path(str(resolved_source)[len(anchor) :].lstrip("/")) if anchor else resolved_source
    mirrored = resolved_root / relative
    return mirrored.with_suffix(".meyer.csv")


def extract_metadata(source: Path) -> dict[str, str]:
    parts = list(source.parts)
    if len(parts) < 6:
        return {"env": "", "variant": "", "stage": "", "workload": "", "rep": ""}
    for env in ("bare", "container", "vm"):
        if env in parts:
            idx = parts.index(env)
            return {
                "env": env,
                "variant": parts[idx + 1] if idx + 1 < len(parts) else "",
                "stage": parts[idx + 2] if idx + 2 < len(parts) else "",
                "workload": parts[idx + 3] if idx + 3 < len(parts) else "",
                "rep": parts[idx + 4] if idx + 4 < len(parts) else "",
            }
    return {"env": "", "variant": "", "stage": "", "workload": "", "rep": ""}


def convert_one(source: Path, output_root: Path | None, force: bool, dry_run: bool) -> ConversionResult:
    output = output_path_for(source, output_root)
    if output.exists() and not force:
        raise FileExistsError(f"Output already exists (use --force): {output}")

    rows: list[list[int]] = []
    with source.open("r", encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, start=1):
            record = parse_metric_row(line, line_no, source)
            if record is not None:
                rows.append(record)

    if not rows:
        raise ValueError(f"No metric rows found in {source}")

    if not dry_run:
        output.parent.mkdir(parents=True, exist_ok=True)
        with output.open("w", encoding="utf-8", newline="") as handle:
            writer = csv.writer(handle, delimiter=";", lineterminator="\n")
            writer.writerows(rows)

    return ConversionResult(source=source, output=output, rows=len(rows))


def write_manifest(path: Path, results: list[ConversionResult]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle, delimiter="\t", lineterminator="\n")
        writer.writerow(["env", "variant", "stage", "workload", "rep", "rows", "source", "output"])
        for result in results:
            meta = extract_metadata(result.source)
            writer.writerow(
                [
                    meta["env"],
                    meta["variant"],
                    meta["stage"],
                    meta["workload"],
                    meta["rep"],
                    result.rows,
                    str(result.source),
                    str(result.output),
                ]
            )


def main() -> int:
    args = parse_args()
    profiler_paths = filter_by_stage(iter_profiler_paths(args.inputs), args.stage)
    if not profiler_paths:
        raise SystemExit("No profiler.tsv files matched the requested filters.")

    results: list[ConversionResult] = []
    for source in profiler_paths:
        result = convert_one(source, args.output_root, args.force, args.dry_run)
        results.append(result)
        print(f"{source} -> {result.output} ({result.rows} rows)")

    if args.manifest and not args.dry_run:
        write_manifest(args.manifest, results)
        print(f"manifest written to {args.manifest}")

    print(f"converted {len(results)} profiler.tsv file(s)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())