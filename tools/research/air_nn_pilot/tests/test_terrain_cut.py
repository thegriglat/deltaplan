#!/usr/bin/env python3
"""Тест вырезки рельефов П6 v3 (NN-P4, NN-16): побитный повтор и прерывание kill -9.

  .venv/bin/python tests/test_terrain_cut.py        (или pytest)

Во временном корне $AIR_NN_DATA/pilot/tmp/nn_p4_test_<pid>/ (удаляется в конце):
  1. 3 места из готового индекса набора (paths.out конфига, tiles/v3) (без индекса — фиксированные точки; разной крутизны) — явный список в
     копии configs/terrain.yaml; источник тайлов — file:// из сырья основного прогона (без сети; если сырья нет — сеть).
  2. Эталон A: fetch → cut без прерываний.
  3. Прогон B: fetch с паузой на тайл, kill -9 через ~1,5 с, повтор той же командой; cut, kill -9 посреди нарезки,
     повтор той же командой.
  4. Сравнение: sha256 всех тайлов raw, всех cut/*.npz и index.csv у A и B совпадают; нет временных файлов;
     вырезки совпадают побитно с файлами основного прогона tiles/v3 (тот же путь → те же байты);
     hc400 = block_mean(h); геометрия пути игры (plan_layer) на известной точке.
"""
from __future__ import annotations

import csv
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import yaml

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
import terrain_cut as TC  # noqa: E402

PY = sys.executable
DATA = Path(os.environ.get("AIR_NN_DATA", "/home/greg/air_nn_data"))
MAIN_OUT = DATA / yaml.safe_load((HERE / "configs/terrain.yaml").read_text())["paths"]["out"]
MAIN_RAW = DATA / "pilot/raw/terrarium"


