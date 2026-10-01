"""Поле прикидки (npz окна 100 м) → поле для игры (`WindField`, AM-05): `<имя>.json` + `<имя>.bin`.

Раскладка — как у решателя (`common.py`, `solver.py`) и эталонов AM-01 (`fixtures.py`), но без
ореола и в центрах клеток: массив (nz, ny, nx), индекс (k·ny + j)·nx + i, float32 little-endian,
i — восток (x мира игры), j — север (y = −Z мира игры), k — вверх (высота над морем).
Центр клетки: x = x0 + (i + ½)·dx, y = y0 + (j + ½)·dx, z = z_bot + (k + ½)·dz. Клетка под землёй,
если z центра < hc столбца (hc — блочное среднее рельефа, как в решателе).

Каналы: u, v (восток, север), w_mech — вертикаль решения без нагрева (механическая: обтекание
рельефа), w_conv = w − w_mech (конвективная), theta — θ′ решения с нагревом; hc (ny, nx).
`.json`: dx, dz, x0, y0, z_bot, nx, ny, nz, z0, `arrays: {имя: [смещение, длина]}` в числах float32,
`source`, `cond` и `probes` — эталонные значения в точках (для тестов: трилинейно по центрам,
из исходных массивов, независимо от кода игры).

    PY=../heat_ca/.venv/bin/python
    F=/home/greg/deltaplan/tools/research/air3d/out/fields
    # маленькая фикстура для тестов (16 × 16 столбцов у старта Каянча, 40 уровней)
    $PY to_game_field.py $F/W100_h13_U3_d180.npz $F/W100_noheat_U3_d180.npz \
        ../../../tests/atmosphere/fixtures/air_model/field/kayancha_w100_h13_U3_d180 --crop 16,40
    # всё окно 64 × 64 для полёта (--air-field=<путь>.json), вне git
    $PY to_game_field.py $F/W100_h13_U3_d180.npz $F/W100_noheat_U3_d180.npz fields/game/kayancha_w100_h13_U3_d180
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

import terrain as T

Z0 = 0.1   # шероховатость решателя (solver.Params.z0), м — лог-профиль у земли в игре


def load(path):
    d = np.load(path)
    meta = json.loads(str(d["meta"]))
    arr = {k: d[k].astype(np.float64) for k in ("u", "v", "w", "th")}
    return meta, arr, d["hc"].astype(np.float64)


def trilinear(a, meta, x, y, z):
    """Трилинейно по центрам клеток (все 8 узлов должны быть в воздухе)."""
    fi = (x - meta["x0"]) / meta["dx"] - 0.5
    fj = (y - meta["y0"]) / meta["dx"] - 0.5
    fk = (z - meta["z_bot"]) / meta["dz"] - 0.5
    i, j, k = int(np.floor(fi)), int(np.floor(fj)), int(np.floor(fk))
    a_, b_, c_ = fi - i, fj - j, fk - k
    out = 0.0
    for dk, wk in ((0, 1 - c_), (1, c_)):
        for dj, wj in ((0, 1 - b_), (1, b_)):
            for di, wi in ((0, 1 - a_), (1, a_)):
                out += wk * wj * wi * a[k + dk, j + dj, i + di]
    return float(out)


def game_sample(ch, hc, g, z0, x, y, z, ground_h=None):
    """Выборка как в игре (WindField.sample, docs/air_model.md → «Поле на CPU»), независимая
    реализация на numpy: 4 столбца, у каждого высота выборки z_c = z + (hc_c − h)·exp(−agl/dx),
    по вертикали линейно между центрами, ниже центра первой воздушной клетки — лог-профиль к 0
    на z0 (θ′ — значение первой клетки), затем билинейно. ground_h — настоящая земля (None — hc
    билинейно)."""
    nx, ny, nz, dx, dz, zb = g["nx"], g["ny"], g["nz"], g["dx"], g["dz"], g["z_bot"]
    gx = min(max((x - g["x0"]) / dx - 0.5, 0.0), nx - 1.0)
    gy = min(max((y - g["y0"]) / dx - 0.5, 0.0), ny - 1.0)
    i0, j0 = min(int(gx), nx - 2), min(int(gy), ny - 2)
    fx, fy = gx - i0, gy - j0
    if ground_h is None:
        ground_h = ((1 - fy) * ((1 - fx) * hc[j0, i0] + fx * hc[j0, i0 + 1])
                    + fy * ((1 - fx) * hc[j0 + 1, i0] + fx * hc[j0 + 1, i0 + 1]))
    e = np.exp(-max(z - ground_h, 0.0) / dx)
    out = {}
    for name, a in ch.items():
        cols = []
        for jj, ii in ((j0, i0), (j0, i0 + 1), (j0 + 1, i0), (j0 + 1, i0 + 1)):
            h = float(hc[jj, ii])
            k1 = int(np.clip(np.ceil((h - zb) / dz - 0.5), 0, nz))
            if k1 >= nz:
                cols.append(0.0)
                continue
            zc = z + (h - ground_h) * e
            kf = (zc - zb) / dz - 0.5
            if kf >= k1:
                k = int(kf)
                t = kf - k
                if k >= nz - 1:
                    k, t = nz - 2, 1.0
                cols.append((1 - t) * a[k, jj, ii] + t * a[k + 1, jj, ii])
            elif name == "theta":
                cols.append(float(a[k1, jj, ii]))
            else:
                agl = zc - h
                a1 = max(zb + (k1 + 0.5) * dz - h, 2 * z0)
                f = 0.0 if agl <= z0 else min(np.log(agl / z0) / np.log(a1 / z0), 1.0)
                cols.append(f * a[k1, jj, ii])
        out[name] = float((1 - fy) * ((1 - fx) * cols[0] + fx * cols[1]) + fy * ((1 - fx) * cols[2] + fx * cols[3]))
    return out, float(ground_h)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("heat", help="npz решения с нагревом")
    ap.add_argument("noheat", help="npz решения без нагрева (та же сетка и ветер)")
    ap.add_argument("out", help="путь без расширения")
    ap.add_argument("--crop", default="", help="n,nz — n × n столбцов вокруг старта, nz уровней снизу")
    args = ap.parse_args()
    meta, A, hc = load(args.heat)
    meta2, B, hc2 = load(args.noheat)
    for k in ("dx", "dz", "x0", "y0", "z_bot", "nx", "ny", "nz"):
        assert meta[k] == meta2[k], ("разные сетки", k)
    assert np.array_equal(hc, hc2)
    ch = dict(u=A["u"], v=A["v"], w_mech=B["w"], w_conv=A["w"] - B["w"], theta=A["th"])
    g = dict((k, meta[k]) for k in ("dx", "dz", "x0", "y0", "z_bot", "nx", "ny", "nz"))
    s = T.sites(T.load_detail()[2])["start"]
    sx, sy = s["x"], s["y"]
    if args.crop:
        n, nzc = (int(v) for v in args.crop.split(","))
        ic = int((sx - g["x0"]) / g["dx"])
        jc = int((sy - g["y0"]) / g["dx"])
        i0, j0 = ic - n // 2, jc - n // 2
        ch = {k: a[:nzc, j0:j0 + n, i0:i0 + n] for k, a in ch.items()}
        hc = hc[j0:j0 + n, i0:i0 + n]
        g.update(x0=g["x0"] + i0 * g["dx"], y0=g["y0"] + j0 * g["dx"], nx=n, ny=n, nz=nzc)
    # эталон в точках над стартом Каянча: «field» — выборка как в игре (game_sample, земля —
    # рельеф сетки), «trilinear» — чисто трилинейно по центрам (для сравнения; у земли не
    # определено). Высоты — над рельефом сетки в точке старта.
    ch32 = {k: a.astype("<f4").astype(np.float64) for k, a in ch.items()}
    probes = []
    for agl in (10.0, 50.0, 150.0, 400.0):
        fs, hg = game_sample(ch32, hc, g, Z0, sx, sy, 0.0)
        z = hg + agl
        fs, _ = game_sample(ch32, hc, g, Z0, sx, sy, z)
        p = dict(name=f"kayancha_start_agl{agl:g}", agl=agl, game=[sx, z, -sy], field=fs)
        if agl >= 150.0:     # все 8 узлов в воздухе
            p["trilinear"] = {k: trilinear(a, g, sx, sy, z) for k, a in ch32.items()}
        probes.append(p)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    parts, arrays, off = [], {}, 0
    for name, a in [(k, a.astype("<f4")) for k, a in ch.items()] + [("hc", hc.astype("<f4"))]:
        a = np.ascontiguousarray(a).ravel()
        arrays[name] = [off, int(a.size)]
        parts.append(a)
        off += a.size
    np.concatenate(parts).tofile(str(out) + ".bin")
    js = dict(format="deltaplan-air-field", version=1, **g, z0=Z0,
              layout="(nz, ny, nx), индекс (k·ny + j)·nx + i; i — восток, j — север (−Z игры), k — вверх",
              source=[Path(args.heat).name, Path(args.noheat).name], cond=meta.get("cond", {}),
              probes=probes, arrays=arrays)
    Path(str(out) + ".json").write_text(json.dumps(js, ensure_ascii=False, indent=1))
    print(out, g, f"{off * 4 / 1e6:.2f} МБ")
    for p in probes:
        print(p["name"], "поле:", {k: round(v, 4) for k, v in p["field"].items()},
              "трилинейно:", {k: round(v, 4) for k, v in p.get("trilinear", {}).items()})


if __name__ == "__main__":
    main()
