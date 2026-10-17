"""AWW-2 (копия AWW-1): сводка прогонов probe → starts.csv (контракт W1 v1) и diag_calc.json (фазы, профиль, MOST).
Запуск: python3 summary.py <метка>=<variant> [<метка>=<variant> …]
  python3 summary.py main=main aww2=AWW-2 > starts.csv
Строки: 8 встроенных стартов (погода старта, файл …_start.json) и Онгудай/Аскарово в два дня (…_weak / …_strong,
погода — ключи запуска run.sh).
Теория (diag.csv): лог-закон u10/u100 по z0 столбца окна 50 м; МОСТ (Businger–Dyer, Paulson 1970) с L из H и u*
столбца; σ_u = u*(12 + 0,5 z_i/|L|)^{1/3} (Panofsky et al. 1977) и 0,6 w*; порыв ≈ U + 3σ_u (60 с, 600 отсчётов).
"""
import csv
import json
import math
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
G, TH0, RHO_CP, KAPPA = 9.81, 300.0, 1206.0, 0.4
W1 = ("variant,place,site,wind_ms,hour,sky,u2,u10,u50,u100,dir10_deg,r10_100,theta_ml_K,frozen_frac,w_mean10,w_max10,"
      "sigma_u10,gust_max10,zi_m,cloud_base_m,cloud_frac,therm_n,therm_w300,wave_w1500").split(",")
SITES = [("training_island", "ridge_west"), ("training_island", "thermal_plain"), ("training_island", "landing_hill"),
         ("training_island", "lee_bowl"), ("volcano_island", "east_cliffs"), ("volcano_island", "crater_ridge"),
         ("volcano_island", "thermal_slope"), ("volcano_island", "plateau_landing")]
DAYS = {"weak": {"wind_speed_ms": 2.0, "start_hour": 12.0, "sky": "clear"},
        "strong": {"wind_speed_ms": 5.0, "start_hour": 12.0, "sky": "partly"}}
RUNS = [(p, s, "start") for p, s in SITES] + [
    (p, s, day) for p, s in (("ongudai", "kayancha_south"), ("askarovo", "biyagoda_west"), ("askarovo", "biyagoda_east"))
    for day in ("weak", "strong")]


def load(path):
    s = path.read_text(encoding="utf-8")
    s = re.sub(r"(?<![\w.])(-?)(nan|inf)\b", lambda m: ("-" if m.group(1) else "") + ("NaN" if m.group(2) == "nan" else "Infinity"), s)
    return json.loads(s)


def weather(place, site):
    d = json.loads((HERE.parents[3] / "configs" / "locations" / f"{place}.json").read_text(encoding="utf-8"))
    for s in d.get("start_sites", []):
        if s.get("id") == site:
            return s["weather"]
    return {}


def from_deg(vx, vz):
    # x — восток, −z — север; «откуда» — противоположно вектору
    e, n = vx, -vz
    return (math.degrees(math.atan2(e, n)) + 180.0) % 360.0


def fmt(v, nd=3):
    if v is None or (isinstance(v, float) and not math.isfinite(v)):
        return ""
    if isinstance(v, float):
        return f"{v:.{nd}f}"
    return str(v)


def psi_m(zeta):
    if zeta >= 0:
        return -5.0 * zeta
    x = (1 - 16 * zeta) ** 0.25
    return 2 * math.log((1 + x) / 2) + math.log((1 + x * x) / 2) - 2 * math.atan(x) + math.pi / 2


def most_ratio(z0, L, z1=10.0, z2=100.0):
    f = lambda z: math.log(z / z0) - psi_m(z / L)
    return f(z1) / f(z2)


