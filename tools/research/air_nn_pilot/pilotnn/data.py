"""Доступ к наборам (контракт П1 v1/v2) и индексу мест П6: метаданные случаев, образцы npz, точки оценки.

Пилот читает НЕСКОЛЬКО наборов (`config.yaml → datasets`: main v1 + terrain v2) — класс `Datasets`; id случаев
уникальны между наборами. Из образца читаются только ключи `d400_*` (окна `w<k>_*` набора v1 не читаются).
Две раскладки набора:
  * «pilot» (П1): <набор>/plan.json, state.sqlite (таблица cases), cases/<id>.npz;
  * «airlite» (данные разработки до слияния P1): <каталог air_lite>/out/plan.json, out/runs.jsonl, fields/<id>.npz.
Метаданные случаев читает ОДНА функция — `case_rows()`; переключение на `state.sqlite` — только здесь.
"""
from __future__ import annotations

import csv
import json
import sqlite3
from pathlib import Path

import numpy as np

KEYS_REQ = ("d400_h", "d400_m", "d400_hc", "d400_H")


class Dataset:
    def __init__(self, root):
        self.root = Path(root)
        if (self.root / "state.sqlite").exists() or (self.root / "cases").is_dir():
            self.layout = "pilot"
            self.plan_path = self.root / "plan.json"
            self.cases_dir = self.root / "cases"
        elif (self.root / "out" / "runs.jsonl").exists():
            self.layout = "airlite"
            self.plan_path = self.root / "out" / "plan.json"
            self.cases_dir = self.root / "fields"
        else:
            raise FileNotFoundError(f"набор не найден или неизвестная раскладка: {self.root}")
        self.plan = json.loads(self.plan_path.read_text())
        self.agl = tuple(float(a) for a in self.plan["agl"])
        man = self.root / "manifest.json"
        self.contract = (json.loads(man.read_text()).get("contract") if man.exists() else None) or "П1 v1"

    # ---------------------------------------------------------------- метаданные (единственное место чтения)
    def case_rows(self):
        """→ list[dict]: строки случаев, у которых есть готовый образец (статус «готов» и файл на месте).
        Поля: id, loc, hour, U10, wdir, t_max, sky, runs{уровень: status…}, d400{…}, day{…}, profile{…}."""
        rows = []
        if self.layout == "airlite":
            seen = {}
            for line in (self.root / "out" / "runs.jsonl").read_text().splitlines():
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if r.get("status") in ("ok", "max", "diverged") and "profile" in r:
                    seen[r["id"]] = r          # последняя строка случая — правда
            rows = list(seen.values())
        else:
            con = sqlite3.connect(f"file:{self.root / 'state.sqlite'}?mode=ro", uri=True, timeout=30)
            try:
                for cid, st, meta in con.execute("SELECT id, status, meta FROM cases"):
                    if st != "done" or not meta:
                        continue
                    row = json.loads(meta)            # строка runs.jsonl air-lite (контракт П1, NN-P1)
                    row["id"] = cid
                    rows.append(row)
            finally:
                con.close()
        rows = [r for r in rows if (self.cases_dir / f"{r['id']}.npz").exists()]
        rows.sort(key=lambda r: r["id"])
        return rows

    def npz_path(self, cid):
        return self.cases_dir / f"{cid}.npz"

    def load(self, cid):
        with np.load(self.npz_path(cid)) as z:
            return {k: z[k] for k in z.files if k.startswith("d400")}

    def starts(self, loc):
        """Точки оценки места (x восток, y север, м): центры окон плана — старты места (слитые ближе 3 км)
        и, у встроенных мест, точки наибольшего превышения над окрестностью (как окна 100 м air-lite)."""
        c = self.plan.get("centers", {}).get(loc)
        if not c:
            return [(0.0, 0.0)]
        return [(float(p[0]), float(p[1])) for p in c]


class Datasets:
    """Несколько наборов как один: строки случаев с полем `ds` (имя набора), загрузка и точки оценки — по id/месту."""

    def __init__(self, specs):
        """specs — список (имя, каталог)."""
        self.sets = {name: Dataset(root) for name, root in specs}
        agls = {d.agl for d in self.sets.values()}
        if len(agls) != 1:
            raise ValueError(f"высоты agl наборов различаются: {agls}")
        self.agl = agls.pop()
        self._id_ds, self._loc_ds, self._rows = {}, {}, None

    def case_rows(self):
        if self._rows is None:
            rows = []
            for name, d in self.sets.items():
                for r in d.case_rows():
                    if r["id"] in self._id_ds:
                        raise ValueError(f"id {r['id']} повторяется в наборах {self._id_ds[r['id']]} и {name}")
                    r["ds"] = name
                    self._id_ds[r["id"]] = name
                    if self._loc_ds.setdefault(r["loc"], name) != name:
                        raise ValueError(f"место {r['loc']} в двух наборах ({self._loc_ds[r['loc']]}, {name})")
                    rows.append(r)
            rows.sort(key=lambda r: r["id"])
            self._rows = rows
        return self._rows

    def ds_of(self, cid):
        if not self._id_ds:
            self.case_rows()
        return self.sets[self._id_ds[cid]]

    def load(self, cid):
        return self.ds_of(cid).load(cid)

    def starts(self, loc):
        if not self._loc_ds:
            self.case_rows()
        return self.sets[self._loc_ds[loc]].starts(loc)


# ------------------------------------------------------------------------------------------- индекс мест П6
P6_FLOATS = ("lat", "lon", "src_spacing_m", "h_mean", "h_min", "h_max", "relief_m", "slope_p50", "slope_p95",
             "tpi2k_p95", "sea_frac")


def read_p6_index(path):
    """index.csv П6 → {id: строка} (числа — float, zoom — int). Нет файла → {}."""
    p = Path(path)
    if not p.exists():
        return {}
    out = {}
    with open(p, newline="") as f:
        for r in csv.DictReader(f):
            for k in P6_FLOATS:
                r[k] = float(r[k])
            r["zoom"] = int(r["zoom"])
            out[r["id"]] = r
    return out


def terrain_features(hc, dx=400.0):
    """Признаки рельефа клеток 400 м как в индексе П6: уклон |∇hc| центральными разностями без 1 клетки у края
    (p50, p95), размах, м. Для мест вне П6 (встроенные, синтетика, процедурные) — из `d400_hc` образца."""
    hc = np.asarray(hc, np.float64)
    gy, gx = np.gradient(hc, dx)
    s = np.hypot(gx, gy)[1:-1, 1:-1]
    return dict(slope_p50=float(np.percentile(s, 50)), slope_p95=float(np.percentile(s, 95)),
                relief_m=float(hc.max() - hc.min()), h_mean=float(hc.mean()))


def solver_status(row):
    """Худший статус решений области (ok < max < diverged)."""
    order = {"ok": 0, "max": 1, "diverged": 2, "error": 3}
    st = [v.get("status", "ok") for k, v in (row.get("runs") or {}).items() if k.startswith("d400")]
    return max(st, key=lambda s: order.get(s, 3)) if st else "ok"
