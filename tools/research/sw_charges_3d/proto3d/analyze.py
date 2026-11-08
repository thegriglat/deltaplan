"""Сводка SWD8: out/proto3d/summary.json (+ .csv) и tables.md из a_*.json, c_*.json. Запуск: ./py -m proto3d.analyze"""
import csv, json, os, subprocess, datetime
import numpy as np
from . import screen

OUT = os.path.join(os.path.dirname(__file__), "..", "out", "proto3d")
J = lambda n: json.load(open(os.path.join(OUT, n)))
rows, timing, problems = [], [], []


def add(proto, case, metric, value, unit, ref, ref_kind, src, rel, ok, note=""):
    rows.append(dict(proto=proto, case=case, metric=metric, value=None if value is None else float(value), unit=unit,
                     ref=None if ref is None else float(ref), ref_kind=ref_kind, ref_source=src, ref_reliability=rel,
                     ok=None if ok is None else bool(ok), note=note))


def within(v, r, tol):
    return abs(v - r) <= tol * abs(r)


# ------------------------------------------------------------------ A
conv = J("a_conv.json")
blob = J("a_blob.json")
get = lambda case, U: next(r for r in blob if r["case"] == case and r["U"] == U)
sg = np.array([c["sg"] * c["h"] / 100.0 for c in conv]); ab = np.array([c["a_over_b"] for c in conv])
# σ→0: линейно по σ/R по трём точкам с σ/R < 0,2 (h = 12,5 и 9 при σ/h = 1,0 / 1,3 / 1,6)
m = sg < 0.21
cf = np.polyfit(sg[m], ab[m], 1)
a0 = float(cf[1])
THEORY_A = "Lamb, Hydrodynamics §92 (присоединённая масса шара ½ρV): a = b/(1+½) = 2b/3"
add("A", "flat", "a_центра/b, h = 9 м, σ = 11,7 м (самый мелкий)", ab[3], "1", 2 / 3, "theory", THEORY_A, "высокая", within(ab[3], 2 / 3, 0.2),
    "допуск ±20 %; сходится снизу при σ/R → 0")
add("A", "flat", "a_центра/b, экстраполяция σ/R → 0 (линейная по 4 точкам σ/R < 0,21)", a0, "1", 2 / 3, "theory", THEORY_A, "высокая", within(a0, 2 / 3, 0.1),
    "допуск ±10 %; экстраполяция, не прогон")
add("A", "flat", "импульс P_z / (∫b dV · t)", conv[3]["Pz_over_Bt"], "1", 1.0, "theory", "Кельвин: dI/dt = ∫b dV ẑ", "высокая", within(conv[3]["Pz_over_Bt"], 1, 0.03), "допуск ±3 %")
for t in ("60", "90"):
    s = get("flat", 0)["snaps"][t]; p = s["plane"]
    add("A", "flat", f"кольцо опускания ∫w⁻/∫w⁺ в плоскости центра, t = {t} с", p["neg"] / p["pos"], "1", 1.0, "theory",
        "нулевой чистый поток через плоскость; 2D A (SWC-13): 0,99–1,00", "высокая", within(p["neg"] / p["pos"], 1, 0.1), "допуск ±10 %, диск 6R")
s = get("flat", 0)["snaps"]["60"]["plane"]
add("A", "flat", "кольцо опускания: w_min/w_max, t = 60 с", s["wmin"] / s["wmax"], "1", -0.135, "game",
    "Гедеон в игре (docs/research/sw_charges/proto-c.md, шаг 1: глубина кольца −0,135); 2D A/C: −0,31", "модель игры", False,
    "в 3D кольцо в 1,5 раза глубже Гедеона (в 2D — 2,3 раза); допуск ±30 %")
for t in ("30", "60"):
    v = get("flat", 0)["snaps"][t]["inflow"][0]
    add("A", "flat", f"подтекание у земли (10 м) к термику на ρ = R, t = {t} с", v, "м/с", 0.24 if t == "30" else 0.42, "2d",
        "SWC-13 (плоская земля, 2D)", "модель", v > 0.1, "порог 0,1 м/с (2D); ref — 2D над плоской землёй")
