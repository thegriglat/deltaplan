"""Итог пачки Морриса одним скриптом: читает out/plan.json и все out/runs/*.jsonl, считает
элементарные эффекты по траекториям и строит таблицы, тепловые карты и графики μ*–σ.

Элементарный эффект фактора i в траектории: Δy = y(шаг) − y(до шага), шаг — ±2/3 диапазона (p = 4) или
смена категории. Со знаком — по направлению шага (к большему значению / к следующему уровню).
  μ*  = ⟨|Δy|⟩ — средний сдвиг наблюдаемой (в её единицах); σ = СКО знакового Δy (нелинейность и
        взаимодействия); μ = ⟨Δy⟩; 95 % интервал μ* — бутстреп по траекториям (1000).
  S   = μ*/порог; порог — различимый сдвиг наблюдаемой (σ данных Askervein, Δχ² = 4, для проверок
        пилота и термиков — назначенные, см. OBS_META). S ≥ 1 — «двигает», 0,3–1 — «слабо», < 0,3 — «нет».
Два варианта: «все» (сошедшиеся и упёршиеся в предел итераций; без разошедшихся и ошибок) и
«сошедшиеся» (оба конца шага — ok). SALib.analyze.morris — сверка μ* на полных траекториях.

  .venv/bin/python analyze.py   → out/morris.json, out/morris_table.csv, out/fig_*.png, out/lists.md
"""
from __future__ import annotations

import csv
import json
import math
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
OUT = HERE / "out"
TUNE = HERE.parent / "tune"
sys.path.insert(0, str(HERE))

FIT = json.loads((TUNE / "out" / "fit_s1.json").read_text())
ASK = {o["name"]: o for o in FIT["obs"]}
GROUPS = ["наветренная сторона", "вершина/гребень", "подветренная сторона", "линия B (вдоль гребня)"]
GSHORT = {"наветренная сторона": "наветр.", "вершина/гребень": "вершина", "подветренная сторона": "подветр.",
          "линия B (вдоль гребня)": "линия B"}

# наблюдаемая → (группа, порог, подпись)
OBS_META = {}
for n, o in ASK.items():
    OBS_META[n] = ("askervein", o["sig_data"], f"Askervein {n}")
for g in GROUPS:
    OBS_META[f"chi2_{GSHORT[g]}"] = ("askervein_chi2", 4.0, f"χ² {GSHORT[g]}")
OBS_META["chi2_all"] = ("askervein_chi2", 4.0, "χ² Askervein, всего")
PILOT = {
    "ridge_su_2H": (0.02, "хребет: разгон на 2H"), "ridge_su_2.5H": (0.02, "хребет: разгон на 2,5H"),
    "ridge_w_2H": (0.01, "хребет: |w|/U на 2H"), "ridge_w_2.5H": (0.01, "хребет: |w|/U на 2,5H"),
    "ridge_crest_su10": (0.05, "хребет: разгон у бровки 10 м"), "ridge_crest_su50": (0.05, "хребет: разгон у бровки 50 м"),
    "lee_s20_2L": (0.05, "за гребнем: S20 в 2L"), "lee_s20_4L": (0.05, "за гребнем: S20 в 4L"),
    "lee_s50_2L": (0.05, "за гребнем: S50 в 2L"), "lee_s50_4L": (0.05, "за гребнем: S50 в 4L"),
    "lee_umin20": (0.05, "за гребнем: мин. u20 (ротор <0)"), "lee_wmin50": (0.02, "за гребнем: мин. w50/U"),
    "saddle_ratio20": (0.1, "седловина ×, 20 м"), "saddle_ratio50": (0.1, "седловина ×, 50 м"),
    "saddle_lee50": (0.05, "за седловиной S50"),
    "obl_w45_w0_50": (0.05, "косой ветер w45/w0, 50 м"), "obl_w45_w0_100": (0.05, "косой ветер w45/w0, 100 м"),
    "obl_w0_50": (0.05, "w у склона 0°, 50 м, м/с"), "obl_su20_0": (0.03, "разгон у гребня 20 м, 0°"),
    "obl_su20_45": (0.03, "разгон у гребня 20 м, 45°"),
}
for k, (t, lab) in PILOT.items():
    OBS_META[k] = ("pilot", t, lab)
