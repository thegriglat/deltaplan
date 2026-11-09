"""TB-12/TB-15 (круг 3): v5 — пузырь from_game_strength (F0 из потока); профиль q(xi) «между» по высоте под шаблон пузыря.

В игре «между» = w_conv - доля * expected_net(p), expected_net = carried * q(xi)/q_mean (rust thermal_air/expected.rs).
Сумма «пузыри + между» совпадает с w_conv на уровне xi, только если q(xi) = профиль среднего потока вверх самого
шаблона (по жизни пузыря). Считаем его, сравниваем с нынешним q (радиус^2 ядра Аллена) и с целевым профилем подъёма
(Lenschow-Stephens 1980: w_hat/w* = xi^(1/3)(1-1.1 xi)).
Запуск: tools/research/thermal_bubble/py tools/research/thermal_bubble/round3/between.py [--check]
"""
from __future__ import annotations

import dataclasses
import json
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT))
import bubble as bb  # noqa: E402

OUT = ROOT / "out" / "round3_between.json"
FIG = HERE / "between_profile.png"
ZL, WSTAR, TAU = 1400.0, 2.56, 690.0
W0_TYP, W0_CAP = bb.K_ALLEN * WSTAR, 2.5 * WSTAR
PHI = 0.35 * 0.45 * WSTAR          # м/с: доля площади подъёма x средний подъём (L&S 1980, Stull 1988)
NA = 8.5 / ZL ** 2                 # Аллен 2006
GAME_LIFE_S = 990.0                # жизнь термика игры (docs/research/thermal_bubble.md, круг 2 п. 5.1)
XI = np.linspace(0.0, 1.0, 21)
ENV = bb.Env(wind=(0.0, 0.0), zi=ZL)


def trap_mean(q):
    return float(np.sum(q[1:] + q[:-1]) * 0.5 / (len(q) - 1))


def norm(q):
    q = np.asarray(q, float)
    return q / trap_mean(q)


def q_now(d0=1000.0, rmin=0.45, ramp=150.0, taper=120.0):
    """Формула expected.rs::q_at (cfg по умолчанию, как в compare.py), d0 = 1000 м как в Shape::new."""
    out = []
    for xi in XI:
        rf = max(rmin, xi ** (1 / 3) * (1 - 0.25 * xi) / 0.75)
        dh = xi * d0
        vert = min(1.0, (dh / ramp) ** (1 / 3)) if dh > 0 else 0.0
        x = np.clip((d0 - dh) / taper, 0, 1)
        out.append(rf * rf * vert * x * x * (3 - 2 * x))
    return np.array(out)


def target():
    """Целевой профиль подъёма: w_hat/w* = xi^(1/3)(1-1.1 xi), >= 0 (L&S 1980); доля площади подъёма от высоты не берётся (допущение: const)."""
    return np.array([max(0.0, xi ** (1 / 3) * (1 - 1.1 * xi)) for xi in XI])


def level_flux(w0, tmax=None, dt=30.0):
    """Средний по жизни поток вверх int max(w,0) dA пузыря from_game_strength(w0) (v5), м^3/с, на уровнях z = xi*z_l (21 уровень)."""
    src = bb.from_game_strength(0.0, 0.0, 0.0, w0, ZL, TAU, ENV)
    tr = bb._traj(src, ENV)
    rho = np.unique(np.concatenate([np.linspace(0.0, 150.0, 46), np.linspace(150.0, 900.0, 45)[1:]]))
    P = np.zeros((XI.size, rho.size, 3))
    P[..., 0] = rho[None, :]
    P[..., 2] = (XI * ZL)[:, None]
    ts = np.arange(15.0, tr.t_end, dt)
    if tmax is not None:
        ts = ts[ts <= tmax]
    acc = []
    for t in ts:
        st = bb.state(src, ENV, float(t))
        if st is None:
            acc.append(np.zeros(XI.size))
            continue
        w = bb.velocity(P, [st], ENV)[..., 2]
        acc.append(np.trapezoid(np.maximum(w, 0.0) * 2 * np.pi * rho[None, :], rho, axis=1))
    return np.mean(acc, axis=0), float(tr.t_end)


