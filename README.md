# IntP -- Interference Profiler: Multi-Variant Comparison

This repository contains seven implementation variants of IntP, an interference
profiler that collects 7 metrics from the Linux kernel. The variants are
organized for systematic comparison as part of a Master's dissertation on
kernel instrumentation for interference profiling (PPGCC/PUCRS, advisor
Prof. Cesar De Rose). The research compares the original SystemTap-based IntP
across kernel eras and an RCU-safe stap+helper hybrid against modern
instrumentation approaches (procfs polling, bpftrace, eBPF/CO-RE) to evaluate
portability, safety, and measurement fidelity tradeoffs.

## About

**Author:** André Sacilotto Santos (PPGCC/PUCRS)
**Advisor:** Prof. Cesar De Rose
**Program:** Post-Graduate Program in Computer Science -- PPGCC, PUCRS
**Research Area:** Cloud computing performance, kernel instrumentation, interference profiling

### Background

IntP (Interference Profiler) was originally developed by Xavier and De Rose (2022, PUCRS)
as a SystemTap-based tool for measuring resource interference between co-located workloads
in cloud environments. It collects seven low-level metrics (network physical, network
stack, block I/O, memory bandwidth, LLC miss ratio, LLC occupancy, CPU) to characterise
how one tenant's resource usage affects another's performance.

This work extends and refactors IntP to support modern Linux kernels (6.8+) and
modern instrumentation frameworks (bpftrace, eBPF/CO-RE), addressing the fragility of
the original SystemTap approach across kernel versions and hardware architectures.

### Research Goals

1. Reproduce the original IntP baseline (V0) and document breakage on kernel 6.8+.
2. Develop minimal patches to restore functionality on current kernels (V0.1, V1) and a stap+helper hybrid (V1.1) that recovers full metric coverage without RCU-unsafe operations.
3. Implement kernel-module-free alternatives using procfs/perf_event (V2), bpftrace (V3.1), and eBPF/CO-RE (V3).
4. Compare all seven variants across portability, safety, deployment complexity, and measurement fidelity dimensions.

### Status

| Variant | Status |
| --------- | -------- |
| V0 -- Original (SystemTap, <=6.6) | Complete (baseline; runs on Ubuntu 22.04 + kernel 6.5 HWE only) |
| V0.1 -- Updated (SystemTap, 6.8+, LLC disabled) | Complete |
| V1 -- Stap-native (SystemTap, 6.8+, mbw/llcocc disabled) | Complete |
| V1.1 -- Stap + userspace helper (SystemTap, 6.8+, full metrics, RCU-safe) | Helper implemented; matching `.stp` and bench integration done; pending target-hardware validation |
| V2 -- C / procfs / perf_event / resctrl | Validated locally; awaiting target hardware for Phase 3 experiments |
| V3.1 -- bpftrace + Python orchestrator | Validated locally; awaiting target hardware for Phase 3 experiments |
| V3 -- eBPF/CO-RE (libbpf) | Validated locally; awaiting target hardware for Phase 3 experiments |

### Citation

If you use this software in your research, please cite it using the metadata in
[CITATION.cff](CITATION.cff). A full thesis citation will be added upon defense
(expected until March 2027).

## Variant Comparison

| Feature                  | V0 classic | V0.1 k68 | V1 native | V1.1 helper | V2 stable-abi | V3.1 bpftrace | V3 ebpf-core |
|--------------------------|:----------:|:--------:|:---------:|:-----------:|:-------------:|:-------------:|:------------:|
| Kernel module required   |    Yes     |   Yes    |    Yes    |     Yes     |      No       |     No        |      No      |
| Userspace helper         |    No      |   No     |    No     |     Yes     |      n/a      |     Yes       |     Yes      |
| Debuginfo required       |    Yes     |   Yes    |    Yes    |     Yes     |      No       |   No (BTF)    |   No (BTF)   |
| Kernel crash risk        |    High    |   High   |    Low    |     Low     |     None      |    None       |     None     |
| Min kernel version       |   <=6.6    |   6.8+   |    6.8+   |     6.8+    |     4.10+     |    5.8+       |     5.8+     |
| netp                     |     x      |    x     |     x     |      x      |       x       |       x       |       x      |
| nets (service-time)      |     x      |    x     |     x     |      x      |       ~       |       x       |       x      |
| blk                      |     x      |    x     |     x     |      x      |       x       |       x       |       x      |
| mbw                      |     x      |    x     |     -     |      x      |       x       |       x       |       x      |
| llcmr                    |     x      |    x     |     x     |      x      |       x       |       x       |       x      |
| llcocc                   |     x      |    -     |     -     |      x      |       x       |       x       |       x      |
| cpu                      |     x      |    x     |     x     |      x      |       x       |       x       |       x      |
| Framework                | SystemTap  | SystemTap| SystemTap | SystemTap+C |     None      |   bpftrace    |    libbpf    |
| AMD EPYC compatible      |  Partial   |  Partial |  Partial  |   Partial   |      Yes      |     Yes       |      Yes     |
| ARM server compatible    |    No      |   No     |    No     |     No      |    Partial    |   Partial     |    Partial   |

