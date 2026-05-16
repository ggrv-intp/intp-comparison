# Dual-Boot Recovery on `intp-master`

Operational notes for the dual-boot rig that hosts both legs of the
campaign:

- **U22 leg:** `nvme0n1` -- Ubuntu 22.04 + kernel 5.15 GA, hostname
  `intp-v1-baseline`. Target for V0 / V0.1 / V0.2.
- **U24 leg:** `nvme1n1` -- Ubuntu 24.04 + kernel 6.8, hostname
  `intp-master`. Target for V1 / V1.1 / V2 / V3 / V3.1 / V3.2.

Both legs share the firmware EFI BootOrder. Wrong defaults can land
the host in the wrong leg silently, and the U22 leg can independently
pick a wrong kernel within itself. This document captures the two
recovery procedures actually used during the 2026-05 pilot.

---

## 1. EFI BootOrder lands in the wrong leg

### Symptom

After a routine `reboot`, the host comes up in U24 (`intp-master`)
when the operator expected U22 (`intp-v1-baseline`), or vice versa.
Confirm with:

```bash
hostnamectl              # hostname differs by leg
uname -r                 # kernel differs by leg
lsblk                    # mount points differ by leg
mount | grep ' / '       # root device tells which disk booted
```

If `lsblk` shows the *expected* disks present but the root mount is
on the wrong one, it is a BootOrder issue, not a reinstall.

### Inspecting the EFI BootOrder

```bash
sudo efibootmgr -v
```

The output lists every EFI entry (`Boot0001`, `Boot0002`, ...) with
its `EFI\<vendor>\<loader>.efi` path and partition. The `BootOrder:`
line shows the priority sequence.

### Mapping between EFI entries and IntP legs

| Boot entry          | Disk     | Leg / kernel                            | EFI loader path                                  |
|---------------------|----------|------------------------------------------|---------------------------------------------------|
| `Boot0003`, `Boot0006` | nvme0n1 | U22.04 + kernel 5.15 GA (`intp-v1-baseline`) | `\EFI\ubuntu-u22-nvme0\grubx64.efi`              |
| `Boot0004` (and others) | nvme1n1 | U24.04 + kernel 6.8 (`intp-master`)          | `\EFI\ubuntu-u24-nvme1\grubx64.efi`              |

(The exact entry numbers can drift if entries are added or deleted.
Always re-check with `efibootmgr -v` rather than memorising numbers.)

### Workaround: one-shot next-boot override

The least invasive recovery is `efibootmgr -n` (next-boot only):

```bash
sudo efibootmgr -n 0003 && sudo reboot   # boot U22 once
```

`-n` survives exactly one boot, so the persistent BootOrder is
untouched. The next reboot returns to the default (whatever the
firmware had ordered before).

### When to persist the change (`-o`)

Persisting the order with `-o`:

```bash
sudo efibootmgr -o 0003,0004,0006,...    # whatever order is desired
```

is more dangerous: if the operator later forgets the change and
issues an unrelated `reboot`, the host will land in whichever leg is
now first in the persistent order. Prefer `-n` for one-off
campaign-leg switches; reserve `-o` for a deliberate, communicated
re-baselining.

### Recommended operator workflow

Before any reboot during a campaign:

1. Decide explicitly which leg the next boot should land in.
2. Issue `sudo efibootmgr -n <entry>` for that leg.
3. Reboot.
4. After the host comes back, verify the leg with `hostnamectl` and
   `uname -r` before resuming the campaign.

---

## 2. Wrong kernel within the U22 leg (5.19 mainline PPA instead of
5.15 GA)

### Symptom

The U22 leg boots successfully but `uname -r` reports
`5.19.17-051917-generic` (mainline PPA) instead of the expected
`5.15.0-XXX-generic` (Canonical GA). For example:

```
$ uname -r
5.19.17-051917-generic        # WRONG, the legacy stack expects 5.15
```

The 5.19 mainline-PPA kernel does **not** carry the Canonical
`intel_cqm` backport that V0 / V0.2 depend on, so V0-family runs will
fail to compile (`cqm_rmid` absent) exactly as documented in
`bench/findings/v0-baseline-failure-diagnosis.md`. The 5.19 kernel is
also outside the V0.2 deployment window (`5.10 <= k < 6.0`).

### Cause

GRUB on U22 is configured for "boot the most-recently-installed
kernel". If a 5.19 (or any non-5.15) kernel was installed at some
point and never pruned, GRUB will pick it as default on the next
boot.

### Diagnosing which kernels are installed

```bash
ls /boot/vmlinuz-*
dpkg -l 'linux-image-*' | grep ^ii
```

### Pinning 5.15 GA so it always wins

Two steps. First, `apt-mark hold` the *current* 5.15 kernel so apt
will not remove it during cleanup:

```bash
KVER=5.15.0-177           # whatever 5.15 is currently installed
sudo apt-mark hold \
    linux-image-${KVER}-generic \
    linux-headers-${KVER}-generic \
    linux-modules-${KVER}-generic \
    linux-modules-extra-${KVER}-generic
```

Second, `apt-mark hold` (or outright remove) the offending mainline
kernel so apt cannot reinstate it as a dependency:

```bash
sudo apt-mark hold linux-image-5.19.17-051917-generic
# or, if you are sure nothing depends on it:
sudo apt-get purge linux-image-5.19.17-051917-generic
sudo update-grub
```

### Making GRUB default to 5.15 explicitly

Even with the mainline removed, defending against the next mainline
showing up is worth doing. Set GRUB's default to a saved entry that
points at 5.15:

```
# /etc/default/grub
GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux 5.15.0-177-generic"
GRUB_SAVEDEFAULT=true
```

then:

```bash
sudo update-grub
```

Verify the next boot lands on 5.15 by rebooting and running
`uname -r`.

### Tying this into `bench/setup/setup-host-legacy.sh`

The legacy-host setup script (`bench/setup/setup-host-legacy.sh`) is
the canonical source of truth for what U22 should look like. Two
defensive additions are tracked in the post-batch follow-up:

1. At the **end** of the script, after the 5.15 kernel and headers
   are installed, run the `apt-mark hold` block above automatically
   against whatever `KVER` was just installed.
2. At the **start** of the script, run a guard that fails early if
   `uname -r` does not match `5.15.*`. The legacy stack is only
   correct for 5.15 GA, and running half of the script under a
   different kernel produces a host that looks fine but breaks at
   the first V0 compile.

Until that lands, this document is the operator's checklist.

---

## 3. References

- Failure logs and root cause: `bench/findings/v0-baseline-failure-diagnosis.md`
- V0 / V0.2 kernel-version constraints: `docs/KERNEL-6.8-CHANGES.md`,
  `variants/v0.2-legacy-bridge/DESIGN.md`
- Legacy-host setup: `bench/setup/setup-host-legacy.sh`