def compute():
    qn, tg = norm(q_now()), norm(target())
    F_typ, t_end = level_flux(W0_TYP)
    F_cap, _ = level_flux(W0_CAP)
    F_one, _ = level_flux(1.0)
    F_game, _ = level_flux(W0_TYP, tmax=GAME_LIFE_S)
    qt, qcap, qone, qgame = norm(F_typ), norm(F_cap), norm(F_one), norm(F_game)
    # баланс типичного случая (compare.md §7): ядра несут 0,30 Phi по правилу игры (кап 2,5 w*, K_bar при w0 = 1,24 w*)
    kb = bb.kbar(ZL, TAU, ENV, W0_TYP)
    carried = NA * kb * W0_CAP
    share = carried / PHI
    def between(q):   # между(xi) = Phi * target - carried * q  (если w_conv поля следует целевому профилю)
        return PHI * tg - carried * q
    # ошибка суммы «пузыри (реальные, шаблон) + между (игры с q)» относительно w_conv, м/с: carried*(q_tmpl - q_assumed)
    err_now = carried * (qt - qn)
    err_tmpl = carried * (qt - qt)
    res = {
        "xi": XI.tolist(), "q_template": qt.tolist(), "q_now": qn.tolist(), "target": tg.tolist(),
        "q_template_w0_1": qone.tolist(), "q_template_w0_cap": qcap.tolist(), "q_template_game_life": qgame.tolist(),
        "between_if_q_template": between(qt).tolist(), "between_if_q_now": between(qn).tolist(),
        "between_if_q_template_game_life": between(qgame).tolist(),
        "case": {"z_l": ZL, "wstar": WSTAR, "tau": TAU, "w0_typ": W0_TYP, "w0_cap": W0_CAP, "phi_m_s": PHI, "n_A": NA,
                 "kbar_typ_m2": kb, "carried_m_s": carried, "core_share_phi": share, "bubble_life_end_s": t_end,
                 "game_life_s": GAME_LIFE_S, "norm": "q нормирован к среднему 1 по xi в [0,1] (трапеции, 21 точка), как q/q_mean в expected.rs"},
        "metrics": {
            "rms_q_now_vs_template": float(np.sqrt(np.mean((qn - qt) ** 2))),
            "rms_q_template_vs_target": float(np.sqrt(np.mean((qt - tg) ** 2))),
            "rms_q_now_vs_target": float(np.sqrt(np.mean((qn - tg) ** 2))),
            "max_abs_sum_error_now_m_s": float(np.abs(err_now).max()),
            "max_abs_sum_error_now_over_phi": float(np.abs(err_now).max() / PHI),
            "max_abs_sum_error_template_m_s": float(np.abs(err_tmpl).max()),
            "xi_peak_template": float(XI[qt.argmax()]), "xi_peak_now": float(XI[qn.argmax()]), "xi_peak_target": float(XI[tg.argmax()]),
            "between_min_template_over_phi": float(between(qt).min() / PHI),
            "between_min_now_over_phi": float(between(qn).min() / PHI),
            "levels_between_negative_template": int((between(qt) < -1e-12).sum()),
            "levels_between_negative_now": int((between(qn) < -1e-12).sum()),
            "rms_q_template_vs_game_life": float(np.sqrt(np.mean((qt - qgame) ** 2))),
            "rms_q_template_w0_1_vs_typ": float(np.sqrt(np.mean((qone - qt) ** 2))),
            "rms_q_template_w0_cap_vs_typ": float(np.sqrt(np.mean((qcap - qt) ** 2))),
        },
        "refs": ["Lenschow & Stephens 1980 BLM 19:509", "Allen 2006 AIAA 2006-1510", "Stull 1988 гл. 4", "Petersen 1999 JAS", "Siebesma & Soares 2007 JAS"],
    }
    m = res["metrics"]
    neg_t, neg_n = m["levels_between_negative_template"], m["levels_between_negative_now"]
    res["recommendation"] = (
        "q(xi) в Shape (expected.rs) = таблица q_template (bubble.between_q, v5) (21 значение, среднее 1): сумма «пузыри + между» "
        f"тогда совпадает с w_conv на каждом уровне (ошибка по высоте 0 вместо {m['max_abs_sum_error_now_m_s']:.3f} м/с = "
        f"{100 * m['max_abs_sum_error_now_over_phi']:.0f} % Phi). Пик q_template при xi={m['xi_peak_template']:.2f}, прежнего {m['xi_peak_now']:.2f}, "
        f"целевого {m['xi_peak_target']:.2f}. Уровней с отрицательным «между» при целевом профиле: {neg_t} (шаблон) против {neg_n} (прежний). "
        "Профиль зависит от жизни пузыря (TB-10): при жизни игры 990 с он иной (q_template_game_life).")
    return res


def main(argv):
    res = compute()
    check = "--check" in argv
    if check:
        old = json.load(open(OUT))
        for k in ("q_template", "q_now", "target", "between_if_q_template"):
            assert np.allclose(old[k], res[k], atol=1e-6, rtol=1e-6), k
        assert np.allclose(res["q_template"], bb.between_q_nodes(), atol=1e-6, rtol=1e-6), "bubble.between_q не совпадает с q_template"
        assert len(res["xi"]) == 21 and abs(trap_mean(np.array(res["q_template"])) - 1) < 1e-9
        assert np.isfinite(np.array(res["q_template"])).all() and res["recommendation"]
        print("check ok")
        return 0
    OUT.parent.mkdir(exist_ok=True)
    json.dump(res, open(OUT, "w"), ensure_ascii=False, indent=1)
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots(1, 2, figsize=(9, 4))
    for k, lab in (("q_now", "прежний q"), ("q_template", "шаблон (жизнь пузыря)"), ("q_template_game_life", "шаблон, жизнь 990 с"), ("target", "цель L&S")):
        ax[0].plot(res[k], res["xi"], label=lab)
    ax[0].set_xlabel("q / среднее"); ax[0].set_ylabel("ξ = z/z_l"); ax[0].legend(fontsize=7)
    for k, lab in (("between_if_q_now", "между, прежний q"), ("between_if_q_template", "между, q шаблона")):
        ax[1].plot(np.array(res[k]) / PHI, res["xi"], label=lab)
    ax[1].axvline(0, color="k", lw=0.5); ax[1].set_xlabel("между / Φ"); ax[1].legend(fontsize=7)
    fig.tight_layout(); fig.savefig(FIG, dpi=110)
    print(json.dumps(res["metrics"], indent=1)); print(res["recommendation"])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
