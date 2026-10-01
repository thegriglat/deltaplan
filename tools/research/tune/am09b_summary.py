#!/usr/bin/env python3
"""AM-09б: итог проб «было при λ/h = 0,1 → стало при 0,25 с согласованным масштабом 3».

Было — закоммиченные результаты до AM-09б (git show BASE:путь; BASE — коммит до перепрогона):
  термики — air_thermals/out/stats.json (AM-07б, поля λ/h = 0,1);
  болтанка за гребнем и таблица σ — air_turb/out/turb_probe_{lee,table}.json (AM-08, 0,1, λ₃ = 40 м);
  то же за гребнем при 0,25 без правок масштаба 3 — строки JSON из tune/out/run_rest.log (AM-09);
  ТКЭ Askervein и проверки масштабов 2–3 — tune/out/fit_s3.json, validate_s23.json (AM-09).
Стало — те же файлы после run_am09b.sh.

  tools/research/tune/.venv/bin/python tools/research/tune/am09b_summary.py [--base <коммит>]
→ tools/research/tune/out/am09b/summary.json, summary.md
"""
from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
R = "tools/research/"
OUT = ROOT / R / "tune/out/am09b"


def git_json(base, path):
    return json.loads(subprocess.check_output(["git", "-C", str(ROOT), "show", f"{base}:{path}"]))


def cur_json(path):
    return json.loads((ROOT / path).read_text())


def pct(a, b):
    return None if a in (None, 0) or b is None else 100.0 * (b / a - 1.0)


def fmt(x, d=2):
    return "—" if x is None else f"{x:.{d}f}"


def fpct(p):
    return "—" if p is None else f"{p:+.0f} %"