fl60 = get("flat", 0)["dn"][59]
for case, U in [("hill_wind", 0), ("hill_foot", 0), ("perd", 0), ("hill_wind", 3), ("perd", 3), ("hill_lee", 3)]:
    r = get(case, U)
    for i, t in ((59, 60), (89, 90)):
        d = r["dn"][i] - get("flat", 0)["dn"][i]
        add("A", f"{case}_U{U}", f"Δd_n(t = {t} с) относительно плоского контроля", d, "м", 5.0, "2d",
            "SWC-13: отрыв, если Δd_n(60 с) > 5 м (в 1 из 8 опытов 2D)", "модель", d > 5.0,
            "ok = отрыв есть; " + ("отрицательно: термик прижат к склону" if d < 0 else "положительно" +
             ("; подветренный склон уходит вниз — рост d_n частично геометрия, не отрыв" if case == "hill_lee" else "")))
    add("A", f"{case}_U{U}", "подтекание (10 м), ρ = R, t = 60 с", r["snaps"]["60"]["inflow"][0], "м/с", 0.1, "2d", "порог SWC-13", "модель",
        r["snaps"]["60"]["inflow"][0] > 0.1, "")
    timing.append(dict(proto="A", case=f"{case}_U{U}", n_nodes=r["N_part"] + r["N_pan"], t_step_s=r["t_step_s"], t_run_s=r["wall_s"],
                       backend="cupy RTX 4070 SUPER f64"))
try:
    flux = J("a_flux.json")
except FileNotFoundError:
    flux = []
for r in flux:
    i = len(r["t"]) - 1
    w = r["wmax"][-1]
    add("A", f"flux_{r['case']}_T{int(r['T'])}_noise{r['noise']}", "скорость вдоль склона на 10 м у пятна в конце", w[2], "м/с", None, "2d",
        "анабатика: данных для порядка нет (подтекание 2D — другая величина)", "нет эксперимента", None,
        f"T = {int(r['T'])} с, H = 250 Вт/м², пятно R = 100 м; w_центра = {w[1]:.3f} м/с, w(10 м) = {w[3]:.3f}")
    add("A", f"flux_{r['case']}_T{int(r['T'])}_noise{r['noise']}", "высота центра плавучести над землёй (норм.) в конце", r["dn"][-1], "м", None, "2d", "—", "—", None,
        f"старт слоя ~12 м; отрыв = рост d_n на десятки метров. B(T) = {r['B'][-1]:.0f} м⁴/с²")
    timing.append(dict(proto="A", case=f"flux_{r['case']}_T{int(r['T'])}_n{r['noise']}", n_nodes=r["N"][-1] + r["N_pan"], t_step_s=r["t_step_s"],
                       t_run_s=r["wall_s"], backend="cupy RTX 4070 SUPER f64"))

flat400 = next((r for r in flux if r["case"] == "flat" and r["T"] > 200 and r["noise"] == 0.0), None)
for r in flux:
    if flat400 is not None and r["T"] > 200 and r["case"] != "flat":
        for t in (300, 400):
            i = int(t / (r["t"][1] - r["t"][0])) - 1
            d = r["dn"][i] - flat400["dn"][i]
            add("A", f"flux_{r['case']}_noise{r['noise']}", f"Δd_n(t = {t} с) нагретого слоя относительно плоского контроля (поток 250 Вт/м²)", d, "м", 5.0, "2d",
                "порог отрыва SWC-13: > 5 м", "модель", d > 5.0, f"d_n: склон {r['dn'][i]:.0f} м, плоско {flat400['dn'][i]:.0f} м; отрицательно — склон не отрывает раньше плоской земли")
    
# ------------------------------------------------------------------ C
neu = J("c_neutral.json")
GAME = "docs/guide/air-model/turbulence.md: σ_w = 1,25 u*(1−z/h)^¾ (нейтральная механическая); 2D C (SWC-7): ×1,53/1,73/1,74/1,35"
for r in neu:
    z = r["z"]
    add("C", "flat_neutral", f"σ_w / (1,25 u*), z = {z:g} м", r["ratio_sw"], "1", 1.0, "game", GAME, "модель игры (Panofsky–Dutton ±20 %)", within(r["ratio_sw"], 1, 0.3), "допуск ±30 %; u* = 0,4; 3 снимка")
    add("C", "flat_neutral", f"L_w / z, z = {z:g} м", r["Lw_over_z"], "1", 1.0, "game", "Карман L_w = z (docs/guide/air-model/turbulence.md); 2D C: 0,31–0,39", "модель", within(r["Lw_over_z"], 1, 0.3),
        "" if z < 100 else "z=120: 4 линии по 96 точек, шум велик")
    add("C", "flat_neutral", f"−⟨u'w'⟩/u*², z = {z:g} м", -r["uw_over_ust2"], "1", 1.0, "theory", "постоянный поток импульса в приземном слое; 2D C: 1,5–2,7 к игре", "высокая", within(-r["uw_over_ust2"], 1, 0.3), "допуск ±30 %")
    add("C", "flat_neutral", f"σ_u/σ_w, z = {z:g} м", r["su_over_sw"], "1", 1.92, "game", "MIL-HDBK-1797: σ_u:σ_w = 2,4:1,25", "модель", within(r["su_over_sw"], 1.92, 0.3), "кольца изотропны по u, w — граница")
    timing.append(dict(proto="C", case=f"neutral_z{z:g}", n_nodes=r["n_rings"] * 12, t_step_s=r["wall_s"] / 3, t_run_s=r["wall_s"], backend="cupy RTX 4070 SUPER f64"))
