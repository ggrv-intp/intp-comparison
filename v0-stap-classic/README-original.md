# IntP - Application Interference Measurement Tool

**SystemTap-based tool for measuring application interference in Linux systems**

[![Kernel](https://img.shields.io/badge/kernel-6.8.0--90-blue)](https://kernel.org/)
[![SystemTap](https://img.shields.io/badge/SystemTap-5.2-green)](https://sourceware.org/systemtap/)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04_LTS-orange)](https://ubuntu.com/)

---

## 🚀 Quick Start

> **Note:** the snippets below reference the kernel-6.8 patched script
> (`intp-6.8.stp`, V0.1) and the resctrl variant (`intp-resctrl.stp`, V1),
> which now live in their own directories under the repository root.
> Run them from there, or use the per-variant Quick Start in the
> [top-level README](../README.md#quick-start).

### Consumer CPUs (Intel Core i5/i7/i9, AMD) -- V0.1

```bash
cd v0.1-stap-k68

# Run IntP (6 out of 7 metrics functional)
sudo stap -g -B CONFIG_MODVERSIONS=y intp-6.8.stp firefox

# View metrics in another terminal
watch -n2 -d cat /proc/systemtap/stap_*/intestbench
```

### Modern stap-native, no helper (5/7 metrics) -- V1

```bash
cd v1-stap-native

# Run IntP -- 5 metrics, mbw and llcocc reported as 0
sudo stap -g -B CONFIG_MODVERSIONS=y intp-resctrl.stp firefox

# View metrics
watch -n2 -d cat /proc/systemtap/stap_*/intestbench
```

### Intel Xeon CPUs with RDT (or AMD EPYC Rome+) -- V1.1

```bash
cd v1.1-stap-helper

# Build the C helper once
make

# Start the userspace helper (owns uncore IMC + resctrl)
sudo ./intp-helper firefox &

# Run IntP (all 7 metrics functional)
sudo stap -g -B CONFIG_MODVERSIONS=y intp-v1.1.stp firefox

# View metrics
watch -n2 -d cat /proc/systemtap/stap_*/intestbench

# Stop helper when done
sudo kill %1 ; wait %1 2>/dev/null
```

---

## 📊 Metrics Measured

| Metric | Acronym | Description | Consumer CPUs | Xeon with RDT |
|--------|---------|-------------|---------------|---------------|
| Network Physical | `netp` | Network layer utilization | ✅ | ✅ |
| Network Stack | `nets` | Network stack utilization | ✅ | ✅ |
| Block I/O | `blk` | Disk I/O utilization | ✅ | ✅ |
| Memory Bandwidth | `mbw` | Memory bandwidth usage | ✅ | ✅ |
| LLC Miss Ratio | `llcmr` | Cache miss percentage | ✅ | ✅ |
| **LLC Occupancy** | `llcocc` | Cache occupancy | ❌ (0) | ✅ |
| CPU Utilization | `cpu` | CPU usage percentage | ✅ | ✅ |

**Example Output:**
```
netp    nets    blk     mbw     llcmr   llcocc  cpu
02      01      05      12      03      00      45
```

---

## 🔄 What Changed for Kernel 6.8.0

| Component | Original (≤6.6) | Kernel 6.8.0+ | Reason |
|-----------|-----------------|---------------|---------|
| **MSR Definitions** | Defined in script | Removed | Now in kernel headers |
| **LLC Occupancy** | perf events (cqm_rmid) | resctrl filesystem | API removed from kernel |
| **Module Loading** | `stap -g` | `stap -g -B CONFIG_MODVERSIONS=y` | MODVERSIONS enforced |
| **SystemTap Version** | 4.9-5.0 (package) | 5.2+ (source) | Kernel 6.8 compatibility |

**New Files:**
- `intp-6.8.stp` - Patched for 6.8.0 (LLC disabled)  
- `intp-resctrl.stp` - Full version with resctrl  
- `intp-resctrl-helper.sh` - LLC monitoring daemon

---

## 📖 Documentation

> **Note:** This README is preserved verbatim from the upstream
> 2022 layout. After the multi-variant refactor, the documentation
> moved out of `v0-stap-classic/`. The pointers below are to the new
> locations in this repository.

| Document | New location |
|----------|--------------|
| **Installation guide (Ubuntu 24.04)**          | [`v1-stap-native/install/install_ubuntu24_desktop.md`](../v1-stap-native/install/install_ubuntu24_desktop.md) |
| **Quick fix: SystemTap "Invalid module format"** | [`v0.1-stap-k68/docs/SYSTEMTAP-MODULE-ISSUE.md`](../v0.1-stap-k68/docs/SYSTEMTAP-MODULE-ISSUE.md) |
| **Kernel 6.8 changes (V0.1 working notes)**      | [`v0.1-stap-k68/docs/KERNEL-6.8-NOTES.md`](../v0.1-stap-k68/docs/KERNEL-6.8-NOTES.md) |
| **LLC monitoring via resctrl**                  | [`v1-stap-native/docs/LLC-OCCUPANCY-RESCTRL.md`](../v1-stap-native/docs/LLC-OCCUPANCY-RESCTRL.md) |
| **Cross-variant kernel-6.8 root document**      | [`docs/KERNEL-6.8-CHANGES.md`](../docs/KERNEL-6.8-CHANGES.md) |
| **Project overview**                            | [`README.md`](../README.md) at the repository root |

---

## 🛠️ Installation (Quick Version)

### 1. Build SystemTap 5.2

```bash
sudo apt install -y build-essential git libdw-dev libelf-dev gettext
cd ~/Documents && git clone https://sourceware.org/git/systemtap.git
cd systemtap && git checkout release-5.2
./configure --prefix=/usr/local --disable-docs && make -j$(nproc)
sudo make install
```

### 2. Install Debug Symbols

```bash
sudo apt install -y ubuntu-dbgsym-keyring
echo "deb http://ddebs.ubuntu.com noble main restricted universe multiverse" | sudo tee /etc/apt/sources.list.d/ddebs.list
sudo apt update && sudo apt install -y linux-image-$(uname -r)-dbgsym
```

### 3. Test

```bash
sudo stap -g -B CONFIG_MODVERSIONS=y -e 'probe begin { printf("OK\n") exit() }'
```

**Full guide:** [`v1-stap-native/install/install_ubuntu24_desktop.md`](../v1-stap-native/install/install_ubuntu24_desktop.md)

---

## 🐛 Common Issues

### "Invalid module format"
```bash
# Add -B CONFIG_MODVERSIONS=y
sudo stap -g -B CONFIG_MODVERSIONS=y intp-6.8.stp firefox
```

### "MSR redefined" or "cqm_rmid" errors
```bash
# Use patched version
sudo stap -g -B CONFIG_MODVERSIONS=y intp-6.8.stp firefox
```

### LLC Occupancy = 0
- **Consumer CPUs**: Expected (no RDT support)
- **Xeon CPUs**: Use `intp-resctrl.stp` + helper daemon

---

## 🤝 Credits

**Original IntP:** [@mclsylva](https://github.com/mclsylva), [@superflit](https://github.com/superflit)  
**Kernel 6.8.0 Adaptation:** @Saccilotto

---

*Kernel: 6.8.0-90 | SystemTap: 5.2 | Updated: Jan 2026*