for tag, lab in (("h0", "штиль"), ("h3", "3 м/с")):
    for k, t, l2 in (("w200_start", 0.1, "подъём у старта (200 м)"), ("speed50", 0.3, "ветер 50 м над стартом"),
                     ("w50", 0.1, "w 50 м над стартом"), ("th50", 0.2, "θ′ 50 м над стартом"),
                     ("d400_w200_p99", 0.1, "область: w200 p99"), ("d400_w200_p01", 0.1, "область: w200 p1"),
                     ("saddle50", 0.3, "седловина Каянчи S50")):
        OBS_META[f"{tag}_{k}"] = ("heat", t, f"Онгудай 12:00 {lab}: {l2}")
for c in ("askervein", "ridge", "saddle", "oblique", "heat0", "heat3"):
    OBS_META[f"{c}_log_iters"] = ("cost", 0.2, f"{c}: ln(итераций)")

GROUP_TITLE = dict(askervein="Askervein, разгон по точкам", askervein_chi2="Askervein, χ² по группам",
                   pilot="Проверки пилота (синтетика)", heat="Нагрев: Онгудай 12:00", cost="Цена: итерации")
KEY_OBS = (["chi2_all", "chi2_наветр.", "chi2_вершина", "chi2_подветр.", "chi2_линия B", "HT", "ASW20", "ANE10",
            "AANE10", "BSE20"]
           + list(PILOT)
           + [f"{t}_{k}" for t in ("h0", "h3") for k in ("w200_start", "speed50", "d400_w200_p99")]
           + [f"{c}_log_iters" for c in ("askervein", "ridge", "saddle", "oblique", "heat0", "heat3")])


def load():
    plan = json.loads((OUT / "plan.json").read_text())
    runs = {}
    for f in sorted((OUT / "runs").glob("*.jsonl")):
        for line in f.read_text().splitlines():
            r = json.loads(line)
            runs.setdefault(r["id"], {})[r["case"]] = r
    return plan, runs


def point_obs(rs):
    """Все наблюдаемые одной точки (по всем случаям) + статус каждого случая."""
    y, st = {}, {}
    for c, r in rs.items():
        st[c] = r["status"]
        if r["status"] in ("error", "diverged") or "obs" not in r:
            continue
        o = r["obs"]
        if c == "askervein":
            terms = {}
            for n, a in ASK.items():
                y[n] = o[n]
                m = o[n] + a["grid_corr"] + a["dom_corr"]
                s2 = a["sig_data"] ** 2 + a["sig_loo"] ** 2 + a["sig_grid"] ** 2 + a["sig_dom"] ** 2
                terms[n] = (m - a["data"]) ** 2 / s2
            for g in GROUPS:
                y[f"chi2_{GSHORT[g]}"] = sum(t for n, t in terms.items() if ASK[n]["grp"] == g)
            y["chi2_all"] = sum(terms.values())
        else:
            y.update(o)
        its = sum(v["iters"] for v in r["runs"].values())
        y[f"{c}_log_iters"] = math.log(max(its, 1))
    return y, st


def case_of(obs):
    g = OBS_META[obs][0]
    if g in ("askervein", "askervein_chi2"):
        return "askervein"
    if g == "cost":
        return obs.rsplit("_log_iters", 1)[0]
    if obs.startswith(("ridge", "lee")):
        return "ridge"
    if obs.startswith("saddle"):
        return "saddle"
    if obs.startswith("obl"):
        return "oblique"
    return "heat0" if obs.startswith("h0") else "heat3"


def effects(plan, runs, conv_only):
    k = plan["problem"]["num_vars"]
    names = plan["problem"]["names"]
    pts = [p for p in plan["points"] if p["id"] != "nom"]
    trajs = sorted({p["traj"] for p in pts})
    E = {}           # obs → factor → list of signed Δy
    steps = {n: [] for n in names}    # смена статуса по фактору: (case, st0, st1)
    ntraj = 0
    for t in trajs:
        tp = [p for p in pts if p["traj"] == t]
        if len(tp) != k + 1 or not all(p["id"] in runs for p in tp):
            continue
        ntraj += 1
        Y = [point_obs(runs[p["id"]]) for p in tp]
        for j in range(k):
            u0, u1 = np.array(tp[j]["u"]), np.array(tp[j + 1]["u"])
            d = u1 - u0
            i = int(np.argmax(np.abs(d)))
            sgn = 1.0 if d[i] > 0 else -1.0
            (y0, s0), (y1, s1) = Y[j], Y[j + 1]
            for c in set(s0) & set(s1):
                steps[names[i]].append((c, s0[c], s1[c]))
            for ob in set(y0) & set(y1):
                if ob not in OBS_META:
                    continue
                c = case_of(ob)
                if conv_only and not (s0.get(c) == "ok" and s1.get(c) == "ok"):
                    continue
                if not (math.isfinite(y0[ob]) and math.isfinite(y1[ob])):
                    continue
                E.setdefault(ob, {}).setdefault(names[i], []).append(sgn * (y1[ob] - y0[ob]))
    return E, steps, ntraj


