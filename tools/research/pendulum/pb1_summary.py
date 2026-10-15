"""PB-1: сводка до/после по PB-К2 v1 (`out/pb1/summary.json`), таблица `out/pb1/tables.md`, графики `out/pb1/fig/`.

  $PY pb1_summary.py   (после pb1_lateral.py run, pb1_turb.py run, pb1_analytic.py)
"""

from __future__ import annotations

import json
import math
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import pb1_turb as T  # noqa: E402

OUT = HERE / "out" / "pb1"
WINGS = ("training", "laminar", "sport")
MAP = {  # ключ PB-К2 → ключ lateral.jsonl
    "clp": "d_Cl_p", "cnp": "d_Cn_p", "cn_beta": "d_Cn_beta", "cl_beta": "d_Cl_beta", "cy_beta": "d_CY_beta",
    "cnr": "d_Cn_r", "clr": "d_Cl_r", "dutch_omega_rad_s": "dr_wn", "dutch_zeta": "dr_zeta",
    "reversal_45_s": "rev_t", "reversal_30_s": "rev30_t", "reversal_beta_max_deg": "rev_beta_max",
    "turn30_beta_cg_deg": "turn_beta_cg", "turn30_ribbon_deg": "turn_beta_node", "ochi_bank_7s_deg": "ochi_phi7",
    "trim_kmh": "trim_kmh", "sink_ms": "sink_ms", "full_pull_kmh": "full_pull_kmh",
}
LIT = {  # Hiway Demon (Cook & Spottiswoode 2005 по Kochi 2020 / arXiv:2108.02393) и суждения литературы
    "clp": (-0.93, "−0,8…−1,1"), "cnp": (0.057, "+0,057 / −0,068"), "cn_beta": (0.0275, "0,018–0,04"),
    "cl_beta": (-0.322, "−0,11…−0,32"), "cy_beta": (-0.226, "−0,19…−0,25"), "cnr": (-0.058, "±30 %"), "clr": (0.326, "±30 %"),
    "dutch_omega_rad_s": (0.92, "0,75–1,1"), "dutch_zeta": (0.29, "0,2–0,4"), "reversal_45_s": (4.0, "≈ 4 с (пилот)"),
    "reversal_beta_max_deg": (15.0, "≤ 15–20° (суждение)"), "turn30_ribbon_deg": (3.0, "< 3° (пилот: «строго назад»)"),
    "ochi_bank_7s_deg": (30.0, "≈ 30° (Ochi)"),
}
DESC = {
    "base": "пилот — точка: изотропное сопротивление pilot_cda 0,21 м² (как в игре и во всех прошлых опытах)",
    "body": "пилот — тело в коконе (pilot_body.py): лобовое CdA 0,21 м² вдоль тела, поперёк — cross-flow Cd 0,8 на площади 1,8×0,45 / 1,8×0,30 м, момент Мунка, инерция по рысканию 28 и по крену 1,3 кг·м² жёстко с крылом (руки)",
    "body_lo": "чувствительность, нижняя граница: CdA 0,12 м², площади кокона −30 %, инерция 14 кг·м²",
    "body_hi": "чувствительность, верхняя граница: CdA 0,23 м², площади кокона +30 %, Cd 1,0, инерция 35 кг·м²",
}


def num(x):
    return None if x is None or (isinstance(x, float) and not math.isfinite(x)) else float(x)


