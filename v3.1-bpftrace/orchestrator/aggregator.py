#!/usr/bin/env python3
"""V3.1 aggregator -- reads bpftrace JSON streams plus resctrl and emits
IntP TSV output (7 columns: netp, nets, blk, mbw, llcmr, llcocc, cpu).

The aggregator is intentionally threaded: each bpftrace script streams
JSON lines on its own FIFO, and a resctrl polling thread maintains
hardware-counter state. The main loop wakes every ``--interval`` seconds
and emits one TSV row with integer percentages.

Output format must match V0/V1/V2 byte-for-byte so IADA consumers work
unchanged.
"""

from __future__ import annotations

import argparse
import json
import signal
import sys
import threading
import time
from pathlib import Path

import detect  # noqa: E402
from resctrl_reader import ResctrlReader  # noqa: E402


METRICS = ("netp", "nets", "blk", "mbw", "llcmr", "llcocc", "cpu")


class MetricState:
    """Shared state updated by reader threads and consumed by the main loop."""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.latest: dict[str, dict] = {}
        self.ready: dict[str, bool] = {}
        self.stop = threading.Event()

    def update(self, metric: str, payload: dict) -> None:
        with self.lock:
            if payload.get("ready"):
                self.ready[metric] = True
                return
            self.latest[metric] = payload
            self.ready[metric] = True

    def snapshot(self, metric: str) -> dict | None:
        with self.lock:
            value = self.latest.get(metric)
            return dict(value) if value else None


def read_bpftrace_stream(pipe_path: Path, metric: str, state: MetricState) -> None:
    """Reader thread for one bpftrace script's JSON output."""
    while not state.stop.is_set():
        try:
            with pipe_path.open("r") as fh:
                for raw in fh:
                    if state.stop.is_set():
                        break
                    line = raw.strip()
                    if not line or not line.startswith("{"):
                        continue
                    try:
                        payload = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if payload.get("metric") != metric:
                        continue
                    state.update(metric, payload)
        except FileNotFoundError:
            time.sleep(0.1)
            continue
        except OSError:
            time.sleep(0.1)
            continue
        if state.stop.is_set():
            break
        time.sleep(0.05)


def resctrl_poll_loop(reader: ResctrlReader, state: MetricState, interval: float) -> None:
    reader.sample()
    while not state.stop.is_set():
        time.sleep(interval)
        sample = reader.sample()
        state.update("mbw", {"mbw_bps": sample["mbw_bps"]})
        state.update("llcocc", {"llcocc_bytes": sample["llcocc_bytes"]})


def _clamp(value: float, lo: int = 0, hi: int = 99) -> int:
    ivalue = int(value)
    if ivalue < lo:
        return lo
    if ivalue > hi:
        return hi
    return ivalue


def compute_netp(payload: dict | None, nic_speed_bps: int, interval: float) -> int:
    if not payload or nic_speed_bps <= 0 or interval <= 0:
        return 0
    tx = payload.get("tx_bytes", 0)
    rx = payload.get("rx_bytes", 0)
    bytes_per_sec = (tx + rx) / interval
    return _clamp(bytes_per_sec / nic_speed_bps * 100)


def compute_nets(payload: dict | None, interval: float, cpus: int) -> int:
    if not payload or interval <= 0 or cpus <= 0:
        return 0
    lat_ns = payload.get("tx_lat_ns", 0) + payload.get("rx_lat_ns", 0)
    interval_ns = interval * 1_000_000_000 * cpus
    if interval_ns <= 0:
        return 0
    return _clamp(lat_ns / interval_ns * 100)


def compute_blk(payload: dict | None, interval: float) -> int:
    if not payload or interval <= 0:
        return 0
    ops = payload.get("ops", 0)
    svctm_sum = payload.get("svctm_sum_ns", 0)
    if ops <= 0:
        return 0
    svctm_ms = (svctm_sum / ops) / 1_000_000
    ops_per_sec = ops / interval
    return _clamp(svctm_ms * ops_per_sec / 100)


def compute_cpu(payload: dict | None, interval: float, cpus: int) -> int:
    if not payload or cpus <= 0:
        return 0
    on_cpu_ns = payload.get("on_cpu_ns", 0)
    total_ns = payload.get("total_ns", 0)
    if total_ns <= 0:
        return 0
    return _clamp(on_cpu_ns / (total_ns * cpus) * 100)


def compute_llcmr(payload: dict | None) -> int:
    if not payload:
        return 0
    refs = payload.get("refs", 0)
    misses = payload.get("misses", 0)
    if refs <= 0:
        return 0
    return _clamp(misses / refs * 100)


def compute_mbw(payload: dict | None, mem_bw_bps: int) -> int:
    if not payload or mem_bw_bps <= 0:
        return 0
    return _clamp(payload.get("mbw_bps", 0) / mem_bw_bps * 100)