sens = J("c_sens.json")
for r in sens:
    add("C", "flat_neutral_sens", f"σ_w/(1,25 u*), z = 25 м, вариант {r['tag']}", r["ratio_sw"], "1", 1.0, "game", GAME, "модель", within(r["ratio_sw"], 1, 0.3),
        f"−⟨u'w'⟩/u*² = {-r['uw_over_ust2']:.2f}; L_w/z = {r['Lw_over_z']:.2f}; чувствительность, не подгонка")
th = J("c_thresh.json")
for zc in (30.0, 60.0):
    for r in th:
        if r["z_c"] == zc and r["fkind"] == "step" and r["z"] in (10, 20, 40, 80, 160):
            ok = (r["ratio_sw"] < 0.1) if r["Ri_z"] > 0.25 else None
            add("C", f"stable_zc{zc:g}", f"σ_w/(1,25 u*) на z = {r['z']:g} м (Ri(z) = {r['Ri_z']:.3f}), порог по Ri", r["ratio_sw"], "1",
                0.0 if r["Ri_z"] > 0.25 else None, "theory", "Майлс 1961, Говард 1961: Ri > 1/4 — устойчиво (нет рождения)", "высокая", ok,
                "ref 0 при Ri > ¼; без порога на тех же высотах ≈ 1,06")
cl = J("c_closure.json")
cK0 = cl[0]["cK"]
add("C", "closure_Ri0", "c_K = −⟨u'w'⟩/(ℓ²S²) при Ri = 0 (локально-однородный сдвиг)", cK0, "1", 1.0, "theory", "mixing-length: K = ℓ²S", "высокая", within(cK0, 1, 0.3), "")
add("C", "closure_Ri0", "κ_eff = κ √c_K (лог-слой газа колец при κ = 0,4)", 0.4 * np.sqrt(cK0), "1", 0.40, "field", "Högström 1996: κ = 0,40 ± 0,01 (Frenzen & Vogel 1995: 0,35–0,41)", "средняя", within(0.4 * np.sqrt(cK0), 0.4, 0.1), "допуск ±10 %")
for r in cl:
    add("C", "closure", f"c_K(Ri = {r['Ri']:.2f}) / c_K(0)", r["cK"] / cK0, "1", max(0.0, 1 - 4 * r["Ri"]), "theory", "F(Ri) = 1 − 4Ri заложено в рождение; в напряжении — после снижения числа и размера пар", "высокая", None,
        f"n колец {r['n_rings']}; c_σ = σ_w/(ℓS) = {r['c_sigma']:.2f}")
for N2 in (1e-4, 4e-4):
    for e in screen.equilibrium(N2):
        add("C", f"screen_N2_{N2:g}", f"равновесие экранировки: Ri_eq на z = {e['z']} м", e["Ri_eq"], "1", 0.25, "theory", "Миллер—Говард: поддержание у Ri ≈ ¼ (Galperin 2007)", "средняя", None,
            f"S_eq/S_log = {e['S_eq']/e['S_log']:.2f}; σ_w,eq/игра = {e['ratio_game']:.2f}; H = 300 м, τ = u*²(1−z/H)")
e0 = screen.equilibrium(0.0)
add("C", "screen_neutral", "S_eq/S_лог на z = 25 м (экранировка без стратификации)", e0[1]["S_eq"] / e0[1]["S_log"], "1", 1.0, "theory", "лог-слой: u*/(κz)", "высокая", within(e0[1]["S_eq"] / e0[1]["S_log"], 1, 0.1), "")
ter = J("c_terrain.json")
fl = next(t for t in ter if t["site"] == "flat")
for t in ter:
    add("C", f"hill_{t['site']}", "σ_w на 40 м над землёй / σ_w ровной земли", t["sigma_w"] / fl["sigma_w"], "1", t["S_zp"] / fl["S_zp"], "theory",
        "локальная шкала σ_w ∝ ℓ·S (S — из потенциального поля панелей + степенной профиль)", "модель", None,
        f"S_40 = {t['S_zp']:.4f} 1/с против {fl['S_zp']:.4f} (ровная); колец {t['n_rings']}; уклон {t['slope']:.2f}; ref = отношение S")

