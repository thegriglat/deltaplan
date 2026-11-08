"""Экранировка (обратное действие колец на сдвиг), среднее поле: равновесие по замеру замыкания c_K(Ri), c_σ(Ri) из 3D-ансамбля.
Стационарное уравнение импульса: напряжение колец −⟨u'w'⟩ = c_K(Ri)·ℓ²S² равно заданному τ(z) = u*²(1 − z/H); Ri = N²/S²,
ℓ = κz. Отсюда S_eq(z), Ri_eq(z), σ_w,eq = c_σ(Ri_eq)·ℓ·S_eq. Без экранировки S = u*/(κz) (лог-слой) задан."""
import json, os
import numpy as np

OUT = os.path.join(os.path.dirname(__file__), "..", "out", "proto3d")


def tables():
    cl = json.load(open(os.path.join(OUT, "c_closure.json")))
    Ri = np.array([r["Ri"] for r in cl]); cK = np.array([r["cK"] for r in cl]); cs = np.array([r["c_sigma"] for r in cl])
    return Ri, cK, cs


def equilibrium(N2, ust=0.4, H=300.0, kappa=0.4, zs=(10, 25, 60, 120)):
    Ri_t, cK_t, cs_t = tables()
    # на Ri ≥ 0,25 рождения нет: c_K = 0 (таблица заканчивается 0,24 → экстраполяция в 0 при 0,25)
    Ri_t = np.append(Ri_t, 0.25); cK_t = np.append(cK_t, 0.0); cs_t = np.append(cs_t, 0.0)
    out = []
    for z in zs:
        tau = ust ** 2 * (1 - z / H)
        ell = kappa * z
        if N2 == 0:
            S = np.sqrt(tau / (cK_t[0] * ell ** 2)); Ri = 0.0
            ok = True
        else:
            Sg = np.linspace(2 * np.sqrt(N2) * 1.0001, 1.0, 200000)
            g = np.interp(N2 / Sg ** 2, Ri_t, cK_t) * ell ** 2 * Sg ** 2
            k = np.where(g >= tau)[0]
            ok = len(k) > 0
            S = Sg[k[0]] if ok else np.nan
            Ri = N2 / S ** 2 if ok else np.nan
        sw = float(np.interp(Ri, Ri_t, cs_t) * ell * S) if ok else 0.0
        S_log = ust / (kappa * z)
        out.append(dict(z=z, N2=N2, ok=bool(ok), S_eq=float(S), S_log=S_log, Ri_eq=float(Ri), sigma_w_eq=sw,
                        sigma_w_game=1.25 * ust * (1 - z / H) ** 0.75, ratio_game=sw / (1.25 * ust * (1 - z / H) ** 0.75)))
    return out


if __name__ == "__main__":
    for N2 in (0.0, 1e-4, 4e-4):
        for r in equilibrium(N2):
            print({k: (round(v, 4) if isinstance(v, float) else v) for k, v in r.items()})
