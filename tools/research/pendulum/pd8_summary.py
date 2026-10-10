"""PD-8: итог — out/game_vs_proto.md и out/pd8_summary.json из pd8_game.jsonl, pd8_proto.jsonl, pd8_bench.jsonl.
  .venv/bin/python tools/research/pendulum/pd8_summary.py
"""
from __future__ import annotations

import json
import math
from pathlib import Path

import numpy as np

OUT = Path(__file__).resolve().parent / "out"
WINGS = ["training", "laminar", "sport"]
DT = 1 / 120
TOL = 15.0


def load(name):
    p = OUT / name
    if not p.exists():
        return []
    return [json.loads(l) for l in p.read_text().splitlines() if l.strip()]


def idx(rows, dt=DT):
    d = {}
    for r in rows:
        if abs(r["dt"] - dt) < 1e-6 and r["sc"] != "turb":
            d[(r["sc"], r["wing"])] = r
    return d


def f(x, n=2):
    return "—" if x is None or (isinstance(x, float) and math.isnan(x)) else f"{x:.{n}f}"


# (сценарий, заголовок, [(ключ, подпись, знаков)])
SC = [
    ("trim", "Трим и снижение (30 с, среднее после 15 с)", [("V_kmh", "V, км/ч", 2), ("sink_ms", "снижение, м/с", 3), ("alpha_deg", "α, °", 2), ("theta_deg", "тангаж, °", 2), ("tension_N", "натяжение стропы, Н", 1)]),
    ("phugoid", "Фугоида (толчок +3 м/с)", [("period_s", "период, с", 2), ("amp_ratio", "отношение амплитуд за период", 2)]),
    ("reversal45", "Переложение 45→45 (вираж 14 с, полное смещение против)", [("phi_start", "крен перед, °", 1), ("t_to_zero", "до горизонта, с", 2), ("t_to_minus", "до −45°, с", 2), ("phi_t2", "крен через 2 с, °", 1)]),
    ("reversal30", "Переложение 30→30", [("phi_start", "крен перед, °", 1), ("t_to_zero", "до горизонта, с", 2), ("t_to_minus", "до −30°, с", 2), ("phi_t2", "крен через 2 с, °", 1)]),
    ("fullshift", "Полное смещение из горизонта (крен через…)", [("phi_1s", "1 с, °", 1), ("phi_2s", "2 с, °", 1), ("phi_4s", "4 с, °", 1), ("phi_6s", "6 с, °", 1), ("phi_10s", "10 с, °", 1), ("phi_15s", "15 с, °", 1)]),
    ("center30", "«В центр» из виража 30° (крен через…)", [("phi_start", "перед, °", 1), ("phi_10s", "10 с, °", 1), ("phi_20s", "20 с, °", 1)]),
    ("pendulum", "Маятник, руки отпущены (толчок 0,5 м/с)", [("lat_period_s", "период поперёк, с", 2), ("lat_ratio", "затухание поперёк", 2), ("lon_period_s", "период вдоль, с", 2), ("lon_ratio", "затухание вдоль", 2)]),
    ("ochi", "Опыт Ochi (laminar, 72,6 кг, 30 Н 8,5 с)", [("phi_7s", "крен через 7 с, °", 1), ("phi_max", "максимум, °", 1)]),
    ("ground_run_w0", "Разбег 15°, штиль", [("t_liftoff", "время до отрыва, с", 2), ("x_liftoff", "путь, м", 1), ("v_liftoff_kmh", "V отрыва, км/ч", 1)]),
    ("ground_run_w3", "Разбег 15°, встречный 3 м/с", [("t_liftoff", "время до отрыва, с", 2), ("x_liftoff", "путь, м", 1), ("v_liftoff_kmh", "V отрыва, км/ч", 1)]),
    ("ground_run_w6", "Разбег 15°, встречный 6 м/с", [("t_liftoff", "время до отрыва, с", 2), ("x_liftoff", "путь, м", 1), ("v_liftoff_kmh", "V отрыва, км/ч", 1)]),
]


