"""Read-only observations of the Mac: memory, swap, thermal state, other benchmark runs."""
from __future__ import annotations

import re
import subprocess

# Benchmarks of other development windows that use the on-device model or the GPU.
OTHER_RUNS = ("hs-semantic-eval", "w63_probe", "run_semantic_eval", "run_window6")


def _out(*command: str) -> str:
    try:
        return subprocess.run(command, capture_output=True, text=True, timeout=20).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def other_runs() -> list[str]:
    lines = []
    for line in _out("ps", "-axo", "pid=,etime=,command=").splitlines():
        if any(name in line for name in OTHER_RUNS) and "model_bench" not in line:
            lines.append(line.strip()[:160])
    return lines


def snapshot() -> dict:
    pressure = re.search(r"free percentage:\s*(\d+)%", _out("memory_pressure"))
    swap = re.search(r"used = ([\d.]+)M", _out("sysctl", "-n", "vm.swapusage"))
    stat = _out("vm_stat")

    def pages(label: str) -> int | None:
        found = re.search(label + r":\s+(\d+)", stat)
        return int(found.group(1)) if found else None

    thermal = _out("pmset", "-g", "therm")
    limit = re.search(r"CPU_Speed_Limit\s*=\s*(\d+)", thermal)
    return {
        "memory_free_percent": int(pressure.group(1)) if pressure else None,
        "swap_used_mb": float(swap.group(1)) if swap else None,
        "swapins": pages("Swapins"), "swapouts": pages("Swapouts"),
        "cpu_speed_limit": int(limit.group(1)) if limit else None,
        "thermal_warning": "No thermal warning level has been recorded" not in thermal,
        "other_runs": other_runs(),
    }