def stats(E, names, rng):
    res = {}
    for ob, per in E.items():
        thr = OBS_META[ob][1]
        rows = {}
        for n in names:
            d = np.array(per.get(n, []))
            if len(d) == 0:
                rows[n] = dict(n=0, mu=float("nan"), mu_star=float("nan"), sigma=float("nan"), ci=float("nan"), S=float("nan"))
                continue
            ms = float(np.mean(np.abs(d)))
            bs = [np.mean(np.abs(rng.choice(d, len(d)))) for _ in range(1000)] if len(d) > 1 else [ms]
            rows[n] = dict(n=int(len(d)), mu=float(d.mean()), mu_star=ms,
                           sigma=float(d.std(ddof=1)) if len(d) > 1 else 0.0,
                           ci=float(np.percentile(bs, 97.5) - np.percentile(bs, 2.5)) / 2, S=ms / thr)
        res[ob] = rows
    return res


def verdict(S):
    if not math.isfinite(S):
        return "—"
    return "двигает" if S >= 1 else ("слабо" if S >= 0.3 else "нет")


def salib_check(plan, runs, ob="chi2_all"):
    """Сверка с SALib.analyze.morris (μ* в единицах EE = Δy/Δ) на полных траекториях без пропусков."""
    from SALib.analyze import morris as MA
    k = plan["problem"]["num_vars"]
    pts = [p for p in plan["points"] if p["id"] != "nom"]
    X, Y = [], []
    for t in sorted({p["traj"] for p in pts}):
        tp = [p for p in pts if p["traj"] == t]
        ys = [point_obs(runs.get(p["id"], {}))[0].get(ob) for p in tp]
        if len(tp) == k + 1 and all(v is not None and math.isfinite(v) for v in ys):
            X += [p["u"] for p in tp]
            Y += ys
    if not Y:
        return None
    r = MA.analyze(plan["problem"], np.array(X), np.array(Y), num_levels=plan["levels"], seed=1)
    delta = plan["levels"] / (2 * (plan["levels"] - 1))
    return dict(obs=ob, n_traj=len(Y) // (k + 1),
                mu_star_times_delta=dict(zip(plan["problem"]["names"], (np.array(r["mu_star"]) * delta).tolist())))


# ----------------------------------------------------------------------------------- картинки
def fig_heat(res, names, obs, title, path, annotate=True):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.colors import BoundaryNorm, ListedColormap
    obs = [o for o in obs if o in res]
    M = np.array([[res[o][n]["S"] for o in obs] for n in names])
    cmap = ListedColormap(["#f4f4f2", "#d6e4f0", "#9cc3e0", "#5a9bd0", "#2c6fb0", "#12427a"])
    norm = BoundaryNorm([0, 0.1, 0.3, 1, 3, 10, 1e9], cmap.N)
    fig, ax = plt.subplots(figsize=(0.36 * len(obs) + 3.2, 0.34 * len(names) + 2.6))
    Mm = np.where(np.isfinite(M), M, 0)
    im = ax.imshow(Mm, cmap=cmap, norm=norm, aspect="auto")
    ax.set_xticks(range(len(obs)))
    ax.set_xticklabels([OBS_META[o][2] for o in obs], rotation=90, fontsize=7)
    ax.set_yticks(range(len(names)))
    ax.set_yticklabels(names, fontsize=8)
    if annotate:
        for i in range(len(names)):
            for j in range(len(obs)):
                v = M[i, j]
                if math.isfinite(v) and v >= 0.3:
                    ax.text(j, i, f"{v:.1f}" if v < 10 else f"{v:.0f}", ha="center", va="center", fontsize=5.5,
                            color="white" if v >= 3 else "#222")
    cb = fig.colorbar(im, ax=ax, fraction=0.025, pad=0.01, ticks=[0.05, 0.2, 0.65, 2, 6.5, 20])
    cb.ax.set_yticklabels(["<0,1", "0,1–0,3", "0,3–1", "1–3", "3–10", ">10"], fontsize=7)
    cb.set_label("S = μ*/порог", fontsize=8)
    ax.set_title(title, fontsize=9)
    fig.tight_layout()
    fig.savefig(path, dpi=130)
    plt.close(fig)


