#!/usr/bin/env python3
"""SR-1: из сырого вывода стенда (out/sr-1/raw) собрать runs.jsonl, summary.json, tables.md (SR-К2).

Запуск: python3 -I tools/research/spin_recovery/sr1/build_out.py <git-хеш драйвера>
"""
import json
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
OUT = ROOT / "tools/research/spin_recovery/out/sr-1"
RAW = OUT / "raw"
COMMIT = sys.argv[1] if len(sys.argv) > 1 else "?"
WINGS = ("sport", "laminar", "training")
VARIANTS = {
    "game": "игра как есть: события мыши через Viewport.push_input, настройки мыши по умолчанию (controls.json → mouse), "
            "режим крена pendulum, штиль, ρ = const, 3000 м над рельефом",
    "model": "тот же сценарий прямым ControlInput в PendulumModel, без пути ввода (как test_pendulum_spin.gd)",
    "model_f1000": "как model, но предел усилия рук arms.force_max = 1000 Н вместо 300 Н (проверка: упирается ли выход в усилие)",
}
SUMMARY_MODES = ("release", "release_center", "standard")
PROBES = ("trim_pitch", "trim_rollp", "trim_rolln", "probe_pitch", "probe_rollp", "probe_rolln")


def load():
    return [json.loads(l) for l in (RAW / "raw_runs.jsonl").read_text(encoding="utf-8").splitlines() if l.strip()]


def f(x, nd=1, none="—"):
    return none if x is None else f"{x:.{nd}f}"


