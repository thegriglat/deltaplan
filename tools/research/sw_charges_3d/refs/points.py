"""SWD-1: определения точек (мачты, синтетические точки Пикара, опорная точка, разрезы) для трёх случаев.

Только данные и рельеф — без Пикара: те же определения читают make_refs.py (расчёт по полю Пикара) и сборка points.json.
Интерпретатор — tools/research/sw_charges_3d/py. Модули случаев (cases/askervein.py, cases/perdigao.py) не меняются.
"""
from __future__ import annotations

import csv
import math
import sys
from functools import lru_cache
from pathlib import Path

import numpy as np
from scipy import ndimage
from scipy.ndimage import map_coordinates

HERE = Path(__file__).resolve().parent
RES = HERE.parents[1]                       # tools/research
ROOT = RES.parents[1]
sys.path.insert(0, str(RES / "cases"))
import askervein as AK     # noqa: E402
import perdigao as PD      # noqa: E402

DATA = RES / "data"
CASES = {
    "ASK_TU03B": dict(mod="ask", sub="tu03b"),
    "PERD_NE": dict(mod="pd", sub="ne"),
    "PERD_SW": dict(mod="pd", sub="sw"),
}
Z_SYN = (10.0, 20.0, 50.0, 100.0, 200.0, 300.0)      # уровни синтетических точек Пикара (контракт: обязательны 10, 50, 300)
Z_LEVELS = (2, 5, 10, 20, 30, 50, 75, 100, 150, 200, 300)
SMOOTH_M = 40.0                                       # σ сглаживания линии рельефа при поиске гребней/дна (как в 2D)
ROTOR_U, ROTOR_Z, ROTOR_LMIN = -0.5, 15.0, 50.0

RS_ASK = AK.RS
HT_ASK = AK.HT
ASK_FILE = DATA / "askervein/askervein_validation1.txt"
RS_NORM_10M = 8.895                                   # м/с, RS AES gill 10 м (в файле данных)


def wind_from(case):
    return AK.WDIR if case == "ASK_TU03B" else PD.case_inputs(CASES[case]["sub"])["wdir"]


def wind_to(case):
    a = math.radians(wind_from(case))
    return -math.sin(a), -math.cos(a)


# ---------------------------------------------------------------- растр рельефа SWD1
@lru_cache(maxsize=None)
def terrain_raster(case):
    """x, y (центры), z (асл), z0, dx, source, smoothing — растр до блочного осреднения Пикара."""
    if case == "ASK_TU03B":
        x0, y0, n, hc = AK.terrain(10.0, 4000.0)
        x = x0 + (np.arange(n) + 0.5) * 10.0
        y = y0 + (np.arange(n) + 0.5) * 10.0
        z = hc.astype("f4")
        z0 = np.full(z.shape, AK.NOM["z0"], "f4")
        return dict(x=x, y=y, z=z, z0=z0, dx=10.0,
                    source="WAsP-изолинии askervein_elevation-roughness.map (Zenodo 4095052, CC BY 4.0), треугольная "
                           "интерполяция, блочное среднее 10 м (air3d/askervein.py terrain(10, 4000)); z0 = 0,03 м (Taylor & Teunissen 1987)",
                    smoothing="нет")
    T = PD._terrain10(6000)
    tree = np.clip(T["tree"], 0, 1)
    z = (T["dsm"] + PD.D_DISP * tree).astype("f4")
    z0 = np.exp(tree * math.log(PD.Z0_FOREST) + (1 - tree) * math.log(PD.Z0_OPEN)).astype("f4")
    return dict(x=np.asarray(T["x"]), y=np.asarray(T["y"]), z=z, z0=z0, dx=10.0,
                source="Copernicus GLO-30 DSM (10 м, cases/perdigao/out/terrain10.npz) + смещение под пологом d = 0,7·h_c = "
                       f"{PD.D_DISP:.1f} м × доля леса ESA WorldCover 2021 (как perdigao.terrain); z0 = exp(f ln 1,8 + (1−f) ln 0,1) по доле леса клетки "
                       f"(в прогоне Пикара — скаляр {PD.z0_nominal():.3f} м)",
                    smoothing="нет")