def fig_mu_sigma(res, names, obs, path):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    obs = [o for o in obs if o in res]
    nc = 4
    nr = math.ceil(len(obs) / nc)
    fig, axs = plt.subplots(nr, nc, figsize=(3.3 * nc, 2.9 * nr))
    for ax, o in zip(np.ravel(axs), obs):
        thr = OBS_META[o][1]
        xs = np.array([res[o][n]["mu_star"] for n in names]) / thr
        ys = np.array([res[o][n]["sigma"] for n in names]) / thr
        ok = np.isfinite(xs)
        ax.scatter(xs[ok], ys[ok], s=14, color="#2c6fb0", zorder=3)
        top = np.argsort(-np.where(ok, xs, -1))[:4]
        for i in top:
            if ok[i] and xs[i] >= 0.3:
                ax.annotate(names[i], (xs[i], ys[i]), fontsize=6.5, xytext=(3, 2), textcoords="offset points")
        lim = max(1.2, np.nanmax(np.r_[xs[ok], ys[ok]]) * 1.1) if ok.any() else 1.2
        ax.plot([0, lim], [0, lim], color="0.75", lw=0.6)
        ax.axvline(1, color="#c0504d", lw=0.6, ls=":")
        ax.set_xlim(0, lim)
        ax.set_ylim(0, lim)
        ax.set_title(OBS_META[o][2], fontsize=7.5)
        ax.tick_params(labelsize=6.5)
        ax.grid(alpha=0.25)
    for ax in np.ravel(axs)[len(obs):]:
        ax.axis("off")
    fig.supxlabel("μ*/порог (средний сдвиг)", fontsize=8)
    fig.supylabel("σ/порог (нелинейность, взаимодействия)", fontsize=8)
    fig.tight_layout()
    fig.savefig(path, dpi=120)
    plt.close(fig)


def fig_degeneracy(res, names, obs, path):
    """Косинус между факторами по вектору знаковых μ/порог (по ключевым наблюдаемым): |cos| ≈ 1 —
    факторы двигают наблюдаемые одинаково, эти данные их не различают (вырождение)."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    obs = [o for o in obs if o in res and OBS_META[o][0] != "cost"]
    V = np.array([[res[o][n]["mu"] / OBS_META[o][1] for o in obs] for n in names])
    V = np.nan_to_num(V)
    act = [i for i in range(len(names)) if np.linalg.norm(V[i]) > 0.3]
    nm = [names[i] for i in act]
    Vn = V[act] / np.linalg.norm(V[act], axis=1, keepdims=True)
    C = Vn @ Vn.T
    fig, ax = plt.subplots(figsize=(0.45 * len(nm) + 2.5, 0.45 * len(nm) + 1.8))
    im = ax.imshow(C, cmap="RdBu_r", vmin=-1, vmax=1)
    ax.set_xticks(range(len(nm)))
    ax.set_xticklabels(nm, rotation=90, fontsize=8)
    ax.set_yticks(range(len(nm)))
    ax.set_yticklabels(nm, fontsize=8)
    for i in range(len(nm)):
        for j in range(len(nm)):
            ax.text(j, i, f"{C[i, j]:.2f}", ha="center", va="center", fontsize=6,
                    color="white" if abs(C[i, j]) > 0.7 else "#222")
    fig.colorbar(im, ax=ax, fraction=0.04)
    ax.set_title("Сходство действия факторов (cos знаковых μ по наблюдаемым)", fontsize=9)
    fig.tight_layout()
    fig.savefig(path, dpi=130)
    plt.close(fig)
    return dict(factors=nm, cos=C.tolist())


def fig_scatter(plan, runs, path):
    """χ² Askervein и ключевые числа против λ/h по всем точкам плана (цвет — замыкание/порядок)."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    rows = []
    for p in plan["points"]:
        if p["id"] not in runs:
            continue
        y, st = point_obs(runs[p["id"]])
        rows.append((p["fx"], y, st))
    obs = ["chi2_all", "HT", "AANE10", "ridge_su_2H", "lee_umin20", "h0_w200_start"]
    fig, axs = plt.subplots(2, 3, figsize=(12, 6.6))
    styles = {("hb", True): ("#2c6fb0", "hb, 2-й пор."), ("hb", False): ("#9cc3e0", "hb, 1-й пор."),
              ("const", True): ("#c0504d", "const, 2-й пор."), ("const", False): ("#e8a09e", "const, 1-й пор.")}
    for ax, o in zip(np.ravel(axs), obs):
        for key, (col, lab) in styles.items():
            xs = [fx["lam_frac"] for fx, y, st in rows if (fx["closure"], bool(fx["adv2"])) == key and o in y]
            ys = [y[o] for fx, y, st in rows if (fx["closure"], bool(fx["adv2"])) == key and o in y]
            ax.scatter(xs, ys, s=12, color=col, label=lab, alpha=0.85)
        nom = runs.get("nom", {})
        if nom:
            yn, _ = point_obs(nom)
            if o in yn:
                ax.scatter([0.25], [yn[o]], marker="*", s=90, color="black", label="номинал", zorder=5)
        if o in ASK:
            ax.axhline(ASK[o]["data"], color="0.3", ls="--", lw=0.8, label="данные (10 м)")
        ax.axvspan(0.03, 0.25, color="#2ca02c", alpha=0.07)
        ax.set_xscale("log")
        ax.set_xlabel("λ/h")
        ax.set_title(OBS_META[o][2], fontsize=8.5)
        ax.grid(alpha=0.25)
        if o == "chi2_all":
            ax.set_yscale("log")
    np.ravel(axs)[0].legend(fontsize=7)
    fig.tight_layout()
    fig.savefig(path, dpi=120)
    plt.close(fig)


