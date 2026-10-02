"""Доступ к набору (контракт П1 v1): метаданные случаев, образцы npz, точки стартов.

Две раскладки:
  * «pilot» (П1): <набор>/plan.json, state.sqlite (таблица cases), cases/<id>.npz;
  * «airlite» (данные разработки до слияния P1): <каталог air_lite>/out/plan.json, out/runs.jsonl, fields/<id>.npz.
Метаданные случаев читает ОДНА функция — `case_rows()`; переключение на `state.sqlite` — только здесь.
"""
from __future__ import annotations

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
            con.row_factory = sqlite3.Row
            for rec in con.execute("SELECT * FROM cases"):
                d = dict(rec)
                if str(d.get("status")) not in ("done", "ok"):
                    continue
                row = {}
                for k, v in d.items():          # JSON-колонки (метаданные случая) — разворачиваются в строку
                    if isinstance(v, str) and v[:1] == "{":
                        try:
                            js = json.loads(v)
                        except ValueError:
                            js = None
                        if isinstance(js, dict):
                            row.update(js)
                            continue
                    row.setdefault(k, v)
                row.setdefault("id", d.get("id"))
                rows.append(row)
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


def solver_status(row):
    """Худший статус решений области (ok < max < diverged)."""
    order = {"ok": 0, "max": 1, "diverged": 2, "error": 3}
    st = [v.get("status", "ok") for k, v in (row.get("runs") or {}).items() if k.startswith("d400")]
    return max(st, key=lambda s: order.get(s, 3)) if st else "ok"