def ground_at(case, x, y):
    R = terrain_raster(case)
    x = np.asarray(x, float)
    y = np.asarray(y, float)
    fi = np.atleast_1d((x - R["x"][0]) / R["dx"])
    fj = np.atleast_1d((y - R["y"][0]) / R["dx"])
    r = map_coordinates(R["z"], [fj, fi], order=1, mode="nearest")
    return r if x.ndim else r[0]


# ---------------------------------------------------------------- гребни (как panels_exp/common.py, SWC-12)
def find_crests(x, z, prom_min=60.0, win=100.0):
    dx = x[1] - x[0]
    w = max(1, int(win / dx))
    out = []
    for i in range(w, len(x) - w):
        if z[i] < z[i - w:i + w + 1].max() or z[i] <= z[i - 1]:
            continue
        j = i
        while j > 0 and z[j - 1] <= z[i]:
            j -= 1
        lm = z[j:i + 1].min()
        k = i
        while k < len(x) - 1 and z[k + 1] <= z[i]:
            k += 1
        rm = z[i:k + 1].min()
        if z[i] - max(lm, rm) >= prom_min:
            out.append(i)
    res = []
    for i in out:
        if not res or x[i] - x[res[-1]] > 3 * win:
            res.append(i)
    return res


def rows_ask():
    return list(csv.DictReader(open(ASK_FILE)))


def frame(case):
    ex, ey = wind_to(case)
    return ex, ey, ey, -ex          # e вдоль ветра (на), a поперёк


def box(case):
    """Внутренность области Пикара без боковой губки (x0, x1, y0, y1)."""
    mod = AK if case == "ASK_TU03B" else PD
    geo = mod.geometry()
    sub = CASES[case]["sub"]
    if case == "ASK_TU03B":
        x0, y0, n, _ = AK.terrain(AK.DX_NOM, geo["L"])
    else:
        x0, y0, n, _ = PD.terrain(PD.DX_NOM, geo["L"])
    sp = geo["sponge_side"]
    L = n * (AK.DX_NOM if case == "ASK_TU03B" else PD.DX_NOM)
    return x0 + sp, x0 + L - sp, y0 + sp, y0 + L - sp


# ---------------------------------------------------------------- геометрия случая и классификация
@lru_cache(maxsize=None)
def geom(case):
    ex, ey, ax, ay = frame(case)
    if case == "ASK_TU03B":
        zr = float(ground_at(case, *RS_ASK))
        zh = float(ground_at(case, *HT_ASK))
        sh = HT_ASK[0] * ex + HT_ASK[1] * ey
        return dict(kind="hill", s_c=sh, z_rs=zr, z_ht=zh, t_line=HT_ASK[0] * ax + HT_ASK[1] * ay)
    sub = CASES[case]["sub"]
    t_line = {"ne": -100.0, "sw": 130.0}[sub]
    s = np.arange(-2800.0, 2800.1, 10.0)
    px, py = t_line * ax + s * ex, t_line * ay + s * ey
    zl = ndimage.gaussian_filter1d(ground_at(case, px, py).astype(float), SMOOTH_M / 10.0, mode="nearest")
    cr = sorted(s[i] for i in find_crests(s, zl, 60.0))
    c1, c2 = cr[0], cr[1]
    m = (s > c1) & (s < c2)
    xv = float(s[m][np.argmin(zl[m])])
    return dict(kind="ridges", t_line=t_line, c1=float(c1), c2=float(c2), xv=xv, s=s, z=zl)