def compare(g, p, summ):
    L = ["## 1. Игра против прототипа (шаг 1/120 с, умолчания класса)", "",
         "Δ% = (игра − прототип)/|прототип|·100; «!» — расхождение > 15 %; «†» — прототип по модулю < 1 (процент не показателен, смотреть разность).", ""]
    nbad = ntot = 0
    for sc, title, keys in SC:
        L += [f"### {title}", "", "| крыло | метрика | игра | прототип | Δ% | |", "|---|---|---|---|---|---|"]
        for w in WINGS:
            a, b = g.get((sc, w)), p.get((sc, w))
            if not a or not b:
                continue
            for k, lab, nd in keys:
                x, y = a.get(k), b.get(k)
                if x is None or y is None:
                    continue
                if isinstance(x, float) and isinstance(y, float) and not (math.isnan(x) or math.isnan(y)):
                    d = 100 * (x - y) / abs(y) if abs(y) > 1e-9 else float("nan")
                    bad = abs(d) > TOL
                    mark = ("!" if bad else "") + ("†" if abs(y) < 1 else "")
                    ntot += 1
                    nbad += bad
                    summ["rows"].append({"sc": sc, "wing": w, "key": k, "game": x, "proto": y, "d_pct": d, "bad": bool(bad)})
                    L.append(f"| {w} | {lab} | {f(x, nd)} | {f(y, nd)} | {f(d, 1)} | {mark} |")
                else:
                    L.append(f"| {w} | {lab} | {f(x, nd)} | {f(y, nd)} | — | |")
        L.append("")
    summ["n_compared"], summ["n_over_15"] = ntot, nbad
    L.insert(3, f"Сравнено значений: {ntot}; с расхождением > 15 %: **{nbad}**.")
    return L


def convergence(gall, summ):
    L = ["## 2. Сходимость по шагу игры (1/60, 1/120, 1/240 с)", "",
         "Δ% — отличие от шага 1/240 (самый точный). Без NaN во всех прогонах: " + ("да" if all(r.get("finite", True) for r in gall) else "НЕТ"), ""]
    cases = [("trim", [("V_kmh", 2), ("sink_ms", 3), ("theta_deg", 2)]),
             ("reversal45", [("t_to_zero", 2), ("t_to_minus", 2), ("phi_t2", 1)]),
             ("fullshift", [("phi_2s", 1), ("phi_4s", 1), ("phi_10s", 1)]),
             ("ground_run_w0", [("t_liftoff", 2), ("x_liftoff", 1), ("v_liftoff_kmh", 1)]),
             ("dive", [("theta_min_deg", 1), ("V_max_kmh", 1), ("n_out_max", 2), ("V_end_kmh", 1)])]
    L += ["| сценарий | крыло | метрика | 1/60 | 1/120 | 1/240 | Δ60 % | Δ120 % |", "|---|---|---|---|---|---|---|---|"]
    worst = {}
    for sc, keys in cases:
        for w in WINGS:
            rs = {round(1 / r["dt"]): r for r in gall if r["sc"] == sc and r["wing"] == w and r["sc"] != "turb"}
            if len(rs) < 3:
                continue
            for k, nd in keys:
                v = {h: rs[h].get(k, float("nan")) for h in (60, 120, 240)}
                ref = v[240]
                d60 = 100 * (v[60] - ref) / abs(ref) if abs(ref) > 1e-9 else float("nan")
                d120 = 100 * (v[120] - ref) / abs(ref) if abs(ref) > 1e-9 else float("nan")
                L.append(f"| {sc} | {w} | {k} | {f(v[60], nd)} | {f(v[120], nd)} | {f(v[240], nd)} | {f(d60, 1)} | {f(d120, 1)} |")
                for h, d in ((60, d60), (120, d120)):
                    if not math.isnan(d):
                        worst[(sc, h)] = max(worst.get((sc, h), 0.0), abs(d))
    summ["conv_worst_pct"] = {f"{sc}@1/{h}": v for (sc, h), v in worst.items()}
    L += ["", "Наибольшее отличие от 1/240, %: " + "; ".join(f"{sc} @1/{h}: {v:.1f}" for (sc, h), v in sorted(worst.items())), ""]
    return L


