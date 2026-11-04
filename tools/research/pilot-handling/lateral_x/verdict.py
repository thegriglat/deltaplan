"""PHD-2: сборка out/../PHD-2_verdict.json (PHD-К2) из out/summary_modes_game.json, out/proto_cnp.jsonl, out/stab_axes.json."""
import json, os
from pathlib import Path
HERE = Path(__file__).resolve().parent
OUT = HERE / "out"
modes = json.load(open(OUT / "summary_modes_game.json"))
for ln in open(OUT / "proto_cnp.jsonl"):
    r = json.loads(ln)
    if r.get("dr_wn") == r.get("dr_wn"):
        modes.append({"wing": r["wing"], "case": f"Cnp={r['d_Cn_p']:+.3f} ({r['tag']}): толчок по рысканию, прототип", "mode": "dutch_roll",
                      "omega_rad_s": round(r["dr_wn"], 3), "zeta": round(r["dr_zeta"], 3), "source": "proto"})
st = json.load(open(OUT / "stab_axes.json"))
for w, o in st.items():
    for m in o["body_modes"]:
        modes.append({"wing": w, "case": "линейная 5-сост. модель, производные игры (связанные оси)", "mode": "dutch_roll",
                      "omega_rad_s": round(m["wn"], 3), "zeta": round(m["zeta"], 3), "source": "linear"})
    sw = o["swap"]["all_Kochi"]["dutch"]
    for m in sw:
        modes.append({"wing": w, "case": "линейная модель: производные Kochi 2020 (оси устойчивости), инерции крыла", "mode": "dutch_roll",
                      "omega_rad_s": round(m["wn"], 3), "zeta": round(m["zeta"], 3), "source": "linear"})
modes.append({"wing": "Hiway Demon", "case": "Cook & Spottiswoode 2005 / arXiv:2108.02393", "mode": "dutch_roll", "omega_rad_s": 0.92, "zeta": 0.29, "source": "literature"})
V = json.load(open(HERE / "verdict_text.json"))
d = {"task": "PHD-2", "items": [V["item3"]], "modes": modes}
dst = HERE.parent / "out" / "PHD-2_verdict.json"
dst.parent.mkdir(parents=True, exist_ok=True)
tmp = dst.with_suffix(".tmp")
tmp.write_text(json.dumps(d, indent=1, ensure_ascii=False))
os.replace(tmp, dst)
print("modes:", len(modes))
