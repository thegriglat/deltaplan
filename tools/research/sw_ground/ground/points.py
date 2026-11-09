"""SWG1: плотный набор приземных точек (центры клеток Пикара nom внутри box(case), тип — classify SWD1).

  py -m ground.points            # → out/points/ground_points.json
Правило прореживания — в `RULE` (пишется в файл). Никакого отбора по значению ошибки.
"""
from __future__ import annotations

import json
from collections import Counter

import h5py
import numpy as np

from . import common as K
import points as P  # noqa: E402  (SWD1 refs/points.py: classify, box, ground_at)

CAP = 225          # ≈ 1,5 · 150: предел числа точек основных типов на (случай, высоту)
RULE = ("центры клеток Пикара nom (сетка 200×200 SWD1) внутри box(case) без боковой губки; тип — refs/points.py classify; "
        "один шаг прореживания k на случай (каждая k-я клетка по x и по y, фаза 0) — наименьший, при котором типы "
        "windward, crest, lee не больше %d точек; тип с ≤ 150 клетками при k = 1 берётся целиком (valley Askervein; на "
        "Perdigão таких нет); upstream (не входит в приёмку) дополнительно равномерно (каждая m-я по порядку строк) до ≤ %d; "
        "высоты z_agl 10, 50, 300 м; отбора по значению ошибки нет; z_ground — растр рельефа SWD1 (асл, как у панелей); "
        "s_nom, s_adv1 — скорость Пикара / скорость Пикара в опорной точке norm (строка мачты norm в points.json SWD1)" % (CAP, CAP))


def _field(h, kind, lev):
    g = h[kind]
    sc = float(g["u"].attrs["scale"])
    return g["u"][lev].astype(float) * sc, g["v"][lev].astype(float) * sc


def norm_speeds(refs):
    """{case: {kind: Пикар-скорость в опорной точке}} — строка мачты norm (имя и z_agl) в points.json SWD1."""
    out = {}
    for c in K.CASES:
        nm = refs["norm"][c]
        out[c] = {}
        for kind in ("picard_nom", "picard_adv1"):
            r = next(r for r in refs["rows"] if r["case"] == c and r["ref_kind"] == kind and r["name"] == nm["name"]
                     and abs(r["z_agl"] - nm["z_agl"]) < 1e-6)
            out[c][kind] = float(r["speed"])
    return out


def classify_grid(case, x, y):
    """Матрица типов на сетке центров (по box) и индексы (ix, iy)."""
    b = P.box(case)
    ix = np.where((x >= b[0]) & (x <= b[1]))[0]
    iy = np.where((y >= b[2]) & (y <= b[3]))[0]
    T = np.empty((iy.size, ix.size), object)
    for a, j in enumerate(iy):
        for c, i in enumerate(ix):
            T[a, c] = P.classify(case, float(x[i]), float(y[j]))
    return ix, iy, T


def choose_step(T):
    """Наименьший k с ≤ CAP точек в windward, crest, lee."""
    for k in range(1, 40):
        c = Counter(T[::k, ::k].ravel())
        if all(c.get(t, 0) <= CAP for t in ("windward", "crest", "lee")):
            return k
    raise RuntimeError("шаг не найден")


def select_cells(T, k):
    """Список (a, c, type) выбранных ячеек матрицы T."""
    full = Counter(T.ravel())
    sel = []
    for a in range(T.shape[0]):
        for c in range(T.shape[1]):
            t = T[a, c]
            small = full[t] <= 150 and t != "upstream"
            if small or (a % k == 0 and c % k == 0):
                sel.append((a, c, t))
    ups = [s for s in sel if s[2] == "upstream"]
    if len(ups) > CAP:
        m = int(np.ceil(len(ups) / CAP))
        keep = {id(s) for s in ups[::m]}
        sel = [s for s in sel if s[2] != "upstream" or id(s) in keep]
    return sel


def build(refs=None):
    refs = refs or json.load(open(K.REFS / "points.json"))
    nsp = norm_speeds(refs)
    rows, steps = [], {}
    for case in K.CASES:
        with h5py.File(K.REFS / f"{case}.h5", "r") as h:
            x = h["picard_nom/x"][:]
            y = h["picard_nom/y"][:]
            zl = [float(v) for v in h["picard_nom/z_agl"][:]]
            ix, iy, T = classify_grid(case, x, y)
            k = choose_step(T)
            steps[case] = k
            sel = select_cells(T, k)
            fl = {}
            for z in K.HEIGHTS:
                lev = int(np.argmin(np.abs(np.array(zl) - z)))
                assert abs(zl[lev] - z) < 1e-6, (case, z, zl)
                un, vn = _field(h, "picard_nom", lev)
                ua, va = _field(h, "picard_adv1", lev)
                fl[z] = (np.hypot(un, vn), np.hypot(ua, va))
            n = 0
            for z in K.HEIGHTS:
                sn, sa = fl[z]
                for a, c, t in sel:
                    i, j = int(ix[c]), int(iy[a])
                    n += 1
                    xx, yy = float(x[i]), float(y[j])
                    sp = float(sn[j, i])
                    s_adv = float(sa[j, i]) / nsp[case]["picard_adv1"]
                    rows.append(dict(case=case, id=f"G_{case}_{n}", type=t, x=xx, y=yy,
                                     z_ground=round(float(P.ground_at(case, xx, yy)), 3), z_agl=z,
                                     s_nom=sp / nsp[case]["picard_nom"], s_adv1=s_adv, speed_nom=sp))
    return dict(format="swg-points", version=1, git=K.git_short(), created=K.now_iso(), rule=RULE + " Шаг k: " +
                ", ".join(f"{c} {k}" for c, k in steps.items()) + ".", steps=steps, rows=rows)


def main():
    doc = build()
    K.dump_json(K.OUT_POINTS, doc)
    cnt = Counter((r["case"], r["type"], r["z_agl"]) for r in doc["rows"])
    for c in K.CASES:
        print(c, "k =", doc["steps"][c], {t: cnt[(c, t, 10.0)] for t in K.TYPES})


if __name__ == "__main__":
    main()