x = supported, ~ = polling approximation, - = disabled in this build

## The 7 Metrics

- **netp** -- Network physical utilization (NIC TX+RX bandwidth)
- **nets** -- Network stack utilization (kernel networking service time)
- **blk** -- Block I/O utilization (disk busy percentage)
- **mbw** -- Memory bandwidth utilization (LLC-to-DRAM traffic)
- **llcmr** -- LLC miss ratio (cache misses / cache references)
- **llcocc** -- LLC occupancy (bytes of last-level cache occupied)
- **cpu** -- CPU utilization (user + system time percentage)

## Directory Layout

```text
.
|-- README.md                  This file
|-- LICENSE                    MIT license
|-- docs/                      Cross-variant documentation
|   |-- METRICS-DEEP-DIVE.md   Technical details of all 7 metrics
|   |-- KERNEL-6.8-CHANGES.md  What kernel 6.8 broke and why
|   |-- PORTABILITY-ROADMAP.md Portability analysis
|   |-- HARDWARE-COMPATIBILITY.md  Hardware feature tables
|   |-- VARIANT-COMPARISON.md  Detailed variant rationale
|-- shared/                    Components used across variants
|   |-- intp-detect.sh         Hardware capability detection
|   |-- intp-resctrl-helper.sh resctrl companion daemon
|-- v0-stap-classic/           Unmodified 2022 IntP (SystemTap, kernel <=6.6)
|-- v0.1-stap-k68/             Kernel 6.8 patch (LLC occupancy disabled)
|-- v1-stap-native/            Kernel 6.8+, stap-native probes (mbw/llcocc disabled)
|-- v1.1-stap-helper/          Kernel 6.8+, stap + userspace helper (full 7 metrics, RCU-safe)
|-- v2-c-stable-abi/           Pure C: procfs / perf_event_open / resctrl
|-- v3.1-bpftrace/             bpftrace scripts + Python orchestrator + resctrl
|-- v3-ebpf-libbpf/            Full eBPF/CO-RE with libbpf
|-- VERSIONS.md                Variant-naming map (current vs legacy pre-2026-05-05)
```

## Quick Start

### V0 -- Original IntP (kernel <= 6.6)

```bash
cd v0-stap-classic
sudo stap -g intp.stp <PID> <interval_ms>
```

Requires: SystemTap, kernel debuginfo, kernel <= 6.6.

### V0.1 -- Updated for Kernel 6.8 (LLC disabled)

```bash
cd v0.1-stap-k68
sudo stap -g intp-6.8.stp <PID> <interval_ms>
```

Requires: SystemTap, kernel debuginfo, kernel 6.8+. Note: llcocc returns 0.

### V1 -- Stap-native (5/7 metrics; no helper, no embedded I/O)

```bash
cd v1-stap-native
sudo stap -g intp-resctrl.stp <comm-pattern>
```

Requires: SystemTap 5.x, kernel debuginfo, kernel 6.8+. mbw and llcocc are
reported as 0 (deferred to V1.1).

### V1.1 -- Stap + userspace helper (full 7/7 metrics, RCU-safe)

```bash
cd v1.1-stap-helper
make
sudo ./intp-helper <comm-pattern> &
sudo stap -g intp-v1.1.stp <comm-pattern>
# after run: kill the helper
```

Requires: SystemTap 5.x, kernel debuginfo, kernel 6.8+, Intel RDT (resctrl)
for `llcocc`, uncore IMC PMU for `mbw`. mbw/llcocc gracefully degrade to 0
if hardware is unavailable.

