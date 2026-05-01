# Bench Findings

This directory is the canonical location for empirical findings from the IntP
benchmark campaign.

## Index

- [V1 Baseline -- Compilation failure diagnosis](v1-baseline-failure-diagnosis.md)
  - Documents why the original V1 probe fails deterministically on modern
    kernel/header combinations.
- [V3 Modernization -- Reliability findings](v3-modernization-reliability-findings.md)
  - Documents what was improved in V3 and which operational limitations remain
    under modern kernels and hardware.

## Scope

Each finding should include:

1. Context and environment.
2. Reproducible evidence (commands/logs).
3. Root-cause analysis.
4. Impact on benchmark validity.
5. Mitigation status and implications for variant comparison.

## Why this matters

The dissertation compares historical portability (V1) versus modern reliability
(V4/V5/V6). Keeping findings centralized and versioned in this directory makes
that argument auditable and reproducible.
