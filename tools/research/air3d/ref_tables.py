"""Сводные таблицы эталона AM-01 из out/ref/*.json → out/ref/tables.md (CPU).

  ../heat_ca/.venv/bin/python ref_tables.py
"""
from __future__ import annotations

import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "out" / "ref"


def load(n):
    p = OUT / f"{n}.json"
    return json.loads(p.read_text()) if p.exists() else None


def f(x, n=2):
    if x is None:
        return "—"
    if isinstance(x, str):
        return x
    return f"{x:.{n}f}".replace(".", ",")


def pct(x):
    return "—" if x is None else f"{100 * x:.0f} %"


def cells(L):
    r = load("cells")
    if not r:
        return
    L.append("## Ветер × клетка (Онгудай, 12:00, ветер с 150° — в лоб старту, U10 — прогноз на 10 м)\n")
    L.append("| U10, м/с | нагрев | клетка | итог | итераций | время, с | подъём у старта, м/с | ветер 50 м над стартом | седловина 50 м | ∇·u СКО, 1/с | ∇·u·Δx/U | баланс тепла |")
    L.append("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for row in r["rows"]:
        for k, name in (("d400", "область 400"), ("d200", "область 200"), ("w100", "окно 100"), ("w50", "окно 50")):
            if k not in row:
                continue
            x = row[k]
            key = x.get("key", {})
            hb = x.get("heat", {})
            L.append(f"| {f(row['U10'], 0)} | {'да' if row['heat'] else 'нет'} | {name} | {x['status']} | {x['iters']} | {f(x['t_solve'], 1)} | "
                     f"{f(key.get('start_w200_max'))} | {f(key.get('start_speed50'))} | {f(key.get('saddle_speed50'))} | "
                     f"{x.get('div_rms', 0):.1e} | {x.get('div_rel', 0):.1e} | {('%.1e' % hb['rel']) if hb.get('rel') is not None else '—'} |")
    L.append("")


def windows(L):
    r = load("windows")
    if not r:
        return
    L.append(f"## Почему окна сходятся медленнее (Онгудай {r['hour']:g}:00, U10 = {r['U10']:g})\n")
    L.append("| вариант | итог | итераций | время, с | множитель невязки за итерацию | уровней V-цикла |")
    L.append("|---|---|---|---|---|---|")
    for x in r["rows"]:
        L.append(f"| {x['name']} | {x['status']} | {x['iters']} | {f(x['t'], 1)} | {f(x['rate'], 4) if x['rate'] else '—'} | {x['mg_levels']} |")
    L.append("")


def hours(L):
    r = load("hours")
    if not r:
        return
    L.append("## Часы старта (Онгудай, типовой ясный день, ветер с 150°)\n")
    L.append("| U10 | час | z_i, м н. м. | прогрев | область 400: итог/итер./с | окно 100: итог/итер./с | подъём у старта | w на 50 м над стартом | ветер 50 м | θ′ 50 м, К |")
    L.append("|---|---|---|---|---|---|---|---|---|---|")
    for x in r["hours"]:
        d, w, k = x["d400"], x["w100"], x["w100"]["key"]
        L.append(f"| {f(x['U10'], 0)} | {f(x['hour'], 0)} | {x['day']['z_i_msl']} | {f(x['day']['heat'])} | {d['status']}/{d['iters']}/{f(d['t_solve'], 1)} | "
                 f"{w['status']}/{w['iters']}/{f(w['t_solve'], 1)} | {f(k['start_w200_max'])} | {f(k['start_w50'])} | {f(k['start_speed50'])} | {f(k['start_th50'])} |")
    L.append("\n### Фоновый пересчёт через 15 игровых минут (от предыдущего поля)\n")
    L.append("| U10 | час → | область 400: холодный / тёплый с p / тёплый без p, итераций | время холодн./тёплый, с | окно 100: холодный / тёплый с p | время, с | изменение поля за 15 мин (w, отн. L2 / макс.) |")
    L.append("|---|---|---|---|---|---|---|")
    for x in r["recompute"]:
        d, w = x["d400"], x["w100"]
        ch = x["change_15min"]["w"]
        L.append(f"| {f(x['U10'], 0)} | {f(x['h0'])} → {f(x['h1'])} | {d['cold']} / {d['warm_p']} / {d['warm_nop']} | {f(d['t_cold'])} / {f(d['t_warm'])} | "
                 f"{w['cold']} / {w['warm_p']} | {f(w['t_cold'])} / {f(w['t_warm'])} | {pct(ch['rel'])} / {f(ch['max'])} |")
    L.append("")


def library(L):
    r = load("library")
    if not r:
        return
    L.append("## Библиотека: ближайшее поле и смесь двух ближайших против точного (12:00, до 600 м над землёй)\n")
    L.append("| что | цель | уровень | ближайшее: w отн. / макс., м/с | ближайшее: u отн. / макс. | смесь: w отн. / макс. | смесь: u отн. / макс. |")
    L.append("|---|---|---|---|---|---|---|")
    for x in r["rows"]:
        n, m = x["nearest"], x["mix"]
        what = f"направление (узлы 135°/180°), {x['U']:g} м/с, {x['d']:g}°" if x["kind"] == "dir" else f"сила (узлы {'0/3' if x['U'] < 3 else '3/6'} м/с), {x['U']:g} м/с"
        L.append(f"| {what} | доля {f(x['frac'])} | {'область 400' if x['level'] == 'd' else 'окно 100'} | {pct(n['w']['rel'])} / {f(n['w']['max'])} | "
                 f"{pct(n['u']['rel'])} / {f(n['u']['max'])} | {pct(m['w']['rel'])} / {f(m['w']['max'])} | {pct(m['u']['rel'])} / {f(m['u']['max'])} |")
    L.append("")


def weather(L):
    r = load("weather")
    if not r:
        return
    L.append("## Классы погоды против типового ясного дня (26 °C): отличие поля, до 600 м над землёй\n")
    L.append("| час | U10 | день | z_i, м | прогрев | область 400: w отн. / макс. | окно 100: w отн. / макс. | окно 100: u отн. / макс. | окно 100: θ′ макс., К |")
    L.append("|---|---|---|---|---|---|---|---|---|")
    for x in r["rows"]:
        L.append(f"| {f(x['hour'], 0)} | {f(x['U10'], 0)} | {x['t_max']:g} °C, {x['sky']} | {x['day']['z_i_msl']} | {f(x['day']['heat'])} | "
                 f"{pct(x['d400']['w']['rel'])} / {f(x['d400']['w']['max'])} | {pct(x['w100']['w']['rel'])} / {f(x['w100']['w']['max'])} | "
                 f"{pct(x['w100']['u']['rel'])} / {f(x['w100']['u']['max'])} | {f(x['w100']['th']['max'])} |")
    L.append("")


def aushkul(L):
    r = load("aushkul")
    if not r:
        return
    L.append("## Аушкуль (низкий хребет, старт ridge_west, 12:00, ветер с 273° — в лоб)\n")
    L.append("| U10 | нагрев | 400: итог/итер. | окно 100: итог/итер. | окно 50: итог/итер. | подъём у старта 100 / 50 м | ветер 50 м над стартом 100 / 50 м |")
    L.append("|---|---|---|---|---|---|---|")
    for x in r["rows"]:
        a, b = x["w100"]["key"], x["w50"]["key"]
        L.append(f"| {f(x['U10'], 0)} | {'да' if x['heat'] else 'нет'} | {x['d400']['status']}/{x['d400']['iters']} | {x['w100']['status']}/{x['w100']['iters']} | "
                 f"{x['w50']['status']}/{x['w50']['iters']} | {f(a['start_w200_max'])} / {f(b['start_w200_max'])} | {f(a['start_speed50'])} / {f(b['start_speed50'])} |")
    L.append("")


def adv(L):
    r = load("adv")
    if not r:
        return
    L.append("## Перенос 1-го против 2-го порядка (Онгудай 12:00; область 400, окна 100 и 50)\n")
    L.append("| U10 | порядок | итераций (400/100/50) | подъём у старта (400/100/50) | ветер 50 м (400/100/50) |")
    L.append("|---|---|---|---|---|")
    for x in r["rows"]:
        if "adv2" in x:
            k = x["key"]
            L.append(f"| {f(x['U10'], 0)} | {'2-й' if x['adv2'] else '1-й'} | {'/'.join(str(i) for i in x['iters'])} | "
                     f"{'/'.join(f(q['start_w200_max']) for q in k)} | {'/'.join(f(q['start_speed50']) for q in k)} |")
    L.append("\n| U10 | уровень | w: отн. / макс. | u: отн. / макс. | θ′: макс. |")
    L.append("|---|---|---|---|---|")
    for x in r["rows"]:
        if "diff_1vs2" in x:
            for lv, d in x["diff_1vs2"].items():
                L.append(f"| {f(x['U10'], 0)} | {lv} | {pct(d['w']['rel'])} / {f(d['w']['max'])} | {pct(d['u']['rel'])} / {f(d['u']['max'])} | {f(d['th']['max'])} |")
    L.append("")


def precision(L):
    r = load("precision")
    if not r:
        return
    L.append("## float32 против float64 (Онгудай 12:00, 3 м/с)\n")
    L.append("| уровень | w отн. / макс. | u отн. / макс. | θ′ макс. |")
    L.append("|---|---|---|---|")
    for lv, d in r["diff"].items():
        L.append(f"| {lv} | {d['w']['rel']:.1e} / {d['w']['max']:.1e} | {d['u']['rel']:.1e} / {d['u']['max']:.1e} | {d['th']['max']:.1e} |")
    L.append(f"\nИтераций f32 / f64: {r['float32']} / {r['float64']}.\n")


if __name__ == "__main__":
    L = ["# Таблицы эталона AM-01 (генерируются ref_tables.py из out/ref/*.json)\n"]
    for fn in (cells, windows, hours, library, weather, aushkul, adv, precision):
        fn(L)
    (OUT / "tables.md").write_text("\n".join(L))
    print("\n".join(L)[:3000])
