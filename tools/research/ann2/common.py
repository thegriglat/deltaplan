"""Общее для AN-1: пути данных P2, загрузка сети P2 и случая (читаем код пилота, не правим)."""
import json
import os
import sys
from pathlib import Path

PILOT_SRC = Path(__file__).resolve().parents[1] / "air_nn_pilot"
sys.path.insert(0, str(PILOT_SRC))
DATA = Path(os.environ.get("AIR_NN_DATA", "/home/greg/air_nn_data")) / "pilot"
RUN = DATA / "runs" / "2026-10-03_p2b"
REPORT = DATA / "reports" / "2026-10-03_p2b"
OUT = Path(__file__).resolve().parent / "out"
OUT.mkdir(exist_ok=True)
