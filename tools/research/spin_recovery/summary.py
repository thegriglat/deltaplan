#!/usr/bin/env python3
"""SR-2: out/sr-2/raw/*.json → runs.jsonl, summary.json, tables.md (SR-К2). python3 tools/research/spin_recovery/summary.py"""
import json, subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
D = ROOT / "tools/research/spin_recovery/out/sr-2"
ORDER_V = ["game", "pnl_off", "rel_off", "wash12", "wash14", "lam_tipchord", "lam_dihedral", "lam_washout", "lam_sweep",
           "lam_all", "sweep_25_5", "sweep_26_25", "sweep_27", "sweep_28"]
VDOC = {
    "game": "игра как есть (pitch_nl и отпускание рук VM-12 включены)",
    "pnl_off": "pitch_nl выключен (strips.nl_on = false), dcm0 пересчитан под паспортный трим",
    "rel_off": "arms.release_event = false (без отпускания рук VM-12)",
    "wash12": "sport: washout_deg 10 → 12",
    "wash14": "sport: washout_deg 10 → 14",
    "lam_tipchord": "sport: tip_chord_m 0,55 → 0,62 (значение laminar)",
    "lam_dihedral": "sport: dihedral_eff_deg 0,5 → −1,5 (значение laminar)",
    "lam_washout": "sport: washout_deg 10 → 11 (значение laminar)",
    "lam_sweep": "sport: sweep_deg 26 → 26,5 (значение laminar)",
    "lam_all": "sport: tip_chord_m 0,62, dihedral_eff_deg −1,5, washout_deg 11, sweep_deg 26,5 (все четыре laminar)",
    "sweep_25_5": "sport: sweep_deg 25,5 (скан чувствительности к стреловидности)",
    "sweep_26_25": "sport: sweep_deg 26,25 (скан)",
    "sweep_27": "sport: sweep_deg 27 (скан)",
    "sweep_28": "sport: sweep_deg 28 (скан)",
}
MODES = ["release", "standard", "pull_release"]
DTN = {1 / 120: "1/120", 1 / 60: "1/60", 1 / 30: "1/30"}


def dtl(d):
    return next((v for k, v in DTN.items() if abs(k - d) < 1e-6), f"{d:.4f}")


def main():
    runs = [json.loads(p.read_text()) for p in sorted((D / "raw").glob("*.json"))]
    key = lambda r: (ORDER_V.index(r["variant"]), ["sport", "laminar", "training"].index(r["wing"]),
                     MODES.index(r["mode"]), -r["dt"])
    runs.sort(key=key)
    tmp = D / "runs.jsonl.tmp"
    tmp.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in runs))
    tmp.rename(D / "runs.jsonl")
    commit = subprocess.run(["git", "log", "-1", "--format=%h", "--", "tools/research/spin_recovery/spin_run.gd"],
                            cwd=ROOT, capture_output=True, text=True).stdout.strip() or "uncommitted"
    rows = [{k: v for k, v in r.items() if k != "extra"} for r in runs]
    used = [v for v in ORDER_V if any(r["variant"] == v for r in runs)]
    s = {"contract": "SR-К2 v1", "task": "SR-2", "commit": commit,
         "cmd": ["python3 tools/research/spin_recovery/run_sr2.py -j 10", "python3 tools/research/spin_recovery/summary.py"],
         "variants": {v: VDOC[v] for v in used}, "rows": rows}
    (D / "summary.json.tmp").write_text(json.dumps(s, ensure_ascii=False, indent=1))
    (D / "summary.json.tmp").rename(D / "summary.json")

    def cell(r):
        if not r["finite"]:
            return "nan"
        if r["first"] == "":
            return "без срыва"
        return f"да {r['recover_s']:.1f} с / {r['loss_m']:.0f} м" if r["recovered"] else "нет"

    by = {(r["wing"], r["variant"], r["mode"], round(1 / r["dt"])): r for r in runs}
    out = ["# SR-2: таблицы (выход да/нет, время от начала выхода / потеря высоты от срыва; шаг 1/120, если не указан)\n"]
    out.append("## Выход по крыльям, вариантам и режимам (1/120)\n")
    out.append("| крыло | вариант | trim, км/ч | release | standard | pull_release | рыскание штопора, °/с | снижение, м/с | макс. крен, ° |")
    out.append("|---|---|---|---|---|---|---|---|---|")
    for v in used:
        for w in ["sport", "laminar", "training"]:
            if (w, v, "release", 120) not in by:
                continue
            a = by[(w, v, "release", 120)]
            cs = [cell(by[(w, v, m, 120)]) if (w, v, m, 120) in by else "—" for m in MODES]
            out.append(f"| {w} | {v} | {a['trim_kmh']:.2f} | {cs[0]} | {cs[1]} | {cs[2]} | {a['spin_yaw_dps']:.0f} | "
                       f"{a['spin_sink_max_ms']:.1f} | {a['spin_bank_max_deg']:.0f} |")
    out.append("\n## Чувствительность к шагу (standard: выход да/нет, время с / потеря м)\n")
    out.append("| крыло | вариант | 1/120 | 1/60 | 1/30 |")
    out.append("|---|---|---|---|---|")
    for v in used:
        for w in ["sport", "laminar", "training"]:
            for m in ("standard", "pull_release"):
                if not all((w, v, m, d) in by for d in (120,)):
                    continue
                cs = [cell(by[(w, v, m, d)]) if (w, v, m, d) in by else "—" for d in (120, 60, 30)]
                if m == "pull_release" and cs[1] == "—":
                    continue
                out.append(f"| {w} | {v} ({m}) | {cs[0]} | {cs[1]} | {cs[2]} |")
    out.append("\n## Состояние в конце 60 с выхода (standard, 1/120): V, высота, крен, рыскание, сорвано полос\n")
    out.append("| крыло | вариант | V макс, км/ч | V в конце | высота в конце, м | крен | рыскание °/с | сорвано |")
    out.append("|---|---|---|---|---|---|---|---|")
    for v in used:
        for w in ["sport", "laminar", "training"]:
            r = by.get((w, v, "standard", 120))
            if r and "end_v_kmh" in r["extra"]:
                e = r["extra"]
                out.append(f"| {w} | {v} | {e['v_max_rec_kmh']:.0f} | {e['end_v_kmh']:.0f} | {e['end_h_m']:.0f} | "
                           f"{e['end_bank_deg']:.0f} | {e['end_yaw_dps']:.0f} | {e['end_stalled']} |")
    out.append("\n## Баланс вариантов\n")
    out.append("| крыло | вариант | dcm0 конфиг | dcm0 после балансировки | trim до, км/ч | trim после | C_L max крыла |")
    out.append("|---|---|---|---|---|---|---|")
    for v in used:
        for w in ["sport", "laminar", "training"]:
            r = by.get((w, v, "release", 120))
            if r:
                i = r["extra"]["info"]
                out.append(f"| {w} | {v} | {i['dcm0_cfg']:.5f} | {i.get('dcm0_balanced', i['dcm0_cfg']):.5f} | "
                           f"{i.get('trim_before_kmh', r['trim_kmh']):.3f} | {r['trim_kmh']:.3f} | {i['cl_max_wing']:.3f} |")
    (D / "tables.md").write_text("\n".join(out) + "\n")
    print("rows", len(rows), "commit", commit)


main()
