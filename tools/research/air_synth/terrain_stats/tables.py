"""Сводные таблицы из out/stats.json -> out/stats_tables.md (медиана [мин–макс] по квадратам)."""
import json, os, numpy as np
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
R = json.load(open(os.path.join(OUT, "stats.json")))


def agg(sqs, f):
    v = np.array([f(s) for s in sqs], float)
    v = v[~np.isnan(v)]
    if len(v) == 0: return "–"
    if len(v) == 1: return f"{v[0]:.3g}"
    return f"{np.median(v):.3g} [{v.min():.3g}–{v.max():.3g}]"


def table(title, cols, names=("detail25", "detail100", "detail400", "far100", "far400")):
    out = [f"\n**{title}**\n", "| место | сетка | " + " | ".join(c[0] for c in cols) + " |", "|---|---|" + "---|" * len(cols)]
    for p in R:
        for n in names:
            if n not in R[p]: continue
            sq = R[p][n]
            out.append(f"| {p} | {n} | " + " | ".join(agg(sq, c[1]) for c in cols) + " |")
    return "\n".join(out)


md = []
md.append(table("Вершины на квадрат 40×40 км по порогу prominence (м)",
                [(f">={t}", (lambda s, t=t: s["peaks_per_sq"][str(t)])) for t in (10, 30, 50, 100, 200, 300, 500)]))
md.append(table("Prominence: показатель b в N(>=P)~P^-b; доля prom/(высота над минимумом квадрата); расстояние до родителя, до седловины, км (вершины >=30 м)",
                [("b 30–300", lambda s: s["prom_exp_b"]["30-300"]), ("b 10–100", lambda s: s["prom_exp_b"]["10-100"]),
                 ("prom/отн.высота", lambda s: s.get("ge30", {}).get("prom_over_rel_height", np.nan)),
                 ("d до родителя, км", lambda s: s.get("ge30", {}).get("d_parent_med", np.nan) / 1000),
                 ("d до седловины, км", lambda s: s.get("ge30", {}).get("d_saddle_med", np.nan) / 1000)]))
md.append(table("Рельеф: перепад в квадрате, ср. локальный перепад 5 км, гипсометрический интеграл, std высот",
                [("перепад, м", lambda s: s["hyps"]["relief"]), ("лок. перепад 5 км, м", lambda s: s["lrelief2500"]),
                 ("HI", lambda s: s["hyps"]["HI"]), ("std, м", lambda s: s["hyps"]["std"])]))
md.append(table("Уклоны (градусы) на сетке шага dx",
                [("средний", lambda s: s["slope"]["mean"]), ("медиана", lambda s: s["slope"]["median"]),
                 ("p90", lambda s: s["slope"]["p90"]), ("p99", lambda s: s["slope"]["p99"]),
                 ("доля >20°", lambda s: s["slope"]["frac_gt20"]), ("доля >30°", lambda s: s["slope"]["frac_gt30"])]))
md.append(table("Анизотропия: простирание хребтов (град), анизотропия тензора, асимметрия склонов, PSD строки/столбцы",
                [("простирание°", lambda s: s["orient"]["strike_deg"]), ("анизотропия", lambda s: s["orient"]["anisotropy"]),
                 ("асимметрия", lambda s: s["asym"]), ("PSD x/y", lambda s: s["psd_rows_over_cols"])]))
bands = ["10000-40000", "3000-10000", "1000-3000", "400-1000", "200-400", "100-200"]
md.append(table("Спектр профиля: β (P~k^-β) по полосам длины волны, м",
                [(b, (lambda s, b=b: s["beta"].get(b, np.nan))) for b in bands]))
md.append(table("Дренаж (сетка 100 м): плотность русел Dd, км/км², при пороге водосбора 0,25 / 1 / 4 км²",
                [("Dd 0,25", lambda s: s["drain"]["0.25"]["Dd_km_per_km2"]), ("Dd 1", lambda s: s["drain"]["1.0"]["Dd_km_per_km2"]),
                 ("Dd 4", lambda s: s["drain"]["4.0"]["Dd_km_per_km2"]), ("полурасст. при 1, м", lambda s: s["drain"]["1.0"]["half_spacing_m"])],
                names=("detail100", "far100")))
md.append(table("Критические точки на сетке (Банчофф): максимумы / минимумы / седловины",
                [("макс", lambda s: s["crit"][0]), ("мин", lambda s: s["crit"][1]), ("седл", lambda s: s["crit"][2])]))
open(os.path.join(OUT, "stats_tables.md"), "w").write("\n".join(md) + "\n")
print("\n".join(md))