# ------------------------------------------------------------------ problems
fl_dn = {k: get(c, U)["dn"][59] - get("flat", 0)["dn"][59] for k, (c, U) in dict(ww=("hill_wind", 0), ft=("hill_foot", 0), pd=("perd", 0), ww3=("hill_wind", 3), pd3=("perd", 3)).items()}
sw_ratio = [r["ratio_sw"] for r in neu]
problems.append(dict(problem="№6", status="ушла",
    evidence=f"σ_w/(1,25 u*) на 10/25/60/120 м: {', '.join(f'{x:.2f}' for x in sw_ratio)} (2D C: 1,53/1,73/1,74/1,35); −⟨u'w'⟩/u* ² {-neu[1]['uw_over_ust2']:.2f}. "
             f"Оговорки: (1) кольцо диаметром d = ℓ (R_r = ℓ/2) — по аналогии с парой; при R_r = ℓ σ_w в {sens[2]['ratio_sw']:.1f} раза выше — выбор масштаба неподтверждён данными; "
             f"(2) кольца не взаимодействуют, анизотропии σ_u/σ_w нет; (3) эталон — формула игры, не измерение."))
fx = [r for r in flux if r["case"] == "hill_wind" and r["T"] > 200]
problems.append(dict(problem="№10", status="осталась",
    evidence=f"шар R = 100 м, Δθ = 1 К: Δd_n(60 с) относительно плоского контроля {fl_dn['ww']:+.1f} (середина склона, штиль), {fl_dn['ft']:+.1f} (подножие), {fl_dn['pd']:+.1f} (Perdigão), "
             f"с ветром 3 м/с {fl_dn['ww3']:+.1f} (наветренный склон Гаусса, прижат), {fl_dn['pd3']:+.1f} (Perdigão); порог отрыва +5 м не достигнут ни в одном штилевом опыте. "
             f"Нагрев склона потоком 250 Вт/м² (пятно R = 100 м, штиль): вдоль склона течёт (0,2 м/с на 10 м к 150 с, на плоской земле 0), слой отрывается через ≈ 250–300 с и на склоне, и на плоской земле; "
             f"Δd_n(300/400 с) склона относительно плоской земли {[round(x['dn'][74]-flat400['dn'][74],1) for x in fx][:1]}/{[round(x['dn'][99]-flat400['dn'][99],1) for x in fx][:1]} м — склон отрыв не ускоряет. "
             "Эксперимента для термика у склона нет; вовлечения нет (w до 4 м/с к 400 с завышена)."))

# ------------------------------------------------------------------ запись
git = subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
summary = {"format": "sw3d-proto", "version": 1, "git": git, "created": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
           "rows": rows, "timing": timing, "problems2d": problems}
with open(os.path.join(OUT, "summary.json.tmp"), "w", encoding="utf-8") as f:
    json.dump(summary, f, ensure_ascii=False, indent=1)
os.replace(os.path.join(OUT, "summary.json.tmp"), os.path.join(OUT, "summary.json"))
with open(os.path.join(OUT, "summary.csv"), "w", newline="", encoding="utf-8") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0].keys())); w.writeheader(); w.writerows(rows)
with open(os.path.join(OUT, "tables.md"), "w", encoding="utf-8") as f:
    f.write("# SWD-12: таблицы прототипов A/C в 3D\n\nИсточник — `summary.json` (контракт SWD8 v1). ok = в допуске из примечания; пусто — допуска нет.\n\n")
    f.write("| proto | постановка | метрика | значение | ед. | ref | ref_kind | ok | примечание |\n|---|---|---|---|---|---|---|---|---|\n")
    fm = lambda v: "—" if v is None else (f"{v:.3g}")
    for r in rows:
        f.write(f"| {r['proto']} | {r['case']} | {r['metric']} | {fm(r['value'])} | {r['unit']} | {fm(r['ref'])} | {r['ref_kind']} | {'' if r['ok'] is None else ('да' if r['ok'] else 'нет')} | {r['note']} |\n")
    f.write("\n## Время\n\n| proto | постановка | узлов | t_шага, с | t_прогона, с |\n|---|---|---|---|---|\n")
    for t in timing:
        f.write(f"| {t['proto']} | {t['case']} | {t['n_nodes']} | {t['t_step_s']:.3g} | {t['t_run_s']:.3g} |\n")
    f.write("\n## Проблемы 2D\n\n")
    for p in problems:
        f.write(f"- **{p['problem']}** — {p['status']}: {p['evidence']}\n")
print(len(rows), "строк;", len(timing), "замеров")
