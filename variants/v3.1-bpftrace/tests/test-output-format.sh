#!/bin/bash
# test-output-format.sh -- verify aggregator produces IntP-compatible TSV.
#
# Feeds synthetic bpftrace JSON into named pipes and checks that the
# aggregator emits well-formed 7-column rows of zero-padded percentages.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON_BIN="${PYTHON:-python3}"

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    echo "test-output-format: python3 not installed; skipping"
    exit 0
fi

WORKDIR="$(mktemp -d /tmp/intp-v3.1-test-XXXXXX)"
cleanup() {
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

for m in netp nets blk cpu llcmr; do
    mkfifo "$WORKDIR/$m.jsonl"
done

(
    # Write one ready + one data line per metric, then hold the pipe open.
    for m in netp nets blk cpu llcmr; do
        printf '{"metric":"%s","ready":true}\n' "$m" >"$WORKDIR/$m.jsonl" &
    done
    wait

    printf '{"metric":"netp","ts":1,"tx_bytes":1000,"rx_bytes":1000}\n' \
        >"$WORKDIR/netp.jsonl" &
    printf '{"metric":"nets","ts":1,"tx_lat_ns":0,"tx_count":0,"rx_lat_ns":0,"rx_count":0}\n' \
        >"$WORKDIR/nets.jsonl" &
    printf '{"metric":"blk","ts":1,"ops":0,"total_bytes":0,"svctm_sum_ns":0}\n' \
        >"$WORKDIR/blk.jsonl" &
    printf '{"metric":"cpu","ts":1,"on_cpu_ns":0,"total_ns":1000000000}\n' \
        >"$WORKDIR/cpu.jsonl" &
    printf '{"metric":"llcmr","ts":1,"refs":0,"misses":0}\n' \
        >"$WORKDIR/llcmr.jsonl" &
    wait
) &
FEEDER_PID=$!

OUTPUT="$WORKDIR/out.tsv"
"$PYTHON_BIN" "$SCRIPT_DIR/orchestrator/aggregator.py" \
    --fifo-dir "$WORKDIR" \
    --interval 0.5 \
    --duration 1.5 \
    --output "$OUTPUT" &
AGG_PID=$!

wait "$AGG_PID"
wait "$FEEDER_PID" 2>/dev/null || true

if [[ ! -s "$OUTPUT" ]]; then
    echo "test-output-format: FAIL -- no rows emitted"
    exit 1
fi

bad=0
tab=$'\t'
row_re="^[0-9]{2}(${tab}[0-9]{2}){6}$"
while IFS= read -r line; do
    # Each row must be seven tab-separated 2-digit integers.
    if ! [[ "$line" =~ $row_re ]]; then
        echo "test-output-format: FAIL -- malformed row: $line"
        bad=1
    fi
done <"$OUTPUT"

if (( bad )); then
    exit 1
fi

echo "test-output-format: OK ($(wc -l <"$OUTPUT") rows)"