### V2 -- C: procfs / perf_event / resctrl

```bash
cd v2-c-stable-abi
make
sudo ./intp-hybrid -p <PID> -i <interval_ms>
```

No framework dependencies. Requires: resctrl for mbw/llcocc.

### V3.1 -- bpftrace

```bash
cd v3.1-bpftrace
sudo ./run-intp-bpftrace.sh <PID> <interval_ms>
```

Requires: bpftrace, kernel BTF, resctrl for mbw/llcocc.

### V3 -- eBPF/CO-RE

```bash
cd v3-ebpf-libbpf
make
sudo ./intp-ebpf -p <PID> -i <interval_ms>
```

Requires: libbpf, clang, kernel BTF, resctrl for mbw/llcocc.

## Documentation

- [Hardware Compatibility](docs/HARDWARE-COMPATIBILITY.md) -- RDT, PQoS, MPAM tables
- [Kernel 6.8 Changes](docs/KERNEL-6.8-CHANGES.md) -- What broke and the fix paths
- [Metrics Deep Dive](docs/METRICS-DEEP-DIVE.md) -- Kernel probe points, formulas, constants
- [Portability Roadmap](docs/PORTABILITY-ROADMAP.md) -- Cross-kernel, cross-arch analysis
- [Variant Comparison](docs/VARIANT-COMPARISON.md) -- Detailed rationale for each variant
- [Bench Findings Index](bench/findings/README.md) -- Centralized empirical findings (V0 baseline diagnosis, V1 reliability notes)

## References

- **Original IntP source repository:** [projectintp/intp](https://github.com/projectintp/intp).
- **Original IntP paper:** Xavier, M. G. and De Rose, C. A. F. (2022). *IntP: Quantifying Cross-Application Interference via System-Level Instrumentation*. SBAC-PAD 2022, Bordeaux, France, pp. 221-230. IEEE. PUCRS. PDF: <https://repositorio.pucrs.br/dspace/bitstream/10923/24018/2/IntP_Quantifying_crossapplication_interference_via_systemlevel_instrumentation.pdf>. IEEE: <https://ieeexplore.ieee.org/document/9980934/>.
- **IADA (interference-aware scheduler that consumes IntP):** Meyer, V., da Silva, M. L., Kirchoff, D. F., De Rose, C. A. F. (2022). *IADA: A dynamic interference-aware cloud scheduling architecture for latency-sensitive workloads*. Journal of Systems and Software, vol. 194, pp. 111491. PUCRS.
- **iprof -- eBPF interference profiler (related work, TU Berlin):**
  - Gögge, R. (2023). *Finding noisy neighbours: Measuring application interference with system-level instrumentation using eBPF*. Master's thesis, Technical University of Berlin. Supervised by Sören Becker and Prof. Dr. Odej Kao.
  - Becker, S., Goegge, R., Kao, O. (2024). *Measuring application interference with system-level instrumentation*. IEEE/ACM International Conference on Utility and Cloud Computing Companion (UCC Companion). Technical University of Berlin.
- **PRISM (related work, Utrecht):** Landau, D., Barbosa, J., Saurabh, N. (2025). *eBPF-based instrumentation for generalisable diagnosis of performance degradation*. arXiv:2505.13160. <https://arxiv.org/abs/2505.13160>. Code: <https://github.com/EC-labs/prism>.
- **eBPF vs SystemTap overhead methodology:** Volpert, S., Eichhammer, P., Held, F., Huffert, T., Wesner, H. P., Domaschka, S. (2025). *Towards eBPF overhead quantification: An exemplary comparison of eBPF and SystemTap*. ICPE '25 Companion. ACM.
- **CO-RE portability study:** Zhong, S., Liu, J., Arpaci-Dusseau, A. C., Arpaci-Dusseau, R. H. (2025). *Revealing the unstable foundations of eBPF-based kernel extensions*. EuroSys '25. ACM. (University of Wisconsin-Madison.)
- **Intel RDT measurement caveats:** Sohal, P., Tabish, R., Drepper, U., Mancuso, R. (2022). *A closer look at Intel resource director technology (RDT)*. RTNS '22. ACM.
- **CO-RE reference guide:** Nakryiko, A. *BPF CO-RE reference guide*. <https://nakryiko.com/posts/bpf-core-reference-guide/>.

## License

MIT -- see [LICENSE](LICENSE).
