"""SWD-16b: влияние неблагоприятного градиента давления и Re ядра на порог S_c (оценки порядка величины).
1) Бернулли по оси: внешний подъём давления dp = c*(rho W^2/2) тормозит осевой поток W -> W_eff=W*sqrt(1-c);
   k_eff=k/sqrt(1-c); срыв при k_eff>=k_c0  =>  k_c(c)=k_c0*sqrt(1-c)   (собственная оценка, не из обзора).
2) c для лежащего ротора: dp = Cp*rho U^2/2, W/U = 5.09*E*(Ls/H/4)*(ut/U/0.5) из s_vs_E.py  => c = Cp*(U/W)^2.
3) Re_core = Gamma/(2 pi nu_eff) для нескольких nu_eff; порог Spall: Ro_c~0.65 при Re_core>100, ниже — меньше."""
import json
import numpy as np
kc0 = (0.9, 1.2)
cs = [0, 0.1, 0.2, 0.3, 0.5, 0.7, 0.9]
out = {'k_c_vs_c': {f'c={c}': [round(k*np.sqrt(1-c), 3) for k in kc0] for c in cs}}
# c, нужное чтобы пересечь порог при заданном S (S>k_c0 -> "нет")
out['c_needed'] = {f'S={S}': {f'kc0={k}': round(max(0.0, 1-(k/S)**2), 3) for k in kc0} for S in (1.7, 2.5, 4.0)}
# давление хребта: W/U от E, c от Cp
rows = []
for E in (0.02, 0.05, 0.10):
    wu = 5.09*E
    for Cp in (0.05, 0.1, 0.3):
        rows.append(dict(E=E, W_over_U=round(wu, 3), Cp=Cp, c=round(Cp/wu**2, 2)))
out['c_from_ridge_pressure'] = rows
# Re ядра
Gam = [300., 400., 1000.]
out['Re_core'] = {f'nu_eff={nu}': [round(g/(2*np.pi*nu), 1) for g in Gam] for nu in (1.5e-5, 0.1, 1.0, 10.0)}
out['Re_core_Gamma'] = Gam
json.dump(out, open('adverse_re.json', 'w'), indent=1, ensure_ascii=False)
print(json.dumps(out, indent=1, ensure_ascii=False))
