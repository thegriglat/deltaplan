#!/usr/bin/env python3
"""CL-1: числа диагноза полос и ряби на крутых склонах по сырым кадрам tools/shots/cliff_look_shot.gd --mode=diag.

    python3 -I tools/research/cliff_look/diag_metrics.py <каталог raw> [--out tools/research/cliff_look/diag_before.json]

Вход: <raw>/<tag>_<view>.json (метаданные) и <tag>_<view>_<член>.rgb (RGB8, w×h), маски m1 (вес скал, уклон/90,
экспозиция/360) и m2 (фаза сетки слоя x, высота mod 32 м, фаза z) — линейный ALBEDO без света, в кадре sRGB.
Маска скал M: вес скал > 0,5 и уклон > 40°, без 2 px у края. Яркость — luma sRGB (как видит глаз на экране).

Числа на ракурс и член (член — кадр с ним ВЫКЛЮЧЕННЫМ; base — исходный):
  strata26, strata7 — амплитуда яркости, привязанной к фазе слоёв шейдера (маска m3: sy = высота + сдвиг fbm 250 м,
            шаги strata_m · 3,7 = 25,9 м и strata_m = 7 м) / средняя яркость: полосы слоёв strata/ledge точно
  band    — СКО полос вдоль горизонталей (band_sko) / средняя яркость; band_rock — то же только на скалах
  aniso   — СКО вертикальной производной / СКО горизонтальной высокочастотной части яркости (масштабы < 40 м);
            > 1 — преобладают горизонтальные полосы, < 1 — вертикальные штрихи (вдоль линии падения)
  period_m, coh — период полос по высоте (автокорреляция по столбцам кадра, пик лага × м высоты на строку) и
            сила пика (0..1)
  ripple  — СКО части яркости мельче 2 м / средняя яркость (рябь)
  contrast — СКО части мельче 40 м / средняя яркость
  grid    — доля высокочастотной яркости, привязанной к фазе сетки слоя (25 м): СКО средних по 8×8 корзинам фазы /
            СКО (фасетки треугольников и нормали по узлам)
  d_*     — вклад члена = base − кадр без него: d_rms (СКО разности / средняя яркость base), d_aniso (анизотропия
            разности), d_ripple (её доля мельче 2 м)
Геометрия: mpp_v — метров высоты на строку кадра (медиана), mpp_h — метров по горизонтали на пиксель;
stretch_tri — растяжение текселя упрощённого трипланара (две вертикальные проекции, смешивание по |nx|, |nz|),
stretch_xz — растяжение шумов по xz (1 / cos уклона) вдоль линии падения; медиана и p90 по M.
"""
import json
import sys
from pathlib import Path

import numpy as np

HP_M = 40.0      # верх «высокочастотной» части, м
RIPPLE_M = 2.0   # рябь — мельче, м


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


def erode(m, n):
    for _ in range(n):
        m = m & np.roll(m, 1, 0) & np.roll(m, -1, 0) & np.roll(m, 1, 1) & np.roll(m, -1, 1)
    return m


def luma(img):
    return (0.2126 * img[..., 0] + 0.7152 * img[..., 1] + 0.0722 * img[..., 2]) / 255.0


def box1(a, r, axis):
    """Скользящее среднее 2r+1 вдоль одной оси (отражение у краёв)."""
    pad = [(0, 0), (0, 0)]
    pad[axis] = (r + 1, r)
    c = np.cumsum(np.pad(a, pad, mode="reflect"), axis=axis)
    k = 2 * r + 1
    if axis == 0:
        return (c[k:, :] - c[:-k, :]) / k
    return (c[:, k:] - c[:, :-k]) / k


def band_sko(hp, m, r=15):
    """СКО полос вдоль горизонталей: дисперсия, которая остаётся после сглаживания вдоль строки кадра (горизонтали
    стены на экране почти горизонтальны — см. contour_tilt), сверх той, что остаётся после такого же сглаживания
    поперёк. Изотропная рябь гасится одинаково и даёт ~0, горизонтальные полосы — свою амплитуду."""
    a = box1(hp, r, 1)[m]
    b = box1(hp, r, 0)[m]
    return float(np.sqrt(max(a.var() - b.var(), 0.0)))


def locked_amp(a, m, phase):
    """Амплитуда первой гармоники a, привязанной к фазе (0..1) — полосы слоёв strata/ledge."""
    if phase is None:
        return None
    ph = 2 * np.pi * phase[m]
    x = a[m]
    return float(2.0 * np.hypot(np.mean(x * np.cos(ph)), np.mean(x * np.sin(ph))))


def grad_rms(a, m):
    mv = m[1:, :] & m[:-1, :]
    mh = m[:, 1:] & m[:, :-1]
    gv = (a[1:, :] - a[:-1, :])[mv]
    gh = (a[:, 1:] - a[:, :-1])[mh]
    return float(np.sqrt(np.mean(gv ** 2))), float(np.sqrt(np.mean(gh ** 2)))