def sha(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def tree_sha(d: Path, pattern: str) -> dict:
    return {str(p.relative_to(d)): sha(p) for p in sorted(d.rglob(pattern)) if p.is_file()}


def run(cfg, root, stage, extra=(), wait=True):
    cmd = [PY, str(HERE / "terrain_cut.py"), stage, "--config", str(cfg), "--root", str(root), *extra]
    env = dict(os.environ)
    if MAIN_RAW.exists():
        env["TERRAIN_URL_TEMPLATE"] = "file://" + str(MAIN_RAW) + "/{z}/{x}/{y}.png"
    if not wait:
        return subprocess.Popen(cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                start_new_session=True)
    r = subprocess.run(cmd, env=env, capture_output=True, text=True)
    assert r.returncode == 0, (stage, r.stdout[-2000:], r.stderr[-3000:])
    return r


def kill9(p, after_s, until=None):
    t0 = time.time()
    while time.time() - t0 < after_s and p.poll() is None:
        if until and until():
            break
        time.sleep(0.05)
    if p.poll() is None:
        os.killpg(p.pid, signal.SIGKILL)   # весь сеанс: процесс и рабочие пула
        p.wait()
        return True
    return False


def pick_places():
    if (MAIN_OUT / "index.csv").exists():
        rows = list(csv.DictReader(open(MAIN_OUT / "index.csv")))
        rows.sort(key=lambda r: float(r["slope_p50"]))
        sel = [rows[0], rows[len(rows) // 2], rows[-1]]
        return [dict(lat=float(r["lat"]), lon=float(r["lon"]), system=r["system"], part=r["part"]) for r in sel], sel
    return [dict(lat=46.55, lon=8.0), dict(lat=42.6, lon=0.5), dict(lat=50.79, lon=86.13)], None


def test_plan_layer_geometry():
    # z12 на 50,79° (Онгудай): шаг 2π·R·cos φ / 2^20 и сетка ≥ 40 км кратно чанку 128 (как _plan_layer игры)
    lc = dict(zoom=12, min_spacing_m=18, size_km=40, chunk_cells=128)
    assert TC.layer_zoom(lc, 50.79) == 12 and TC.layer_zoom(lc, 65.0) == 11
    p = TC.plan_layer(50.79, 86.13, 12, 40000.0, 128)
    assert abs(p["spacing"] - 2 * np.pi * 6378137.0 * np.cos(np.radians(50.79)) / 2 ** 20) < 1e-9
    assert (p["n"] - 1) % 128 == 0 and (p["n"] - 1) * p["spacing"] >= 40000.0
    half = (p["n"] - 1) / 2 * p["spacing"]
    assert -half - p["spacing"] <= p["origin"][0] <= -half + 1e-6


def test_system_of_nz():
    # v2: Южные Альпы НЗ раньше общего бокса new_zealand; север острова и чужие системы — как раньше
    cfg = yaml.safe_load((HERE / "configs/terrain.yaml").read_text())
    assert TC.system_of(cfg, -43.8, 170.1) == "southern_alps_nz"
    assert TC.system_of(cfg, -38.0, 176.0) == "new_zealand"
    assert TC.system_of(cfg, 43.0, 44.0) == "caucasus"
    assert "southern_alps_nz" in cfg["select"]["holdout"]["systems"]


def test_repeat_and_kill():
    places, rows = pick_places()
    base = DATA / f"pilot/tmp/nn_p4_test_{os.getpid()}"
    shutil.rmtree(base, ignore_errors=True)
    try:
        cfg = yaml.safe_load((HERE / "configs/terrain.yaml").read_text())
        cfg["explicit"] = places
        cfg["ref_cuts"] = []
        base.mkdir(parents=True)
        cp = base / "terrain.yaml"
        cp.write_text(yaml.safe_dump(cfg, allow_unicode=True, sort_keys=False))
        A, B = base / "A", base / "B"
        for st in ("select", "fetch", "cut"):
            run(cp, A, st)
        run(cp, B, "select")
        p = run(cp, B, "fetch", ["--throttle", "0.05"], wait=False)
        nraw = lambda: sum(1 for _ in (B / "raw/terrarium").rglob("*.png")) if (B / "raw").exists() else 0
        killed_fetch = kill9(p, 8.0, until=lambda: nraw() >= 20)
        n_after_kill = nraw()
        run(cp, B, "fetch")
        p = run(cp, B, "cut", ["--workers", "1"], wait=False)
        ncut = lambda: sum(1 for _ in (B / "work/cut_all").glob("*.json")) if (B / "work/cut_all").exists() else 0
        killed_cut = kill9(p, 60.0, until=lambda: ncut() >= 1)
        n_cut_kill = ncut()
        run(cp, B, "cut")
        ra, rb = tree_sha(A / "raw/terrarium", "*.png"), tree_sha(B / "raw/terrarium", "*.png")
        assert ra == rb and ra, "сырьё A ≠ B"
        ca, cb = tree_sha(A / "tiles", "*.npz"), tree_sha(B / "tiles", "*.npz")
        assert ca == cb and len(ca) == len(places), "вырезки A ≠ B"
        assert sha(A / "tiles/index.csv") == sha(B / "tiles/index.csv"), "index.csv A ≠ B"
        assert not list(B.rglob(".*.tmp.*")), "остались временные файлы"
        for r in csv.DictReader(open(A / "tiles/index.csv")):
            z = np.load(A / "tiles/cut" / f"{r['id']}.npz")
            assert np.abs(z["hc400"] - TC.block_mean_400(z["h"])).max() == 0.0
        n_main = 0
        if rows:   # побитно как основной прогон
            ia = list(csv.DictReader(open(A / "tiles/index.csv")))
            for r_main in rows:
                ra_ = next(x for x in ia if abs(float(x["lat"]) - float(r_main["lat"])) < 1e-9
                           and abs(float(x["lon"]) - float(r_main["lon"])) < 1e-9)
                assert ra_["sha256"] == r_main["sha256"], ("вырезка ≠ основной прогон", r_main["id"])
                for k in TC.INDEX_COLUMNS[6:-1]:
                    assert ra_[k] == r_main[k], (k, r_main["id"])
                n_main += 1
        print(f"повтор и прерывание: ок — мест {len(places)}, тайлов {len(ra)}; kill -9 fetch: {killed_fetch} "
              f"(было {n_after_kill} тайлов), kill -9 cut: {killed_cut} (готово {n_cut_kill}); "
              f"совпало с основным прогоном: {n_main}")
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    test_plan_layer_geometry()
    test_system_of_nz()
    test_repeat_and_kill()