def classify(case, x, y):
    ex, ey, ax, ay = frame(case)
    g = geom(case)
    s = x * ex + y * ey
    if g["kind"] == "hill":
        h = (float(ground_at(case, x, y)) - g["z_rs"]) / (g["z_ht"] - g["z_rs"])
        if h >= 0.85:
            return "crest"
        if s < g["s_c"]:
            return "windward" if h > 0.12 else "upstream"
        return "lee" if h > 0.12 else "valley"
    c1, c2, xv = g["c1"], g["c2"], g["xv"]
    if abs(s - c1) < 150 or abs(s - c2) < 150:
        return "crest"
    if s < c1 - 600:
        return "upstream"
    if s < c1:
        return "windward"
    if s < xv - 150:
        return "lee"
    if s < xv + 150:
        return "valley"
    if s < c2:
        return "windward"
    return "lee"


# ---------------------------------------------------------------- синтетические положения (по типам)
def synthetic(case):
    """{point: (x, y, описание)} — по одному положению каждого типа на линии через опорный гребень/вершину вдоль ветра."""
    ex, ey, ax, ay = frame(case)
    g = geom(case)
    b = box(case)
    inb = lambda x, y: b[0] + 30 <= x <= b[1] - 30 and b[2] + 30 <= y <= b[3] - 30
    if g["kind"] == "hill":
        t0 = g["t_line"]
        s_c = g["s_c"]
        s = np.arange(-2500.0, 2500.1, 10.0) + s_c
    else:
        t0 = g["t_line"]
        s_c = g["c1"]
        s = np.arange(-1500.0, 2500.1, 10.0) + s_c
    px, py = t0 * ax + s * ex, t0 * ay + s * ey
    ok = np.array([inb(a, b_) for a, b_ in zip(px, py)])
    z = ndimage.gaussian_filter1d(ground_at(case, px, py).astype(float), SMOOTH_M / 10.0, mode="nearest")
    ic = int(np.argmin(np.abs(s - s_c)))
    if g["kind"] == "ridges":
        ic = int(np.argmax(np.where((s > s_c - 100) & (s < s_c + 100), z, -1e9)))
    zc = z[ic]
    # опорные высоты
    iu = int(np.argmin(np.abs(s - (s_c - 1500.0)))) if ok[np.argmin(np.abs(s - (s_c - 1500.0)))] else int(np.argmax(ok))
    zu = z[iu]
    up = np.arange(iu, ic + 1)
    iw = int(up[np.argmax(z[up] >= zu + 0.5 * (zc - zu))])
    dn = np.arange(ic, len(s))
    dn = dn[ok[dn]]
    if g["kind"] == "ridges":
        dn = dn[s[dn] <= g["xv"] + 1.0]
        iv = int(dn[np.argmin(z[dn])])
    else:
        iv = int(dn[np.argmin(z[dn])])
    zv = z[iv]
    il = int(dn[np.argmax(z[dn] <= zc - 0.5 * (zc - zv))])
    out = {}
    for name, i in (("upstream", iu), ("windward", iw), ("crest", ic), ("lee", il), ("valley", iv)):
        out[name] = dict(x=float(px[i]), y=float(py[i]), s=float(s[i]), ground=float(z[i]),
                         in_box=bool(ok[i]))
    return out


# ---------------------------------------------------------------- опорная точка и мачты
def norm_point(case):
    if case == "ASK_TU03B":
        return dict(name="RS", x=RS_ASK[0], y=RS_ASK[1], z_agl=10.0, speed=RS_NORM_10M,
                    source="опорная мачта RS (Taylor & Teunissen 1987), AES gill uvw 10 м, S = 8,895 м/с (askervein_validation1.txt)")
    sub = CASES[case]["sub"]
    ci = PD.case_inputs(sub)
    m = PD.masts()[ci["ref"]]
    return dict(name=ci["ref"], x=m["x"], y=m["y"], z_agl=100.0, speed=ci["u100"],
                source=f"{ci['ref']} 100 м — мачта ISFS на гребне наветренной гряды (в perdigao.py CASES ref); U100 окна "
                       f"{PD.CASES[sub]['window'][0]}–{PD.CASES[sub]['window'][1]} UTC = {ci['u100']:.2f} м/с")


def _ask_rs_speeds():
    out = {}
    for r in rows_ask():
        if r["Name"] == "RS":
            out.setdefault(float(r["H(m)"]), float(r["S(m/s)"]))
    # на 10 м — gill (первая строка), порядок файла
    return out