def period(hp, m, mpp_v):
    """Период полос по высоте: средняя автокорреляция по отрезкам столбцов внутри M (≥ 64 px)."""
    h, w = hp.shape
    maxlag = 96
    acc = np.zeros(maxlag)
    cnt = 0
    for x in range(0, w, 4):
        col = m[:, x]
        y = 0
        while y < h:
            if not col[y]:
                y += 1
                continue
            y0 = y
            while y < h and col[y]:
                y += 1
            if y - y0 >= 64:
                s = hp[y0:y, x] - hp[y0:y, x].mean()
                v = float(np.dot(s, s))
                if v > 1e-9:
                    n = min(maxlag, (y - y0) // 2)
                    for lag in range(1, n):
                        acc[lag] += float(np.dot(s[:-lag], s[lag:])) / v
                    cnt += 1
    if cnt == 0:
        return None, None
    ac = acc / cnt
    best, coh = None, 0.0
    for lag in range(3, maxlag - 1):
        if ac[lag] > ac[lag - 1] and ac[lag] >= ac[lag + 1] and ac[lag] > coh:
            best, coh = lag, float(ac[lag])
    if best is None:
        return None, 0.0
    return best * mpp_v, coh


def stretch(slope_deg, aspect_deg):
    """Растяжение текселя трипланара (две вертикальные проекции) и шумов по xz на поверхности."""
    t = np.radians(slope_deg)
    a = np.radians(aspect_deg)
    n = np.stack([np.sin(t) * np.sin(a), np.cos(t), -np.sin(t) * np.cos(a)], -1)
    # касательные: вдоль горизонтали и вдоль линии падения
    hx = np.stack([np.cos(a), np.zeros_like(a), np.sin(a)], -1)
    fl = np.cross(n, hx)
    out = []
    for drop in (2, 0):  # проекция xy (без z) и zy (без x)
        keep = [i for i in range(3) if i != drop]
        m = np.stack([hx[..., keep], fl[..., keep]], -1)  # (..., 2, 2)
        sv = np.linalg.svd(m, compute_uv=False)
        out.append(1.0 / np.maximum(sv[..., -1], 1e-3))
    bx = np.abs(n[..., 0]) / np.maximum(np.abs(n[..., 0]) + np.abs(n[..., 2]), 1e-3)
    tri = (1 - bx) * out[0] + bx * out[1]
    xz = 1.0 / np.maximum(np.cos(t), 1e-3)
    return tri, xz


def analyze(raw, stem):
    meta = json.loads((raw / f"{stem}.json").read_text())
    w, h = meta["w"], meta["h"]
    m1 = srgb_to_lin(load(raw / f"{stem}_m1.rgb", w, h))
    m2 = srgb_to_lin(load(raw / f"{stem}_m2.rgb", w, h))
    rsw, slope, aspect = m1[..., 0], m1[..., 1] * 90.0, m1[..., 2] * 360.0
    p3 = raw / f"{stem}_m3.rgb"
    m3 = srgb_to_lin(load(p3, w, h)) if p3.exists() else None
    ph26 = m3[..., 0] if m3 is not None else None
    ph7 = m3[..., 1] if m3 is not None else None
    # рельеф: маски m1 и m2 различаются (небо чёрное, остатки облаков/дымки одинаковы в обеих)
    terrain = np.abs(m1 - m2).sum(-1) > 0.03
    # крутые склоны (> 40°) целиком — полосы видны и на снегу поверх скал; Mr — только скалы (вес > 0,5)
    M = erode(terrain & (slope > 40.0), 2)
    Mr = erode(terrain & (rsw > 0.5) & (slope > 40.0), 2)
    dist = float(np.linalg.norm(np.array(meta["cam"]) - np.array(meta["tgt"])))
    res = {"tag": meta["tag"], "view": meta["view"], "sun_elev_deg": round(meta["sun_elev_deg"], 1), "dist_m": round(dist),
           "steep_px_share": round(float(M.mean()), 4), "rock_px_share": round(float(Mr.mean()), 4)}
    if M.sum() < 5000:
        res["note"] = "мало пикселей скал в кадре"
        return res
    # метры на пиксель: высота (mod 32 м) по строкам, фаза сетки по столбцам
    yv = m2[..., 1] * 32.0
    dy = np.diff(yv, axis=0)
    dy = (dy + 16.0) % 32.0 - 16.0
    mv = M[1:, :] & M[:-1, :]
    mpp_v = float(np.median(np.abs(dy[mv])))
    # наклон горизонталей на экране: направление градиента высоты (м/px) по строкам и столбцам
    dyx = np.diff(yv, axis=1)
    dyx = (dyx + 16.0) % 32.0 - 16.0
    gy_ = dy[:, :-1]
    gx_ = dyx[:-1, :]
    mm = M[1:, 1:] & M[:-1, 1:] & M[1:, :-1]
    tilt = np.degrees(np.arctan2(np.abs(gx_[mm]), np.abs(gy_[mm]) + 1e-9))
    res["contour_tilt_med_deg"] = round(float(np.median(tilt)), 1)
    ph = [m2[..., 0], m2[..., 2]]
    dd = [((np.diff(p, axis=1) + 0.5) % 1.0 - 0.5) * meta["spacing"] for p in ph]
    mh = M[:, 1:] & M[:, :-1]
    mpp_h = float(np.median(np.hypot(dd[0][mh], dd[1][mh])))
    tri, xz = stretch(slope[M], aspect[M])
    q = lambda a, p: round(float(np.percentile(a, p)), 2)  # noqa: E731
    res.update({"slope_med_deg": q(slope[M], 50), "mpp_v": round(mpp_v, 3), "mpp_h": round(mpp_h, 3),
                "stretch_tri_med": q(tri, 50), "stretch_tri_p90": q(tri, 90),
                "stretch_xz_med": q(xz, 50), "stretch_xz_p90": q(xz, 90)})
    mpp = max(mpp_h, 1e-3)
    r_hp = HP_M / mpp / 2.0
    r_rp = max(RIPPLE_M / mpp / 2.0, 1.0)
    fx = np.minimum(ph[0], 1 - ph[0])
    fz = np.minimum(ph[1], 1 - ph[1])
    bins = (np.minimum((fx[M] * 16).astype(int), 7), np.minimum((fz[M] * 16).astype(int), 7))
    lums = {}
    for mem in meta["members"]:
        lums[mem] = luma(load(raw / f"{stem}_{mem}.rgb", w, h))
    base = lums.get("base")
    rows = {}
    for mem, L in lums.items():
        mean = float(L[M].mean())
        hp = L - box(L, r_hp)
        rp = L - box(L, r_rp)
        sv, sh = grad_rms(hp, M)
        per, coh = period(hp, M, mpp_v)
        hm = hp[M]
        s = np.zeros((8, 8))
        c = np.zeros((8, 8))
        np.add.at(s, bins, hm)
        np.add.at(c, bins, 1)
        ok = c > 50
        gmeans = s[ok] / c[ok]
        # высокочастотная часть с окном в один шаг слоя по высоте: синус слоя проходит целиком, тренды длиннее
        # шага (освещение склона, границы снега) уходят
        l26 = locked_amp(L - box(L, max(25.9 / mpp_v / 2.0, 1.0)), M, ph26)
        l7 = locked_amp(L - box(L, max(7.0 / mpp_v / 2.0, 1.0)), M, ph7)
        row = {"mean": round(mean, 4), "band": round(band_sko(hp, M) / mean, 4),
               "strata26": round(l26 / mean, 4) if l26 is not None else None,
               "strata7": round(l7 / mean, 4) if l7 is not None else None,
               "band_rock": round(band_sko(hp, Mr) / max(float(L[Mr].mean()), 1e-6), 4) if Mr.sum() > 2000 else None,
               "aniso": round(sv / max(sh, 1e-9), 3),
               "period_m": round(per, 1) if per else None, "coh": round(coh, 3) if coh is not None else None,
               "ripple": round(float(rp[M].std()) / mean, 4), "contrast": round(float(hm.std()) / mean, 4),
               "grid": round(float(gmeans.std()) / max(float(hm.std()), 1e-9), 3)}
        if base is not None and mem != "base":
            d = base - L
            dhp = d - box(d, r_hp)
            dv, dh = grad_rms(dhp, M)
            drp = d - box(d, r_rp)
            bm = float(base[M].mean())
            dper, dcoh = period(dhp, M, mpp_v)
            row.update({"d_rms": round(float(d[M].std()) / bm, 4), "d_band": round(band_sko(dhp, M) / bm, 4),
                        "d_aniso": round(dv / max(dh, 1e-9), 3), "d_ripple": round(float(drp[M].std()) / bm, 4),
                        "d_period_m": round(dper, 1) if dper else None, "d_coh": round(dcoh, 3) if dcoh is not None else None})
        rows[mem] = row
    res["members"] = rows
    return res


def summarize(results):
    """Сводка «член × дальность»: медиана по ракурсам доли полос слоёв, что остаётся без члена (strata26 без / с),
    вклада члена в полосы вдоль горизонталей (d_band) и в рябь мельче 2 м (d_ripple) и доли ряби без члена."""
    cls = {"near": lambda d: d <= 250, "mid": lambda d: 250 < d <= 900, "far": lambda d: d > 900}
    mems = []
    for r in results:
        for m in r.get("members", {}):
            if m not in mems and m != "base":
                mems.append(m)
    lines = ["Медианы по ракурсам; near ≤ 250 м, mid 250–900 м, far > 900 м. s26/s7 — доля полос слоёв (25,9 и 7 м по высоте), "
             "что остаётся с выключенным членом (1 — член не влияет, 0 — полос нет); rp — доля ряби < 2 м, что остаётся; "
             "dB, dR — вклад члена в полосы вдоль горизонталей и в рябь (доля средней яркости).", "",
             "член | " + " | ".join(f"{c}: s26 / s7 / rp / dB / dR" for c in cls), "--- | " + " | ".join("---" for _ in cls)]
    for m in mems:
        cells = []
        for c, f in cls.items():
            vs = [r for r in results if "members" in r and f(r["dist_m"]) and m in r["members"]]
            if not vs:
                cells.append("—")
                continue
            def med(fn):
                xs = [fn(r) for r in vs]
                xs = [x for x in xs if x is not None]
                return float(np.median(xs)) if xs else float("nan")
            s26 = med(lambda r: r["members"][m]["strata26"] / max(r["members"]["base"]["strata26"], 1e-6)
                      if r["members"][m].get("strata26") is not None else None)
            s7 = med(lambda r: r["members"][m]["strata7"] / max(r["members"]["base"]["strata7"], 1e-6)
                     if r["members"][m].get("strata7") is not None else None)
            rp = med(lambda r: r["members"][m]["ripple"] / max(r["members"]["base"]["ripple"], 1e-6))
            db = med(lambda r: r["members"][m]["d_band"])
            dr = med(lambda r: r["members"][m]["d_ripple"])
            cells.append(f"{s26:.2f} / {s7:.2f} / {rp:.2f} / {db:.3f} / {dr:.3f}")
        lines.append(f"{m} | " + " | ".join(cells))
    # по ракурсам: полосы слоёв A = √(s26² + s7²); без члена A_m / A_base < 0,5 — «нет», иначе «есть»;
    # фон — A кадра all_off (всё выключено: случайная связь яркости с фазой слоёв)
    vs = [r for r in results if "members" in r]
    amp = lambda row: float(np.hypot(row.get("strata26") or 0.0, row.get("strata7") or 0.0))  # noqa: E731
    lines += ["", "Полосы слоёв по ракурсам: A = √(s26² + s7²) в долях средней яркости; ячейка — «есть/нет» и A без члена / A base "
              "(нет — < 0,5).", "",
              "выключен | " + " | ".join(f"{r['tag']}/{r['view']} {r['dist_m']} м" for r in vs),
              "--- | " + " | ".join("---" for _ in vs),
              "base: A (фон all_off) | " + " | ".join(f"{amp(r['members']['base']):.3f} ({amp(r['members']['all_off']):.3f})"
                                                   for r in vs)]
    for m in mems:
        cells = []
        for r in vs:
            k = amp(r["members"][m]) / max(amp(r["members"]["base"]), 1e-6)
            cells.append(f"{'нет' if k < 0.5 else 'есть'} {k:.2f}")
        lines.append(f"{m} | " + " | ".join(cells))
    n = {c: sum(1 for r in results if "members" in r and f(r["dist_m"])) for c, f in cls.items()}
    lines.append("")
    lines.append("Ракурсов: " + ", ".join(f"{c} {k}" for c, k in n.items()))
    return "\n".join(lines)


def main():
    raw = Path(sys.argv[1])
    out = Path(sys.argv[sys.argv.index("--out") + 1]) if "--out" in sys.argv else None
    stems = sorted(p.stem for p in raw.glob("*.json"))
    results = [analyze(raw, s) for s in stems]
    for r in results:
        print(f"## {r['tag']} / {r['view']}: круче 40° {r['steep_px_share']:.1%}, скалы {r['rock_px_share']:.1%} кадра, "
              + ", ".join(f"{k} {r[k]}" for k in ("contour_tilt_med_deg", "slope_med_deg", "mpp_v", "mpp_h", "stretch_tri_med", "stretch_tri_p90",
                                                   "stretch_xz_med", "stretch_xz_p90") if k in r))
        if "members" not in r:
            continue
        cols = ("strata26", "strata7", "band", "band_rock", "aniso", "ripple", "contrast", "grid", "d_rms", "d_band", "d_aniso", "d_ripple",
                "d_period_m", "d_coh")
        print("член | " + " | ".join(cols))
        for mem, row in r["members"].items():
            print(" | ".join([mem] + [str(row.get(k, "")) for k in cols]))
    summary = summarize(results)
    print(summary)
    if out:
        out.with_suffix(".md").write_text(summary + "\n")
        out.write_text(json.dumps({"version": 1, "views": results}, ensure_ascii=False, indent=1) + "\n")
        print("diag_metrics:", out)


if __name__ == "__main__":
    main()
