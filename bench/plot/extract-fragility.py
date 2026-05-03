#!/usr/bin/env python3
# extract-fragility.py — turn raw stap.log + run.json into structured fragility metrics.
#
# Usage:
#   python3 bench/plot/extract-fragility.py <bench-full dir>
#
# Walks <env>/<variant>/<stage>/<workload>/rep<R>/, parses profiler.stap.log
# (SystemTap variants v1/v2/v3) and run.json, and writes:
#   <bench-full>/fragility-summary.tsv      one row per (env,variant,stage,workload,rep)
#   <bench-full>/fragility-aggregated.tsv   one row per (env,variant) with mean/std

import json
import os
import re
import sys
from collections import defaultdict
from pathlib import Path
from statistics import mean, pstdev

SKIPPED_RE = re.compile(r'[Ss]kipped\s+(\d+)\s+probes?')
SKIPPED_FATAL_RE = re.compile(r'too many probes', re.IGNORECASE)
OVERLOAD_RE = re.compile(r'\boverload\b', re.IGNORECASE)
ERROR_RE = re.compile(r'^(ERROR|error:|FATAL|fatal:)', re.MULTILINE)
WARN_RE = re.compile(r'^(WARNING|warning:)', re.MULTILINE)
PROBE_REGISTRATION_RE = re.compile(r'probe registration', re.IGNORECASE)

# Default sampling interval (seconds) used by run-intp-bench.sh; the bench
# script does not record this in run.json, so the extractor accepts an override
# via env var INTP_INTERVAL when callers ran with --interval != 1.
DEFAULT_INTERVAL_S = float(os.environ.get('INTP_INTERVAL', '1'))


def parse_stap_log(path: Path) -> dict:
    """Return fragility counters extracted from a stap stderr/stdout log."""
    out = {
        'stap_log_present': 1,
        'stap_log_bytes': path.stat().st_size,
        'skipped_probes_lines': 0,
        'skipped_probes_total': 0,
        'skipped_fatal': 0,
        'overload_lines': 0,
        'error_lines': 0,
        'warning_lines': 0,
        'probe_registration_failures': 0,
    }
    try:
        text = path.read_text(errors='replace')
    except OSError:
        out['stap_log_present'] = 0
        return out

    for m in SKIPPED_RE.finditer(text):
        out['skipped_probes_lines'] += 1
        try:
            out['skipped_probes_total'] += int(m.group(1))
        except ValueError:
            pass
    out['skipped_fatal'] = len(SKIPPED_FATAL_RE.findall(text))
    out['overload_lines'] = len(OVERLOAD_RE.findall(text))
    out['error_lines'] = len(ERROR_RE.findall(text))
    out['warning_lines'] = len(WARN_RE.findall(text))
    out['probe_registration_failures'] = len(PROBE_REGISTRATION_RE.findall(text))
    return out


def empty_stap_metrics() -> dict:
    return {
        'stap_log_present': 0,
        'stap_log_bytes': 0,
        'skipped_probes_lines': 0,
        'skipped_probes_total': 0,
        'skipped_fatal': 0,
        'overload_lines': 0,
        'error_lines': 0,
        'warning_lines': 0,
        'probe_registration_failures': 0,
    }


def discover_runs(root: Path):
    """Yield rep directories that contain a run.json."""
    for run_json in root.rglob('run.json'):
        yield run_json.parent


def load_run_json(rep_dir: Path) -> dict | None:
    try:
        return json.loads((rep_dir / 'run.json').read_text())
    except (OSError, json.JSONDecodeError):
        return None


def count_tsv_samples(prof: Path) -> int:
    samples_file = prof.with_suffix('.tsv.samples')
    if samples_file.exists():
        try:
            return int(samples_file.read_text().strip() or 0)
        except ValueError:
            pass
    if not prof.exists():
        return 0
    n = 0
    with prof.open() as fh:
        for line in fh:
            if line and line[0].isdigit():
                n += 1
    return n


def row_for(rep_dir: Path) -> dict | None:
    meta = load_run_json(rep_dir)
    if not meta:
        return None
    variant = meta.get('variant', '')
    prof = rep_dir / 'profiler.tsv'
    samples = count_tsv_samples(prof)
    duration_target = float(meta.get('duration_target_s') or 0)
    duration_observed = float(meta.get('duration_observed_s') or 0)
    expected = duration_target / DEFAULT_INTERVAL_S if duration_target > 0 else 0
    if expected > 0:
        sample_loss_pct = max(0.0, (expected - samples) / expected * 100.0)
    else:
        sample_loss_pct = 0.0

    stap_log = rep_dir / 'profiler.stap.log'
    if variant in ('v1', 'v2', 'v3') and stap_log.exists():
        stap = parse_stap_log(stap_log)
    else:
        stap = empty_stap_metrics()

    row = {
        'env': meta.get('env', ''),
        'variant': variant,
        'stage': meta.get('stage', ''),
        'workload': meta.get('workload', ''),
        'rep': meta.get('rep', 0),
        'duration_target_s': duration_target,
        'duration_observed_s': duration_observed,
        'expected_samples': round(expected, 2),
        'actual_samples': samples,
        'sample_loss_pct': round(sample_loss_pct, 2),
        'notes': (meta.get('notes') or '').replace('\t', ' '),
    }
    row.update(stap)
    return row


