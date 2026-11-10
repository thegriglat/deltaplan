"""TB-10: жизнь термика игры (~990 с) против подъёма головы шаблона (~1480 с до верха головы 0,9 z_i).
Только читает bubble.py (не правит); варианты, где нужно, меняют константы модуля во время расчёта (monkeypatch) и возвращают их.
Запуск: py round3/life.py [--check]   (--check: пересчёт опорных чисел и сверка с out/round3_life.json)."""
import dataclasses, json, os, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import bubble as b  # noqa: E402

OUT = os.path.join(os.path.dirname(HERE), "out", "round3_life.json")
ZI = 1400.0
ENV = b.Env(zi=ZI)
W0 = 2.5                 # м/с, сила термика игры (пик Гедеона), как в docs «Круг 2» §5.1
WSTAR = W0 / 1.24        # 2,016 м/с
TAU = 690.0
GAME_LIFE = 990.0        # с, по docs/research/thermal_bubble.md §5.1 (огибающая игры)
FRAC = 0.9
TG = np.arange(5.0, 4000.0, 5.0)


def ls_what(zeta):
    """Lenschow–Stephens 1980: средний подъём термика, в w*: ζ^⅓ (1 − 1,1 ζ)."""
    return zeta ** (1 / 3) * (1 - 1.1 * zeta)


def traj(src, env=ENV):
    out = []
    for t in TG:
        st = b.state(src, env, float(t))
        if st is None:
            break
        out.append((t, st.zc, st.R, st.U, st.Uh))
    return np.array(out)


def rise(src, env=ENV, frac=FRAC):
    a = traj(src, env)
    top = a[:, 1] + a[:, 2]
    i = np.nonzero(top >= frac * env.zi)[0]
    t09 = float(np.interp(frac * env.zi, top, a[:, 0])) if i.size else None
    # время до 0,5 z_i для сравнения с литературой там, где ŵ не обращается в нуль
    t05 = float(np.interp(0.5 * env.zi, top, a[:, 0]))
    zc_game = float(np.interp(GAME_LIFE, a[:, 0], a[:, 1]))
    U = a[:, 3]
    return dict(t_rise_09_s=t09, t_rise_05_s=t05, zc_at_game_life_m=zc_game,
                top_frac_at_game_life=float(np.interp(GAME_LIFE, a[:, 0], top) / env.zi),
                U_start=float(U[1]), U_at_tau=float(np.interp(TAU, a[:, 0], U)), U_mean_0_09=(frac * env.zi) / t09 if t09 else None,
                t_end_s=float(b._traj(src, env).t_end))


def lit_times(wstar):
    """Время подъёма до ζ, если термик движется со скоростью воздуха: ŵ_LS (среднее) или k·w*."""
    z = np.linspace(0.0, 1.0, 20001)[1:]
    zeta = z
    res = {}
    for top in (0.5, 0.8):
        m = zeta <= top
        v = ls_what(zeta[m]) * wstar
        res["LS_mean_to_%.1f" % top] = float(np.trapezoid(ZI / v, zeta[m]))
    for k in (0.45, 0.63, 1.0, 1.5, 2.0):
        res["const_%.2f_wstar_to_0.9" % k] = FRAC * ZI / (k * wstar)
    return res


def variant_strength(k_w0):
    s = b.from_strength(0.0, 0.0, 0.0, k_w0 * WSTAR, ZI, TAU, ENV)
    d = rise(s)
    d.update(F0=float(s.F0), w0_over_wstar=k_w0)
    return d


def variant_allen():
    old = (b._AL_T, b._ZH_FRAC)
    b._AL_T, b._ZH_FRAC = b._ALPHA_ALLEN, b._ZH_FRAC_ALLEN
    try:
        b._CACHE.clear()
        s = b.from_strength(0.0, 0.0, 0.0, W0, ZI, TAU, ENV)
        s = dataclasses.replace(s, zh=b._ZH_FRAC_ALLEN * ZI)
        b._CACHE.clear()
        d = rise(s)
        d.update(F0=float(s.F0), alpha=b._AL_T)
    finally:
        b._AL_T, b._ZH_FRAC = old
        b._CACHE.clear()
    return d


