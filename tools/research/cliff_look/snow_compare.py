#!/usr/bin/env python3
"""CL-3: рельеф снега — числа «до/после» по сырым кадрам стенда CL-К1 (tools/shots/cliff_look_shot.gd --mode=diag).

    python3 -I tools/research/cliff_look/snow_compare.py

Пути внутри (без аргументов): «до» — build/cliff_look_raw/before (CL-1), «после» — build/cliff_look_raw/cl3
(кадр base и маски m1, m2 тех же ракурсов). Ракурсы — снежные: everest/snow_mid, everest/snow_near,
shymbulak/peak_snow. Пишет tools/research/cliff_look/snow_cl3.json.

Маска снега S (по цвету, одна для «до» и «после»): рельеф (маски m1 и m2 различаются) и в ОБОИХ кадрах base пиксель
снежный по цвету: яркость luma > 0,5, насыщенность (max − min) / max < 0,3 и синий ≥ зелёный − 4 (белый/голубоватый
снег; бледная трава зеленее, порода темнее); без 3 px у края маски. Скалы поверх снега (вес скал) рисуются породой —
цвет их отсекает. Масштаб — метры на пиксель по фазе сетки слоя (маска m2), сглаженные окном 9 px; полосы масштабов
считаются по корзинам-октавам м/px, у каждой — свои окна в пикселях.

Числа на ракурс (luma sRGB, в долях средней яркости в S):
  large  — СКО полосы 5–40 м: box(L, 5 м) − box(L, 40 м) (окна — полный размер, в пикселях по м/px корзины)
  ripple — СКО ряби мельче 2 м: L − box(L, 2 м) (окно не меньше 3 px)
  Окна усредняют только пиксели S (нормированная свёртка): кромка снега с тёмной породой не попадает в полосы.
Печатает SNOW_LARGE_RATIO — медиана по ракурсам large(после) / large(до), SNOW_RIPPLE_RATIO — то же для ripple.
"""
import json
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[3]
BEFORE = ROOT / "build/cliff_look_raw/before"
AFTER = ROOT / "build/cliff_look_raw/cl3"
OUT = ROOT / "tools/research/cliff_look/snow_cl3.json"
VIEWS = ["everest_snow_mid", "everest_snow_near", "shymbulak_peak_snow"]
LARGE_M = (5.0, 40.0)
RIPPLE_M = 2.0


def srgb_to_lin(v):
    v = v / 255.0
    return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)


def load(path, w, h):
    return np.fromfile(path, dtype=np.uint8).reshape(h, w, 3).astype(np.float64)


def box(a, r):
    """Скользящее среднее (2r+1)² через накопленные суммы, края — отражение."""
    r = max(int(round(r)), 1)
    p = np.pad(a, r, mode="reflect")
    c = np.cumsum(np.cumsum(p, axis=0), axis=1)
    c = np.pad(c, ((1, 0), (1, 0)))
    k = 2 * r + 1
    s = c[k:, k:] - c[:-k, k:] - c[k:, :-k] + c[:-k, :-k]
    return s / (k * k)


def sbox(a, m, r):
    """Среднее окна только по пикселям маски m (нормированная свёртка): соседняя порода и небо не попадают
    в полосу масштабов на краю снега."""
    mf = m.astype(np.float64)
    return box(a * mf, r) / np.maximum(box(mf, r), 1e-6)


def erode(m, n):
    for _ in range(n):
        m = m & np.roll(m, 1, 0) & np.roll(m, -1, 0) & np.roll(m, 1, 1) & np.roll(m, -1, 1)
    return m


def luma(img):
    return (0.2126 * img[..., 0] + 0.7152 * img[..., 1] + 0.0722 * img[..., 2]) / 255.0


def snow_color(img):
    mx = img.max(-1)
    mn = img.min(-1)
    return (luma(img) > 0.5) & ((mx - mn) / np.maximum(mx, 1.0) < 0.3) & (img[..., 2] >= img[..., 1] - 4.0)