def main():
    runs = load()
    assert not (OUT / "traces").exists() or RAW.exists()
    # runs.jsonl
    tmp = OUT / "runs.jsonl.tmp"
    tmp.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in runs), encoding="utf-8")
    tmp.replace(OUT / "runs.jsonl")
    # summary
    rows = []
    for r in runs:
        if r["mode"] in SUMMARY_MODES:
            rows.append({k: v for k, v in r.items() if k != "extra"})
    summary = {
        "contract": "SR-К2 v1", "task": "SR-1", "commit": COMMIT,
        "cmd": [
            "XDG_DATA_HOME=~/.cache/dp-xdg/<копия> godot --headless --path . "
            "res://tools/research/spin_recovery/sr1/sr1_run.tscn -- --out=$PWD/tools/research/spin_recovery/out/sr-1/raw",
            "python3 -I tools/research/spin_recovery/sr1/build_out.py <git-хеш драйвера>",
        ],
        "variants": VARIANTS, "rows": rows,
    }
    tmp = OUT / "summary.json.tmp"
    tmp.write_text(json.dumps(summary, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    tmp.replace(OUT / "summary.json")
    # трассы
    dst = OUT / "traces"
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(RAW / "traces", dst)
    shutil.rmtree(RAW)  # raw_runs.jsonl == runs.jsonl, трассы скопированы
    # таблицы
    idx = {(r["variant"], r["wing"], r["mode"]): r for r in runs}
    L = []
    L.append("### Выход из штопора (SR-К1), шаг 1/120 с\n")
    L.append("Штопор одинаков во всех вариантах (одно и то же состояние в t_rec0). Выход — |крен| < 15°, "
             "|dψ/dt| < 20°/с, срыва нет 3 с подряд, за 60 с от t_rec0.\n")
    L.append("| крыло | штопор: рыскание °/с / макс. крен ° / снижение м/с | вариант | release | release_center | standard |")
    L.append("|---|---|---|---|---|---|")
    for w in WINGS:
        g = idx[("game", w, "standard")]
        sp = f"{f(g['spin_yaw_dps'], 0)} / {f(g['spin_bank_max_deg'], 0)} / {f(g['spin_sink_max_ms'], 1)}"
        for v in VARIANTS:
            cells = []
            for m in SUMMARY_MODES:
                r = idx[(v, w, m)]
                cells.append(f"{r['recover_s']:.1f} с, {r['loss_m']:.0f} м" if r["recovered"] else "нет выхода")
            L.append(f"| {w} | {sp} | {v} | " + " | ".join(cells) + " |")
    L.append("")
    L.append("### Отклик трапеции на шаг мыши (звено «руки → штанга»)\n")
    L.append("Ход = смещение пилота вдоль киля (тангаж) или поперёк (крен) относительно подвески за 1 с после шага; "
             "resp_ratio = ход в штопоре / ход на триме (знак учтён); t63 — время до 63 % заданного хода; "
             "насыщение — доля первой секунды с |F| ≥ 0,98·F_max. Шаг тангажа в штопоре — из «от себя» (+1) в «на себя» "
             "(−1), крена — из замороженного значения в ±1; на триме — из 0.\n")
    L.append("| крыло | вариант | шаг | ход за 1 с, м (триме) | ход за 1 с, м (штопор) | resp_ratio | t63, с (трим → штопор) | насыщение F_max | звено |")
    L.append("|---|---|---|---|---|---|---|---|---|")
    names = {"pitch": "тангаж −1", "rollp": "крен +1", "rolln": "крен −1"}
    for w in WINGS:
        for v in VARIANTS:
            for k in ("pitch", "rollp", "rolln"):
                t = idx[(v, w, "trim_" + k)]["extra"]["probe"]
                p = idx[(v, w, "probe_" + k)]["extra"]["probe"]
                L.append("| {} | {} | {} | {} | {} | {} | {} → {} | {} (трим {}) | {} |".format(
                    w, v, names[k], f(t["stroke1_m"], 2), f(p["stroke1_m"], 2),
                    f(p["resp_ratio"], 2), f(t["t63_s"], 2), f(p["t63_s"], 2, "не достигнут"),
                    f(p["force_sat_frac"], 2), f(t["force_sat_frac"], 2), p.get("lost") or "—"))
    L.append("")
    L.append("### Звенья пути ввода (игра, шаг в штопоре)\n")
    L.append("Смещение мыши `_mouse_offset` (до → через 0,1 с), ввод `inp` (ожидаемый → фактический), цель рук "
             "(ожидаемая по вводу → фактическая), м.\n")
    L.append("| крыло | шаг | offset | inp | цель рук, м | усилие рук, пик Н | ход Н/упор |")
    L.append("|---|---|---|---|---|---|---|")
    for w in WINGS:
        for k, ax in (("pitch", "y"), ("rollp", "x"), ("rolln", "x")):
            p = idx[("game", w, "probe_" + k)]["extra"]["probe"]
            L.append("| {} | {} | {} → {} | {} → {} | {} → {} | {} | F_max = 300 |".format(
                w, names[k], f(p.get("off_before"), 2), f(p.get("off_after"), 2),
                f(p.get("in_cmd"), 2), f(p.get("in_after"), 2),
                f(p.get("target_expected_m"), 3, "—"), f(p.get("target_m"), 3), f(p.get("force_peak_n"), 0)))
    L.append("")
    L.append("### Отпускание рук VM-12 в штопоре\n")
    L.append("Сценарий: с t_rec0 «на себя» (−1) 1,5 с → ввод ровно 0 (2 с; в игре мышь в мёртвой зоне ±0,02) → "
             "ввод −0,5.\n")
    L.append("| крыло | вариант | отпустили (с от t_rec0) | держали отпущенными до, с | f_x = 0 в окне ввода 0 | взяли снова после движения, с | доля времени отпущены в standard |")
    L.append("|---|---|---|---|---|---|---|")
    for w in WINGS:
        for v in ("game", "model"):
            e = idx[(v, w, "probe_vm12")]["extra"]["vm12"]
            s = idx[(v, w, "standard")]["extra"]
            L.append("| {} | {} | {} | {} | {} | {} | {} |".format(
                w, v, f(e["released_at_s"], 2), f(e["released_until_s"], 2), f(e["f_x_zero_frac_in_0_window"], 2),
                f(e["regrip_after_move_s"], 3), f(s.get("rel_on_frac"), 2)))
    L.append("")
    L.append("### Вердикт input_lost_at (правило SR-1)\n")
    L.append("`\"\"` — ввод доходит (resp_ratio ≥ 0,5 и t63 ≤ 3× трима); иначе первое звено цепочки "
             "event → offset → inp → arms_target → arms_force → bar. Вердикт крыла — первое непустое по трём шагам.\n")
    L.append("| крыло | " + " | ".join(VARIANTS) + " |")
    L.append("|---|" + "---|" * len(VARIANTS))
    for w in WINGS:
        L.append(f"| {w} | " + " | ".join(idx[(v, w, "standard")]["extra"]["input_lost_at"] or "—" for v in VARIANTS) + " |")
    (OUT / "tables.md").write_text("\n".join(L) + "\n", encoding="utf-8")
    print("ok", len(runs), "строк runs.jsonl,", len(rows), "строк summary")


main()
