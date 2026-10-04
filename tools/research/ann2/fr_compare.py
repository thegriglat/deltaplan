"""AN-4 п. 1: Fr⁻¹ случая против старого (по фону 3 К/км): Fr⁻¹ = N·σ_h/U10, σ_h, U10 те же, N: sqrt(g/θ0·3 К/км) = 0,00990 1/с (AN-3)
против N_bl случая (z_i…z_i+1500 м, Day.gamma). Отношение новое/старое = N_bl/0,0099 — по часам и режимам → out/an4/fr_compare.json."""
import json
import numpy as np
import phys, regime as RG, common as C

t = RG.table()
n0 = phys.N2_BG ** 0.5
ratio = t["N_bl"] / n0
mech = t["wsu"] <= RG.WSU_THR
out = dict(N_old=n0, n_cases=int(len(ratio)), n_mech=int(mech.sum()))
def q(a):
    return {k: float(v) for k, v in zip(("p10", "p50", "p90", "min", "max"), list(np.percentile(a, [10, 50, 90])) + [a.min(), a.max()])}
out["ratio_new_old_all"] = q(ratio); out["ratio_new_old_mech"] = q(ratio[mech])
out["by_hour_mech"] = {str(int(h)): q(ratio[mech & (t["hour"] == h)]) for h in np.unique(t["hour"])}
out["frac_mech_ratio_ne_1p39pm5pct"] = float(np.mean(np.abs(ratio[mech] / np.median(ratio[mech]) - 1) > 0.05))
out["N_bl_unique_mech_rounded_1e-4"] = int(len({round(x, 4) for x in t["N_bl"][mech]}))
(C.OUT / "an4").mkdir(exist_ok=True)
(C.OUT / "an4" / "fr_compare.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))
print(json.dumps(out, ensure_ascii=False, indent=1))
