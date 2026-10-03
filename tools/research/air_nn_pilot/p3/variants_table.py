#!/usr/bin/env python3
"""Таблица вариантов П-3 (контракт П3 v4) из metrics.json оценок: reports/<run>/variants.md + variants.json.

  .venv/bin/python p3/variants_table.py --run <каталог прогона> --rep <каталог отчёта> --best300 <имя>

Строки: П-2 (main 300 мест, curve_100), варианты (0)–(4) на 100 местах, лучший на 300 местах. Числа (г) — сошедшиеся
решения, 60 м, все клетки области без края: медиана и p90 ошибки ветра, «ок» ветра и подъёма (без/с нагревом),
смещение e (среднее по высотам ≤ 300 м), ρ (медиана, p90; заменимость — config.yaml → eval.replace); (б) — медиана
ветра (сошедшиеся); время эпохи, размер и время ONNX (4 потока). Вердикт ШП-3 — правилом (П3 v4).
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
from pilotnn import common as C  # noqa: E402

ROWS = [("p2_main", "П-2 main (300 мест, зерно 1)"), ("p2_c100", "П-2 curve_100 (100 мест, зерно 1)"),
        ("v0_ctrl", "(0) контроль: кодировка П-2"), ("v1_wide", "(1) кодировка П-2, каналы ×2"),
        ("v2_in5", "(2) вход v5, выход v4"), ("v3_out5", "(3) вход v4, выход v5"), ("v4_io5", "(4) вход и выход v5")]
NUM = {"v0_ctrl": "(0)", "v1_wide": "(1)", "v2_in5": "(2)", "v3_out5": "(3)", "v4_io5": "(4)"}


def row_of(rep: Path, name, rc):
    p = rep / name / "metrics.json"
    if not p.exists():
        return None
    m = json.loads(p.read_text())
    hs = m["sets"]["holdout_sys"]["net"]
    c, nc = hs["conv"], hs.get("nc")
    ar = c["area"]
    agl = m["agl"]
    e = [v for a, v in zip(agl, c["bias"]["e"]) if a <= 300]
    hp = (m["sets"].get("holdout_place") or {}).get("net", {}).get("conv")
    rho = ar.get("rho") or {}
    groups = {}
    for g, d in (m["sets"]["holdout_sys"].get("groups") or {}).items():
        if g.startswith("система"):
            cc = (d.get("net") or {}).get("conv") or {}
            rr = (cc.get("area") or {}).get("rho") or {}
            groups[g.replace("система ", "")] = dict(n_cases=cc.get("n_cases"), rho_median=rr.get("median"),
                                                    rho_p90=rr.get("p90"), wind_median=(cc.get("area") or {}).get("wind", {}).get("median"))
    nrho = ((nc or {}).get("area") or {}).get("rho") or {}
    mm = m["main"]
    hist = mm.get("history") or []
    tr = None
    pt = rep / f"{name}__train" / "metrics.json"
    if pt.exists():
        tc = json.loads(pt.read_text())["sets"]["train"]["net"]["conv"]
        ta = tc["area"]
        tr = dict(n_cases=tc["n_cases"], wind_median=ta["wind"]["median"], wind_p90=ta["wind"]["p90"],
                  frac_wind_ok=ta["frac_wind_ok"], frac_lift_m_ok=ta.get("frac_lift_m_ok"), frac_lift_h_ok=ta.get("frac_lift_h_ok"),
                  rho_median=(ta.get("rho") or {}).get("median"))
    ok = (rho.get("median") is not None and rho["median"] <= rc["median_max"] and rho["p90"] <= rc["p90_max"])
    return dict(
        name=name, n_cases_conv=c["n_cases"], wind_median=ar["wind"]["median"], wind_p90=ar["wind"]["p90"],
        frac_wind_ok=ar["frac_wind_ok"], frac_lift_m_ok=ar.get("frac_lift_m_ok"), frac_lift_h_ok=ar.get("frac_lift_h_ok"),
        bias_e_le300=sum(e) / len(e), rho_median=rho.get("median"), rho_p90=rho.get("p90"), rho_frac_le1=rho.get("frac_le1"),
        replaceable=bool(ok), nc_rho_median=nrho.get("median"), nc_rho_p90=nrho.get("p90"),
        nc_wind_median=(((nc or {}).get("area") or {}).get("wind") or {}).get("median"),
        hp_wind_median=(hp or {}).get("area", {}).get("wind", {}).get("median") if hp else None,
        systems=groups, t_epoch_s=mm.get("t_epoch_median_s"), epochs=mm.get("epochs"), best_epoch=(mm.get("best") or {}).get("epoch"),
        n_params=mm.get("n_params"), n_train=mm.get("n_train"), train_set=tr,
        loss_val_best=(mm.get("best") or {}).get("val"), loss_train_last=hist[-1]["train"] if hist else None, enc=m.get("enc"), channels=(m.get("model_cfg") or {}).get("channels"),
        onnx=dict(path=m["onnx"]["path"], size_mb=m["onnx"]["size_mb"], time_ms_4=m["onnx"]["time_ms"].get("4", {}).get("median"),
                  ort_vs_torch_max_abs=m["onnx"]["ort_vs_torch_max_abs"], ort_vs_torch_ok=m["onnx"]["ort_vs_torch_ok"],
                  inputs=m["onnx"]["inputs"], metadata=m["onnx"].get("metadata", {})))


def verdict(r):
    """ШП-3 правилом (П3 v4) по медиане и p90 ветра на (г) сошедшиеся."""
    m = {k: r[k]["wind_median"] for k in NUM if r.get(k)}
    p = {k: r[k]["wind_p90"] for k in NUM if r.get(k)}
    enc = [k for k in ("v2_in5", "v3_out5", "v4_io5") if k in m]
    eb = min(enc, key=lambda k: m[k])
    lines = []
    if m[eb] <= 0.9 * min(m["v0_ctrl"], m["v1_wide"]) and p[eb] <= min(p["v0_ctrl"], p["v1_wide"]):
        v = "кодировка"
        lines.append(f"{NUM[eb]} медиана {m[eb]:.3f} ≤ 0,9 × min((0) {m['v0_ctrl']:.3f}, (1) {m['v1_wide']:.3f}) и p90 "
                     f"{p[eb]:.3f} не хуже → берём кодировку П-3 в волну 0 / air-onnx")
    elif m["v1_wide"] <= 0.9 * m[eb]:
        v = "ёмкость"
        lines.append(f"(1) медиана {m['v1_wide']:.3f} ≤ 0,9 × лучшего из (2)–(4) {NUM[eb]} {m[eb]:.3f} → сеть шире и каскад")
    elif not any(m[k] <= 0.9 * m["v0_ctrl"] for k in m if k != "v0_ctrl"):
        v = "данные"
        lines.append(f"ни один вариант не лучше (0) {m['v0_ctrl']:.3f} на ≥ 10 % → массовый счёт")
    else:
        v = "смешанный"
        lines.append("ни одно правило не выполнено целиком (лучше (0) на ≥ 10 %, но не по условиям «кодировка»/«ёмкость»)")
    lines.append("медианы: " + ", ".join(f"{NUM[k]} {m[k]:.3f}" for k in m) + "; p90: " + ", ".join(f"{NUM[k]} {p[k]:.3f}" for k in p))
    return v, eb, lines


def train_lines(r):
    """Вывод по обучающим: снижает ли ошибку на обучении кодировка (той же ширины) или только ширина, или оба
    (порог — разброс от зерна по (0) против curve_100 на обучающих)."""
    t = {k: (r.get(k) or {}).get("train_set") for k in NUM}
    if not all(t.values()) or not (r.get("p2_c100") or {}).get("train_set"):
        return ["обучающие: оценок нет"]
    m = {k: v["wind_median"] for k, v in t.items()}
    sp = abs(m["v0_ctrl"] - r["p2_c100"]["train_set"]["wind_median"])
    eb = min(("v2_in5", "v3_out5", "v4_io5"), key=lambda k: m[k])
    d_enc, d_wide = m["v0_ctrl"] - m[eb], m["v0_ctrl"] - m["v1_wide"]
    enc_ok, wide_ok = d_enc > max(sp, 0.1 * m["v0_ctrl"]), d_wide > max(sp, 0.1 * m["v0_ctrl"])
    v = ("оба" if enc_ok and wide_ok else "кодировка" if enc_ok else "ширина (ёмкость)" if wide_ok else "ни то, ни другое")
    return [f"обучающие, медиана ветра: (0) {m['v0_ctrl']:.3f}, (1) {m['v1_wide']:.3f}, (2) {m['v2_in5']:.3f}, (3) {m['v3_out5']:.3f}, "
            f"(4) {m['v4_io5']:.3f}; разброс от зерна {sp:.3f}; порог — max(разброс, 10 % от (0))",
            f"снижает ошибку на обучении: **{v}** (кодировка {NUM[eb]} −{d_enc:.3f}, ширина (1) −{d_wide:.3f} м/с к (0))"]


def f(x, nd=3, pct=False):
    if x is None:
        return "—"
    return f"{100 * x:.0f} %" if pct else f"{x:.{nd}f}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", required=True)
    ap.add_argument("--rep", required=True)
    ap.add_argument("--best300", required=True)
    a = ap.parse_args()
    run, rep = Path(a.run), Path(a.rep)
    cfg = C.load_config(HERE / "config.yaml")
    rc = cfg["eval"]["replace"]
    rows = {n: row_of(rep, n, rc) for n, _ in ROWS}
    rows[a.best300] = row_of(rep, a.best300, rc)
    sel = C.read_json(rep / "best_choice.json", {})
    best = rows[a.best300]
    v, eb, vlines = verdict(rows)
    spread = abs(rows["v0_ctrl"]["wind_median"] - rows["p2_c100"]["wind_median"])
    labels = dict(ROWS)
    labels[a.best300] = f"лучший {NUM.get(sel.get('best'), '?')} на 300 местах (зерно {cfg['p3']['seed']})"
    order = [n for n, _ in ROWS] + [a.best300]
    L = ["# П-3: таблица вариантов (NN-P12, контракт П3 v4)", "",
         f"Прогон `{run}`; оценки — `{rep}/<вариант>/metrics.json` (evaluate.py П3 v3 + ρ). Варианты (0)–(4) — 100 мест "
         f"(списки и гиперпараметры `curve_100` П-2, зерно {cfg['p3']['seed']}, до {cfg['p3']['max_epochs']} эпох, ранняя остановка "
         f"30); лучший — 300 мест (списки `main` П-2). Базовые линии в оценке — в кодировке v4 у всех строк.", "",
         "## (г) отложенные горные системы, сошедшиеся решения, 60 м, все клетки области", "",
         "| вариант | случаев | ветер медиана, м/с | p90 | «ок» ветра | «ок» подъёма m / h | смещение e ≤ 300 м | ρ медиана | ρ p90 | заменима | (б) ветер медиана | эпоха, с | эпох (лучшая) | параметров | ONNX МБ / мс |",
         "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for n in order:
        r = rows.get(n)
        if not r:
            L.append(f"| {labels[n]} | нет оценки |" + " |" * 13)
            continue
        L.append(f"| {labels[n]} | {r['n_cases_conv']} | {f(r['wind_median'])} | {f(r['wind_p90'])} | {f(r['frac_wind_ok'], pct=True)} | "
                 f"{f(r['frac_lift_m_ok'], pct=True)} / {f(r['frac_lift_h_ok'], pct=True)} | {r['bias_e_le300']:+.3f} | {f(r['rho_median'], 2)} | "
                 f"{f(r['rho_p90'], 2)} | {'да' if r['replaceable'] else 'нет'} | {f(r['hp_wind_median'])} | {f(r['t_epoch_s'], 1)} | "
                 f"{r['epochs']} ({(r['best_epoch'] or 0) + 1}) | {r['n_params'] / 1e6:.1f} M | {r['onnx']['size_mb']:.1f} / {f(r['onnx']['time_ms_4'], 1)} |")
    L += ["", f"Разброс от зерна: |(0) − curve_100 П-2| по медиане ветра = {spread:.3f} м/с "
              f"({100 * spread / rows['p2_c100']['wind_median']:.1f} %); p90: {abs(rows['v0_ctrl']['wind_p90'] - rows['p2_c100']['wind_p90']):.3f} м/с.",
          f"Выбор лучшего из (1)–(4): {NUM.get(sel.get('best'), '?')} (наименьшая медиана {sel.get('median_min', float('nan')):.3f}; "
          f"в пределах разброса {sel.get('spread', 0):.3f} — {', '.join(NUM.get(t, t) for t in sel.get('tie', []))}; из них — по p90).", "",
          "## Заменимость (ρ = ошибка ветра сети / погрешность решателя u на 60 м)", "",
          f"u_ref = max({rc['u_ref_floor_ms']} м/с; {rc['u_ref_rel']}·‖V_решателя‖), у несошедшихся — max(u_ref, late_spread60_p90). "
          f"«Заменима» — (г) сошедшиеся: медиана ρ ≤ {rc['median_max']} и p90 ρ ≤ {rc['p90_max']} (config.yaml → eval.replace).", "",
          "| вариант | ρ сошедшиеся медиана / p90 | доля ρ ≤ 1 | ρ несошедшиеся медиана / p90 | ветер несошедшиеся медиана |",
          "|---|---|---|---|---|"]
    for n in order:
        r = rows.get(n)
        if r:
            L.append(f"| {labels[n]} | {f(r['rho_median'], 2)} / {f(r['rho_p90'], 2)} | {f(r['rho_frac_le1'], pct=True)} | "
                     f"{f(r['nc_rho_median'], 2)} / {f(r['nc_rho_p90'], 2)} | {f(r['nc_wind_median'])} |")
    L += ["", "## Обучающие случаи (60 случаев из обучения curve_100 П-2 — в обучении всех строк; сошедшиеся, 60 м)", "",
          "Ошибка обучения (loss): v4 и v5 считаются по-разному (v5 — ошибка вектора с весом скорости) — сравнимы только внутри "
          "кодировки выхода.", "",
          "| вариант | случаев | ветер медиана | p90 | «ок» ветра | «ок» подъёма m / h | ρ медиана | (г) медиана | loss проверки (лучшая) | loss обучения (последняя эпоха) |",
          "|---|---|---|---|---|---|---|---|---|---|"]
    for n in order:
        r = rows.get(n)
        t = (r or {}).get("train_set")
        if r and t:
            L.append(f"| {labels[n]} | {t['n_cases']} | {f(t['wind_median'])} | {f(t['wind_p90'])} | {f(t['frac_wind_ok'], pct=True)} | "
                     f"{f(t['frac_lift_m_ok'], pct=True)} / {f(t['frac_lift_h_ok'], pct=True)} | {f(t['rho_median'], 2)} | "
                     f"{f(r['wind_median'])} | {f(r['loss_val_best'], 4)} | {f(r['loss_train_last'], 4)} |")
    tl = train_lines(rows)
    L += [""] + [f"- {x}" for x in tl]
    systems = sorted({s for n in order if rows.get(n) for s in rows[n]["systems"]})
    L += ["", "### (г) по горным системам, сошедшиеся: ρ медиана / p90 (ветер медиана, м/с)", "",
          "| вариант | " + " | ".join(systems) + " |", "|---|" + "---|" * len(systems)]
    for n in order:
        r = rows.get(n)
        if r:
            L.append(f"| {labels[n]} | " + " | ".join(
                f"{f(r['systems'].get(s, {}).get('rho_median'), 2)} / {f(r['systems'].get(s, {}).get('rho_p90'), 2)} "
                f"({f(r['systems'].get(s, {}).get('wind_median'))})" for s in systems) + " |")
    p2m = rows["p2_main"]
    d_med = (best["wind_median"] / p2m["wind_median"] - 1) * 100
    d_p90 = (best["wind_p90"] / p2m["wind_p90"] - 1) * 100
    L += ["", "## Лучший на 300 местах против П-2 main", "",
          f"{labels[a.best300]}: медиана {best['wind_median']:.3f} м/с ({d_med:+.1f} % к П-2 main {p2m['wind_median']:.3f}), "
          f"p90 {best['wind_p90']:.3f} ({d_p90:+.1f} % к {p2m['wind_p90']:.3f}); «ок» ветра {f(best['frac_wind_ok'], pct=True)} "
          f"(П-2 {f(p2m['frac_wind_ok'], pct=True)}); подъём m/h {f(best['frac_lift_m_ok'], pct=True)} / {f(best['frac_lift_h_ok'], pct=True)} "
          f"(П-2 {f(p2m['frac_lift_m_ok'], pct=True)} / {f(p2m['frac_lift_h_ok'], pct=True)}); смещение {best['bias_e_le300']:+.3f} "
          f"(П-2 {p2m['bias_e_le300']:+.3f}); ρ {f(best['rho_median'], 2)} / {f(best['rho_p90'], 2)} (П-2 {f(p2m['rho_median'], 2)} / {f(p2m['rho_p90'], 2)}).",
          f"ONNX: `{best['onnx']['path']}`, {best['onnx']['size_mb']:.1f} МБ, {f(best['onnx']['time_ms_4'], 1)} мс (4 потока CPU), "
          f"вход {best['onnx']['inputs']}, ORT ↔ PyTorch max|Δ| {best['onnx']['ort_vs_torch_max_abs']:.1e} "
          f"({'ок' if best['onnx']['ort_vs_torch_ok'] else 'НЕ ок'}); метаданные {best['onnx']['metadata']}.", "",
          "## Вердикт ШП-3 (правилом, П3 v4)", "", f"**{v}**", ""] + [f"- {x}" for x in vlines] + [
          f"- заменима (лучший на 300 местах): **{'да' if best['replaceable'] else 'нет'}** "
          f"(ρ медиана {f(best['rho_median'], 2)} ≤ {rc['median_max']}? p90 {f(best['rho_p90'], 2)} ≤ {rc['p90_max']}?)"]
    (rep / "variants.md").write_text("\n".join(L) + "\n")
    C.atomic_write_json(rep / "variants.json", dict(
        rows=rows, labels=labels, spread_seed=spread, choice=sel, verdict=dict(rule=v, best_encoding=eb, lines=vlines),
        train_verdict=train_lines(rows), replace_rule=rc, best=dict(best, run=a.best300, variant=sel.get("best"))))
    print("\n".join(L))
    return 0


if __name__ == "__main__":
    sys.exit(main())