def masts_ask():
    rs = _ask_rs_speeds()
    seen = {}
    out = []
    for r in rows_ask():
        try:
            S = float(r["S(m/s)"])
            h = float(r["H(m)"])
        except ValueError:
            continue
        if S <= 0 or h < 2.0:
            continue
        x, y = float(r["X(m)"]), float(r["Y(m)"])
        name = r["Name"]
        key = (name, h)
        seen[key] = seen.get(key, 0) + 1
        nm = name if seen[key] == 1 else f"{name}#{seen[key]}"
        fmin, fmax = float(r["FSRmin"]), float(r["FSRmax"])
        fsr = float(r["FSR"])
        err = None
        if fmin > -900 and fmax > -900 and fsr > -900:
            err = max(fmin, fmax) / (1.0 + fsr)
        dS = (S / rs[h] - 1.0) if h in rs else None
        if h == 10.0 and fsr > -900:
            dS = fsr          # опубликованный FSR (RS того же прогона; от S/8,895 − 1 отличается до 0,06)
        out.append(dict(case="ASK_TU03B", name=nm, x=x, y=y, z_agl=h, speed=S, u=None, v=None, w=None, dS=dS,
                        ref_err=err, point=classify("ASK_TU03B", x, y),
                        ref_source=f"askervein_validation1.txt: {r['Sensor'].strip()}, Zenodo 4095052 (Taylor & Teunissen 1983/85); "
                                   f"линия по имени ({name}), смещения от линии нет (координаты мачты в файле)"
                                   + ("; dS — FSR опубл. (RS своего прогона; s_norm = S/8,895, расхождение до 0,06)" if h == 10.0 and fsr > -900 else ""),
                        ref_reliability="измерение", sensor=r["Sensor"].strip()))
    return out


def masts_pd(case):
    sub = CASES[case]["sub"]
    c = PD.CASES[sub]
    ms = PD.masts()
    ex, ey, ax, ay = frame(case)
    g = geom(case)
    out = []
    for r in PD._csv(PD.DATA / f"cases/{c['file']}_windowmean.csv"):
        if r["spd"] == "" or r["site"] not in ms:
            continue
        z = int(float(r["z_agl_m"]))
        if z < PD.MIN_Z_TOWER or int(r["n_5min"]) < 6:
            continue
        m = ms[r["site"]]
        spd = float(r["spd"])
        d = math.radians(float(r["dir_deg"]))
        u, v = -spd * math.sin(d), -spd * math.cos(d)
        w = float(r["w"]) if r["w"] != "" else None
        st, _ = PD._ratio_sigma(sub, r["site"], z, "S")
        st = 0.0 if math.isnan(st) else st
        ref = PD.case_inputs(sub)["u100"]
        rr = spd / ref
        err = math.sqrt(st ** 2 + (PD.SIG_REP * rr) ** 2 + PD.SIG_FLOOR ** 2) / rr
        tm = m["x"] * ax + m["y"] * ay - g["t_line"]
        out.append(dict(case=case, name=r["site"], x=m["x"], y=m["y"], z_agl=float(z), speed=spd, u=u, v=v, w=w, dS=None,
                        ref_err=err, point=classify(case, m["x"], m["y"]),
                        ref_source=f"ISFS NCAR/EOL doi:10.26023/ZDMJ-D1TY-FG14, cases/{c['file']}_windowmean.csv "
                                   f"(окно {c['window'][0]}–{c['window'][1]} UTC); мачта в {tm:+.0f} м от линии гребней (t_line {g['t_line']:+.0f} м, поперёк ветра)",
                        ref_reliability="измерение", sensor="ISFS sonic"))
    return out


def masts(case):
    return masts_ask() if case == "ASK_TU03B" else masts_pd(case)