def bench(rows, summ):
    if not rows:
        return []
    L = ["## 3. Цена шага (мкс/шаг, лучший из 3 прогонов по 10 с; полёт со смещением и ветром)", "",
         "| крыло | шаг | PendulumModel, мкс | FlightModel, мкс | отношение | PendulumModel, мс на 1 с полёта |", "|---|---|---|---|---|---|"]
    for r in rows:
        L.append(f"| {r['wing']} | 1/{round(1 / r['dt'])} | {r['us_pendulum']:.1f} | {r['us_flight_model']:.1f} | "
                 f"{r['us_pendulum'] / r['us_flight_model']:.2f} | {r['ms_per_second_pendulum']:.2f} |")
    summ["bench"] = rows
    return L + [""]


def turb(rows_g, rows_p, summ):
    L = ["## 4. Серия болтанки laminar (σ 1 м/с, поле — сумма синусоид, 60 с, пилот держит горизонт ПИД 1,5/0,8/0,3)", ""]
    for dt in (1 / 120, 1 / 60):
        g = {r["seed"]: r for r in rows_g if r["sc"] == "turb" and abs(r["dt"] - dt) < 1e-6}
        p = {r["seed"]: r for r in rows_p if r["sc"] == "turb" and abs(r["dt"] - dt) < 1e-6}
        if not g:
            continue
        L += [f"### Шаг 1/{round(1 / dt)}", "",
              "| зерно | игра: СКО крена, ° | макс. крен, ° | СКО пилота поперёк, м | дрейф курса, ° | развал | прототип: СКО крена, ° | макс. крен, ° | СКО поперёк, м | дрейф курса, ° |",
              "|---|---|---|---|---|---|---|---|---|---|"]
        for sd in sorted(g):
            a, b = g[sd], p.get(sd, {})
            L.append(f"| {sd} | {f(a['std_phi_deg'])} | {f(a['max_abs_phi_deg'], 1)} | {f(a['std_rel_y_m'], 3)} | {f(a['heading_drift_deg'], 0)} | "
                     f"{'да' if a['blowup'] else 'нет'} | {f(b.get('std_phi_deg'))} | {f(b.get('max_abs_phi_deg'), 1)} | {f(b.get('std_rel_y_m'), 3)} | {f(b.get('heading_drift_deg'), 0)} |")
        def agg(rs, k):
            v = np.array([r[k] for r in rs.values()], float)
            return float(v.mean()), float(v.max())
        s = {"dt": dt, "n": len(g)}
        for nm, rs in (("game", g), ("proto", p)):
            if rs:
                s[nm] = {k: dict(zip(("mean", "max"), agg(rs, k))) for k in ("std_phi_deg", "max_abs_phi_deg", "std_rel_y_m", "heading_drift_deg")}
                s[nm]["blowups"] = sum(r["blowup"] for r in rs.values())
        summ.setdefault("turb", []).append(s)
        L += ["", f"Среднее по зёрнам: игра — СКО крена {s['game']['std_phi_deg']['mean']:.2f}°, наибольший крен {s['game']['max_abs_phi_deg']['max']:.1f}°, "
              f"СКО пилота {s['game']['std_rel_y_m']['mean']:.3f} м, развалов {s['game']['blowups']}"
              + (f"; прототип — СКО {s['proto']['std_phi_deg']['mean']:.2f}°, наибольший {s['proto']['max_abs_phi_deg']['max']:.1f}°, СКО пилота {s['proto']['std_rel_y_m']['mean']:.3f} м." if "proto" in s else "."), ""]
    return L