def main():
    lat = [json.loads(l) for l in (OUT / "lateral.jsonl").read_text().splitlines() if l.strip()]
    lat = {(r["name"], r["wing"]): r for r in lat if not r.get("err")}
    turb = T.summarize(OUT / "turb.jsonl") if (OUT / "turb.jsonl").exists() else {}
    an = json.loads((OUT / "analytic.json").read_text()) if (OUT / "analytic.json").exists() else {}
    variants, notes = {}, {}
    names = sorted({k[0] for k in lat}, key=lambda n: ["base", "body", "body_lo", "body_hi"].index(n) if n in DESC else 9)
    for name in names:
        wings = {}
        for w in WINGS:
            r = lat.get((name, w))
            if r is None:
                continue
            m = {k: num(r.get(src)) for k, src in MAP.items()}
            tb = turb.get((name, w))
            m["turb_capsize_n"] = tb["turb_capsize_n"] if tb else None
            m["turb_runs_n"] = tb["turb_runs_n"] if tb else None
            m["_extra"] = {"spiral30_phi_5_10_20": [r.get("sp30_phi5"), r.get("sp30_phi10"), r.get("sp30_phi20")],
                           "spiral_E": r.get("d_spiral_E"), "Izz_kgm2": r.get("Izz_wing"), "wn_weathercock": r.get("wn_simple"),
                           "turn30_r_rad_s": r.get("turn_r"), "turb_max_phi_deg": tb["turb_max_phi_deg"] if tb else None,
                           "turb_by_hz": tb["by_hz"] if tb else None, "trim_alpha_deg": r.get("trim_alpha_deg")}
            wings[w] = m
        variants[name] = {"desc": DESC.get(name, name), "wings": wings}
    notes["ochi_bank_7s_deg"] = "опыт Ochi (Wills Wing Sport 2 155, пилот 72,6 кг) ставится только на laminar — ближайшее крыло; у training и sport null"
    notes["turb_runs_n"] = "прототип: 11 полей × 3 шага (1/120, 1/60, 1/30) = 33 прогона на крыло; «2 блока» PD-19 — различие блока pendulum игры и прототипа, которого в прототипе нет"
    for name in names:
        for w in WINGS:
            if name in variants and w in variants[name]["wings"]:
                for k, v in variants[name]["wings"][w].items():
                    if v is None and k not in ("ochi_bank_7s_deg",) and not k.startswith("_"):
                        notes[f"{name}/{w}/{k}"] = "опыт не дал числа (см. lateral.jsonl / turb.jsonl)"
    sources = [
        {"what": "боковые производные, голландский шаг, спираль Hiway Demon", "ref": "M. V. Cook, M. Spottiswoode, 2005, Modelling the flight dynamics of the hang glider, Aeronaut. J. 109(1102)", "url": "https://doi.org/10.1017/S0001924000001007"},
        {"what": "таблица производных Hiway Demon (из Cook & Spottiswoode)", "ref": "Kochi University of Technology, 2020, Study on hang glider type small UAV, выпускная работа 1235104, табл. 2–4", "url": "https://www.kochi-tech.ac.jp/library/ron/pdf/2020/03/20/a1235104.pdf"},
        {"what": "дискретная боковая матрица ALat Hiway Demon (Ts 0,01 с) и полюса — пилот с крылом одно твёрдое тело", "ref": "M. Abouheaf, W. Gueaieb, F. Lewis, 2021, Online model-free RL for the automatic control of a flexible wing aircraft, табл. 1–2", "url": "https://arxiv.org/abs/2108.02393"},
        {"what": "в модели Cook относительная поза пилота — вход управления, относительное движение пилота не рассматривается", "ref": "T. Takamatsu, Y. Ochi, 2022, Flight tests and simulation of a hang glider, ICAS 2022-0135", "url": "https://www.icas.org/ICAS_ARCHIVE/ICAS2022/data/papers/ICAS2022_0135_paper.pdf"},
        {"what": "CdA пилота лёжа 0,21 м² (разброс 0,12–0,23); киль-карман", "ref": "I. M. Kroo, 1981, Aerodynamics, aeroelasticity, and stability of hang gliders — experimental results, NASA TM-81269", "url": "https://ntrs.nasa.gov/api/citations/19810015490/downloads/19810015490.pdf"},
        {"what": "принцип поперечного обтекания (cross-flow): нормальная сила тела ∝ квадрату поперечной скорости", "ref": "H. J. Allen, E. W. Perkins, 1951, A study of effects of viscosity on flow over slender inclined bodies of revolution, NACA Report 1048 (RM A50L07)", "url": "https://ntrs.nasa.gov/citations/19930092065"},
        {"what": "Cd конечного цилиндра поперёк потока l/d ≈ 5 ≈ 0,8 (оценка для кокона)", "ref": "S. F. Hoerner, 1965, Fluid-Dynamic Drag, гл. III", "url": "https://archive.org/details/FluidDynamicDragHoerner1965"},
        {"what": "момент Мунка q·Vol·(k2 − k1)·sin 2β, коэффициенты эллипсоида", "ref": "M. M. Munk, 1924, The aerodynamic forces on airship hulls, NACA Report 184", "url": "https://ntrs.nasa.gov/citations/19930091249"},
        {"what": "сегментные параметры тела (массы, ЦМ, радиусы инерции) — инерция тела лёжа", "ref": "P. de Leva, 1996, Adjustments to Zatsiorsky-Seluyanov's segment inertia parameters, J. Biomech. 29(9):1223–1230", "url": "https://doi.org/10.1016/0021-9290(95)00178-6"},
        {"what": "длины сегментов в долях роста", "ref": "D. A. Winter, 2009, Biomechanics and Motor Control of Human Movement, 4th ed., табл. 4.1 (по Drillis & Contini 1966)", "url": "https://doi.org/10.1002/9780470549148"},
        {"what": "лётный опыт: 30 Н вбок → крен ≈ 30° за ≈ 7 с", "ref": "T. Takamatsu, Y. Ochi, 2022, ICAS 2022-0135", "url": "https://www.icas.org/ICAS_ARCHIVE/ICAS2022/data/papers/ICAS2022_0135_paper.pdf"},
    ]
    summary = {
        "contract": "PB-К2 v1", "task": "PB-1", "variants": variants, "notes": notes, "sources": sources,
        "literature": {k: {"value": v[0], "range": v[1]} for k, v in LIT.items()},
        "analytic": {k: an.get(k) for k in ("body_inertia", "cook", "substitute_cook_training", "cook_derivs_our_inertia_training")},
        "reproduce": "PY=/home/greg/deltaplan/tools/research/heat_ca/.venv/bin/python; cd tools/research/pendulum; $PY pb1_analytic.py; "
                     "$PY pb1_lateral.py run --jobs 6; $PY pb1_turb.py run --jobs 16; $PY pb1_summary.py",
    }
    tmp = OUT / "summary.json.tmp"
    tmp.write_text(json.dumps(summary, ensure_ascii=False, indent=1))
    os.replace(tmp, OUT / "summary.json")
    write_tables(variants, names)
    figures(variants, names)
    print("→", OUT / "summary.json")


