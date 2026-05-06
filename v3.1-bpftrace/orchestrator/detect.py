"""Runs shared/intp-detect.sh and parses the INTP_* environment variables.

Returns a dict of detected capability values. Keys match the INTP_*
variable names emitted by shared/intp-detect.sh.
"""

from __future__ import annotations

import os
import shlex
import subprocess
from pathlib import Path


_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_DETECT_SH = _REPO_ROOT / "shared" / "intp-detect.sh"


def detect(detect_sh: Path | str | None = None) -> dict[str, str]:
    """Execute intp-detect.sh and return parsed INTP_* key/value pairs."""
    script = Path(detect_sh) if detect_sh else _DETECT_SH
    if not script.exists():
        return {}

    result = subprocess.run(
        ["bash", str(script)],
        capture_output=True,
        text=True,
        check=False,
    )
    caps: dict[str, str] = {}
    for raw in result.stdout.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        if not line.startswith("INTP_"):
            continue
        key, value = line.split("=", 1)
        try:
            tokens = shlex.split(value)
        except ValueError:
            tokens = [value]
        caps[key] = tokens[0] if tokens else value
    return caps


def nic_speed_bps(caps: dict[str, str]) -> int:
    """Return the detected NIC speed in bytes/sec (defaults to 1 Gbps = 125 MB/s).

    Uses bytes/sec to match V2/V3 convention: sysfs reports Mbps (megabits),
    we convert via ``Mbps * 1_000_000 / 8``.
    """
    mbps = int(caps.get("INTP_NIC_SPEED_MBPS", "1000") or "1000")
    return mbps * 1_000_000 // 8


def llc_size_bytes(caps: dict[str, str]) -> int:
    kb = int(caps.get("INTP_LLC_SIZE_KB", "0") or "0")
    return kb * 1024


def mem_bw_bps(caps: dict[str, str]) -> int:
    """Return max memory bandwidth in bytes/sec.

    INTP_MEM_BW_MBPS from intp-detect.sh is in MB/s (megabytes), so
    ``* 1_000_000`` yields bytes/sec directly.
    """
    mbps = int(caps.get("INTP_MEM_BW_MBPS", "0") or "0")
    return mbps * 1_000_000


def cpu_count(caps: dict[str, str]) -> int:
    try:
        return int(caps.get("INTP_CPU_COUNT", "") or os.cpu_count() or 1)
    except ValueError:
        return os.cpu_count() or 1


def resctrl_available(caps: dict[str, str]) -> bool:
    return caps.get("INTP_RESCTRL_MOUNTED", "0") == "1"


if __name__ == "__main__":
    for k, v in detect().items():
        print(f"{k}={v}")