def rank_info(res, names, obs):
    """Сколько независимых направлений в действии факторов на набор наблюдаемых: SVD матрицы
    (фактор × наблюдаемая) знаковых μ/порог. Доля квадрата сингулярных чисел — «сколько параметров
    эти данные вообще могут различить»; главные векторы — какие факторы вместе в направлении."""
    obs = [o for o in obs if o in res]
    V = np.nan_to_num(np.array([[res[o][n]["mu"] / OBS_META[o][1] for o in obs] for n in names]))
    U, s, Wt = np.linalg.svd(V, full_matrices=False)
    frac = (s ** 2 / np.sum(s ** 2)).tolist()
    dirs = []
    for q in range(3):
        load = U[:, q] * s[q]
        top = np.argsort(-np.abs(load))[:6]
        dirs.append({names[i]: round(float(load[i]), 2) for i in top})
    Vn = V / np.maximum(np.linalg.norm(V, axis=1, keepdims=True), 1e-12)
    C = Vn @ Vn.T
    return dict(n_obs=len(obs), sv=s.tolist(), frac=frac, dirs=dirs,
                cos_lam_frac={names[j]: round(float(C[0, j]), 2) for j in range(len(names))})


def fig_alpha(best, path):
    """χ² Askervein по всем точкам плана на плоскости (α притока, λ/h); цвет — χ²."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots(figsize=(6.2, 4.4))
    hb = [b for b in best if b["fx"]["closure"] == "hb" and b["fx"]["adv2"]]
    other = [b for b in best if not (b["fx"]["closure"] == "hb" and b["fx"]["adv2"])]
    ax.scatter([0.17 * b["fx"]["alpha_mul"] for b in other], [b["fx"]["lam_frac"] for b in other], s=10,
               color="0.8", label="const или 1-й порядок")
    sc = ax.scatter([0.17 * b["fx"]["alpha_mul"] for b in hb], [b["fx"]["lam_frac"] for b in hb],
                    c=[b["chi2"] for b in hb], cmap="viridis_r", vmin=50, vmax=200, s=26, label="hb, 2-й порядок")
    fig.colorbar(sc, ax=ax, label="χ² Askervein (39 точек)")
    ax.axvspan(0.207, 0.225, color="#c0504d", alpha=0.12, label="α по профилю RS 10→116/267 м")
    ax.axvline(0.17, color="0.3", ls=":", lw=0.8, label="α AM-09 (0,17)")
    ax.set_yscale("log")
    ax.set_xlabel("α профиля притока (Askervein)")
    ax.set_ylabel("λ/h")
    ax.legend(fontsize=7, loc="lower left")
    ax.grid(alpha=0.25)
    fig.tight_layout()
    fig.savefig(path, dpi=130)
    plt.close(fig)


def fig_status(steps, names, path):
    """Какие факторы при шаге меняют статус сходимости (ok ↔ предел итераций/расхождение/ошибка)."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    cases = ["askervein", "ridge", "saddle", "oblique", "heat0", "heat3"]
    M = np.zeros((len(names), len(cases)))
    for i, n in enumerate(names):
        for j, c in enumerate(cases):
            s = [(a, b) for cc, a, b in steps[n] if cc == c]
            M[i, j] = sum(a != b for a, b in s) / max(len(s), 1)
    fig, ax = plt.subplots(figsize=(5.5, 6))
    im = ax.imshow(M, cmap="Oranges", vmin=0, vmax=1, aspect="auto")
    ax.set_xticks(range(len(cases)))
    ax.set_xticklabels(cases, rotation=45, fontsize=8)
    ax.set_yticks(range(len(names)))
    ax.set_yticklabels(names, fontsize=8)
    for i in range(len(names)):
        for j in range(len(cases)):
            if M[i, j] > 0:
                ax.text(j, i, f"{M[i, j]:.1f}", ha="center", va="center", fontsize=6.5)
    fig.colorbar(im, ax=ax, fraction=0.04, label="доля шагов со сменой статуса")
    ax.set_title("Сходимость: смена статуса при шаге фактора", fontsize=9)
    fig.tight_layout()
    fig.savefig(path, dpi=130)
    plt.close(fig)
    return M.tolist()


