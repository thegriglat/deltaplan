"""SWG-13: свод вариантов слоя у земли (SWG-1…12) по измерениям (мачты) и выбор по правилу карточки.

Читает только out/swg-*/ground.json. Правило (зафиксировано до свода):
 (1) среднее по трём случаям RMSE s мачт (все мачты случая); ни в одном случае не хуже базы potential_jh больше чем на 0,02;
 (2) второй критерий — лее мачты: RMSE, среднее rel, доля в ±15 %;
 (4) Пикар — справочно (не участвует в выборе);
 (5) несошедшиеся/частичные варианты — в таблице, eligible = False.
Запуск: tools/research/sw_ground/py -m summary.select  ->  out/summary/selection.json, tables.md
"""
import json
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "out")
CASES = ["ASK_TU03B", "PERD_NE", "PERD_SW"]
BASE = "potential_jh"
TOL = 0.02
TYPES = ["lee", "valley", "crest", "windward"]
# задача -> файл; для каждого варианта берётся ПЕРВАЯ задача по списку приоритета (свои строки задачи)
TASKS = [1, 4, 5, 7, 8, 9, 10, 11, 12]
# несошедшиеся/частичные (правило 5)
NOT_ELIGIBLE = {
    "vii": "Perdigão: полуобратная связь Carter не сошлась (SWG-10), последняя итерация",
    "vii_nc": "Perdigão: не сошлось (SWG-10)",
    "vii2": "Perdigão: Ньютон дошёл до ε 0,81/0,84, не полный рельеф (SWG-11)",
    "vii2_nc": "Perdigão: Ньютон до ε≈0,8, не полный рельеф (SWG-11)",
}
# нет вывода в виде варианта слоя: фон и чистый потенциал — справка
REFERENCE = {"bg_only": "лог-фон без панелей", "potential": "панели без JH"}
# диагностика нормировки (SWG-12): та же геометрия, нормировка по potential_jh в опорной точке
DIAG = {"free_jh_fixnorm": "free_jh", "free_jh_slope_fixnorm": "free_jh_slope"}


def load(task):
    with open(os.path.join(OUT, f"swg-{task}", "ground.json"), encoding="utf-8") as f:
        return json.load(f)


def mast_stats(rows, case, variant, typ):
    r = [x for x in rows if x["case"] == case and x["variant"] == variant and x["ref_kind"] == "mast"
         and (typ == "all" or x["type"] == typ)]
    if not r:
        return None
    n = len(r)
    mse = sum((x["s_pan"] - x["s_ref"]) ** 2 for x in r) / n
    return {"n": n, "rmse": math.sqrt(mse), "mean_rel": sum(x["rel_err"] for x in r) / n,
            "frac_tol": sum(1 for x in r if x["within_tol"]) / n}


def picard_stats(rows, case, variant, typ, z):
    r = [x for x in rows if x["case"] == case and x["variant"] == variant and x["ref_kind"] == "picard_nom"
         and x["type"] == typ and abs(x["z_agl"] - z) < 1e-6]
    if not r:
        return None
    n = len(r)
    return {"n": n, "mean_rel": sum(x["rel_err"] for x in r) / n,
            "frac_tol": sum(1 for x in r if x["within_tol"]) / n}


def collect():
    """variant -> {task, rows}. Строки варианта берутся из первой задачи, где он есть (копии одинаковы)."""
    got = {}
    for t in TASKS:
        d = load(t)
        vs = {r["variant"] for r in d["rows"]}
        for v in sorted(vs):
            if v not in got:
                got[v] = (t, d["rows"])
    return got


