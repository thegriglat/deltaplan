"""Общее для ground: пути, импорты SWD (только чтение), git-хеш, запись JSON через временный файл."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
SG = HERE.parent                                   # tools/research/sw_ground
RES = SG.parent                                    # tools/research
S3 = RES / "sw_charges_3d"
for p in (S3 / "compare", S3 / "refs", S3):
    if str(p) not in sys.path:
        sys.path.insert(0, str(p))

REFS = S3 / "out" / "refs"
OUT_POINTS = SG / "out" / "points" / "ground_points.json"
OUT_TASK = SG / "out" / "swg-1"
CASES = ("ASK_TU03B", "PERD_NE", "PERD_SW")
MAIN_TYPES = ("lee", "valley", "crest", "windward")
TYPES = ("upstream", "windward", "crest", "lee", "valley")
HEIGHTS = (10.0, 50.0, 300.0)
TOL = 0.15


def git_short() -> str:
    try:
        return subprocess.check_output(["git", "rev-parse", "--short", "HEAD"], cwd=HERE, text=True).strip()
    except Exception:
        return "unknown"


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S")


def dump_json(path, doc):
    """Запись во временный файл и переименование (контракт sw-ground)."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with open(tmp, "w") as f:
        json.dump(doc, f, ensure_ascii=False, allow_nan=False)
    os.replace(tmp, path)
