# LAD pantanal01 -- RDT monitoring unavailable on Skylake-SP gen1

**Date observed:** 2026-05-04
**Host:** pantanal01.lad.pucrs.br
**CPU:** Intel Xeon Gold 5118 (Skylake-SP gen1), stepping 4
**Microcode:** 0x2007006
**Kernel:** 5.15.0-163-generic (Ubuntu 22.04.5 LTS)

---

## Summary

The CPU + microcode + kernel combination on the LAD pantanal01 host
**does not expose** Cache Monitoring Technology (CMT) or Memory
Bandwidth Monitoring (MBM) through the `resctrl` interface, even
though the CPUID flags claim support. As a result, `llcocc` cannot
be collected on this hardware by any IntP variant (V0, V1, V2, V3.1,
V3).

Implication: maximum IntP coverage on LAD pantanal01 is 6/7 metrics,
regardless of which instrumentation variant is selected.

---

## Empirical evidence

### What CPUID advertises

Flags present in `/proc/cpuinfo`:

```
cqm   cqm_llc   cqm_occup_llc   cqm_mbm_total   cqm_mbm_local
cat_l3   mba   rdt_a
```

These suggest full Intel RDT support: monitoring (CMT, MBM) and
allocation (CAT, MBA).

### What the kernel resctrl driver actually delivers

After mounting resctrl:

```bash
$ sudo mount -t resctrl resctrl /sys/fs/resctrl
mount: /sys/fs/resctrl: resctrl already mounted on /sys/fs/resctrl.

$ ls /sys/fs/resctrl/info/L3_MON/
ls: cannot access '/sys/fs/resctrl/info/L3_MON/': No such file or directory

$ sudo mkdir /sys/fs/resctrl/mon_groups/test
$ sudo cat /sys/fs/resctrl/mon_groups/test/mon_data/mon_L3_*/llc_occupancy
cat: '...llc_occupancy': No such file or directory
```

Kernel messages during resctrl init:

```bash
$ sudo dmesg | grep -i resctrl
[    4.402824] resctrl: MB allocation detected
```

**Only MBA (Memory Bandwidth Allocation) was detected.** L3 cache
monitoring (CMT), memory bandwidth monitoring (MBM), and L3
allocation (CAT) were **not** initialised by the driver, even though
CPUID flags advertised them.

### Diagnosis

The kernel resctrl driver saw the CPUID flags but chose **not to
enable** the monitoring features. Plausible (non-mutually-exclusive)
causes:

1. **Documented Intel errata for Skylake-SP gen1.** First-generation
   Xeon Scalable shipped with multiple RDT/CMT errata (reference:
   *Intel Xeon Processor Scalable Family Specification Update*).
   Stepping 4 of the Gold 5118 falls in the affected range.
2. **Microcode 0x2007006** is in the post-Spectre/MDS-mitigation
   series, which degraded RDT functionality on several Skylake-SP
   SKUs. Subsequent microcode revisions silently disable CMT/MBM in
   multiple cases to close side channels.
3. **Kernel quirk list.** The Linux resctrl driver carries a list of
   CPUs with broken RDT and suppresses monitoring init when it
   detects a known-bad combination — conservative and correct
   behaviour.

Whatever the exact cause, the observable result is deterministic and
does not depend on root, kernel parameters, or instrumentation
software: **`llcocc` cannot be read via resctrl on this host.**

---

## Implication for the IntP methodology

`llcocc` (LLC occupancy) is one of the seven metrics defined in the
IntP paper (Xavier et al., SBAC-PAD 2022, Sec. III-E). The original
paper collects it by reading `task_struct->cqm_rmid` directly from
the kernel (a field that was removed in kernel 6.8+).

Alternative paths for collecting `llcocc` on modern hardware:

- **V0 (kernel <=6.6):** reads `cqm_rmid` directly. Requires the
  kernel to have monitoring enabled — when the resctrl driver does
  not activate CMT, no RMID is allocated and the field returns
  garbage or zero.
- **V1 / V2 / V3.1 / V3:** read via the `resctrl` interface under
  `/sys/fs/resctrl/`. Requires `info/L3_MON/` to exist and
  mon_groups to be creatable with `mon_data/mon_L3_*/llc_occupancy`
  populated.

On pantanal01, **none** of these paths work. This is a
hardware/microcode/kernel limitation, not an instrumentation-software
limitation.

---

## Resulting methodological decision

Migrating the experimental infrastructure from LAD/PUCRS to Hetzner
(a dedicated server with Xeon Gold 5412U / Sapphire Rapids gen4) was
**not optional** — it was forced by the requirement that all seven
IntP metrics be collected. Sapphire Rapids is the first Intel
generation where:

- RDT monitoring (CMT, MBM) is detected and exposed via resctrl
  without caveats.
- CAT and MBA work in conjunction with monitoring.
- No errata force the kernel to degrade features.

Verification on Hetzner:

```bash
# Same procedure, host intp-master (Xeon Gold 5412U):
$ sudo mount -t resctrl resctrl /sys/fs/resctrl
$ ls /sys/fs/resctrl/info/L3_MON/
mon_features  num_rmids  ...
$ sudo dmesg | grep -i resctrl
[ ... ] resctrl: L3 allocation detected
[ ... ] resctrl: MB allocation detected
[ ... ] resctrl: L3 monitoring detected
[ ... ] resctrl: Memory bandwidth monitoring detected
```

Coverage: 7/7 metrics on every variant.

---

## What can still be run on pantanal01

Despite the `llcocc` limitation, LAD pantanal01 remains useful for:

1. **Partial V0 reproduction** with 6/7 coverage (excluding
   `llcocc`). Demonstrates that the legacy methodology still
   executes on hardware from the original paper era.
2. **Portability sanity check for V2** (procfs+perf+resctrl, the
   only variant that runs without a kernel framework dependency).
   Cross-host comparison (LAD vs. Hetzner) of the six common
   metrics validates result transferability.

---

## Verification commands (reproducible)

Anyone can audit this finding by running:

```bash
# 1) Hardware advertising
grep -oE 'cqm[a-z_]*|cat_l3|mba|rdt_a' /proc/cpuinfo | sort -u

# 2) Kernel CONFIG
grep -E 'CONFIG_X86_CPU_RESCTRL|CONFIG_PROC_CPU_RESCTRL' \
     /boot/config-$(uname -r)

# 3) resctrl driver init (the kernel's actual decision)
sudo dmesg | grep -i resctrl

# 4) Empirical attempt
sudo mount -t resctrl resctrl /sys/fs/resctrl 2>&1
ls /sys/fs/resctrl/info/
ls /sys/fs/resctrl/info/L3_MON/ 2>&1
```

If `dmesg` reports only "MB allocation detected" and `info/L3_MON/`
does not exist, the limitation is confirmed.
