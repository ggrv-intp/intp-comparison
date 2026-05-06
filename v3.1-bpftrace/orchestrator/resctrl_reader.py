"""Resctrl reader for V3.1.

Creates a resctrl monitoring group, assigns PIDs (or runs system-wide
by leaving tasks empty), and polls llc_occupancy / mbm_total_bytes.
Failures degrade gracefully -- callers inspect ``available`` and treat
absent hardware metrics as zero.
"""

from __future__ import annotations

import contextlib
import os
import threading
import time
from pathlib import Path


RESCTRL_ROOT = Path("/sys/fs/resctrl")


class ResctrlReader:
    def __init__(self, mon_group_name: str = "intp-v3.1", pids: list[int] | None = None):
        self.mon_group = mon_group_name
        self.pids = list(pids or [])
        self.base_path = RESCTRL_ROOT / "mon_groups" / mon_group_name
        self.available = self._check_availability()
        self._created = False
        self._last_mbm_total: int | None = None
        self._last_mbm_ts: float | None = None
        self._state_lock = threading.Lock()
        self._latest = {"mbw_bps": 0, "llcocc_bytes": 0}

    def _check_availability(self) -> bool:
        return RESCTRL_ROOT.is_dir() and (RESCTRL_ROOT / "mon_groups").is_dir()

    def setup(self) -> bool:
        if not self.available:
            return False
        try:
            self.base_path.mkdir(exist_ok=True)
            self._created = True
        except PermissionError:
            self.available = False
            return False
        except OSError:
            self.available = False
            return False

        tasks_file = self.base_path / "tasks"
        for pid in self.pids:
            try:
                with tasks_file.open("w") as fh:
                    fh.write(f"{pid}\n")
            except OSError:
                continue
        return True

    def _sum_across_domains(self, filename: str) -> int:
        total = 0
        mon_data = self.base_path / "mon_data"
        if not mon_data.is_dir():
            return 0
        for domain in mon_data.glob("mon_L3_*"):
            target = domain / filename
            try:
                raw = target.read_text().strip()
            except OSError:
                continue
            try:
                total += int(raw)
            except ValueError:
                continue
        return total

    def read_llcocc(self) -> int:
        """Current LLC occupancy across all domains, in bytes."""
        if not self.available:
            return 0
        return self._sum_across_domains("llc_occupancy")

    def read_mbm_total(self) -> int:
        if not self.available:
            return 0
        return self._sum_across_domains("mbm_total_bytes")

    def sample(self) -> dict[str, int]:
        """One-shot sample: derives mbw_bps from delta of mbm_total_bytes."""
        now = time.monotonic()
        total = self.read_mbm_total()
        occ = self.read_llcocc()
        mbw_bps = 0
        if self._last_mbm_total is not None and self._last_mbm_ts is not None:
            dt = now - self._last_mbm_ts
            if dt > 0:
                delta = total - self._last_mbm_total
                if delta < 0:
                    delta = 0
                mbw_bps = int(delta / dt)
        self._last_mbm_total = total
        self._last_mbm_ts = now
        with self._state_lock:
            self._latest = {"mbw_bps": mbw_bps, "llcocc_bytes": occ}
        return dict(self._latest)

    def latest(self) -> dict[str, int]:
        with self._state_lock:
            return dict(self._latest)

    def cleanup(self) -> None:
        if self._created and self.base_path.is_dir():
            with contextlib.suppress(OSError):
                os.rmdir(self.base_path)
            self._created = False