def rank_rule(table):
    """table: список записей по (variant, case). Возвращает [{variant,...,rank}] по правилу (1)+(2)."""
    by = {}
    for r in table:
        by.setdefault(r["variant"], {})[r["case"]] = r
    base = by[BASE]
    out = []
    for v, c in by.items():
        if any(cs not in c for cs in CASES):
            continue
        mean_all = sum(c[cs]["rmse_all"] for cs in CASES) / 3
        worst = max(c[cs]["rmse_all"] - base[cs]["rmse_all"] for cs in CASES)
        lee = [c[cs]["rmse_lee"] for cs in CASES if c[cs]["rmse_lee"] is not None]
        out.append({"variant": v, "mean_rmse_all": mean_all, "worst_vs_base": worst,
                    "passes_1": worst <= TOL, "mean_rmse_lee": sum(lee) / len(lee) if lee else None,
                    "eligible": all(c[cs]["eligible"] for cs in CASES)})
    ok = sorted([o for o in out if o["eligible"] and o["passes_1"]],
                key=lambda o: (o["mean_rmse_all"], o["mean_rmse_lee"] if o["mean_rmse_lee"] is not None else 9))
    for i, o in enumerate(ok, 1):
        o["rank"] = i
    for o in out:
        o.setdefault("rank", None)
    return sorted(out, key=lambda o: (o["rank"] is None, o["rank"] or 0, o["mean_rmse_all"]))


def paired(got, v, base=BASE):
    """Парное сравнение по мачтам: сколько мачт ближе к измерению, чем у базы (все три случая)."""
    def errs(var):
        t, rows = got[var]
        return {(r["case"], r["id"], r["z_agl"]): abs(r["s_pan"] - r["s_ref"]) for r in rows
                if r["variant"] == var and r["ref_kind"] == "mast"}
    a, b = errs(v), errs(base)
    keys = [k for k in a if k in b]
    better = sum(1 for k in keys if a[k] < b[k] - 1e-9)
    worse = sum(1 for k in keys if a[k] > b[k] + 1e-9)
    return {"n": len(keys), "better": better, "worse": worse, "same": len(keys) - better - worse}


def build():
    got = collect()
    table, picard = [], []
    tasks_of = {}
    for v, (t, rows) in got.items():
        tasks_of[v] = t
        elig = v not in NOT_ELIGIBLE and v not in REFERENCE
        for cs in CASES:
            rec = {"variant": v, "task": f"SWG-{t}", "case": cs, "converged": v not in NOT_ELIGIBLE,
                   "eligible": elig, "diagnostic": v in DIAG, "reference": v in REFERENCE}
            for typ in ["all"] + TYPES:
                m = mast_stats(rows, cs, v, typ)
                key = "all" if typ == "all" else typ
                rec[f"rmse_{key}"] = m["rmse"] if m else None
                if typ in ("all", "lee"):
                    rec[f"n_{key}"] = m["n"] if m else 0
                if typ == "lee":
                    rec["mean_rel_lee"] = m["mean_rel"] if m else None
                    rec["frac_tol_lee"] = m["frac_tol"] if m else None
                if typ == "all":
                    rec["frac_tol_all"] = m["frac_tol"] if m else None
            table.append(rec)
            for typ in TYPES:
                for z in (10.0, 50.0, 300.0):
                    p = picard_stats(rows, cs, v, typ, z)
                    if p:
                        picard.append({"variant": v, "case": cs, "type": typ, "z_agl": z, **p})
    ranked = rank_rule(table)
    rk = {o["variant"]: o for o in ranked}
    for r in table:
        o = rk.get(r["variant"])
        r["rank"] = o["rank"] if o else None
        r["passes_1"] = o["passes_1"] if o else None
    winners = [o for o in ranked if o["rank"] is not None]
    base_o = rk[BASE]
    best = winners[0] if winners else None
    verdict = {
        "base": BASE, "base_mean_rmse_all": base_o["mean_rmse_all"],
        "best": best["variant"] if best else None,
        "best_mean_rmse_all": best["mean_rmse_all"] if best else None,
        "better_than_base": bool(best and best["variant"] != BASE and best["mean_rmse_all"] < base_o["mean_rmse_all"]),
        "rule": "среднее RMSE s мачт по трём случаям; ни в одном случае не хуже базы potential_jh больше чем на %.2f; "
                "второй — RMSE лее; несошедшиеся не входят; Пикар справочно" % TOL,
    }
    verdict["paired_vs_base"] = {o["variant"]: paired(got, o["variant"]) for o in winners if o["variant"] != BASE}
    return {"format": "swg-selection", "version": 1, "base": BASE, "tol_worse": TOL, "cases": CASES,
            "table": table, "ranking": ranked, "picard_ref": picard, "verdict": verdict, "task_of": tasks_of,
            "not_eligible": NOT_ELIGIBLE, "diagnostic": DIAG}


