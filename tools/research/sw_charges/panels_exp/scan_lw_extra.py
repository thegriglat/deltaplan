"""SWC-16 (1), добавка: профиль UC Davis по высоте (5 мм → 0.13H; 12.5 мм → 0.33H: dS 0.68 и 0.50 в статье), предел z→0 для
однородного потока, метрика «набор как в трубе» по 6 моделям. Пишет out/panels2d/tunnel/scan_lw_extra.json."""
import json, os, sys, itertools
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C
from scan_lw import dS_at, LW, Z_SW12, H

out = {}
# предел у земли, однородный поток
out["uniform_z_to_0"] = {m: [float(dS_at("cos2", LW[m][0], None, 0.0, [z * H])[0]) for z in (0.002, 0.01, 0.05)] for m in LW}
# Taylor–Lee B*H/L (B=2) для сравнения
out["TL_pred"] = {m: 2.0 * LW[m][0] for m in LW}
# UCD: две точки по высоте из статьи (Fig. 5: 0.68..0.72 при 5 мм, 0.50 при 12.5 мм)
zz = np.array([5 / 38.0, 12.5 / 38.0])
out["UCD_two_heights"] = {}
for name, a, s in [("uniform", None, 0.0), ("a0.19 s0", 0.19, 0.0), ("a0.19 s50", 0.19, 50.0), ("a0.19 s250", 0.19, 250.0), ("a0.19 s1000", 0.19, 1000.0)]:
    out["UCD_two_heights"][name] = dS_at("cos2", LW["UCD"][0], a, s, zz * H).tolist()
out["UCD_two_heights"]["obs"] = [0.68, 0.50]
# метрика: набор (профиль, сглаживание) на высоте «как в трубе» (UCD 0.13H, остальные — SWC-12); отношение модель/набл.
zH = dict(Z_SW12); zH["UCD"] = 5 / 38.0
sets = {}
for a, s in itertools.product((None, 0.10, 0.15, 0.19, 0.25), (0.0, 50.0, 250.0, 1000.0)):
    if a is None and s > 0:
        continue
    r = {m: float(dS_at("cos2", LW[m][0], a, s, [zH[m] * H])[0]) for m in LW}
    ratio = np.array([r[m] / LW[m][1] for m in LW])
    sets[f"{'uni' if a is None else a}|{int(s)}"] = dict(dS=r, ratio={m: float(x) for m, x in zip(LW, ratio)},
                                                       mean_ratio=float(ratio.mean()), rms_log=float(np.sqrt(np.mean(np.log(ratio) ** 2))),
                                                       range=[float(ratio.min()), float(ratio.max())])
out["sets"] = sets
out["z_used"] = zH
json.dump(out, open(os.path.join(C.OUT, "tunnel", "scan_lw_extra.json"), "w"), indent=1)
print(json.dumps({k: v for k, v in out.items() if k != "sets"}, indent=0)[:1500])
for k, v in sorted(sets.items(), key=lambda kv: kv[1]["rms_log"]):
    print(k, round(v["mean_ratio"], 2), round(v["rms_log"], 2), [round(x, 2) for x in v["range"]])