def s3_analysis(rng):
    """Масштаб 3: ТКЭ/ТКЭ(RS) по мачтам Askervein, χ² по группам (σ = 15 % отношения, как fit_s3),
    σ_w за гребнем (ANE), признак отрыва за гребнем — на полях 12,5 / 25 / 50 м (1-й пор., как в игре)."""
    pm = OUT / "plan_s3_meta.json"
    rp = OUT / "s3_runs.json"
    if not (pm.exists() and rp.exists()):
        return None
    plan = json.loads(pm.read_text())
    runs = json.loads(rp.read_text())
    pts = json.loads((TUNE / "out" / "tke_points.json").read_text())
    ref = next(p for p in pts if p["name"] == "RS_10")
    obs_p = [p for p in pts if p["name"] != "RS_10"]
    d = {p["name"]: p["tke"] / ref["tke"] for p in obs_p}

    def grp(n):
        return "подветр." if n.startswith(("ANE", "AANE")) else ("вершина" if n.startswith(("HT", "CP")) else "наветр.")
    names = plan["problem"]["names"]
    short = [n.split(".")[-1] for n in names]
    meta3 = {}
    out = {}
    for field, rows in runs.items():
        tag = field.replace("ask_", "").replace("_best", "")
        Y = {}
        for r in rows:
            P = r["pts"]
            y = {}
            chi = {}
            for n in d:
                v = P[n]["tke"] / P["RS_10"]["tke"]
                y[f"{tag}:{n}"] = v
                chi[n] = (v - d[n]) ** 2 / (0.15 * d[n]) ** 2
                meta3[f"{tag}:{n}"] = (0.15 * d[n], f"{tag}: ТКЭ/RS {n}")
            for g in ("наветр.", "вершина", "подветр."):
                y[f"{tag}:chi2_{g}"] = sum(c for n, c in chi.items() if grp(n) == g)
                meta3[f"{tag}:chi2_{g}"] = (4.0, f"{tag}: χ² ТКЭ {g}")
            y[f"{tag}:chi2_all"] = sum(chi.values())
            meta3[f"{tag}:chi2_all"] = (4.0, f"{tag}: χ² ТКЭ всего")
            for n in ("ANE10_10", "ANE20_10", "ANE40_10"):
                if n in P:
                    y[f"{tag}:sw_{n}"] = P[n]["sw"]
                    meta3[f"{tag}:sw_{n}"] = (0.1, f"{tag}: σ_w за гребнем {n}, м/с")
                    y[f"{tag}:lee_{n}"] = P[n]["lee"]
                    meta3[f"{tag}:lee_{n}"] = (0.1, f"{tag}: признак отрыва {n}")
            Y[r["id"]] = y
        out[tag] = Y
    k = len(names)
    E = {}
    pts_plan = plan["points"]
    for t in sorted({p["traj"] for p in pts_plan}):
        tp = [p for p in pts_plan if p["traj"] == t]
        for j in range(k):
            dlt = np.array(tp[j + 1]["u"]) - np.array(tp[j]["u"])
            i = int(np.argmax(np.abs(dlt)))
            sgn = 1.0 if dlt[i] > 0 else -1.0
            for tag, Y in out.items():
                y0, y1 = Y.get(tp[j]["id"]), Y.get(tp[j + 1]["id"])
                if y0 is None or y1 is None:
                    continue
                for ob in y0:
                    E.setdefault(ob, {}).setdefault(short[i], []).append(sgn * (y1[ob] - y0[ob]))
    res = {}
    for ob, per in E.items():
        thr = meta3[ob][0]
        res[ob] = {}
        for n in short:
            a = np.array(per.get(n, []))
            ms = float(np.mean(np.abs(a))) if len(a) else float("nan")
            res[ob][n] = dict(n=int(len(a)), mu=float(a.mean()) if len(a) else float("nan"), mu_star=ms,
                              sigma=float(a.std(ddof=1)) if len(a) > 1 else 0.0, S=ms / thr)
    nominal_chi2 = {}
    for tag, Y in out.items():
        vals = [y[f"{tag}:chi2_all"] for y in Y.values()]
        nominal_chi2[tag] = dict(min=float(np.min(vals)), median=float(np.median(vals)), max=float(np.max(vals)))
    for ob, (t, lab) in meta3.items():
        OBS_META[ob] = ("s3", t, lab)
    GROUP_TITLE["s3"] = "Масштаб 3: ТКЭ Askervein"
    keys = [o for o in res if ":chi2" in o or ":sw_" in o or ":lee_" in o]
    keys.sort(key=lambda o: (o.split(":")[0], o))
    fig_heat(res, short, keys, f"Масштаб 3: S = μ*/порог (r = {plan['r']}, поля 12,5 / 25 / 50 м)", OUT / "fig_heatmap_s3.png")
    return dict(r=plan["r"], factors=plan["factors"], effects=res, chi2_range=nominal_chi2)