def pitch(g, p, gall, summ):
    L = ["## 5. Тангаж: слова пилота", "",
         "### 5.1 Брошенная ручка в штиле (60 с, статистика после 10 с)", "",
         "«нейтраль» — руки на штанге в нейтрали; «отпущены» — `arms_relaxed` (пилот висит на стропе).", "",
         "| крыло | руки | модель | тангаж, ° | размах тангажа, ° | V, км/ч | макс. |крен|, ° | дрейф курса, ° |", "|---|---|---|---|---|---|---|---|"]
    for sc, nm in (("hold_neutral", "нейтраль"), ("hold_relaxed", "отпущены")):
        for w in WINGS:
            for lab, src in (("игра", g), ("прототип", p)):
                r = src.get((sc, w))
                if r:
                    L.append(f"| {w} | {nm} | {lab} | {f(r['theta_deg'])} | {f(r['theta_range_deg'])} | {f(r['V_kmh'])} | {f(r['max_abs_phi_deg'])} | {f(r['heading_drift_deg'], 1)} |")
    def outcome(r):
        if r["stall_end"] > 0.5:
            return f"глубокий срыв (α {r['alpha_end_deg']:.0f}°, V {r['V_end_kmh']:.0f} км/ч)"
        if r["t_settle_s"] > 100:
            return "не успокоилось за 120 с"
        return f"к триму за {r['t_settle_s']:.1f} с"
    L += ["", "### 5.2 Вывод из пикирования: «на себя» до упора 3 с, затем руки в нейтраль (120 с)", "",
          "θ — тангаж киля; «вывод» — после отпускания тангаж снова выше (трим − 2°); «успокоение» — после отпускания V в пределах 5 % трима и θ в 3° от трима; "
          "n — натяжение стропы / вес пилота; срыв — доля сорванных полос в конце.", "",
          "| крыло | модель | трим θ, ° | θ мин., ° | V макс., км/ч | n за 3 с | n макс. после | вывод (θ выше трим−2°), с | θ макс. после, ° | V мин. после, км/ч | итог через 120 с |",
          "|---|---|---|---|---|---|---|---|---|---|---|"]
    for w in WINGS:
        for lab, src in (("игра", g), ("прототип", p)):
            r = src.get(("dive", w))
            if r:
                L.append(f"| {w} | {lab} | {f(r['theta_trim_deg'], 1)} | {f(r['theta_min_deg'], 1)} | {f(r['V_max_kmh'], 1)} | {f(r['n_pull_max'])} | "
                         f"{f(r['n_out_max'])} | {f(r['t_recover_s'])} | {f(r['theta_max_after_deg'], 1)} | {f(r['V_min_after_kmh'], 1)} | {outcome(r)} |")
    L += ["", "### 5.3 Слабее и короче «на себя» (где граница глубокого срыва)", "",
          "| крыло | «на себя» | модель | θ мин., ° | V макс., км/ч | n макс. после | θ макс. после, ° | V мин. после, км/ч | итог через 120 с |", "|---|---|---|---|---|---|---|---|---|"]
    names = sorted({r["sc"] for r in gall if r["sc"].startswith("dive_a")}, key=lambda x: (-int(x[6:].split("_t")[0]), int(x.split("_t")[1])))
    summ["dive"] = {}
    for w in WINGS:
        for nm in ["dive"] + names:
            lab_ = "100 % 3 с" if nm == "dive" else f"{nm[6:].split('_t')[0]} % {nm.split('_t')[1]} с"
            for lab, src in (("игра", g), ("прототип", p)):
                r = src.get((nm, w))
                if r:
                    summ["dive"][f"{w}|{lab_}|{lab}"] = outcome(r)
                    L.append(f"| {w} | {lab_} | {lab} | {f(r['theta_min_deg'], 1)} | {f(r['V_max_kmh'], 1)} | {f(r['n_out_max'])} | {f(r['theta_max_after_deg'], 1)} | {f(r['V_min_after_kmh'], 1)} | {outcome(r)} |")
    return L + [""]


def main():
    gall, pall = load("pd8_game.jsonl"), load("pd8_proto.jsonl")
    g, p = idx(gall), idx(pall)
    summ = {"rows": []}
    L = ["# PD-8: сверка игры с прототипом", "",
         "Данные: `pd8_game.jsonl` (игра, `tools/flight/pendulum_compare.gd`), `pd8_proto.jsonl` (прототип, `pd8_proto.py`), `pd8_bench.jsonl` (цена шага). "
         "Сводка строится `pd8_summary.py`.", ""]
    L += compare(g, p, summ)
    L += convergence(gall, summ)
    L += bench(load("pd8_bench.jsonl"), summ)
    L += turb(gall, pall, summ)
    L += pitch(g, p, gall, summ)
    (OUT / "game_vs_proto.md").write_text("\n".join(L) + "\n")
    (OUT / "pd8_summary.json").write_text(json.dumps(summ, ensure_ascii=False, indent=1) + "\n")
    print(f"→ game_vs_proto.md: {summ['n_compared']} значений, > 15 %: {summ['n_over_15']}")


if __name__ == "__main__":
    main()
