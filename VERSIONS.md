# IntP variant naming

This document maps the variant naming after the 2026-05-05 reorganization.
Use it to translate references between the legacy naming (used in commits
before the rename, in the original IntP paper, and in the `pre-rename-2026-05-05`
git tag) and the current naming (used everywhere else).

## Naming scheme

Major version groups variants by *paradigm*; minor version distinguishes
implementations within the same paradigm.

- **v0.x** -- legacy SystemTap. v0 / v0.1 are kept read-only for paper
  reproducibility; v0.2 (new) ports the V0 semantics to a userspace-helper
  pattern so the U22 / kernel 5.15 GA leg is runnable without the V0
  fragility cliff.
- **v1.x** -- modern SystemTap. Active.
- **v2.x** -- userspace C using stable kernel ABIs (procfs, perf_event_open,
  resctrl). Active.
- **v3.x** -- eBPF-based implementations. Active.

## Mapping

| Current | Legacy | Directory | Approach | Status |
|---------|--------|-----------|----------|--------|
| v0      | v1     | `v0-stap-classic/`        | Original IntP paper, SystemTap + embedded C, MSR-direct RDT, kernel 4.x baseline | Reference only |
| v0.1    | v2     | `v0.1-stap-k68/`          | v0 patched for kernel 6.8: removes `cqm_rmid` access and conflicting MSR redefinitions; LLC occupancy disabled | Reference only |
| v0.2    | (new)  | `v0.2-stap-helper/`       | V0 probe set (paper-faithful for netp/nets/blk/llcmr/cpu) + userspace helper for the two RCU-unsafe operations (uncore IMC via `perf_event_open` syscall, LLC occupancy via resctrl mon\_groups). Target kernel **5.15 GA / Ubuntu 22.04**; same helper pattern v1.1 uses on 6.8+ | Active (legacy-V0 campaign) |
| v1      | v3*    | `v1-stap-native/`         | Stap-only, native probes (`probe perf.type(3).config(...).process(@1)`); no embedded C creating perf events; mbw and llcocc reported as 0 | Active |
| v1.1    | (new)  | `v1.1-stap-helper/`       | New build: stap for software metrics + userspace helper for hardware metrics (uncore IMC via `perf_event_open` syscall, LLC occupancy via resctrl mon\_groups). Helper architecture isolates RCU-unsafe operations from probe context | Active |
| v2      | v4     | `v2-c-stable-abi/`        | Pure C (no framework): procfs polling, `perf_event_open` syscall, resctrl filesystem. Runtime-adaptive backend hierarchy | Active |
| v3      | v6     | `v3-ebpf-libbpf/`         | C + libbpf + CO-RE; software metrics through ring buffer, hardware metrics through resctrl | Active |
| v3.1    | v5     | `v3.1-bpftrace/`          | bpftrace DSL scripts + Python orchestrator + resctrl. SystemTap-script-style ergonomics on top of eBPF | Active |

\* The v3 lineage was discontinued at the `pre-rename-2026-05-05` tag because
its embedded-C `perf_event_create_kernel_counter()` calls triggered RCU
stalls on kernel 6.8. The current v1 restores the v0-faithful stap-native
approach; v1.1 revisits the resctrl integration with a userspace helper
to avoid the RCU-unsafe pattern, recovering the full 7-metric coverage.

## Why the rename

1. **Major versions reflect paradigm.** The legacy naming grew incrementally
   (v1 -> v2 -> ... -> v6) and number proximity did not imply architectural
   proximity. v1 (legacy) and v3 (legacy) are both SystemTap and architecturally
   close; v4 (legacy) is a different paradigm. The new scheme groups paradigms
   under the same major version.
2. **Minor versions distinguish implementations.** v3 / v3.1 share eBPF as a
   paradigm but differ in DSL choice (libbpf C vs bpftrace).
3. **Paper references.** Citing "v3.1" tells readers it is a variant of the
   v3 approach with a specific implementation choice, more useful than "v5".

## Reproducing experiments

- For experiments published with **legacy naming**, check out
  `git checkout pre-rename-2026-05-05` to get the source tree as it existed
  on the day of the rename.
- For **current and future experiments**, use the current naming.
- Result snapshots in `results/` generated before the rename retain the legacy
  variant strings (e.g., `bare/v3/solo/...`) by design -- snapshots are
  immutable. Use this table to translate when reading them.

## Status after rename (2026-05-05)

- v1.1 (the helper-userspace SystemTap variant) is implemented and integrated
  into `bench/run-intp-bench.sh`; see `v1.1-stap-helper/` and
  `METRICS-ALIGNMENT.md` for the full coverage matrix and the documented
  HiBench distributed-mode limitation.
- v1 was validated on the production host (no RCU stalls under repeated
  runs); see `bench/findings/v1-modernization-reliability-findings.md`.
- The v3-legacy result gap from the 2026-05-04 campaign (7 of 60 solo runs
  before the kernel hung) was retired in favour of the post-rename
  campaign on Hetzner Sapphire Rapids (`results/bench-full/`, dated
  2026-05-07), which covers v1.1, v2, v3, and v3.1.

## Status after legacy-V0 + cross-env campaigns (2026-05-11)

- v0 was re-enabled as the default measured baseline in
  `bench/run-intp-bench.sh`; v3.1 was swapped out of the default measured
  set but remains routable via `BENCH_VARIANTS=...,v3.1`. See
  `docs/EXPERIMENT-STRATEGY.md` for the rationale.
- v0.2 (new) was scaffolded as the U22 / kernel 5.15 leg of the
  legacy-V0 campaign. It uses the same userspace-helper pattern v1.1
  uses, but targets kernel 5.15 GA so the U22 leg of the experiment
  doesn't trip V0's stability cliff. Gated by `variant_kernel_ok` to
  `5.10 ≤ k < 6.0`; on 6.x v1.1 is the right variant. Not yet
  validated on a real U22 host -- pending the operator-side smoke
  test.
- Cross-environment campaign infrastructure (BENCH_CPUS/BENCH_MEM
  parity knobs, orphan-qemu PID reaping, Kruskal-Wallis + Mann-Whitney
  + Cliff's delta analysis over `aggregate-means.tsv`) is integrated
  in `bench/run-intp-bench.sh` and `bench/plot/plot-cross-environment.py`;
  see `docs/CROSS-ENV-CAMPAIGN.md`.
