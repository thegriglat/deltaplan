"""Общая подготовка python-тестов: путь к модулю и zstandard (при отсутствии — перезапуск через venv эталона)."""
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools/osm_tiles"))
GOLDEN = ROOT / "tests/contracts/osm_tiles"
VENV_PY = os.environ.get("OSM_VENV_PYTHON", "/home/greg/deltaplan_data/osm_pack/venv/bin/python")


def ensure_zstd():
    """В Python < 3.14 нет zstd в stdlib: перезапустить тот же запуск тестов интерпретатором venv, где есть zstandard."""
    try:
        from compression import zstd  # noqa: F401
        return
    except ImportError:
        pass
    try:
        import zstandard  # noqa: F401
        return
    except ImportError:
        pass
    if os.environ.get("_OSM_TESTS_REEXEC") or not os.path.exists(VENV_PY):
        raise ImportError("нет zstd: нужен Python 3.14+ или пакет zstandard (venv эталона: %s)" % VENV_PY)
    os.environ["_OSM_TESTS_REEXEC"] = "1"
    os.execv(VENV_PY, [VENV_PY] + sys.orig_argv[1:])


ensure_zstd()
