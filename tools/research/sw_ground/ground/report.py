"""Таблицы для README из out/swg-1/ground.json → out/swg-1/tables.md (Markdown)."""
from __future__ import annotations

import json
from collections import defaultdict

from . import common as K

SHORT = {"ASK_TU03B": "ASK", "PERD_NE": "NE", "PERD_SW": "SW"}


def fmt(v, p=2):
    return "–" if v is None else f"{v:+.{p}f}"


def main():
    d = json.load(open(K.OUT_TASK / "ground.json"))
    out = []
    # ---- до
    out.append("### Таблица «до»: potential_jh против Пикара nom (n / доля в ±15 % / среднее rel / медиана rel)\n")
    for var in ("potential_jh", "potential"):
        out.append(f"**{var}**\n")
        out.append("| тип | z, м | " + " | ".join(SHORT[c] for c in K.CASES) + " |")
        out.append("|---|---|" + "---|" * len(K.CASES))
        S = {(s["case"], s["type"], s["z_agl"]): s for s in d["summary"] if s["variant"] == var and s["ref_kind"] == "picard_nom"}
        for t in ("lee", "valley", "crest", "windward", "upstream"):
            for z in K.HEIGHTS:
                cells = []
                for c in K.CASES:
                    s = S.get((c, t, z))
                    cells.append("–" if not s else f"{s['n']} / {s['frac_tol']:.2f} / {s['mean_rel']:+.2f} / {s['median_rel']:+.2f}")
                out.append(f"| {t} | {z:g} | " + " | ".join(cells) + " |")
        out.append("")
    out.append("### Мачты (RMSE s, доля в ±15 %)\n")
    out.append("| вариант | случай | тип | n | RMSE s | доля |\n|---|---|---|---|---|---|")
    for m in d["masts"]:
        if m["type"] == "all":
            out.append(f"| {m['variant']} | {SHORT[m['case']]} | all | {m['n']} | {m['rmse_s']:.3f} | {m['frac_tol']:.2f} |")
    out.append("")
    out.append("### Мачты по типам: potential_jh (n, среднее rel к измерению, доля в ±15 %)\n")
    out.append("| случай | тип | n | высоты, м | mean rel | доля |\n|---|---|---|---|---|---|")
    g = defaultdict(list)
    for r in d["rows"]:
        if r["ref_kind"] == "mast" and r["variant"] == "potential_jh":
            g[(r["case"], r["type"])].append(r)
    for (c, t), rr in sorted(g.items(), key=lambda kv: (K.CASES.index(kv[0][0]), K.TYPES.index(kv[0][1]))):
        zs = sorted({x["z_agl"] for x in rr})
        out.append(f"| {SHORT[c]} | {t} | {len(rr)} | {zs[0]:g}…{zs[-1]:g} | {sum(x['rel_err'] for x in rr) / len(rr):+.2f} | "
                   f"{sum(x['within_tol'] for x in rr) / len(rr):.2f} |")
    out.append("")
    # ---- разложение
    out.append("### Разложение rel_err potential_jh (средние по точкам; bg + panels + jh = total)\n")
    D = defaultdict(dict)
    for r in d["decomp"]:
        D[(r["case"], r["type"], r["z_agl"])][r["term"]] = r["value"]
    cols = ["s_ref", "s_bg", "s_pot", "s_jh", "total", "bg", "panels", "jh", "wake_ref", "wake_pan", "capture_pot", "capture_jh", "profile_log_vs_picard_median", "profile_log_vs_picard_lnmean",
            "jh_logfac", "jh_speedup", "su_required", "norm_logfac", "norm_speedup", "jh_inner_frac", "jh_dS", "jh_t", "head_cover", "rel_in_head_zone", "rel_outside_head_zone", "head"]
    out.append("| случай | тип | z | " + " | ".join(cols) + " |")
    out.append("|---|---|---|" + "---|" * len(cols))
    for c in K.CASES:
        for t in ("lee", "valley", "crest", "windward", "upstream"):
            for z in (10.0, 50.0):
                x = D.get((c, t, z))
                if not x:
                    continue
                out.append(f"| {SHORT[c]} | {t} | {z:g} | " + " | ".join(("–" if x.get(k) is None else f"{x[k]:+.2f}") for k in cols) + " |")
    out.append("")
    # ---- сканы
    out.append("### Сканы (potential_jh; lee/valley 10 и 50 м; доля в ±15 % / среднее rel; RMSE s мачт)\n")
    S = defaultdict(dict)
    for r in d["scan"]:
        if r["variant"] != "potential_jh":
            continue
        S[(r["case"], r["param"], r["value"])][r["metric"]] = r["result"]
    mets = ["frac_tol_lee_10", "frac_tol_lee_50", "frac_tol_valley_10", "frac_tol_valley_50", "mean_rel_lee_10", "mean_rel_lee_50",
            "mean_rel_valley_10", "mean_rel_valley_50", "rmse_s_mast"]
    out.append("| случай | параметр | значение | " + " | ".join(mets) + " |")
    out.append("|---|---|---|" + "---|" * len(mets))
    for (c, p, v), m in sorted(S.items(), key=lambda kv: (K.CASES.index(kv[0][0]), kv[0][1], kv[0][2])):
        out.append(f"| {SHORT[c]} | {p} | {v:g} | " + " | ".join("–" if m.get(k) is None else f"{m[k]:.2f}" for k in mets) + " |")
    (K.OUT_TASK / "tables.md").write_text("\n".join(out) + "\n")
    print("tables.md", len(out), "строк")


if __name__ == "__main__":
    main()