ROWS = [("Clβ", "cl_beta", "{:.3f}"), ("Clp", "clp", "{:.3f}"), ("Clr", "clr", "{:.3f}"), ("Cnβ", "cn_beta", "{:.4f}"),
        ("Cnp", "cnp", "{:.4f}"), ("Cnr", "cnr", "{:.4f}"), ("CYβ", "cy_beta", "{:.3f}"),
        ("Izz крыла (+тело), кг·м²", "_extra.Izz_kgm2", "{:.0f}"),
        ("голландский шаг ωn, рад/с", "dutch_omega_rad_s", "{:.2f}"), ("голландский шаг ζ", "dutch_zeta", "{:.2f}"),
        ("перекладка 45→45, с", "reversal_45_s", "{:.2f}"), ("перекладка: наибольшее |β|, °", "reversal_beta_max_deg", "{:.1f}"),
        ("перекладка 30→30, с", "reversal_30_s", "{:.2f}"), ("вираж 30°: β у ЦМ, °", "turn30_beta_cg_deg", "{:.1f}"),
        ("вираж 30°: лента у узла, °", "turn30_ribbon_deg", "{:.1f}"), ("Ochi: крен через 7 с, °", "ochi_bank_7s_deg", "{:.1f}"),
        ("болтанка: |крен| ≥ 60°, из 33", "turb_capsize_n", "{:d}"), ("болтанка: макс |крен|, °", "_extra.turb_max_phi_deg", "{:.0f}"),
        ("из 30° руки в нейтраль: крен через 5/10/20 с", "_extra.spiral30_phi_5_10_20", None),
        ("трим, км/ч", "trim_kmh", "{:.1f}"), ("снижение, м/с", "sink_ms", "{:.2f}"), ("полный «на себя», км/ч", "full_pull_kmh", "{:.1f}")]


