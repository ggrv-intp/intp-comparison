# V0 -- Original IntP (SystemTap, kernel ≤6.6)

Reference baseline used for portability and metric-fidelity comparison.
This directory contains only the canonical V0 script (`intp.stp`, 660
lines) preserved unchanged from the 2022 IntP paper. It is **not built
or run** in current campaigns; it exists so that:

- the Makefile can parse-check it (`make validate-v0`),
- `docs/METRICS-DEEP-DIVE.md` and `docs/VARIANT-COMPARISON.md` can cite
  exact line numbers, and
- `bench/findings/v0-baseline-failure-diagnosis.md` documents why this
  script no longer compiles on kernel ≥6.8.

## Files

- `intp.stp` -- the canonical V0 SystemTap script. **Read-only**; do not
  modify. Contract with the 2022 paper baseline.
- `intp.stp.template` -- byte-for-byte copy of `intp.stp` with hardware
  constants replaced by `@@PLACEHOLDER@@` tokens. Edited only when the
  recalibration set itself changes.
- `generate-stp.sh` -- sources `shared/intp-detect.sh`, substitutes
  placeholders, writes `intp.recal.stp`. Prints a `KEY=VALUE` calibration log
  on stdout (captured per-rep as `<rep>/...v0-calibration.kv`).
- `intp.recal.stp` -- the recalibrated script actually loaded by `stap`.
  Gitignored; regenerated on every V0 run.

## Recalibration constants

The original `intp.stp` embeds calibrated constants from the 2022 PUCRS dev
machine. Five of them must be recomputed per-host or normalisation produces
the wrong percentage. `intp.stp.template` carries the placeholders below;
`generate-stp.sh` fills them from `shared/intp-detect.sh`.

| Placeholder                  | Source variable             | Unit (template)   | Original value     | Source                                                          |
|------------------------------|-----------------------------|-------------------|--------------------|-----------------------------------------------------------------|
| `@@NIC_BYTES_PER_SEC@@`      | `INTP_NIC_SPEED_MBPS`       | bytes/sec (×125k) | `125000000` (1GbE) | `/sys/class/net/<iface>/speed`                                  |
| `@@LLC_BYTES@@`              | `INTP_LLC_SIZE_KB`          | bytes (×1024)     | `34000000` (~34MB) | `/sys/devices/system/cpu/cpu0/cache/index*/size`                |
| `@@MEM_BW_BYTES_PER_SEC@@`   | `INTP_MEM_BW_MBPS`          | bytes/sec (×125k) | `34000000000`      | dmidecode (root) or DDR4-2666 dual-channel default              |
| `@@IMC_PMU_TYPE@@`           | `INTP_IMC_PMU_TYPE`         | integer           | `14`               | `/sys/devices/uncore_imc/type` or `/sys/devices/uncore_imc_0/type` |
| `@@CMT_SCALE_FACTOR@@`       | `INTP_CMT_SCALE_FACTOR`     | bytes/RMID-tick   | `49152`            | `/sys/devices/intel_cqm/format/event` (fallback: 49152)         |

Constants **not** placed via the template:

- **IMC channel count.** `intp.stp` registers events on CPUs 0 and 1
  (two channels). Sapphire Rapids exposes up to 8 channels per socket
  (`uncore_imc_0..7`). The generator warns when
  `INTP_IMC_CHANNEL_COUNT > 2`; measured `mbw` is a lower bound until
  the script is extended.
- **CMT IPI cpumask.** The embedded C block IPIs CPUs 0 and 1 to read
  `MSR_IA32_QM_CTR`. On dual-socket hosts the second CPU should live on
  socket 1. Single-socket Sapphire Rapids is unaffected.
- **NIC iface / block dev.** Not hardcoded in `intp.stp` -- the netfilter
  and `kernel.trace("block_rq_complete")` probes are system-wide.
  `INTP_DEFAULT_NIC_IFACE` / `INTP_DEFAULT_BLOCK_DEV` are exported for
  launcher-side filtering, not for substitution.

## Status

- Compiles only on kernel ≤6.6 (the `cqm_rmid` field of
  `struct hw_perf_event` and the `MSR_IA32_QM_CTR` redefinitions used by
  the embedded C blocks were removed in 6.8). For modern kernels use
  V0.1 (`v0.1-stap-k68/`), V1 (`v1-stap-native/`), or V1.1
  (`v1.1-stap-helper/`).
- Hardware constants (1 GbE NIC, 34 GB/s memory bandwidth, 34 MB LLC,
  IMC PMU type 14, CMT scale factor 49152) reflect the 2022 PUCRS dev
  machine. Variants V2/V3/V3.1 autodetect these via
  `shared/intp-detect.sh`.

## See also

- Upstream archival repo: <https://github.com/projectintp/intp> -- the
  original layout (additional `.STP` build variants, screenshots, and
  Debian/RedHat install guides) is preserved there.
- Top-level [README.md](../README.md) -- variant matrix and quick start.
- [VERSIONS.md](../VERSIONS.md) -- legacy ↔ current naming map.
- [METRICS-ALIGNMENT.md](../METRICS-ALIGNMENT.md) -- per-metric formulas
  across all variants, with V0 as reference.