def am09_lee(base):
    log = subprocess.check_output(["git", "-C", str(ROOT), "show", f"{base}:{R}tune/out/run_rest.log"]).decode()
    rows = [json.loads(ln) for ln in log.splitlines() if ln.startswith('{"analytic"')]
    return {r["key"]: r for r in rows}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="4c8251e")
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    res = dict(base=a.base, thermals=[], lee=[], table=[], checks=[], tke={})
    md = [f"# AM-09б: пробы 0,1 → 0,25 (база — {a.base})", ""]

    # --- термики (масштаб 2): поле
    b = git_json(a.base, R + "air_thermals/out/stats.json")
    c = cur_json(R + "air_thermals/out/stats.json")
    md += ["## Термики из поля (4 ч; круг 2,5 км у Каянчи для окна 100 м, 6 км для области 400 м)", "",
           "| поле | сила, м/с | живых ядер | сосед, м | потолок над землёй, м |", "|---|---|---|---|---|"]
    for k in sorted(b):
        fb, fc = b[k]["field"], c[k]["field"]
        row = dict(field=k)
        cells = []
        for name, get in (("strength", lambda f: f["strength"]["mean"]), ("alive", lambda f: f["alive_mean"]),
                          ("neighbor_m", lambda f: f["neighbor_m"]), ("ceiling_agl", lambda f: f["ceiling_agl"]["mean"])):
            vb, vc = get(fb), get(fc)
            row[name] = [vb, vc, pct(vb, vc)]
            cells.append(f"{fmt(vb, 2 if name == 'strength' else 0)} → {fmt(vc, 2 if name == 'strength' else 0)} ({fpct(pct(vb, vc))})")
        res["thermals"].append(row)
        md.append(f"| {k} | " + " | ".join(cells) + " |")

    # --- проверки масштабов 2–3 (густота, спектр)
    vb = git_json(a.base, R + "tune/out/validate_s23.json")
    vc = cur_json(R + "tune/out/validate_s23.json")
    md += ["", "## Проверки масштабов 2–3 по литературе", "", "| наблюдаемая | данные | было | стало | χ² было → стало |",
           "|---|---|---|---|---|"]
    for rb, rc in zip(vb, vc):
        res["checks"].append(dict(name=rc["name"], data=rc["data"], was=rb["model"], now=rc["model"],
                                  chi2=[rb["chi2"], rc["chi2"]]))
        md.append(f"| {rc['name']} | {fmt(rc['data'])} ± {fmt(rc['sig_data'])} | {fmt(rb['model'])} | "
                  f"{fmt(rc['model'])} | {fmt(rb['chi2'])} → {fmt(rc['chi2'])} |")
    md.append(f"| **сумма χ²** | | | | {fmt(sum(r['chi2'] for r in vb))} → {fmt(sum(r['chi2'] for r in vc))} |")

    # --- за гребнем (база AM-00, 10 м над склоном)
    lb = {r["key"]: r for r in git_json(a.base, R + "air_turb/out/turb_probe_lee.json")["lee"]}
    l9 = am09_lee(a.base)
    lc = {r["key"]: r for r in cur_json(R + "air_turb/out/turb_probe_lee.json")["lee"]}
    md += ["", "## За гребнем: точки базы AM-00 (10 м над склоном, ветер 20 км/ч с обратной стороны), с полем",
           "", "0,1 — AM-08; 0,25* — AM-09 (поля 0,25, масштаб 3 с λ = 40 м, k = 0,25); 0,25 — AM-09б.", "",
           "| старт | σ_w, м/с 0,1 / 0,25* / 0,25 | σ_u, м/с | рывки/мин | среднее w, м/с | аналитика AM-00: σ_w, рывки/мин |",
           "|---|---|---|---|---|---|"]
    for k in lb:
        f0, f9, f1 = lb[k]["field"], l9[k]["field"], lc[k]["field"]
        row = dict(site=k)
        cells = []
        for name, d in (("sigma_w", 2), ("sigma_u", 2), ("jerks_per_min", 1), ("mean_w", 2)):
            v = [f0[name], f9[name], f1[name]]
            row[name] = v + [pct(v[0], v[2])]
            cells.append(" / ".join(fmt(x, d) for x in v) + f" ({fpct(pct(v[0], v[2]))})")
        an = lc[k]["analytic"]
        res["lee"].append(row)
        md.append(f"| {k} | " + " | ".join(cells) + f" | {fmt(an['sigma_w'])}, {fmt(an['jerks_per_min'], 1)} |")

    # --- таблица σ (ветер, бровка, устойчивость)
    tb = git_json(a.base, R + "air_turb/out/turb_probe_table.json")["table"]
    tc = cur_json(R + "air_turb/out/turb_probe_table.json")["table"]
    md += ["", "## Таблица σ болтанки с полем (turb_probe --only=table)", "",
           "| случай | высота, м | σ_u 0,1 → 0,25 | σ_w 0,1 → 0,25 |", "|---|---|---|---|"]
    for rb, rc in zip(tb, tc):
        assert rb["case"] == rc["case"] and rb["agl"] == rc["agl"]
        res["table"].append(dict(case=rc["case"], agl=rc["agl"], sigma_u=[rb["sigma_u"], rc["sigma_u"]],
                                 sigma_w=[rb["sigma_w"], rc["sigma_w"]]))
        md.append(f"| {rc['case']} | {rc['agl']:.0f} | {fmt(rb['sigma_u'])} → {fmt(rc['sigma_u'])} "
                  f"({fpct(pct(rb['sigma_u'], rc['sigma_u']))}) | {fmt(rb['sigma_w'])} → {fmt(rc['sigma_w'])} "
                  f"({fpct(pct(rb['sigma_w'], rc['sigma_w']))}) |")

    # --- ТКЭ Askervein (масштаб 3)
    sb = git_json(a.base, R + "tune/out/fit_s3.json")
    sc = cur_json(R + "tune/out/fit_s3.json")
    res["tke"] = dict(groups=[sb["groups"], sc["groups"]], nominal=[sb["nominal"], sc["nominal"]])
    md += ["", "## ТКЭ на мачтах Askervein (масштаб 3, пороги AM-08)", "", "| группа | χ² AM-09 → AM-09б |", "|---|---|"]
    for g in sc["groups"]:
        gb, gc = sb["groups"].get(g), sc["groups"][g]
        md.append(f"| {g} | {json.dumps(gb, ensure_ascii=False)} → {json.dumps(gc, ensure_ascii=False)} |")
    md.append(f"| номинал | {json.dumps(sb['nominal'], ensure_ascii=False)} → {json.dumps(sc['nominal'], ensure_ascii=False)} |")

    steps = OUT / "steps.jsonl"
    if steps.exists():
        res["steps"] = [json.loads(ln) for ln in steps.read_text().splitlines() if ln.strip()]
    (OUT / "summary.json").write_text(json.dumps(res, ensure_ascii=False, indent=1))
    (OUT / "summary.md").write_text("\n".join(md) + "\n")
    print("\n".join(md))


if __name__ == "__main__":
    main()
