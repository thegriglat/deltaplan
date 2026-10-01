"""Б1: регрессия матрицы А2 на λ совместной калибровки — таблица против базы А2 (old+kr10, new+kr10).

  python a2_table.py   → out/a2_regression.md, out/a2_regression.json
Вход: tools/research/a2pre/out/matrix_b1.jsonl (run.py b1), matrix_a2.jsonl (А2, вариант kr10).
"""
from __future__ import annotations

import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
A2 = HERE.parents[1] / "a2pre/out"
OUT = HERE / "out"


def load(f, cond=lambda r: True):
    return [json.loads(l) for l in (A2 / f).read_text().splitlines() if l.strip() and cond(json.loads(l))]


def main():
    b1 = load("matrix_b1.jsonl")
    base = load("matrix_a2.jsonl", lambda r: r.get("variant") == "kr10")
    rows = {}
    for r in base:
        rows[(r["base"], r["key"].split("|", 1)[1])] = r
    for r in b1:
        rows[(r["pset"], r["key"].split("|", 1)[1])] = r
    psets = ["old", "new", "b1a_game", "b1a_recal", "b1b_game", "b1b_recal"]
    scen = sorted({k[1] for k in rows}, key=lambda s: (not s.endswith("cbl"), s))
    info = b1[0]["b1"]
    L = ["# Б1: регрессия матрицы А2 (сходимость и цена) на λ совместной калибровки\n",
         f"λ совместной подгонки = {info['lam_fit']:.1f} м; h_нейтр: Askervein {info['h_ask']:.0f} м, Perdigão {info['h_pd']:.0f} м → "
         f"λ/h = {info['lf']:.4f}. Переводы: (а) lam = λ, lam_frac = 0; (б) lam = 40, lam_frac = λ/h. Профиль Онгудая: game — α 0,14, "
         "z0 0,1, max_profile 1,8 (номинал игры); recal — α 0,235, z0 0,09, max_profile 2,0 (перекалибровка Askervein) — не "
         "подбирались. База: old+kr10 (λ/h 0,25), new+kr10 (λ/h 0,031) из матрицы А2. k_relax 0,1. Ячейка — итерации по решениям "
         "цепочки (область / окно 100 / окно 50), * — не сошлось (max), в скобках — с решателя суммарно.\n",
         "| сценарий | " + " | ".join(psets) + " |", "|---|" + "---|" * len(psets)]
    summ = {}
    for s in scen:
        cells = []
        for p in psets:
            r = rows.get((p, s))
            if not r:
                cells.append("—")
                continue
            sv = r["solves"]
            it = "/".join(f"{v['iters']}{'*' if v['status'] != 'ok' else ''}" for v in sv.values())
            t = sum(v["t_solve"] for v in sv.values())
            cells.append(f"{it} ({t:.1f} с)")
            summ.setdefault(p, {})[s] = dict(ok=all(v["status"] == "ok" for v in sv.values()),
                                             iters=sum(v["iters"] for v in sv.values()), t=t)
        L.append(f"| {s} | " + " | ".join(cells) + " |")
    L += ["", "| набор | cbl: сошлось | cbl: итераций всего | cbl: с решателя всего | surface: сошлось |", "|---|---|---|---|---|"]
    for p in psets:
        c = [v for k, v in summ.get(p, {}).items() if k.endswith("cbl")]
        sf = [v for k, v in summ.get(p, {}).items() if k.endswith("surface")]
        L.append(f"| {p} | {sum(v['ok'] for v in c)}/{len(c)} | {sum(v['iters'] for v in c)} | {sum(v['t'] for v in c):.1f} | "
                 f"{sum(v['ok'] for v in sf)}/{len(sf)} |")
    (OUT / "a2_regression.md").write_text("\n".join(L) + "\n")
    (OUT / "a2_regression.json").write_text(json.dumps(dict(info=info, summary=summ), indent=1, ensure_ascii=False))
    print("\n".join(L))


if __name__ == "__main__":
    main()
