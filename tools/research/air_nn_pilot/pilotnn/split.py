"""Деление случаев (контракт П2, план §5.1 в масштабе пилота) — детерминированно, по хешу id и зерну конфига.

  (б) отложенные места: `holdout_places` (ongudai) + `holdout_proc_n` мест с префиксом `holdout_proc_prefix`
      (первые по хешу (зерно, место)) — целиком вне обучения и проверки;
  (а) у каждого места обучения доля `newcond_frac` случаев — «новые условия» (тест), доля `val_frac` — проверка
      для ранней остановки, остальное — обучение (по хешу (зерно, id));
  (в) кривая: места обучения в порядке хеша (зерно, «curve», место); точка n — первые n мест (вложенные
      подмножества); обучение/проверка — их части из (а); оценка — на отложенных местах (б).
"""
from __future__ import annotations

import hashlib


def u01(*parts) -> float:
    h = hashlib.sha256(":".join(str(p) for p in parts).encode()).digest()
    return int.from_bytes(h[:8], "big") / 2 ** 64


def make_split(rows, sc):
    seed = sc["seed"]
    locs = sorted({r["loc"] for r in rows})
    proc = sorted((l for l in locs if l.startswith(sc["holdout_proc_prefix"]) and l not in sc["holdout_places"]),
                  key=lambda l: u01(seed, "hold", l))
    hold_proc = sorted(proc[: sc["holdout_proc_n"]])
    hold_places = [l for l in sc["holdout_places"] if l in locs]
    hold = set(hold_places) | set(hold_proc)
    pool = sorted((l for l in locs if l not in hold), key=lambda l: u01(seed, "curve", l))
    part = {}
    for r in rows:
        if r["loc"] in hold:
            part[r["id"]] = "holdout"
            continue
        u = u01(seed, r["id"])
        part[r["id"]] = ("newcond" if u < sc["newcond_frac"] else
                         "val" if u < sc["newcond_frac"] + sc["val_frac"] else "train")
    by = {}
    for r in rows:
        by.setdefault((part[r["id"]], r["loc"]), []).append(r["id"])

    def ids(kind, places):
        return sorted(i for l in places for i in by.get((kind, l), []))

    curve = []
    for n in sc["curve_sizes"]:
        n_eff = min(n, len(pool))
        if curve and curve[-1]["n_places"] == n_eff:
            continue
        pl = pool[:n_eff]
        curve.append(dict(n=n, n_places=n_eff, places=sorted(pl), train_ids=ids("train", pl), val_ids=ids("val", pl)))
    return dict(seed=seed, holdout_places=hold_places, holdout_proc=hold_proc, pool_order=pool,
                train_ids=ids("train", pool), val_ids=ids("val", pool), newcond_ids=ids("newcond", pool),
                holdout_place_ids=ids("holdout", hold_places), holdout_proc_ids=ids("holdout", hold_proc), curve=curve)