def variant_flux():
    """F0 прямо из потока (from_game: 0,371·w*³z_l/8,5), без привязки пика w к w0: проверка, что задаёт U."""
    s = b.from_game(0.0, 0.0, 0.0, WSTAR, ZI, ENV)
    d = rise(s)
    d.update(F0=float(s.F0))
    a = traj(s)
    d["peak_axis_centre_w_2p5U"] = float(2.5 * a[1, 3])
    return d


def variant_tau(tau):
    s = dataclasses.replace(b.from_strength(0.0, 0.0, 0.0, W0, ZI, TAU, ENV), tau=tau)
    d = rise(s)
    d.update(tau=tau)
    return d


def compute(fast=False):
    res = {}
    base = b.from_strength(0.0, 0.0, 0.0, W0, ZI, TAU, ENV)
    res["baseline"] = rise(base)
    res["baseline"].update(F0=float(base.F0))
    if fast:
        return res
    V = {}
    for k in (1.0, 1.24, 1.6, 2.0):
        V["w0_%.2f_wstar" % k] = variant_strength(k)
    V["allen_alpha_0.033"] = variant_allen()
    V["flux_from_game"] = variant_flux()
    for tau in (420.0, 960.0):
        V["tau_%d" % tau] = variant_tau(tau)
    res["variants"] = V
    return res


LIT = [
    dict(ref="Lenschow & Stephens 1980, Boundary-Layer Meteorol. 19:509", what="средний подъём термика ŵ/w* = ζ^⅓(1−1,1ζ), макс. 0,45; ядро 1–2 w*",
         value="0,45 w* (среднее), 1–2 w* (ядро)", reliability="high для 0,45, low для 1–2 (из пересказа)"),
    dict(ref="Ansmann, Fruntke & Engelmann 2010, Atmos. Chem. Phys. 10:7845", what="средний подъём в апдрафтах 0,40–0,45 w* (аннотация, лидар)",
         value="0,40–0,45 w*", reliability="medium-high"),
    dict(ref="Schmidt & Schumann 1989, J. Fluid Mech. 200:511", what="LES: композит сильных w-событий, центр 2,0 w*; события наблюдались на 6<t*<7, t*=z_i/w*; пузыри внутри апдрафта быстрее среднего",
         value="пик 2,0 w*", reliability="medium"),
    dict(ref="Stull 1988, Introduction to Boundary Layer Meteorology, гл. 4/6", what="конвективное время t* = z_i/w* — масштаб оборота вихря (порядка 5–15 мин); оригинал не открывался",
         value="1 t* = z_i/w* = 694 с здесь", reliability="medium (учебник, из памяти)"),
    dict(ref="Scorer 1957, J. Fluid Mech. 2:583; Turner 1962, J. Fluid Mech. 13:356", what="свободный термик: U·(z+z_h)=K, фронт факела 0,6 скорости шлейфа",
         value="закон подобия", reliability="medium"),
    dict(ref="Young 1988, J. Atmos. Sci. 45:719", what="время жизни и бюджеты апдрафтов — числа не прочитаны (AMS 403)", value="нет", reliability="не использовано"),
]