def mpp_map(m2, spacing):
    """Метры на пиксель по горизонтали: разность фазы сетки слоя (x, z) между соседними столбцами."""
    d = [((np.diff(m2[..., i], axis=1) + 0.5) % 1.0 - 0.5) * spacing for i in (0, 2)]
    m = np.hypot(d[0], d[1])
    m = np.pad(m, ((0, 0), (0, 1)), mode="edge")
    return box(m, 4)


def metrics(L, S, mp):
    """Полосы масштабов — по корзинам м/px (октавы): в каждой корзине окна в пикселях по её м/px; СКО — по всем
    корзинам вместе (сумма квадратов отклонений от среднего корзины)."""
    mean = float(L[S].mean())
    oc = np.floor(np.log2(np.maximum(mp, 1e-3)))
    acc = {"large": 0.0, "ripple": 0.0}
    n = 0
    for o in np.unique(oc[S]):
        B = S & (oc == o)
        if B.sum() < 2000:
            continue
        mpp = float(np.median(mp[B]))
        r5 = max(LARGE_M[0] / mpp / 2.0, 1.0)
        r40 = max(LARGE_M[1] / mpp / 2.0, r5 + 1.0)
        band = (sbox(L, S, r5) - sbox(L, S, r40))[B]
        rp = (L - sbox(L, S, max(RIPPLE_M / mpp / 2.0, 1.0)))[B]
        acc["large"] += float(((band - band.mean()) ** 2).sum())
        acc["ripple"] += float(((rp - rp.mean()) ** 2).sum())
        n += int(B.sum())
    n = max(n, 1)
    return {"mean": round(mean, 4), "px": n, "large": round(np.sqrt(acc["large"] / n) / mean, 5),
            "ripple": round(np.sqrt(acc["ripple"] / n) / mean, 5)}


def analyze(stem):
    meta = json.loads((AFTER / f"{stem}.json").read_text())
    w, h = meta["w"], meta["h"]
    m1 = srgb_to_lin(load(AFTER / f"{stem}_m1.rgb", w, h))
    m2 = srgb_to_lin(load(AFTER / f"{stem}_m2.rgb", w, h))
    b0 = load(BEFORE / f"{stem}_base.rgb", w, h)
    b1 = load(AFTER / f"{stem}_base.rgb", w, h)
    terrain = np.abs(m1 - m2).sum(-1) > 0.03
    mp = mpp_map(m2, meta["spacing"])
    S = erode(terrain & snow_color(b0) & snow_color(b1), 3)
    med = float(np.median(mp[S])) if S.sum() else 1.0
    res = {"view": stem, "snow_px_share": round(float(S.mean()), 4), "mpp_med": round(med, 3),
           "dist_m": round(float(np.linalg.norm(np.array(meta["cam"]) - np.array(meta["tgt"]))))}
    if S.sum() < 5000:
        res["note"] = "мало снега в кадре"
        return res
    res["before"] = metrics(luma(b0), S, mp)
    res["after"] = metrics(luma(b1), S, mp)
    res["large_ratio"] = round(res["after"]["large"] / max(res["before"]["large"], 1e-9), 3)
    res["ripple_ratio"] = round(res["after"]["ripple"] / max(res["before"]["ripple"], 1e-9), 3)
    return res


def main():
    rows = [analyze(s) for s in VIEWS if (AFTER / f"{s}.json").exists()]
    for r in rows:
        print(json.dumps(r, ensure_ascii=False))
    ok = [r for r in rows if "large_ratio" in r]
    if not ok:
        print("snow_compare: нет кадров", file=sys.stderr)
        sys.exit(1)
    lr = float(np.median([r["large_ratio"] for r in ok]))
    rr = float(np.median([r["ripple_ratio"] for r in ok]))
    OUT.write_text(json.dumps({"version": 1, "before": str(BEFORE.relative_to(ROOT)), "after": str(AFTER.relative_to(ROOT)),
                               "snow_large_ratio": round(lr, 3), "snow_ripple_ratio": round(rr, 3), "views": rows},
                              ensure_ascii=False, indent=1) + "\n")
    print(f"SNOW_LARGE_RATIO {lr:.3f}")
    print(f"SNOW_RIPPLE_RATIO {rr:.3f}")


if __name__ == "__main__":
    main()
