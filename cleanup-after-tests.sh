#!/usr/bin/env bash
set -euo pipefail

pkill -f 'stress-ng|intp-hybrid|intp-ebpf|run-intp-bpftrace|bpftrace|stap .*intp|intp-resctrl-helper' || true

find /tmp -maxdepth 1 -type d \
  \( -name 'intp-*' -o -name 'intp-xval-*' -o -name 'intp-bpftrace-*' \) \
  -exec rm -rf {} + || true

make -C /root/intp/v4-hybrid-procfs clean || true
make -C /root/intp/v5-bpftrace clean || true
make -C /root/intp/v6-ebpf-core clean || true

echo "Cleanup concluido."