def main():
    plan, runs = load()
    names = plan["problem"]["names"]
    rng = np.random.default_rng(1)
    out = dict(n_points=len(runs), levels=plan["levels"], r=plan["r"])
    # статусы и время
    st = {}
    for pid, rs in runs.items():
        for c, r in rs.items():
            s = st.setdefault(c, dict(n=0, t=0.0, iters=[], status={}))
            s["n"] += 1
            s["t"] += r.get("t_wall", 0.0)
            s["status"][r["status"]] = s["status"].get(r["status"], 0) + 1
            s["iters"].append(sum(v["iters"] for v in r.get("runs", {}).values()))
    for c, s in st.items():
        s["t_mean"] = s["t"] / s["n"]
        s["iters_median"] = float(np.median(s["iters"]))
        del s["iters"]
    out["cases"] = st
    out["gpu_hours"] = sum(s["t"] for s in st.values()) / 3600
    if "nom" in runs:
        out["nominal"] = point_obs(runs["nom"])[0]
    variants = {}
    for label, conv in (("all", False), ("conv", True)):
        E, steps, ntraj = effects(plan, runs, conv)
        res = stats(E, names, rng)
        variants[label] = dict(ntraj=ntraj, res=res)
        if label == "all":
            out["status_change"] = fig_status(steps, names, OUT / "fig_status.png")
    out["ntraj"] = variants["all"]["ntraj"]
    res = variants["all"]["res"]
    resc = variants["conv"]["res"]
    out["effects"] = res
    out["effects_conv"] = resc
    # таблица
    with (OUT / "morris_table.csv").open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["group", "obs", "label", "threshold", "factor", "n", "mu", "mu_star", "mu_star_ci95", "sigma", "S",
                    "verdict", "n_conv", "mu_star_conv", "S_conv"])
        for ob in sorted(res, key=lambda o: (OBS_META[o][0], o)):
            for n in names:
                r = res[ob][n]
                rc = resc.get(ob, {}).get(n, dict(n=0, mu_star=float("nan"), S=float("nan")))
                w.writerow([OBS_META[ob][0], ob, OBS_META[ob][2], OBS_META[ob][1], n, r["n"], f"{r['mu']:.4g}",
                            f"{r['mu_star']:.4g}", f"{r['ci']:.3g}", f"{r['sigma']:.4g}", f"{r['S']:.3g}", verdict(r["S"]),
                            rc["n"], f"{rc['mu_star']:.4g}", f"{rc['S']:.3g}"])
    # списки «двигает / нет» по наблюдаемым и по факторам
    lines = ["# Моррис: что двигает каждую наблюдаемую (вариант «все»; S = μ*/порог)", ""]
    per_group = {}
    for ob in [o for o in OBS_META if o in res]:
        rr = res[ob]
        srt = sorted(names, key=lambda n: -np.nan_to_num(rr[n]["S"]))
        mv = [f"{n} {rr[n]['S']:.1f}" for n in srt if rr[n]["S"] >= 1]
        wk = [f"{n} {rr[n]['S']:.2f}" for n in srt if 0.3 <= rr[n]["S"] < 1]
        per_group.setdefault(OBS_META[ob][0], []).append(
            f"- **{OBS_META[ob][2]}** (порог {OBS_META[ob][1]:g}): двигают — {', '.join(mv) or 'ничто'}; "
            f"слабо — {', '.join(wk) or '—'}")
    for g, ls in per_group.items():
        lines += [f"## {GROUP_TITLE[g]}", ""] + ls + [""]
    lines += ["## По факторам: сколько наблюдаемых двигает (S ≥ 1 / 0,3–1), без цены", ""]
    fac = {}
    for n in names:
        a = [o for o in res if OBS_META[o][0] != "cost" and res[o][n]["S"] >= 1]
        b = [o for o in res if OBS_META[o][0] != "cost" and 0.3 <= res[o][n]["S"] < 1]
        fac[n] = dict(moves=a, weak=b)
        lines.append(f"- **{n}**: {len(a)} / {len(b)}" + (f" — {', '.join(OBS_META[o][2] for o in a[:12])}"
                                                          + (" …" if len(a) > 12 else "") if a else ""))
    out["by_factor"] = fac
    (OUT / "lists.md").write_text("\n".join(lines) + "\n")
    # картинки
    fig_heat(res, names, KEY_OBS, f"Моррис: S = μ*/порог (r = {out['ntraj']} траекторий, все прогоны)",
             OUT / "fig_heatmap_key.png")
    fig_heat(resc, names, KEY_OBS, "то же, только сошедшиеся шаги", OUT / "fig_heatmap_key_conv.png")
    ask = [o for o in ASK] + [o for o in OBS_META if OBS_META[o][0] == "askervein_chi2"]
    fig_heat(res, names, ask, "Askervein: S = μ*/σ данных по точкам; χ² — μ*/4", OUT / "fig_heatmap_askervein.png")
    fig_heat(res, names, [o for o in OBS_META if OBS_META[o][0] in ("pilot", "heat", "cost")],
             "Проверки пилота, нагрев, цена: S = μ*/порог", OUT / "fig_heatmap_pilot_heat.png")
    fig_mu_sigma(res, names, ["chi2_all", "chi2_вершина", "chi2_подветр.", "chi2_линия B", "HT", "AANE10",
                              "ridge_su_2H", "ridge_su_2.5H", "lee_umin20", "saddle_ratio20", "obl_w45_w0_50",
                              "h0_w200_start", "h3_w200_start", "h3_speed50", "heat0_log_iters", "askervein_log_iters"],
                 OUT / "fig_mu_sigma.png")
    out["degeneracy"] = fig_degeneracy(res, names, KEY_OBS, OUT / "fig_degeneracy.png")
    fig_scatter(plan, runs, OUT / "fig_scatter_lamfrac.png")
    out["rank"] = dict(askervein=rank_info(res, names, list(ASK)),
                       pilot=rank_info(res, names, list(PILOT)),
                       heat=rank_info(res, names, [o for o in OBS_META if OBS_META[o][0] == "heat"]))
    best = []
    for p in plan["points"]:
        y, _ = point_obs(runs.get(p["id"], {}))
        if "chi2_all" in y:
            best.append(dict(id=p["id"], chi2=y["chi2_all"], HT=y["HT"], AANE10=y["AANE10"], fx=p["fx"],
                             groups={g: y[f"chi2_{g}"] for g in GSHORT.values()}))
    best.sort(key=lambda b: b["chi2"])
    out["askervein_best"] = best[:15]
    fig_alpha(best, OUT / "fig_askervein_alpha_lamfrac.png")
    s3 = s3_analysis(rng)
    if s3:
        out["s3"] = s3
        ls = ["", "## Масштаб 3: ТКЭ Askervein (поля 12,5 / 25 / 50 м)", ""]
        for ob, rr in s3["effects"].items():
            if ":chi2" not in ob and ":sw_" not in ob and ":lee_" not in ob:
                continue
            srt = sorted(rr, key=lambda n: -np.nan_to_num(rr[n]["S"]))
            mv = [f"{n} {rr[n]['S']:.1f}" for n in srt if rr[n]["S"] >= 1]
            wk = [f"{n} {rr[n]['S']:.2f}" for n in srt if 0.3 <= rr[n]["S"] < 1]
            ls.append(f"- **{OBS_META[ob][2]}**: двигают — {', '.join(mv) or 'ничто'}; слабо — {', '.join(wk) or '—'}")
        with (OUT / "lists.md").open("a") as f:
            f.write("\n".join(ls) + "\n")
    try:
        out["salib_check"] = salib_check(plan, runs)
    except Exception as e:  # noqa: BLE001
        out["salib_check"] = f"{type(e).__name__}: {e}"
    (OUT / "morris.json").write_text(json.dumps(out, ensure_ascii=False, indent=1, default=float))
    print(f"точек {len(runs)}, полных траекторий {out['ntraj']} (сошедшиеся шаги — {variants['conv']['ntraj']}), "
          f"GPU {out['gpu_hours']:.2f} ч")
    for c, s in st.items():
        print(f"  {c}: {s['n']} прогонов, {s['t_mean']:.0f} с, медиана итераций {s['iters_median']:.0f}, {s['status']}")
    print((OUT / "lists.md").read_text()[:6000])


if __name__ == "__main__":
    main()
