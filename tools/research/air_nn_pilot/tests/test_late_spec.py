#!/usr/bin/env python3
"""late_points / late_spec (П1 v3, уточнение 03.10): from и step кратны 10 (решатель зовёт обратный вызов раз в 10 итераций);
снимки from, from + step, …, max_outer (последний — всегда предел). Без GPU.

  .venv/bin/python tests/test_late_spec.py
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import airlite_gen as G  # noqa: E402
import dataset as DS  # noqa: E402

assert G.late_points(500, 50, 1000) == list(range(500, 1001, 50))
assert G.late_points(150, 50, 300) == [150, 200, 250, 300]
assert G.late_points(500, 60, 1000)[-1] == 1000      # предел всегда входит
for bad in ((505, 50, 1000), (500, 25, 1000), (500, 0, 1000)):
    try:
        G.late_points(*bad)
    except ValueError:
        continue
    raise AssertionError(f"late_points{bad}: ожидалась ошибка")
cfg = DS.load_cfg(Path(__file__).resolve().parents[1] / "configs/dataset.yaml")
for name, spec in cfg["datasets"].items():
    ls = DS.late_spec(cfg, spec)
    if ls:
        assert ls["from"] % 10 == 0 and ls["step"] % 10 == 0, (name, ls)
print("ok: late_points/late_spec — кратность 10 проверяется, конфиги наборов корректны")
