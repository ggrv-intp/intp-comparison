# Bench Findings

This directory is the canonical location for empirical findings from the IntP
benchmark campaign.

## Index

- [V0 Baseline -- Compilation failure diagnosis](v0-baseline-failure-diagnosis.md)
  - Documents why the original V0 probe fails deterministically on modern
    kernel/header combinations.
- [V1 Modernization -- Reliability findings](v1-modernization-reliability-findings.md)
  - Documents what was improved in V1 (the restored stap-native build) and
    which operational limitations remain under modern kernels and hardware.
    The userspace-helper recovery path is implemented in V1.1.
- [LAD pantanal01 -- RDT monitoring unavailable on Skylake-SP gen1](lad-skylake-sp-rdt-monitoring-disabled.md)
  - Documents the platform-level limitation that disables CMT/MBM on the
    LAD Skylake-SP host (microcode + erratum), affecting `mbw` and
    `llcocc` on every variant that depends on RDT.

## Scope

Each finding should include:

1. Context and environment.
2. Reproducible evidence (commands/logs).
3. Root-cause analysis.
4. Impact on benchmark validity.
5. Mitigation status and implications for variant comparison.

## Why this matters

The dissertation compares historical portability (V0) versus modern
reliability (V1.1 stap+helper, V2 procfs, V3.1 bpftrace, V3 eBPF/CO-RE).
Keeping findings centralized and versioned in this directory makes that
argument auditable and reproducible.