COLUMNS = [
    'env', 'variant', 'stage', 'workload', 'rep',
    'duration_target_s', 'duration_observed_s',
    'expected_samples', 'actual_samples', 'sample_loss_pct',
    'stap_log_present', 'stap_log_bytes',
    'skipped_probes_lines', 'skipped_probes_total', 'skipped_fatal',
    'overload_lines', 'error_lines', 'warning_lines',
    'probe_registration_failures', 'notes',
]


def write_summary(rows, out_path: Path) -> None:
    with out_path.open('w') as fh:
        fh.write('\t'.join(COLUMNS) + '\n')
        for r in rows:
            fh.write('\t'.join(str(r.get(c, '')) for c in COLUMNS) + '\n')


def aggregate(rows, out_path: Path) -> None:
    grouped = defaultdict(list)
    for r in rows:
        grouped[(r['env'], r['variant'])].append(r)

    agg_cols = [
        'env', 'variant', 'n_runs',
        'mean_sample_loss_pct', 'std_sample_loss_pct', 'max_sample_loss_pct',
        'sum_skipped_probes_total', 'mean_skipped_probes_total',
        'sum_skipped_fatal', 'sum_overload_lines',
        'sum_error_lines', 'sum_warning_lines',
        'sum_probe_registration_failures',
        'runs_with_loss_gt_5pct', 'runs_with_zero_samples',
    ]
    with out_path.open('w') as fh:
        fh.write('\t'.join(agg_cols) + '\n')
        for (env, variant), items in sorted(grouped.items()):
            losses = [r['sample_loss_pct'] for r in items]
            skips = [r['skipped_probes_total'] for r in items]
            row = {
                'env': env,
                'variant': variant,
                'n_runs': len(items),
                'mean_sample_loss_pct': round(mean(losses), 2) if losses else 0,
                'std_sample_loss_pct': round(pstdev(losses), 2) if len(losses) > 1 else 0,
                'max_sample_loss_pct': round(max(losses), 2) if losses else 0,
                'sum_skipped_probes_total': sum(skips),
                'mean_skipped_probes_total': round(mean(skips), 2) if skips else 0,
                'sum_skipped_fatal': sum(r['skipped_fatal'] for r in items),
                'sum_overload_lines': sum(r['overload_lines'] for r in items),
                'sum_error_lines': sum(r['error_lines'] for r in items),
                'sum_warning_lines': sum(r['warning_lines'] for r in items),
                'sum_probe_registration_failures': sum(r['probe_registration_failures'] for r in items),
                'runs_with_loss_gt_5pct': sum(1 for r in items if r['sample_loss_pct'] > 5),
                'runs_with_zero_samples': sum(1 for r in items if r['actual_samples'] == 0),
            }
            fh.write('\t'.join(str(row[c]) for c in agg_cols) + '\n')


def main(argv):
    if len(argv) != 2:
        print(f'usage: {argv[0]} <bench-full dir>', file=sys.stderr)
        return 2
    root = Path(argv[1]).resolve()
    if not root.is_dir():
        print(f'not a directory: {root}', file=sys.stderr)
        return 2

    rows = []
    for rep_dir in discover_runs(root):
        r = row_for(rep_dir)
        if r:
            rows.append(r)

    if not rows:
        print('no run.json files found under', root, file=sys.stderr)
        return 1

    rows.sort(key=lambda r: (r['env'], r['variant'], r['stage'], r['workload'], r['rep']))

    summary_path = root / 'fragility-summary.tsv'
    agg_path = root / 'fragility-aggregated.tsv'
    write_summary(rows, summary_path)
    aggregate(rows, agg_path)

    print(f'wrote {summary_path}  ({len(rows)} runs)')
    print(f'wrote {agg_path}')
    print()
    print('Per-variant fragility (env=bare, sorted by mean sample loss):')
    bare = [r for r in rows if r['env'] == 'bare']
    if bare:
        per_variant = defaultdict(list)
        for r in bare:
            per_variant[r['variant']].append(r)
        ranked = sorted(
            per_variant.items(),
            key=lambda kv: -mean([x['sample_loss_pct'] for x in kv[1]] or [0]),
        )
        print(f'  {"variant":<6} {"runs":>5} {"mean_loss%":>11} {"max_loss%":>10} {"skipped":>10} {"fatals":>7} {"errors":>7}')
        for v, items in ranked:
            losses = [x['sample_loss_pct'] for x in items]
            print(f'  {v:<6} {len(items):>5} '
                  f'{mean(losses):>11.2f} {max(losses):>10.2f} '
                  f'{sum(x["skipped_probes_total"] for x in items):>10d} '
                  f'{sum(x["skipped_fatal"] for x in items):>7d} '
                  f'{sum(x["error_lines"] for x in items):>7d}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
