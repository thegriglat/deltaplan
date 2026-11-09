#!/usr/bin/env python3
"""Сборка lee_obs.csv (LTO v1) из данных в git: Perdigão (ISFS, окна случаев) и Askervein (TU03B).
Только stdlib. Запуск: python3 build_lee_obs.py   (из любого каталога)
Bolund не включён (источник недоступен, см. README). σ Perdigão — отдельным шагом (sigma_perdigao.py), если сервер жив.
"""
import csv, math, os
HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "..", "..", "data")
PD = os.path.join(DATA, "perdigao")
AV = os.path.join(DATA, "askervein")
MASTS = os.path.join(HERE, "..", "..", "cases", "perdigao", "out", "masts.csv")
COLS = ("site,case,station,x_m,z_m,H_m,xr_m,x_game,z_game,u_ref_ms,u_ref_def,sigma_u_ms,sigma_v_ms,"
        "sigma_w_ms,tke_m2s2,uw_m2s2,L_u_m,n,stab,source,reliability,note").split(",")
MAX_PERP = 500.0   # м; станции дальше от оси ветра через гребень в разрез не берём
rows = []


def f(v, nd=4):
    return "" if v is None else repr(round(v, nd))


def pd_case(case, wm_file, crest, floor, zl, win_note):
    masts = {r["name"]: r for r in csv.DictReader(open(MASTS))}
    ground = {n: float(m["ground_asl"]) for n, m in masts.items()}
    wm = list(csv.DictReader(open(os.path.join(PD, "cases", wm_file))))
    ref = next(r for r in wm if r["site"] == crest and r["z_agl_m"] == "100")
    uref, wdir = float(ref["spd"]), float(ref["dir_deg"])
    tdir = math.radians((wdir + 180) % 360)          # куда дует
    ex, ey = math.sin(tdir), math.cos(tdir)          # E, N
    cx, cy = float(masts[crest]["x"]), float(masts[crest]["y"])
    H = ground[crest] - ground[floor]
    skipped = set()
    for r in wm:
        s = r["site"]
        if s not in masts or not r["tke"]:
            continue
        dx, dy = float(masts[s]["x"]) - cx, float(masts[s]["y"]) - cy
        x, perp = dx * ex + dy * ey, dx * ey - dy * ex
        if abs(perp) > MAX_PERP:
            skipped.add(s); continue
        rows.append(dict(site="perdigao", case=case, station=f"{s}_{r['z_agl_m']}m", x_m=f(x + 0.0, 1).replace("-0.0", "0.0"), z_m=r["z_agl_m"],
            H_m=f(H, 1), xr_m="", x_game="", z_game="", u_ref_ms=f(uref, 3),
            u_ref_def=f"U100 (ультразвук, среднее по окну) наветренной гребневой мачты {crest}",
            sigma_u_ms="", sigma_v_ms="", sigma_w_ms="", tke_m2s2=f(float(r["tke"]), 4), uw_m2s2="", L_u_m="",
            n=r["n_5min"], stab=zl, source="NCAR/EOL ISFS 5-мин, doi:10.26023/ZDMJ-D1TY-FG14", reliability="A",
            note=f"{win_note}; ТКЭ=0.5(u'u'+v'v'+w'w') по 5-мин; ветер {wdir:.0f} град на {crest}100м; поперёк оси {perp:+.0f} м; "
                 f"высота земли {ground[s]:.0f} м над у.м. (гребень {ground[crest]:.0f}, дно {ground[floor]:.0f}); H=гребень-дно {floor}"))
    return skipped


