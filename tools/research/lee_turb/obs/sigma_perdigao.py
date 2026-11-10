#!/usr/bin/env python3
"""σ_u, σ_v, σ_w, u'w' Perdigão в осях среднего ветра станции из 5-мин ковариаций ISFS -> sigma_perdigao.csv
(потом python3 build_lee_obs.py подставит их в lee_obs.csv). Нужны netCDF4, numpy (venv: tools/research/data/perdigao/scripts).
python3 sigma_perdigao.py [каталог с isfs_qc_tiltcor_*.nc = ~/data/lee_turb/isfs5]
Окна как в extract_profiles.py: NE 17-19 UTC 2017-04-27, SW 10-11 UTC 2017-05-11. Ось u — по осреднённому за окно (u_east, v_north)
станции; дисперсии 5-мин усредняются по окну (дисперсия на периодах >5 мин не входит - как и в TKE).
Переменные: u_,v_,w_ (средние), u_u__,v_v__,w_w__,u_v__,u_w__,v_w__ (ковариации). Проверено только на синтетике (selftest)."""
import csv, math, os, re, sys
import numpy as np
WIN = {"NE": ("20170427", 17, 19), "SW": ("20170511", 10, 11)}


def rotate(ubar, vbar, uu, vv, ww, uv, uw, vw):
    """Дисперсии и u'w' в осях среднего ветра (u вдоль горизонтального среднего). Массивы за окно."""
    th = math.atan2(vbar, ubar)
    c, s = math.cos(th), math.sin(th)
    su2 = c * c * uu + 2 * s * c * uv + s * s * vv
    sv2 = s * s * uu - 2 * s * c * uv + c * c * vv
    uwr = c * uw + s * vw
    return np.nanmean(su2), np.nanmean(sv2), np.nanmean(ww), np.nanmean(uwr)


def selftest():
    # ветер вдоль +v (север): sigma_u(вдоль) = sqrt(vv), sigma_v = sqrt(uu)
    r = rotate(0.0, 5.0, np.array([1.0]), np.array([4.0]), np.array([0.25]), np.array([0.0]), np.array([0.1]), np.array([-0.3]))
    assert abs(math.sqrt(r[0]) - 2.0) < 1e-9 and abs(math.sqrt(r[1]) - 1.0) < 1e-9 and abs(r[3] + 0.3) < 1e-9, r
    print("selftest ok")


def main():
    import netCDF4
    d = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/data/lee_turb/isfs5")
    out = []
    for case, (day, h0, h1) in WIN.items():
        V = netCDF4.Dataset(f"{d}/isfs_qc_tiltcor_{day}.nc").variables
        arr = lambda k: np.ma.filled(V[k][:].astype(float), np.nan)
        a, b = h0 * 12, h1 * 12
        for k in sorted(V):
            m = re.match(r"u_u__(\d+)m_(\w+)$", k)
            if not m or not m.group(2).startswith(("tse", "rsw", "rne", "v0")):
                continue
            s = f"{m.group(1)}m_{m.group(2)}"
            need = ["u_", "v_", "w_", "u_u__", "v_v__", "w_w__", "u_v__", "u_w__", "v_w__"]
            if any(p + s not in V for p in need):
                continue
            g = {p: arr(p + s)[a:b] for p in need}
            for x in g.values():
                x[x < -900] = np.nan
            ub, vb = np.nanmean(g["u_"]), np.nanmean(g["v_"])
            if not (np.isfinite(ub) and np.isfinite(vb)):
                continue
            su2, sv2, sw2, uw = rotate(ub, vb, g["u_u__"], g["v_v__"], g["w_w__"], g["u_v__"], g["u_w__"], g["v_w__"])
            out.append([case, f"{m.group(2)}_{m.group(1)}m", math.sqrt(su2), math.sqrt(sv2), math.sqrt(sw2), uw])
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "sigma_perdigao.csv"), "w", newline="") as fh:
        w = csv.writer(fh, lineterminator="\n")
        w.writerow("case,station,sigma_u_ms,sigma_v_ms,sigma_w_ms,uw_m2s2".split(","))
        w.writerows([[r[0], r[1]] + [round(x, 4) for x in r[2:]] for r in out])
    print(len(out), "строк")


if __name__ == "__main__":
    selftest() if "--selftest" in sys.argv else main()
