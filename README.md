# IntP -- Interference Profiler: Multi-Variant Comparison

This repository contains six implementation variants of IntP, an interference
profiler that collects 7 metrics from the Linux kernel. The variants are
organized for systematic comparison as part of a Master's dissertation on
kernel instrumentation for interference profiling (PPGCC/PUCRS, advisor
Prof. Cesar De Rose). The research compares the original SystemTap-based IntP
against modern instrumentation approaches (procfs polling, bpftrace, eBPF/CO-RE)
to evaluate portability, safety, and measurement fidelity tradeoffs.

## About

**Author:** André Sacilotto Santos (PPGCC/PUCRS)
**Advisor:** Prof. Cesar De Rose
**Program:** Graduate Program in Computer Science -- PPGCC, PUCRS
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

1. Reproduce the original IntP baseline (V1) and document breakage on kernel 6.8+.
2. Develop minimal patches to restore functionality on current kernels (V2, V3).
3. Implement kernel-module-free alternatives using procfs/perf_event (V4), bpftrace (V5), and eBPF/CO-RE (V6).
4. Compare all six variants across portability, safety, deployment complexity, and measurement fidelity dimensions.

### Status

| Variant | Status |
| --------- | -------- |
| V1 -- Original (SystemTap, <=6.6) | Complete (baseline) |
| V2 -- Updated (SystemTap, 6.8+, LLC disabled) | Complete |
| V3 -- Resctrl (SystemTap, 6.8+, full metrics) | Complete |
| V4 -- Hybrid procfs | Validated locally; awaiting target hardware for Phase 3 experiments |
| V5 -- bpftrace | Validated locally; awaiting target hardware for Phase 3 experiments |
| V6 -- eBPF/CO-RE | Validated locally; awaiting target hardware for Phase 3 experiments |

### Citation

If you use this software in your research, please cite it using the metadata in
[CITATION.cff](CITATION.cff). A full thesis citation will be added upon defense
(expected March 2027).

## Variant Comparison

| Feature                  | V1 original | V2 updated | V3 resctrl | V4 hybrid | V5 bpftrace | V6 ebpf-core |
|--------------------------|:-----------:|:----------:|:----------:|:---------:|:-----------:|:------------:|
| Kernel module required   |     Yes     |    Yes     |    Yes     |    No     |     No      |      No      |
| Debuginfo required       |     Yes     |    Yes     |    Yes     |    No     |   No (BTF)  |   No (BTF)   |
| Kernel crash risk        |    High     |   High     |   High     |   None    |    None     |     None     |
| Min kernel version       |   <=6.6     |   6.8+     |   6.8+     |   4.10+   |    5.8+     |     5.8+     |
| netp                     |      x      |     x      |     x      |     x     |      x      |       x      |
| nets (service-time)      |      x      |     x      |     x      |     ~     |      x      |       x      |
| blk                      |      x      |     x      |     x      |     x     |      x      |       x      |
| mbw                      |      x      |     x      |     x      |     x     |      x      |       x      |
| llcmr                    |      x      |     x      |     x      |     x     |      x      |       x      |
| llcocc                   |      x      |            |     x      |     x     |      x      |       x      |
| cpu                      |      x      |     x      |     x      |     x     |      x      |       x      |
| Framework                | SystemTap   | SystemTap  | SystemTap  |   None    |  bpftrace   |    libbpf    |
| AMD EPYC compatible      |   Partial   |  Partial   |  Partial   |    Yes    |     Yes     |      Yes     |
| ARM server compatible    |     No      |    No      |    No      |  Partial  |   Partial   |    Partial   |

x = supported, ~ = polling approximation, empty = not supported

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
|-- v1-original/               Unmodified 2022 IntP (SystemTap)
|-- v2-updated/                Kernel 6.8 patch (LLC disabled)
|-- v3-updated-resctrl/        Kernel 6.8+ with resctrl LLC
|-- v4-hybrid-procfs/          procfs/perf_event/resctrl [scaffold]
|-- v5-bpftrace/               bpftrace scripts + resctrl [scaffold]
|-- v6-ebpf-core/              Full eBPF/CO-RE with libbpf [scaffold]
```

## Quick Start

### V1 -- Original IntP (kernel <= 6.6)

```bash
cd v1-original
sudo stap -g intp.stp <PID> <interval_ms>
```

Requires: SystemTap, kernel debuginfo, kernel <= 6.6.

### V2 -- Updated for Kernel 6.8 (LLC disabled)

```bash
cd v2-updated
sudo stap -g intp-6.8.stp <PID> <interval_ms>
```

Requires: SystemTap, kernel debuginfo, kernel 6.8+. Note: llcocc returns 0.

### V3 -- Resctrl Solution (full 7/7 metrics)

```bash
cd v3-updated-resctrl
# Start the resctrl helper daemon first:
sudo ../shared/intp-resctrl-helper.sh start <PID>
sudo stap -g intp-resctrl.stp <PID> <interval_ms>
```

Requires: SystemTap, kernel debuginfo, kernel 6.8+, Intel RDT or AMD PQoS.

### V4 -- Hybrid procfs (scaffold)

```bash
cd v4-hybrid-procfs
make
sudo ./intp-hybrid -p <PID> -i <interval_ms>
```

No framework dependencies. Requires: resctrl for mbw/llcocc.

### V5 -- bpftrace (scaffold)

```bash
cd v5-bpftrace
sudo ./run-intp-bpftrace.sh <PID> <interval_ms>
```

Requires: bpftrace, kernel BTF, resctrl for mbw/llcocc.

### V6 -- eBPF/CO-RE (scaffold)

```bash
cd v6-ebpf-core
make
sudo ./intp-ebpf -p <PID> -i <interval_ms>
```

Requires: libbpf, clang, kernel BTF, resctrl for mbw/llcocc.

## Documentation

- [Metrics Deep Dive](docs/METRICS-DEEP-DIVE.md) -- Kernel probe points, formulas, constants
- [Kernel 6.8 Changes](docs/KERNEL-6.8-CHANGES.md) -- What broke and the fix paths
- [Portability Roadmap](docs/PORTABILITY-ROADMAP.md) -- Cross-kernel, cross-arch analysis
- [Hardware Compatibility](docs/HARDWARE-COMPATIBILITY.md) -- RDT, PQoS, MPAM tables
- [Variant Comparison](docs/VARIANT-COMPARISON.md) -- Detailed rationale for each variant

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
