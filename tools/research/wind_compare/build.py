#!/usr/bin/env python3
"""Сборка самодостаточного HTML (plotly встроен) из out/<случай>_{main,air}.json.
python3 build.py <случай: base|saddle|mountain|…_strong|strong> [куда.html] [каталог air в out/, напр. am08v]"""
import json, sys, os
here = os.path.dirname(os.path.abspath(__file__))
case = sys.argv[1]
strong = case.endswith("strong")
kind = "base" if case == "strong" else case.replace("_strong", "")
pre = "" if case == "base" else case + "_"
dst = sys.argv[2] if len(sys.argv) > 2 else os.path.join(here, "out", "wind_compare_ongudai%s.html" % ("" if case == "base" else "_" + case))
air_dir = sys.argv[3] if len(sys.argv) > 3 else ""
D = {k: json.load(open(os.path.join(here, "out", air_dir if k == "air" else "", pre + k + ".json"))) for k in ("main", "air")}
g = D["main"]["grid"]
assert g == D["air"]["grid"] and D["main"]["ground"] == D["air"]["ground"]
c = D["main"]["cond"]
H = g["half"]
ce, cn = c.get("center_east", 0.0), c.get("center_north", 0.0)
ai = D["air"]["info"]
base = (
    f'<span class="hl">Условия одинаковы для обеих версий:</span> место Онгудай (старт {c["site"]}, {c["start_h"]:.0f} м), '
    f'лето, {c["hour"]:.0f}:00 местного, ветер {c["wind_ms_10m"]:g} м/с на 10 м у старта с {c["wind_from"]:g}° (встречный склону старта; '
    f'ветер дует на {(c["wind_from"]+180)%360:g}°, к ССЗ), погода {c["weather"]}, небо «{c["sky"]}» (прогрев для решателя), сид {c["seed"]}, '
    'порывы и термики выключены — осреднённое поле. Выборка — Atmosphere.air_velocity_at. ')
solver = (f'air-model: решатель на GPU ({ai["solver_wall_s"]:.1f} с), область 400 м (96×96 клеток) + окна 100 м и 50 м, '
          'окна строятся вокруг старта; main — аналитика (профиль + склоновый подъём + подветренная зона). ')
# покрытие окон (в координатах от старта; окна клипмапа берутся из выгрузки)
cover = ""
if "start_world" in c:
    sx, sz = c["start_world"]
    import numpy as np
    n = g["n"]
    ee, nn = np.meshgrid(-H + g["step"] * np.arange(n) + ce, -H + g["step"] * np.arange(n) + cn)
    parts = []
    for l in sorted(ai["levels"], key=lambda l: l["dx"]):
        e0, e1 = l["x0"] - sx, l["x0"] + l["nx"] * l["dx"] - sx
        n0, n1 = -(l["y0"] + l["ny"] * l["dx"] - sz), -(l["y0"] - sz)
        f = float(((ee >= e0) & (ee <= e1) & (nn >= n0) & (nn <= n1)).mean())
        parts.append(f'окно {l["dx"]:g} м (восток {e0:.0f}…{e1:.0f}, север {n0:.0f}…{n1:.0f} м от старта): {100*f:.0f} % точек')
    cover = "Покрытие точек выборки полями air-model — " + "; ".join(parts) + ". Вне окон 50 и 100 м ветер берётся из области 400 м. "
if kind == "base":
    title = "Ветер у старта Онгудая: main и air-model"
    extra = f'Область ±{H:g} м вокруг старта, шаг 100 м.'
    meta = dict(deflv=[20, 100, 400], dens=2, size=4, markers=[[0, 0, 0, "старт"]])
elif kind == "saddle":
    title = "Седловина у Онгудая: main и air-model"
    extra = (f'<span class="hl">Седловина:</span> (центр области: {ce:.0f} м восток, {cn:.0f} м север от старта; высота седла ≈1710 м, '
             'на ~160 м ниже старта; ось прохода 147°/327° — вдоль ветра; выбрана по рельефу detail 25 м, сглаженному σ=150 м; '
             'это неглубокая выемка на отроге: к ВСВ — склон к вершине над стартом (до 1830 м), к ЗЮЗ — спад, перепад вдоль ветра ≈190 м с наветренной и ≈340 м с подветренной стороны на 1,5 км. '
             'Классической пары вершин по обе стороны нет — «ближайшая подходящая»). ' + f'Область ±{H:g} м вокруг седла, шаг {g["step"]:g} м. ' + cover)
    meta = dict(deflv=[20, 50, 100], dens=1, size=9, markers=[[0, 0, D["main"]["ground"][(g["gn"] // 2) * g["gn"] + g["gn"] // 2], "седловина"]])
else:
    title = "Вся гора у Онгудая: main и air-model"
    extra = (f'Область ±{H:g} м вокруг старта (охватывает хребет со стартом, наветренное подножие — долина Урсула к ЮЮВ, подветренный склон к ССЗ), '
             f'шаг стрелок {g["step"]:g} м (клетка области решателя). Уровни AGL ' + ", ".join(str(k) for k in sorted(int(float(k)) for k in D["main"]["levels"])) + ' м. ' + cover)
    meta = dict(deflv=[100, 800], dens=1, size=2, markers=[[0, 0, 0, "старт"]])
if strong:
    title = "Сильный ветер: " + title
    extra += (' <span class="hl">Сильный ветер:</span> 9 м/с на 10 м (в меню игры максимум 12 м/с). Возвратное течение (ротор) у земли: в main — только эвристика '
              'подветренной зоны (линия тени от гребня), в air-model — решатель с собственной рециркуляцией в среднем поле плюс та же эвристика сверху.')
if air_dir:
    extra += (f' <span class="hl">air-model — после AM-08в ({air_dir}):</span> поверх поля обратный поток эвристики 0,22·U_H только там, '
              'где пузырь отрыва (2,8 превышения гребня) решателем не разрешён (меньше 8 клеток), рывки — только с болтанкой (здесь выключена).')
meta["cond_html"] = base + extra
meta["sum_note"] = solver
payload = {
    "meta": meta, "cond": c, "grid": g, "ground": D["main"]["ground"],
    "main": {L: v["air"] for L, v in D["main"]["levels"].items()},
    "air": {L: v["air"] for L, v in D["air"]["levels"].items()},
}
html = open(os.path.join(here, "template.html")).read()
html = html.replace("/*TITLE*/", title)
html = html.replace("/*PLOTLY*/", open(os.path.join(here, "plotly-3.0.1.min.js")).read()).replace("/*DATA*/", json.dumps(payload, separators=(",", ":")))
open(dst, "w").write(html)
print(dst, len(html) / 1e6, "МБ")