def get(m, key):
    if key.startswith("_extra."):
        return m["_extra"].get(key[7:])
    return m.get(key)


def cell(m, key, f):
    v = get(m, key)
    if v is None:
        return "—"
    if f is None:
        return "/".join("—" if x is None else f"{x:.0f}" for x in v)
    if f == "{:d}":
        return str(int(v))
    return f.format(v)


def write_tables(variants, names):
    lines = ["# PB-1: пилот-точка (base) и пилот-тело (body) — опыты PD-21/PD-24", ""]
    lines.append("| величина | литература | " + " | ".join(f"{n} (tr / lam / sp)" for n in names) + " |")
    lines.append("|---|---|" + "---|" * len(names))
    for title, key, f in ROWS:
        lit = LIT.get(key)
        ls = f"{lit[0]} ({lit[1]})" if lit else "—"
        cells = []
        for n in names:
            ws = variants[n]["wings"]
            cells.append(" / ".join(cell(ws[w], key, f) if w in ws else "—" for w in WINGS))
        lines.append(f"| {title} | {ls} | " + " | ".join(cells) + " |")
    (OUT / "tables.md").write_text("\n".join(lines) + "\n")


def figures(variants, names):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        return
    fig_dir = OUT / "fig"
    fig_dir.mkdir(exist_ok=True)
    colors = {"base": "#6b7280", "body": "#2563eb", "body_lo": "#93c5fd", "body_hi": "#1e3a8a"}
    items = [("clp", "Clp"), ("cn_beta", "Cnβ"), ("dutch_omega_rad_s", "ГШ ωn, рад/с"), ("dutch_zeta", "ГШ ζ"),
             ("reversal_beta_max_deg", "перекладка |β|max, °"), ("turn30_ribbon_deg", "лента в вираже 30°, °")]
    fig, axes = plt.subplots(2, 3, figsize=(12, 6.5))
    for ax, (key, title) in zip(axes.flat, items):
        x = range(len(WINGS))
        for j, n in enumerate(names):
            ys = [get(variants[n]["wings"][w], key) if w in variants[n]["wings"] else None for w in WINGS]
            ax.plot([xi + (j - 1.5) * 0.12 for xi in x], [float("nan") if y is None else y for y in ys], "o",
                    color=colors.get(n, "k"), label=n)
        if key in LIT:
            ax.axhline(LIT[key][0], color="#dc2626", ls="--", lw=1, label="литература")
        ax.set_xticks(list(x)); ax.set_xticklabels(WINGS); ax.set_title(title); ax.grid(alpha=0.3)
    axes[0, 0].legend(fontsize=8)
    fig.suptitle("PB-1: пилот-точка против пилота-тела (прототип маятника, трим, эталонная масса)")
    fig.tight_layout()
    fig.savefig(fig_dir / "pb1_metrics.png", dpi=130)
    plt.close(fig)
    # болтанка
    fig, ax = plt.subplots(figsize=(6, 3.5))
    for j, n in enumerate(names):
        ys = [get(variants[n]["wings"][w], "turb_capsize_n") if w in variants[n]["wings"] else None for w in WINGS]
        ax.bar([i + (j - 1.5) * 0.2 for i in range(len(WINGS))], [0 if y is None else y for y in ys], width=0.18,
               color=colors.get(n, "k"), label=n)
    ax.set_xticks(range(len(WINGS))); ax.set_xticklabels(WINGS); ax.set_ylabel("прогонов с |крен| ≥ 60° из 33")
    ax.set_title("Болтанка σ 1 м/с, 11 полей × 3 шага"); ax.legend(fontsize=8); ax.grid(alpha=0.3, axis="y")
    fig.tight_layout()
    fig.savefig(fig_dir / "pb1_turb.png", dpi=130)
    plt.close(fig)


if __name__ == "__main__":
    main()