# ---------------------------------------------------------------- разрезы
def transects(case):
    ex, ey, ax, ay = frame(case)
    out = []
    if case == "ASK_TU03B":
        g = geom(case)
        b = box(case)
        for name, s0, s1, src in (("wind_HT", -1000.0, 450.0, "линия вдоль ветра 210° через вершину HT; вниз по потоку до границы внутренности области (боковая губка 700 м)"),):
            ss = (HT_ASK[0] * ex + HT_ASK[1] * ey)
            tt = HT_ASK[0] * ax + HT_ASK[1] * ay
            out.append(dict(case=case, name=name, x0=tt * ax + (ss + s0) * ex, y0=tt * ay + (ss + s0) * ey,
                            x1=tt * ax + (ss + s1) * ex, y1=tt * ay + (ss + s1) * ey, source=src))
        rows = rows_ask()
        for ln, pref in (("A", ("ASW", "ANE")), ("AA", ("AASW", "AANE")), ("B", ("BSE", "BNW"))):
            P = np.array([(float(r["X(m)"]), float(r["Y(m)"])) for r in rows
                          if r["Name"].startswith(pref) and r["Name"][-1].isdigit()])
            if ln == "A":
                P = np.vstack([P, HT_ASK])
            c0 = P.mean(axis=0)
            vt = np.linalg.svd(P - c0)[2][0]
            d = (P - c0) @ vt
            p0, p1 = P[np.argmin(d)], P[np.argmax(d)]
            out.append(dict(case=case, name=f"line_{ln}", x0=float(p0[0]), y0=float(p0[1]), x1=float(p1[0]), y1=float(p1[1]),
                            source=f"линия мачт {ln}: крайние точки в askervein_validation1.txt"))
        return out
    for off in PD.SECTION_OFFSETS:
        nm = f"sec{off:+.0f}"
        out.append(dict(case=case, name=nm, x0=off * ax - 1500 * ex, y0=off * ay - 1500 * ey,
                        x1=off * ax + 1500 * ex, y1=off * ay + 1500 * ey,
                        source="разрез вдоль ветра через центр области (сдвиг вдоль гряды "
                               f"{off:+.0f} м, как perdigao.zone_metrics)" + (" — центральный" if off == 0 else "")))
    g = geom(case)
    t = g["t_line"]
    out.append(dict(case=case, name="mast_line", x0=t * ax - 2700 * ex, y0=t * ay - 2700 * ey, x1=t * ax + 2700 * ex,
                    y1=t * ay + 2700 * ey, source="линия через мачты гребней (t_line как в panels_exp/run_case.py), вдоль ветра"))
    # разрезы Menke 2019: положение WS105 в данных не задано — условно по сдвигам -500, 0, +500 м (порядок неизвестен)
    for k, off in enumerate(PD.SECTION_OFFSETS, 1):
        out.append(dict(case=case, name=f"menke_T{k}", x0=off * ax - 1500 * ex, y0=off * ay - 1500 * ey,
                        x1=off * ax + 1500 * ex, y1=off * ay + 1500 * ey,
                        source=f"разрез {k} Menke et al. 2019 (ACP 19, 2713; menke2019/fig8_zones_approx.csv). Положение лидара "
                               f"WS105 в данных не задано — условно как sec{off:+.0f} (допущение, нумерация T1–T3 с сдвигами не сопоставлена)"))
    return out


def menke_ref(case):
    """Длины зоны по разрезам 1–3 Menke 2019 (Рис. 8) для направления подслучая: SW-случай — зоны за SW-грядой («SW»), NE — «NE»."""
    sub = CASES[case]["sub"]
    d = "SW" if sub == "sw" else "NE"
    rows = [r for r in PD._csv(DATA / "perdigao/menke2019/fig8_zones_approx.csv") if r["direction"] == d]
    return {int(r["transect"]): float(r["length_m"]) for r in rows}


if __name__ == "__main__":
    for c in CASES:
        print(c, {k: (round(v["x"]), round(v["y"]), v["in_box"]) for k, v in synthetic(c).items()}, "box", [round(b) for b in box(c)])
        ms_ = masts(c)
        from collections import Counter
        print(len(ms_), Counter(m["point"] for m in ms_))
