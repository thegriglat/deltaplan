"""PB-1: аналитические оценки до прогонов и сопоставимость с моделью Cook (Hiway Demon).

1. Инерция тела пилота лёжа по сегментам de Leva 1996 (масса 85 кг, рост 1,75 м, руки вперёд).
2. Вклад пилота-точки и пилота-тела в Clp, CYβ, Cnβ (линейно, малые углы) — формулы и численно через pilot_body.
3. Дискретная боковая матрица Hiway Demon (Abouheaf et al., arXiv:2108.02393, табл. 1, Ts 0,01 с) →
   непрерывная A, её полюса, и какие Ixx, Izz, Yv, Nv в ней «зашиты» (по производным Kochi 2020:
   Cnβ 0,0275, Clβ −0,322, Clp −0,93, Clr 0,326, Cnr −0,0578, Cnp 0,0568; q = ½·1,225·10,8², S 16,26, b 10).
4. Та же 5-мерная линейная модель твёрдого тела (v, p, r, φ, ψ) с НАШИМИ производными и инерциями
   (пилот жёстко с крылом, как у Cook) — голландский шаг «как если бы пилот не качался».
5. ΔIzz тела → Δωn голландского шага.

  $PY pb1_analytic.py [out/pb1/lateral.jsonl]   → out/pb1/analytic.json, печать таблиц
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import numpy as np


def logm(A):
    """Матричный логарифм через собственное разложение (матрица близка к единичной, диагонализуема)."""
    w, Vm = np.linalg.eig(A)
    return Vm @ np.diag(np.log(w.astype(complex))) @ np.linalg.inv(Vm)

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from pendulum import pilot_body, trim  # noqa: E402
import pd21_lateral as L  # noqa: E402

OUT = HERE / "out" / "pb1"
G = 9.80665

# de Leva 1996 (J. Biomech. 29(9):1223–1230, табл. 4, мужчины): доля массы сегмента, положение ЦМ от
# проксимального конца (доля длины), радиус инерции вокруг поперечной оси (доля длины); длины — доли роста
# (Drillis & Contini 1966 / Winter 2009, табл. 4.1). Поза: лёжа, руки вперёд вдоль тела (вытянуты к штанге),
# ноги прямые — тело как цепочка сегментов вдоль одной оси.
DE_LEVA = {  # имя: (масса %, длина/рост, ЦМ доля от прокс., радиус инерции доля длины, число)
    "head": (6.94, 0.130, 0.5, 0.31, 1),
    "trunk": (43.46, 0.288 + 0.145, 0.45, 0.37, 1),  # грудь+живот+таз (de Leva: 15,96 + 16,33 + 11,17)
    "upper_arm": (2.71, 0.186, 0.577, 0.285, 2),
    "forearm": (1.62, 0.146, 0.457, 0.276, 2),
    "hand": (0.61, 0.108, 0.79, 0.628, 2),
    "thigh": (14.16, 0.245, 0.41, 0.329, 2),
    "shank": (4.33, 0.246, 0.44, 0.251, 2),
    "foot": (1.37, 0.152, 0.44, 0.257, 2),
}


def body_inertia(mass=85.0, height=1.75, harness=5.0, harness_len=1.8):
    """Инерция тела лёжа вокруг оси ⊥ телу через ЦМ (кг·м²): сегменты вдоль одной оси.
    Голова — на одном конце, затем туловище, бёдра, голени, стопы; руки — вдоль туловища вперёд
    (от плеча к голове, плечевой сустав ≈ верх туловища). Подвесная — стержень harness_len."""
    H = height
    pos, m, I = [], [], []
    x = 0.0  # от макушки вниз по телу
    def add(name, x0, direction=1):
        pct, ln, cg, rg, n = DE_LEVA[name]
        ln *= H
        ms = mass * pct / 100 * n
        xc = x0 + direction * cg * ln
        pos.append(xc); m.append(ms); I.append(ms * (rg * ln) ** 2)
        return x0 + direction * ln
    x = add("head", 0.0)
    x_sh = x  # плечи
    x = add("trunk", x)
    x = add("thigh", x)
    x = add("shank", x)
    add("foot", x)
    xa = add("upper_arm", x_sh, -1)  # руки вперёд, вдоль головы
    xa = add("forearm", xa, -1)
    add("hand", xa, -1)
    pos, m, I = np.array(pos), np.array(m), np.array(I)
    cg = (pos * m).sum() / m.sum()
    I_body = float((I + m * (pos - cg) ** 2).sum())
    I_h = harness * harness_len ** 2 / 12
    return {"m_body": float(m.sum()), "I_body_transverse": I_body, "I_harness": I_h,
            "I_total": I_body + I_h, "I_uniform_rod": mass * (1.75 ** 2) / 12}


def pilot_contrib(s, st, p=None):
    """Прямой вклад пилота в CYβ, Clβ, Cnβ, Clp, Cnp, Clr, Cnr (около ЦМ системы, оси устойчивости) при
    состоянии трима st — как trim.lateral_derivatives, но только сила пилота и момент тела."""
    p = p or s.p
    R = np.array(st["R"])
    V = st["V"]
    vel0 = np.array(st["vel"])
    d_b = np.array(st["pilot_dir_b"]) * p.hang_len
    r_p_b = s.r_hang_b + d_b
    r_sys_b = r_p_b * p.m_pilot / p.m_total
    q = 0.5 * p.rho * V * V
    Sb = p.area * p.span

    def fm(dv_b=np.zeros(3), w_b=np.zeros(3)):
        vel = vel0 + R @ dv_b
        w = R @ w_b
        vp = vel + np.cross(w, R @ r_p_b)
        F, M = pilot_body.pilot_force(p, vp, w, R, R @ d_b)
        Fb = R.T @ F
        return Fb, np.cross(r_p_b - r_sys_b, Fb) + R.T @ M

    F0, M0 = fm()
    db = math.radians(1.0)
    Fb_, Mb_ = fm(dv_b=np.array([0.0, V * math.sin(db), 0.0]))
    out = {"CY_beta": (Fb_[1] - F0[1]) / (q * p.area * db), "Cl_beta": (Mb_[0] - M0[0]) / (q * Sb * db),
           "Cn_beta": (Mb_[2] - M0[2]) / (q * Sb * db)}
    dr = 0.05
    rate = dr * 2 * V / p.span
    for name, wv in (("p", np.array([rate, 0, 0])), ("r", np.array([0, 0, rate]))):
        Fx, Mx = fm(w_b=wv)
        out[f"Cl_{name}"] = (Mx[0] - M0[0]) / (q * Sb * dr)
        out[f"Cn_{name}"] = (Mx[2] - M0[2]) / (q * Sb * dr)
    return {k: float(v) for k, v in out.items()}


def cook_matrix():
    """ALat Hiway Demon (arXiv:2108.02393, табл. 1; состояния v, p, r, φ, ψ; Ts = 0,01 с)."""
    A = np.array([
        [0.9977, -0.0028, -0.1069, 0.0971, -0.0131],
        [-0.0131, 0.8092, 0.0677, -0.0007, 0.0001],
        [0.0026, 0.0332, 0.9802, 0.0001, -0.0000],
        [-0.0001, 0.0090, 0.0004, 1.0000, 0.0000],
        [0.0000, 0.0002, 0.0099, 0.0000, 1.0000],
    ])
    Ts = 0.01
    Ac = np.real(logm(A)) / Ts
    ev = np.linalg.eigvals(Ac)
    return A, Ac, ev


def modes(ev):
    out = []
    for l_ in ev:
        if l_.imag > 1e-6:
            wn = abs(l_)
            out.append({"sigma": float(l_.real), "omega": float(l_.imag), "wn": float(wn), "zeta": float(-l_.real / wn)})
        elif abs(l_.imag) < 1e-6:
            out.append({"real": float(l_.real)})
    return out


def rigid_lateral_A(d, m, Ixx, Izz, V, S, b, theta=0.0, Ixz=0.0):
    """Непрерывная A (v, p, r, φ, ψ) твёрдого тела по производным d (Cl*, Cn*, CY*), американская форма."""
    q = 0.5 * 1.225 * V * V
    qS, qSb = q * S, q * S * b
    Yv = d.get("CY_beta", 0.0) * qS / (m * V)
    Yp = d.get("CY_p", 0.0) * qS * b / (2 * V * m)
    Yr = d.get("CY_r", 0.0) * qS * b / (2 * V * m)
    Lv, Lp, Lr = d["Cl_beta"] * qSb / V, d["Cl_p"] * qSb * b / (2 * V), d["Cl_r"] * qSb * b / (2 * V)
    Nv, Np, Nr = d["Cn_beta"] * qSb / V, d["Cn_p"] * qSb * b / (2 * V), d["Cn_r"] * qSb * b / (2 * V)
    Iinv = np.linalg.inv(np.array([[Ixx, -Ixz], [-Ixz, Izz]]))
    M = Iinv @ np.array([[Lv, Lp, Lr], [Nv, Np, Nr]])
    A = np.zeros((5, 5))
    A[0] = [Yv, Yp, Yr - V, G * math.cos(theta), 0]
    A[1, :3] = M[0]
    A[2, :3] = M[1]
    A[3] = [0, 1, math.tan(theta), 0, 0]
    A[4] = [0, 0, 1 / math.cos(theta), 0, 0]
    return A


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    res = {}
    # 1. инерция тела
    bi = body_inertia()
    res["body_inertia"] = bi
    print("1. Инерция тела лёжа (de Leva 1996), кг·м²:", {k: round(v, 1) for k, v in bi.items()})
    # 2. вклад пилота в производные: формулы и численно
    rows = {}
    for wing in L.WINGS:
        s = L.make_v(wing, {}, {})
        p, st = s.p, s.trim_state
        h = p.hang_len
        S, b = p.area, p.span
        f_clp_point = -2 * p.pilot_cda * h * h / (S * b * b)  # L = −½ρ·CdA·V·p·h² на p·b/2V
        f_cy_point = -p.pilot_cda / S  # Y = −½ρ·CdA·V·(V·β)
        d0 = trim.lateral_derivatives(s, st)
        sb = L.make_v(wing, {"pilot_body": "body"}, {})
        d1 = trim.lateral_derivatives(sb, sb.trim_state)
        # прямой вклад пилота в производные при ОДНОМ состоянии трима (сила пилота + момент тела)
        pc = pilot_contrib(s, st)
        pb = pilot_contrib(s, st, p.with_(pilot_body="body"))
        Izz0, Izz1 = float(s.I_b[2, 2]), float(sb.I_b[2, 2])
        rows[wing] = {
            "formula_Clp_point": f_clp_point, "formula_CYbeta_point": f_cy_point,
            "pilot_point": pc, "pilot_body": pb,
            "Izz_point": Izz0, "Izz_body": Izz1, "dwn_rel_from_Izz": math.sqrt(Izz0 / Izz1) - 1.0,
            "V_trim": st["V"], "gamma_deg": math.degrees(st["gamma"]),
            "derivs_point": {k: float(v) for k, v in d0.items()}, "derivs_body": {k: float(v) for k, v in d1.items()},
            "Ixx_wing_air": float(s.I_b[0, 0]), "Ixx_wing": float(s.I_struct[0, 0]), "m_wing": p.m_wing, "m_pilot": p.m_pilot,
            "theta_deg": math.degrees(st["theta"]), "S": S, "b": b,
        }
        r = rows[wing]
        print(f"2. {wing}: вклад пилота (точка / тело): Clp {pc['Cl_p']:+.5f} / {pb['Cl_p']:+.5f} (формула точки {f_clp_point:+.5f}); "
              f"CYβ {pc['CY_beta']:+.4f} / {pb['CY_beta']:+.4f} (формула {f_cy_point:+.4f}); Cnβ {pc['Cn_beta']:+.4f} / {pb['Cn_beta']:+.4f}; "
              f"Clβ {pc['Cl_beta']:+.4f} / {pb['Cl_beta']:+.4f}; Cnr {pc['Cn_r']:+.4f} / {pb['Cn_r']:+.4f}; "
              f"Izz {Izz0:.0f} → {Izz1:.0f} (Δωn по √ {100 * r['dwn_rel_from_Izz']:+.1f} %)")
    res["pilot_contrib"] = rows
    # 3. матрица Cook
    A, Ac, ev = cook_matrix()
    V, S, b, m = 10.8, 16.26, 10.0, 111.0
    q = 0.5 * 1.225 * V * V
    qSb = q * S * b
    ck = {"Cn_beta": 0.0275, "Cl_beta": -0.322, "CY_beta": -0.226, "Cl_p": -0.930, "Cl_r": 0.326, "Cn_r": -0.0578, "Cn_p": 0.0568,
          "CY_p": -0.0326, "CY_r": 0.0004}
    Yv, Lv, Lp, Lr, Nv, Np, Nr = Ac[0, 0], Ac[1, 0], Ac[1, 1], Ac[1, 2], Ac[2, 0], Ac[2, 1], Ac[2, 2]
    cook = {
        "Ac": Ac.tolist(), "poles": [[float(l_.real), float(l_.imag)] for l_ in ev], "modes": modes(ev),
        "Yv": float(Yv), "Lv": float(Lv), "Lp": float(Lp), "Lr": float(Lr), "Nv": float(Nv), "Np": float(Np), "Nr": float(Nr),
        "m_from_Yv": float(ck["CY_beta"] * q * S / (V * Yv)),
        "Ixx_from_Lv": float(ck["Cl_beta"] * qSb / (V * Lv)), "Ixx_from_Lp": float(ck["Cl_p"] * qSb * b / (2 * V * Lp)),
        "Ixx_from_Lr": float(ck["Cl_r"] * qSb * b / (2 * V * Lr)),
        "Izz_from_Nv": float(ck["Cn_beta"] * qSb / (V * Nv)), "Izz_from_Nr": float(ck["Cn_r"] * qSb * b / (2 * V * Nr)),
        "Izz_from_Np": float(ck["Cn_p"] * qSb * b / (2 * V * Np)),
        "wn_weathercock_sqrt_NvV": float(math.sqrt(max(Nv * V, 0))),
        "Nbeta_over_wn2_375_assumption": float(ck["Cn_beta"] * qSb / 0.92 ** 2),
    }
    # та же модель, собранная из производных Kochi с инерциями «по матрице» — проверка, что это даёт 0,92
    Ixx_c, Izz_c = cook["Ixx_from_Lp"], cook["Izz_from_Nv"]
    Ar = rigid_lateral_A(ck, m, Ixx_c, Izz_c, V, S, b)
    cook["rebuilt_modes"] = modes(np.linalg.eigvals(Ar))
    # без связи с креном (только v, r): √(Nβ/Izz) с Yv
    A2 = np.array([[Yv, -V], [Nv, Nr]])
    cook["yaw_only_modes"] = modes(np.linalg.eigvals(A2))
    res["cook"] = cook
    print("3. Cook (Hiway Demon) из матрицы arXiv: полюса", [f"{l_.real:+.3f}{l_.imag:+.3f}j" for l_ in ev])
    print(f"   Yv {Yv:.3f} 1/с, Lv {Lv:.3f}, Lp {Lp:.2f}, Lr {Lr:.2f}, Nv {Nv:.3f}, Np {Np:.2f}, Nr {Nr:.2f}")
    print(f"   m по Yv {cook['m_from_Yv']:.0f} кг; Ixx по Lv/Lp/Lr {cook['Ixx_from_Lv']:.0f}/{cook['Ixx_from_Lp']:.0f}/{cook['Ixx_from_Lr']:.0f}; "
          f"Izz по Nv/Nr/Np {cook['Izz_from_Nv']:.0f}/{cook['Izz_from_Nr']:.0f}/{cook['Izz_from_Np']:.0f} кг·м²")
    print(f"   флюгер √(Nv·V) = {cook['wn_weathercock_sqrt_NvV']:.2f} рад/с; «Izz = Nβ/ωn²» дало бы {cook['Nbeta_over_wn2_375_assumption']:.0f}")
    print("   моды, пересобранные из производных Kochi + инерций по матрице:", cook["rebuilt_modes"])
    print("   только рыскание (v, r):", cook["yaw_only_modes"])
    # 4. наша модель как твёрдое тело (пилот жёстко с крылом): v, p, r, φ, ψ
    rigid = {}
    for wing, r in rows.items():
        mw, mp = r["m_wing"], r["m_pilot"]
        h = 1.2
        mu = mw * mp / (mw + mp)
        th = math.radians(r["theta_deg"])
        for key, dd, I_add in (("point", r["derivs_point"], 0.0), ("body", r["derivs_body"], 14.0)):
            Ixx = r["Ixx_wing_air"] + mu * h * h + (1.3 if key == "body" else 0.0)
            Izz = r["Izz_point"] + I_add + mp * (h * math.sin(th)) ** 2 * mw / (mw + mp)
            Ar = rigid_lateral_A(dd, mw + mp, Ixx, Izz, r["V_trim"], r["S"], r["b"], theta=th)
            rigid[f"{wing}/{key}"] = {"Ixx": Ixx, "Izz": Izz, "modes": modes(np.linalg.eigvals(Ar)),
                                      "wn_weathercock": math.sqrt(max(dd["Cn_beta"] * 0.5 * 1.225 * r["V_trim"] ** 2 * r["S"] * r["b"] / Izz, 0))}
            dr = [mm for mm in rigid[f"{wing}/{key}"]["modes"] if "wn" in mm]
            print(f"4. {wing}/{key} жёсткий пилот: Ixx {Ixx:.0f}, Izz {Izz:.0f}; голландский шаг",
                  [f"ωn {mm['wn']:.2f} ζ {mm['zeta']:.2f}" for mm in dr], f"флюгер {rigid[f'{wing}/{key}']['wn_weathercock']:.2f}")
    res["rigid_pilot_linear"] = rigid
    # 4б. что сдвигает голландский шаг к Cook: наши производные (training, point), по одной заменяем на Cook
    r = rows["training"]
    th = math.radians(r["theta_deg"])
    mw, mp = r["m_wing"], r["m_pilot"]
    Ixx = r["Ixx_wing_air"] + mw * mp / (mw + mp) * 1.44
    Izz = r["Izz_point"]
    subst = {}
    base_d = dict(r["derivs_point"])
    for key in ("none", "Cn_beta", "Cl_beta", "Cl_p", "Cl_r", "Cn_r", "Cn_p", "CY_beta", "all"):
        dd = dict(base_d)
        if key == "all":
            dd.update({k: ck[k] for k in ("Cn_beta", "Cl_beta", "Cl_p", "Cl_r", "Cn_r", "Cn_p", "CY_beta")})
        elif key != "none":
            dd[key] = ck[key]
        mm = [x for x in modes(np.linalg.eigvals(rigid_lateral_A(dd, mw + mp, Ixx, Izz, r["V_trim"], r["S"], r["b"], theta=th))) if "wn" in x]
        subst[key] = mm
        print(f"4б. training, {key} → Cook:", [f"ωn {x['wn']:.2f} ζ {x['zeta']:.2f}" for x in mm])
    res["substitute_cook_training"] = subst
    # и наоборот: производные Cook с нашими инерциями и скоростью training — только инерция/скорость
    mm = [x for x in modes(np.linalg.eigvals(rigid_lateral_A(ck, mw + mp, Ixx, Izz, r["V_trim"], r["S"], r["b"], theta=th))) if "wn" in x]
    res["cook_derivs_our_inertia_training"] = mm
    print("4в. производные Cook + наши инерции, S, b, V (training):", [f"ωn {x['wn']:.2f} ζ {x['zeta']:.2f}" for x in mm])
    (OUT / "analytic.json").write_text(json.dumps(res, ensure_ascii=False, indent=1))
    print("→", OUT / "analytic.json")


if __name__ == "__main__":
    main()
