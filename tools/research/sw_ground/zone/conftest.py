"""GPU делят с долгими счётами: если свободной памяти < 3 ГиБ, тесты идут на CPU (CuPy скрывается до импорта)."""
import os
import subprocess


def _gpu_free_mib():
    try:
        out = subprocess.check_output(["nvidia-smi", "--query-gpu=memory.free", "--format=csv,noheader,nounits"],
                                      text=True, timeout=20)
        return min(int(v) for v in out.split())
    except Exception:
        return 0


if "CUDA_VISIBLE_DEVICES" not in os.environ and _gpu_free_mib() < 3072:
    os.environ["CUDA_VISIBLE_DEVICES"] = ""
