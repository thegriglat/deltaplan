"""Собирает docs/research/sw_ground.md: таблицы — из out/summary/selection.json, текст — summary/doc_template.md."""
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
REPO = os.path.abspath(os.path.join(ROOT, "..", "..", ".."))
CASES = ["ASK_TU03B", "PERD_NE", "PERD_SW"]
SHORT = {"ASK_TU03B": "Askervein", "PERD_NE": "Perdigão NE", "PERD_SW": "Perdigão SW"}
SHOW = ["potential_jh", "sheet_jh_mix", "zone_jh", "attached_jh", "free_jh", "free_jh_slope"]
RANK_SHOW = SHOW + ["wake_jh", "rotor_jh", "vii2"]


def f(x, k=3):
    return "–" if x is None else f"{x:.{k}f}".replace(".", ",")


def main():
    sel = json.load(open(os.path.join(ROOT, "out", "summary", "selection.json"), encoding="utf-8"))
    byv = {}
    for r in sel["table"]:
        byv.setdefault(r["variant"], {})[r["case"]] = r
    rk = {o["variant"]: o for o in sel["ranking"]}

    # 1. выбор
    L = ["| ранг | вариант | задача | ASK | NE | SW | среднее | худший минус база | лее ср. |", "|---|---|---|---|---|---|---|---|---|"]
    for o in sel["ranking"]:
        v = o["variant"]
        if v in ("bg_only",):
            continue
        tag = ""
        if not o["eligible"]:
            tag = " *(не в выборе)*"
        elif v in sel["diagnostic"]:
            tag = " *(диагн.)*"
        elif v == "potential":
            tag = " *(справка)*"
        L.append("| %s | `%s`%s | %s | %s | %s | %s | **%s** | %s | %s |" % (
            o["rank"] or "–", v, tag, byv[v][CASES[0]]["task"], *[f(byv[v][c]["rmse_all"]) for c in CASES],
            f(o["mean_rmse_all"]), ("%+.3f" % o["worst_vs_base"]).replace(".", ","), f(o["mean_rmse_lee"])))
    sel_table = "\n".join(L)

    # 2. мачты по типам
    L = ["| случай | тип | n | " + " | ".join("`%s`" % v for v in SHOW) + " |", "|---|---|---|" + "---|" * len(SHOW)]
    for c in CASES:
        for t, name in (("all", "все"), ("lee", "лее"), ("valley", "долина"), ("crest", "гребень"), ("windward", "наветренный")):
            n = byv["potential_jh"][c].get("n_all" if t == "all" else "n_lee") if t in ("all", "lee") else None
            cells = []
            for v in SHOW:
                x = byv[v][c]["rmse_" + t]
                cells.append(f(x))
            if all(x == "–" for x in cells):
                continue
            L.append("| %s | %s | %s | %s |" % (SHORT[c], name, n if n is not None else "", " | ".join(cells)))
    mast_table = "\n".join(L)

    # 3. лее мачты
    L = ["| вариант | " + " | ".join(SHORT[c] for c in CASES) + " |", "|---|---|---|---|"]
    for v in SHOW:
        cells = []
        for c in CASES:
            r = byv[v][c]
            cells.append("%s / %s / %s" % (f(r["rmse_lee"]), ("%+.2f" % r["mean_rel_lee"]).replace(".", ","), f(r["frac_tol_lee"], 2)))
        L.append("| `%s` | %s |" % (v, " | ".join(cells)))
    lee_table = "\n".join(L)

    # 4. Пикар справочно: тип × высота
    P = sel["picard_ref"]
    L = ["| тип | z, м | случай | n | " + " | ".join("`%s`" % v for v in SHOW) + " |", "|---|---|---|---|" + "---|" * len(SHOW)]
    for typ, name in (("lee", "лее"), ("valley", "долина"), ("crest", "гребень"), ("windward", "наветренный")):
        for z in (10.0, 50.0, 300.0):
            for c in CASES:
                cells, n = [], None
                for v in SHOW:
                    r = [p for p in P if p["variant"] == v and p["case"] == c and p["type"] == typ and p["z_agl"] == z]
                    if r:
                        n = r[0]["n"]
                        cells.append("%s / %s" % (f(r[0]["frac_tol"], 2), ("%+.2f" % r[0]["mean_rel"]).replace(".", ",")))
                    else:
                        cells.append("–")
                if n is None:
                    continue
                note = "*" if z == 10.0 else ""
                L.append("| %s | %d%s | %s | %d | %s |" % (name, z, note, SHORT[c], n, " | ".join(cells)))
    picard_table = "\n".join(L)

    pv = sel["verdict"]["paired_vs_base"]
    paired = "\n".join("| `%s` | %d | %d | %d |" % (v, p["better"], p["worse"], p["same"]) for v, p in pv.items()
                      if v in ("sheet_jh_mix", "attached_jh", "zone_jh"))
    vd = sel["verdict"]
    vals = {"SEL_TABLE": sel_table, "MAST_TABLE": mast_table, "LEE_TABLE": lee_table, "PICARD_TABLE": picard_table,
            "PAIRED": paired, "BEST": vd["best"], "BEST_MEAN": f(vd["best_mean_rmse_all"]),
            "BASE_MEAN": f(vd["base_mean_rmse_all"])}
    t = open(os.path.join(HERE, "doc_template.md"), encoding="utf-8").read()
    t = re.sub(r"\{\{(\w+)\}\}", lambda m: vals[m.group(1)], t)
    out = os.path.join(REPO, "docs", "research", "sw_ground.md")
    open(out, "w", encoding="utf-8").write(t)
    print(out, len(t.encode("utf-8")))


if __name__ == "__main__":
    main()