def askervein():
    HT = (75387.0, 23735.0)
    flow = math.radians(30.0)                        # ветер 210 град -> дует на 30
    ex, ey = math.sin(flow), math.cos(flow)
    v = lambda s: None if float(s) <= -998 else float(s)
    inl = list(csv.DictReader(open(os.path.join(AV, "askervein_inlet1.txt"))))
    rs = {"AES tilted gill uvw": "A", "AES cups": "C"}
    rs_x = (74300 - HT[0]) * ex + (20980 - HT[1]) * ey
    uref = 8.895
    udef = "S на 10 м эталонной мачты RS (tilted gill), 8.895 м/с"
    for r in inl:
        sn, z = r["Sensor"], r["Z (m)"]
        su, sv, sw, uw, tk = (v(r[k]) for k in ("Sigma_u(m/s)", "Sigma_v(m/s)", "Sigma_w(m/s)", "uw(m^2/s^2)", "tke(m^2/s^2)"))
        if su is None and tk is None:
            continue
        rows.append(dict(site="askervein", case="TU03B", station=f"RS_{sn.replace(' ', '_')}_{z}m", x_m=f(rs_x, 0), z_m=z,
            H_m="116", xr_m="", x_game="", z_game="", u_ref_ms=repr(uref), u_ref_def=udef,
            sigma_u_ms=f(su), sigma_v_ms=f(sv), sigma_w_ms=f(sw), tke_m2s2=f(tk), uw_m2s2=f(uw), L_u_m="", n="1",
            stab="neutral", source="Taylor & Teunissen 1985; Zenodo 4095052 (CC BY 4.0), inlet1", reliability=rs.get(sn, "C"),
            note="наветренный профиль эталонной мачты RS (за 2.9 км до вершины); осреднение по прогону TU03B (период в Zenodo не дан); "
                 "у чашечных анемометров только sigma_u" if tk is None else
                 "наветренный профиль эталонной мачты RS; осреднение по прогону TU03B"))
    seen = {}
    for r in csv.DictReader(open(os.path.join(AV, "askervein_validation1.txt"))):
        if r["Name"] == "RS":
            continue
        tk = v(r["tke(m^2/s^2)"])
        if tk is None:
            continue
        dx, dy = float(r["X(m)"]) - HT[0], float(r["Y(m)"]) - HT[1]
        x, perp = dx * ex + dy * ey, dx * ey - dy * ex
        name = r["Name"].replace(" ", "").replace("(", "_").replace(")", "")
        sens = r["Sensor"].split()[0] + ("_gill" if "gill" in r["Sensor"] else "_" + r["Sensor"].split()[-1])
        st = f"{name}_{r['H(m)']}m"
        if st in seen:                               # второй блок файла (другая обработка) — отдельная станция
            st = f"{st}_{sens}"
        seen[st] = 1
        rel = "A" if "gill" in r["Sensor"] or "sonic" in r["Sensor"] else "B"
        rows.append(dict(site="askervein", case="TU03B", station=st, x_m=f(x, 0), z_m=r["H(m)"], H_m="116", xr_m="",
            x_game="", z_game="", u_ref_ms=repr(uref), u_ref_def=udef, sigma_u_ms="", sigma_v_ms="", sigma_w_ms="",
            tke_m2s2=f(tk, 4), uw_m2s2="", L_u_m="", n="1", stab="neutral",
            source="Taylor & Teunissen 1985; Zenodo 4095052 (CC BY 4.0), validation1", reliability=rel,
            note=f"x от вершины HT вдоль 210->30 град; поперёк {perp:+.0f} м; датчик {r['Sensor']}; S={r['S(m/s)']} м/с; "
                 f"FSR={r['FSR']}; высота земли {r['Z(m)']} м"))


if __name__ == "__main__":
    sk1 = pd_case("NE", "ne_20170427_windowmean.csv", "tse13", "tse09", "-0.089", "окно 17-19 UTC 2017-04-27 (2 ч, 24 пятиминутки); z/L - среднее часов 17,18 по tse04 100 м")
    sk2 = pd_case("SW", "sw_20170511_windowmean.csv", "tse04", "tse09", "-0.14", "окно 10 UTC 2017-05-11 (1 ч, 12 пятиминуток); z/L часа 10")
    askervein()
    sp = os.path.join(HERE, "sigma_perdigao.csv")          # есть, если sigma_perdigao.py отработал
    if os.path.exists(sp):
        sg = {(r["case"], r["station"]): r for r in csv.DictReader(open(sp))}
        for r in rows:
            g = sg.get((r["case"], r["station"])) if r["site"] == "perdigao" else None
            if g:
                for k in ("sigma_u_ms", "sigma_v_ms", "sigma_w_ms", "uw_m2s2"):
                    r[k] = g[k]
    with open(os.path.join(HERE, "lee_obs.csv"), "w", newline="") as fh:
        w = csv.DictWriter(fh, COLS, lineterminator="\n"); w.writeheader(); w.writerows(rows)
    print(len(rows), "строк; вне оси (>%d м):" % MAX_PERP, sorted(sk1), sorted(sk2))