def main():
    check = "--check" in sys.argv
    res = compute(fast=check)
    if check:
        ref = json.load(open(OUT))
        for k in ("t_rise_09_s", "t_rise_05_s", "U_start"):
            assert abs(res["baseline"][k] - ref["variants"]["baseline"][k]) < 1.0, k
        assert abs(ref["t_rise_09_s"] - res["baseline"]["t_rise_09_s"]) < 1.0
        print("ok", res["baseline"]["t_rise_09_s"])
        return
    lit = lit_times(WSTAR)
    V = dict(baseline=res["baseline"], **res["variants"])
    base = res["baseline"]
    out = dict(
        task="TB-10", w0=W0, wstar=WSTAR, z_i=ZI, tau=TAU, frac_top=FRAC,
        t_rise_09_s=base["t_rise_09_s"], game_life_s=GAME_LIFE, t_star_s=ZI / WSTAR,
        ratio_rise_over_life=base["t_rise_09_s"] / GAME_LIFE,
        literature_times_s=lit, literature=LIT, variants=V,
    )
    # вывод/рекомендация заполняются после разбора чисел (см. life.md)
    out["recommendation"] = RECO.format(**{
        "t0": base["t_rise_09_s"], "tf": V["flux_from_game"]["t_rise_09_s"],
        "tl": lit["const_0.45_wstar_to_0.9"]})
    json.dump(out, open(OUT, "w"), ensure_ascii=False, indent=1)
    plot(V)
    print(json.dumps({k: (v["t_rise_09_s"], round(v["U_start"], 2), round(v["U_mean_0_09"], 2)) for k, v in V.items()}, indent=1))
    print(lit)


RECO = ("Согласовать через поток, а не через пик: F0 брать из бюджета плавучести (from_game: 0,371·w*³z_l/8,5 = 501 против 204 у from_strength), "
        "а не из условия «max w на оси = w0 игры». Тогда голова поднимается до 0,9 z_i за {tf:.0f} с (было {t0:.0f}; жизнь игры 990 с, остаток +10 %), "
        "U = 1,25→0,95 м/с = 0,62→0,47 w*, пик центра головы 2,5U = 3,1 м/с = 1,55 w* — внутри ядер 1–2 w* (L&S 1980; S&S 1989). "
        "Причина разрыва: 2,5·U_h Хилла пришит к w0 = 1,24 w* (пик Гедеона), и U ≈ w0/2,5 = 0,46→0,31 w*, ниже среднего подъёма 0,40–0,45 w*. "
        "Старый подъём {t0:.0f} с сам по себе не противоречит литературе (при 0,45 w* — {tl:.0f} с); τ и α (Аллен) на время не влияют (±3 %). "
        "Цена: пик на оси в игре +25 % (3,1 против 2,5), K̄ и доля Φ ядер пересчитать (TB-12/15); core_flux_fraction — low.")


def plot(V):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots(1, 2, figsize=(10, 4))
    for name, s in [("baseline", None)]:
        pass
    base = b.from_strength(0.0, 0.0, 0.0, W0, ZI, TAU, ENV)
    for k in (1.24, 1.6, 2.0):
        s = b.from_strength(0.0, 0.0, 0.0, k * WSTAR, ZI, TAU, ENV)
        a = traj(s)
        ax[0].plot(a[:, 0], (a[:, 1] + a[:, 2]) / ZI, label="w0=%.2f w*" % k)
    ax[0].axvline(GAME_LIFE, ls="--", c="k"); ax[0].axhline(FRAC, c="gray", ls=":")
    ax[0].set_xlim(0, 2500); ax[0].set_ylim(0, 1); ax[0].set_xlabel("t, с"); ax[0].set_ylabel("(z_c+R)/z_i"); ax[0].legend()
    z = np.linspace(0.02, 0.88, 100)
    ax[1].plot(z, ls_what(z) * WSTAR, label="ŵ L&S (среднее)")
    a = traj(base)
    ax[1].plot((a[:, 1]) / ZI, a[:, 3], label="U головы, w0=1,24 w*")
    ax[1].set_xlabel("z/z_i"); ax[1].set_ylabel("м/с"); ax[1].legend()
    fig.tight_layout(); fig.savefig(os.path.join(HERE, "life_rise.png"), dpi=110)


if __name__ == "__main__":
    main()