def row_of(d, variant, place, site, day="start"):
    w = DAYS[day] if day in DAYS else weather(place, site)
    c = d["column"]
    rows = {r["agl"]: r for r in c["rows"]}
    m10 = rows[10.0]["mean"]
    u2, u10, u50, u100 = (rows[a]["mean_h"] for a in (2.0, 10.0, 50.0, 100.0))
    ground = c["ground"]
    zi_msl = c["z_i_msl"].get("dx400")
    zi = zi_msl - ground if zi_msl is not None and math.isfinite(zi_msl) else None
    # θ′ слоя перемешивания области над стартом: dx400 на середине слоя (не ниже 300 м)
    th = None
    if zi:
        zmid = max(300.0, 0.5 * zi)
        best = min(rows, key=lambda a: abs(a - zmid))
        lv = rows[best].get("levels", {}).get("dx400")
        th = lv[4] if lv else None
    li = d.get("last_info", {})
    ff = li.get("frozen_frac")
    s10 = d["series"]["10.0"]
    ar = d["around"]
    cb = ar.get("cloud_at_start")
    cloud_base = cb[1] if cb and cb[0] > 0 else None
    out = {
        "variant": variant, "place": place, "site": site, "wind_ms": w.get("wind_speed_ms"), "hour": w.get("start_hour"),
        "sky": w.get("sky"), "u2": u2, "u10": u10, "u50": u50, "u100": u100, "dir10_deg": from_deg(m10[0], m10[1]),
        "r10_100": u10 / u100 if u100 > 0 else None, "theta_ml_K": th, "frozen_frac": ff,
        "w_mean10": s10["w"]["mean"], "w_max10": s10["w"]["max"], "sigma_u10": s10["along"]["std"],
        "gust_max10": s10["h"]["max"], "zi_m": zi, "cloud_base_m": cloud_base,
        "cloud_frac": ar["cloud_frac"] if ar["cloud_frac"] >= 0 else None, "therm_n": ar["therm_n"],
        "therm_w300": ar["therm_w300"] if ar["therm_n"] > 0 else None, "wave_w1500": ar["wave_w1500"],
    }
    # диагностика
    ph = d.get("phase", {})
    st = ph.get("stats", {})
    cs = ph.get("case", {})
    ws = ph.get("weights_at_start", {})
    t10 = c.get("turb10") or [None] * 9
    z0w = c["z0"].get("dx50") or c["z0"].get("dx100") or c["z0"].get("dx400")
    z0d = c["z0"].get("dx400")
    H = cs.get("heat_start_wm2")
    ust = t10[2]
    wst = t10[6]
    L = None
    if H and ust and abs(H) > 1e-3:
        L = -ust ** 3 * TH0 / (KAPPA * G * (H / RHO_CP))
    r_log = math.log(10 / z0w) / math.log(100 / z0w) if z0w else None
    r_most = most_ratio(z0w, L) if (z0w and L) else None
    sig_th = None
    if ust is not None and zi:
        zil = (zi / abs(L)) if L and L < 0 else 0.0
        sig_th = ust * (12 + 0.5 * zil) ** (1 / 3)
    diag = {
        "u10_menu": w.get("wind_speed_ms"), "u300": rows[300.0]["mean_h"], "u1000": rows[1000.0]["mean_h"],
        "u10_dx400": (lambda l: math.hypot(l[0], l[1]) if l else None)(rows[10.0].get("levels", {}).get("dx400")),
        "u100_dx400": (lambda l: math.hypot(l[0], l[1]) if l else None)(rows[100.0].get("levels", {}).get("dx400")),
        "u10_dx50": (lambda l: math.hypot(l[0], l[1]) if l else None)(rows[10.0].get("levels", {}).get("dx50")),
        "u100_dx50": (lambda l: math.hypot(l[0], l[1]) if l else None)(rows[100.0].get("levels", {}).get("dx50")),
        "theta1_dx50": (lambda l: l[4] if l else None)(rows[1.0].get("levels", {}).get("dx50")),
        "theta1_dx400": (lambda l: l[4] if l else None)(rows[1.0].get("levels", {}).get("dx400")),
        "z0_w50": z0w, "z0_dx400": z0d, "z0_case": cs.get("z0"), "alpha": cs.get("alpha"), "u_sat": cs.get("u_a"),
        "ustar_case": cs.get("ustar"), "h_bl_start": cs.get("h_bl_start"), "H_start_wm2": H,
        "fr": st.get("fr"), "n_bv": st.get("n_bv"), "u_over_n": st.get("u_over_n"), "w_h": st.get("w_h_case"),
        "w_d_strong": st.get("w_d_strong"), "full_mech": st.get("full_mech"), "wstar_f": st.get("wstar_f"),
        "wstar_max": st.get("wstar_max"), "iters": li.get("iters"), "win_iters": [x.get("iters") for x in li.get("windows", [])],
        "win_status": [x.get("status") for x in li.get("windows", [])], "nonconv": li.get("nonconv_fallback"),
        "not_converged": li.get("not_converged"), "inflow_k": li.get("inflow_k"),
        "pf": {k: round(v, 3) for k, v in (li.get("phase_frac") or {}).items()},
        "w_start": {k: round(v, 3) for k, v in ws.items()},
        "ustar10": ust, "wstar10": wst, "hmix10": t10[7], "L": L, "r_log": r_log, "r_most": r_most,
        "sigma_u_theory": sig_th, "sigma_u_conv": 0.6 * wst if wst else None, "gust_theory": (u10 + 3 * sig_th) if sig_th else None,
        "h_mean10": s10["h"]["mean"], "along_mean10": s10["along"]["mean"], "sigma_w10": s10["w"]["std"],
        "s2": {k: round(d["series"]["2.0"][k]["std"], 3) for k in ("w", "along")},
        "s50": {k: round(d["series"]["50.0"][k]["std"], 3) for k in ("w", "along")},
        "gust_max2": d["series"]["2.0"]["h"]["max"], "gust_max50": d["series"]["50.0"]["h"]["max"],
    }
    return out, diag


def main():
    args = [a for a in sys.argv[1:] if "=" in a]
    mode = "calc"
    if "--mode" in sys.argv:
        mode = sys.argv[sys.argv.index("--mode") + 1]
    w = csv.writer(sys.stdout, lineterminator="\n")
    w.writerow(W1)
    diags = []
    for a in args:
        tag, variant = a.split("=", 1)
        for place, site, day in RUNS:
            p = HERE / "out" / tag / f"{place}_{site}_{day}.json"
            if not p.exists():
                print(f"нет {p}", file=sys.stderr)
                continue
            d = load(p)
            if not d.get("field_on", False):
                print(f"{p}: поле выключено (аналитика) — строка пропущена", file=sys.stderr)
                continue
            r, dg = row_of(d, variant, place, site, day)
            w.writerow([fmt(r[k]) for k in W1])
            diags.append({**{k: r[k] for k in ("variant", "place", "site")}, "day": day, **dg})
    with (HERE / f"diag_{mode}.json").open("w", encoding="utf-8") as f:
        json.dump(diags, f, ensure_ascii=False, indent=1, default=str)


if __name__ == "__main__":
    main()
