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

- `intp.stp` -- the canonical V0 SystemTap script. Read-only; do not modify.

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