def fmt(x, k=3):
    return "–" if x is None else f"{x:.{k}f}"


def tables_md(sel):
    L = ["# SWG-13: свод по мачтам (RMSE s, эталон — мачты SWD1)", "",
         f"База `{BASE}`. Правило: среднее RMSE all по трём случаям, ни в одном не хуже базы на {TOL}.", "",
         "| ранг | вариант | задача | RMSE all ASK | NE | SW | среднее | худший минус база | лее ср. | допуск | пометка |",
         "|---|---|---|---|---|---|---|---|---|---|---|"]
    byv = {}
    for r in sel["table"]:
        byv.setdefault(r["variant"], {})[r["case"]] = r
    for o in sel["ranking"]:
        v = o["variant"]
        c = byv[v]
        note = []
        if v in NOT_ELIGIBLE:
            note.append("не в выборе: " + NOT_ELIGIBLE[v])
        if v in DIAG:
            note.append("диагностика нормировки (" + DIAG[v] + ")")
        if v in REFERENCE:
            note.append("справка: " + REFERENCE[v])
        if not o["passes_1"] and o["eligible"]:
            note.append("хуже базы > %.2f" % TOL)
        L.append("| %s | %s | %s | %s | %s | %s | %s | %+.3f | %s | %s | %s |" % (
            o["rank"] or "–", v, sel["task_of"][v].__str__() if False else c[CASES[0]]["task"],
            *[fmt(c[cs]["rmse_all"]) for cs in CASES], fmt(o["mean_rmse_all"]), o["worst_vs_base"],
            fmt(o["mean_rmse_lee"]), "да" if o["passes_1"] else "нет", "; ".join(note)))
    L += ["", "## Лее мачты: RMSE / среднее rel / доля в ±15 % (n)", "",
          "| вариант | ASK | NE | SW |", "|---|---|---|---|"]
    for o in sel["ranking"]:
        v = o["variant"]
        cells = []
        for cs in CASES:
            r = byv[v][cs]
            cells.append("–" if r["rmse_lee"] is None else "%.3f / %+.2f / %.2f (%d)" % (
                r["rmse_lee"], r["mean_rel_lee"], r["frac_tol_lee"], r["n_lee"]))
        L.append("| %s | %s |" % (v, " | ".join(cells)))
    L += ["", "## RMSE по типам мачт (долина, гребень, наветренный)", "",
          "| вариант | случай | valley | crest | windward |", "|---|---|---|---|---|"]
    for o in sel["ranking"]:
        for cs in CASES:
            r = byv[o["variant"]][cs]
            L.append("| %s | %s | %s | %s | %s |" % (o["variant"], cs, fmt(r["rmse_valley"]), fmt(r["rmse_crest"]),
                                                       fmt(r["rmse_windward"])))
    vd = sel["verdict"]
    L += ["", "## Вердикт", "", f"Лучший по правилу: `{vd['best']}`, среднее RMSE {fmt(vd['best_mean_rmse_all'])} против базы "
          f"{fmt(vd['base_mean_rmse_all'])}; лучше базы: {'да' if vd['better_than_base'] else 'нет'}."]
    return "\n".join(L) + "\n"


def main():
    sel = build()
    od = os.path.join(OUT, "summary")
    os.makedirs(od, exist_ok=True)
    with open(os.path.join(od, "selection.json"), "w", encoding="utf-8") as f:
        json.dump(sel, f, ensure_ascii=False, indent=1)
    with open(os.path.join(od, "tables.md"), "w", encoding="utf-8") as f:
        f.write(tables_md(sel))
    print(json.dumps(sel["verdict"], ensure_ascii=False, indent=1))


if __name__ == "__main__":
    sys.exit(main())