def compute_llcocc(payload: dict | None, llc_size_bytes: int) -> int:
    if not payload or llc_size_bytes <= 0:
        return 0
    return _clamp(payload.get("llcocc_bytes", 0) / llc_size_bytes * 100)


def emit_tsv_row(values: dict[str, int], output) -> None:
    row = "\t".join(f"{values[m]:02d}" for m in METRICS)
    output.write(row + "\n")
    output.flush()


def main() -> int:
    parser = argparse.ArgumentParser(description="V3.1 bpftrace IntP aggregator")
    parser.add_argument("--fifo-dir", required=True,
                        help="directory holding named pipes per metric")
    parser.add_argument("--interval", type=float, default=1.0,
                        help="sampling interval in seconds (default 1.0)")
    parser.add_argument("--duration", type=float, default=0.0,
                        help="total run time in seconds (0 = infinite)")
    parser.add_argument("--output", default="-",
                        help="output file path ('-' for stdout)")
    parser.add_argument("--pid", type=int, default=0,
                        help="target PID for resctrl monitoring (0 = system-wide)")
    parser.add_argument("--mon-group", default="intp-v3.1",
                        help="resctrl monitoring group name")
    parser.add_argument("--header", action="store_true",
                        help="emit a header line describing each backend")
    parser.add_argument("--nic-speed-bps", type=int, default=0,
                        help="override detected NIC speed (bytes/sec)")
    parser.add_argument("--mem-bw-max-bps", type=int, default=0,
                        help="override detected memory bandwidth ceiling (bytes/sec)")
    parser.add_argument("--llc-size-bytes", type=int, default=0,
                        help="override detected LLC size (bytes)")
    args = parser.parse_args()

    caps = detect.detect()
    nic_speed = args.nic_speed_bps if args.nic_speed_bps > 0 else detect.nic_speed_bps(caps)
    llc_bytes = args.llc_size_bytes if args.llc_size_bytes > 0 else detect.llc_size_bytes(caps)
    mem_bw = args.mem_bw_max_bps if args.mem_bw_max_bps > 0 else detect.mem_bw_bps(caps)
    cpus = detect.cpu_count(caps)

    state = MetricState()
    fifo_dir = Path(args.fifo_dir)

    threads: list[threading.Thread] = []
    for metric in ("netp", "nets", "blk", "cpu", "llcmr"):
        pipe = fifo_dir / f"{metric}.jsonl"
        t = threading.Thread(
            target=read_bpftrace_stream,
            args=(pipe, metric, state),
            daemon=True,
            name=f"reader-{metric}",
        )
        t.start()
        threads.append(t)

    pids = [args.pid] if args.pid > 0 else []
    reader = ResctrlReader(mon_group_name=args.mon_group, pids=pids)
    if reader.available:
        reader.setup()
    if reader.available:
        t = threading.Thread(
            target=resctrl_poll_loop,
            args=(reader, state, args.interval),
            daemon=True,
            name="reader-resctrl",
        )
        t.start()
        threads.append(t)

    out = sys.stdout if args.output == "-" else open(args.output, "w", buffering=1)  # noqa: SIM115
    try:
        if args.header:
            backends = (
                "# V3.1 bpftrace -- netp:tracepoint nets:tracepoint "
                "blk:tracepoint cpu:sched_switch llcmr:hardware_event "
                f"mbw:{'resctrl' if reader.available else 'unavailable'} "
                f"llcocc:{'resctrl' if reader.available else 'unavailable'}"
            )
            out.write(backends + "\n")
            out.write("\t".join(METRICS) + "\n")

        def handle_signal(signum, frame):  # noqa: ARG001
            state.stop.set()

        signal.signal(signal.SIGINT, handle_signal)
        signal.signal(signal.SIGTERM, handle_signal)

        start = time.monotonic()
        next_tick = start + args.interval
        while not state.stop.is_set():
            now = time.monotonic()
            sleep_for = next_tick - now
            if sleep_for > 0:
                state.stop.wait(sleep_for)
            if state.stop.is_set():
                break
            next_tick += args.interval

            values = {
                "netp": compute_netp(state.snapshot("netp"), nic_speed, args.interval),
                "nets": compute_nets(state.snapshot("nets"), args.interval, cpus),
                "blk":  compute_blk(state.snapshot("blk"), args.interval),
                "llcmr": compute_llcmr(state.snapshot("llcmr")),
                "cpu":  compute_cpu(state.snapshot("cpu"), args.interval, cpus),
                "mbw":  compute_mbw(state.snapshot("mbw"), mem_bw) if reader.available else 0,
                "llcocc": (
                    compute_llcocc(state.snapshot("llcocc"), llc_bytes)
                    if reader.available else 0
                ),
            }
            emit_tsv_row(values, out)

            if args.duration > 0 and (time.monotonic() - start) >= args.duration:
                break
    finally:
        state.stop.set()
        if reader.available:
            reader.cleanup()
        if out is not sys.stdout:
            out.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
