#!/usr/bin/env python3
"""Суррогаты по набору точек (build.py → out/ds_points.npz), от простого к сложному:

  (а) phys — физические формулы с коэффициентами из подгонки, отдельно на каждую высоту AGL:
      механика: линейное обтекание (Jackson–Hunt, внешняя область) + устойчивый слой (Smith 1980)
      + укрытость с наветра; нагрев: склоновый ветер (масштаб (g/θ0·H_kin·L)^(1/3) по уклону),
      схождение у гребней (w*·кривизна), избыток θ′ (H_kin/w_m, Холтслаг–Бовилль);
  (б) lin — гребневая (ridge) линейная регрессия по всем признакам + произведения с pf/ws и
      устойчивостью, отдельно на каждую высоту (кусочно по высоте);
  (в) gbm — градиентный бустинг (LightGBM) по всем признакам (верхняя оценка того, что признаки
      вообще объясняют; в игре дорог — см. evaluate.py → цена).

Проверка: (1) «новое место» — по очереди одно встроенное место вне обучения (обучение — 3 других
+ синтетика), (2) «синтетика вне обучения» — обучение только на встроенных, проверка на 5 синтетиках,
(3) «новые условия на знакомых местах» — 20 % случаев каждого места (по случаю) вне обучения.
Итоговые модели (на всём наборе) → out/models.json (коэффициенты phys/lin), out/gbm_<цель>.txt.
Метрики → out/fit_metrics.json.

  .venv/bin/python fit.py
"""
from __future__ import annotations

import json
import math
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
OUT = HERE / "out"
G, THETA0, RHO_CP, KAPPA, Z0 = 9.81, 300.0, 1200.0, 0.4, 0.1
MECH = ("t_mpar", "t_mper", "t_mw")
HEAT = ("t_cpar", "t_cper", "t_cw", "t_th")
TARGETS = MECH + HEAT
REAL = ("ongudai", "aushkul", "altai", "askarovo")


# ------------------------------------------------------------------ производные величины
def derived(d):
    """Физические масштабы из признаков (без решения)."""
    a = d["a"].astype(np.float64)
    U10 = d["U10"].astype(np.float64)
    ustar = KAPPA * U10 / math.log(10.0 / Z0)
    Hk = np.maximum(d["H"], 0) / RHO_CP
    Hks = np.maximum(d["H_s1500"], 0) / RHO_CP
    h = np.maximum(d["hbl"], 1.0)
    wstar = (G / THETA0 * Hks * h) ** (1 / 3)
    wm = (ustar ** 3 + 0.28 * wstar ** 3) ** (1 / 3) + 0.05
    xi = np.clip(a / h, 0, 1.5)
    gm = np.hypot(d["gx_500"], d["gy_500"]) + 1e-3
    # склоновый ветер (анабатический): масштаб скорости (g/θ0 · H_kin · L · sinα)^(1/3), L = 1000 м (Hunt et al. 2003)
    v_ana = (G / THETA0 * np.maximum(d["H_s500"], 0) / RHO_CP * 1000.0 * np.sin(np.arctan(gm))) ** (1 / 3)
    # выхолаживание (катабатический): H < 0 — вниз по склону
    v_kat = (G / THETA0 * np.maximum(-d["H_s500"], 0) / RHO_CP * 1000.0 * np.sin(np.arctan(gm))) ** (1 / 3)
    out = dict(ustar=ustar, wstar=wstar, wm=wm, xi=xi, exi=np.exp(-a / 150.0), exh=np.exp(-xi * 3),
               v_ana=v_ana, v_kat=v_kat, ux=d["gx_500"] / gm, uy=d["gy_500"] / gm,
               dth_s=Hk / wm, Fr_i=d["N"] * np.maximum(d["relief"], 50.0) / np.maximum(d["Ub"], 0.3))
    return out


def basis(d, target, kind):
    """Матрица базиса (n, p) и имена для цели target: kind = phys | lin."""
    q = derived(d)
    cols = {}
    if target in MECH:
        pf = dict(t_mpar="pf_u", t_mper="pf_v", t_mw="pf_w")[target]
        ws = dict(t_mpar="ws_u", t_mper="pf_v", t_mw="ws_w")[target]
        cols["pf"] = d[pf]
        if ws != pf:
            cols["ws"] = d[ws]
        cols["sx_1500"] = d["sx_1500"]
        if target == "t_mw":
            cols["gpar_100·e"] = d["gpar_100"] * q["exi"]
    else:
        if target in ("t_cpar", "t_cper"):
            gm = np.hypot(d["gpar_500"], d["gper_500"]) + 1e-3
            e = (d["gpar_500"] if target == "t_cpar" else d["gper_500"]) / gm
            cols["ana"] = q["v_ana"] * e * q["exh"]          # вверх по склону днём
            cols["kat"] = -q["v_kat"] * e * q["exi"]         # вниз по склону вечером
            if target == "t_cpar":
                # перемешивание импульса конвекцией: профиль ветра в слое выравнивается (Ub·f(ξ), w*/u*)
                cols["Ub·mix"] = d["Ub"] * np.tanh(q["wstar"] / (q["ustar"] + 0.1)) * (1 - np.minimum(q["xi"], 1))
                cols["Ub·mix2"] = d["Ub"] * np.tanh(q["wstar"] / (q["ustar"] + 0.1)) * np.minimum(q["xi"], 1)
        elif target == "t_cw":
            cols["w*·lap"] = -q["wstar"] * d["lap_1000"]
            cols["w*·tpi"] = q["wstar"] * d["tpi_2000"] / 1000.0
            cols["v_ana·tpi"] = q["v_ana"] * d["tpi_500"] / 100.0
        else:
            cols["dth"] = q["dth_s"] * q["exh"]
            cols["kat"] = -q["v_kat"] * q["exi"]
            cols["H·tpi"] = d["H_s1500"] / 300.0 * d["tpi_1000"] / 100.0
    if kind == "lin":
        base = ["tpi_100", "tpi_250", "tpi_500", "tpi_1000", "tpi_2000", "gmag_250", "gmag_1000", "lap_250", "lap_1000",
                "gpar_100", "gpar_250", "gpar_500", "gpar_1000", "gper_100", "gper_250", "gper_500", "gper_1000",
                "sx_500", "sx_1500", "sx_4000", "ahead_1500", "relief", "pf_u", "pf_v", "pf_w", "ws_u", "ws_w",
                "gx_500", "gy_500", "gx_1000", "gy_1000"]
        for k in base:
            cols.setdefault(k, d[k])
        st = np.tanh(q["Fr_i"])        # 0 — нейтрально, 1 — сильно устойчиво
        for k in ("pf_u", "pf_v", "pf_w", "ws_u", "ws_w", "gpar_250", "gpar_1000", "sx_1500", "tpi_500", "tpi_2000"):
            cols[k + "·st"] = d[k] * st
        if target in HEAT:
            for k in ("tpi_500", "tpi_2000", "lap_1000", "gx_500", "gy_500", "gpar_500", "sx_1500"):
                cols[k + "·w*"] = d[k] * q["wstar"]
                cols[k + "·vana"] = d[k] * q["v_ana"]
            cols["w*"] = q["wstar"]; cols["dth_s"] = q["dth_s"]; cols["v_kat"] = q["v_kat"]; cols["v_ana"] = q["v_ana"]
            cols["U10"] = d["U10"]; cols["H"] = d["H"] / 300.0; cols["H_s1500"] = d["H_s1500"] / 300.0
            cols["zi"] = d["zi_agl"] / 1000.0
            for k in ("xi", "exh", "exi"):
                cols[k] = q[k]
                cols[k + "·Ub"] = q[k] * d["Ub"]
                cols[k + "·w*"] = q[k] * q["wstar"]
                cols[k + "·dth"] = q[k] * q["dth_s"]
                cols[k + "·vkat"] = q[k] * q["v_kat"]
            cols["Ub·w*/u*"] = d["Ub"] * np.tanh(q["wstar"] / (q["ustar"] + 0.1))
            for k in ("tpi_500", "tpi_2000", "gx_500", "gy_500", "lap_1000"):
                cols[k + "·U"] = d[k] * d["U10"]
        else:
            cols["U10"] = d["U10"]; cols["alpha"] = d["alpha"]; cols["N"] = d["N"] * 100
            cols["w*"] = q["wstar"] / np.maximum(d["Ub"], 0.5)
            for k in ("tpi_500", "tpi_2000", "gpar_500", "pf_u", "pf_w"):
                cols[k + "·w*/U"] = d[k] * cols["w*"]
    names = list(cols)
    X = np.stack([np.asarray(cols[k], np.float64) for k in names], axis=1)
    return X, names


# ------------------------------------------------------------------ гребневая регрессия по высотам
class PerLevel:
    """Отдельная линейная модель на каждую высоту AGL (кусочно по высоте), стандартизация, ridge λ."""

    def __init__(self, target, kind, lam=1.0):
        self.target, self.kind, self.lam = target, kind, lam
        self.coef = {}

    def fit(self, d, y):
        X, self.names = basis(d, self.target, self.kind)
        a = d["a"]
        for lv in np.unique(a):
            m = (a == lv) & np.isfinite(y) & np.all(np.isfinite(X), axis=1)
            Xm, ym = X[m], y[m]
            mu, sd = Xm.mean(0), Xm.std(0) + 1e-9
            Z = (Xm - mu) / sd
            A = Z.T @ Z + self.lam * len(ym) * 1e-4 * np.eye(Z.shape[1])
            b = np.linalg.solve(A, Z.T @ (ym - ym.mean()))
            self.coef[float(lv)] = dict(mu=mu, sd=sd, b=b, c=float(ym.mean()))
        return self

    def predict(self, d):
        X, _ = basis(d, self.target, self.kind)
        out = np.full(len(X), np.nan)
        a = d["a"]
        for lv, c in self.coef.items():
            m = a == lv
            out[m] = c["c"] + ((X[m] - c["mu"]) / c["sd"]) @ c["b"]
        return out

    def to_json(self):
        return dict(target=self.target, kind=self.kind, names=self.names,
                    levels={str(k): dict(mu=v["mu"].tolist(), sd=v["sd"].tolist(), b=v["b"].tolist(), c=v["c"])
                            for k, v in self.coef.items()})


FEATS_GBM = None


def gbm_features(d):
    q = derived(d)
    names = [k for k in d if not k.startswith("t_") and k not in ("case", "win")]
    cols = [d[k] for k in names] + [q["wstar"], q["v_ana"], q["v_kat"], q["dth_s"], q["Fr_i"]]
    return np.stack(cols, axis=1).astype(np.float32), names + ["wstar", "v_ana", "v_kat", "dth_s", "Fr_i"]


class GBM:
    def __init__(self, target, n_trees=400, leaves=31):
        self.target, self.n_trees, self.leaves = target, n_trees, leaves

    def fit(self, d, y):
        import lightgbm as lgb
        X, self.names = gbm_features(d)
        m = np.isfinite(y)
        self.model = lgb.LGBMRegressor(n_estimators=self.n_trees, num_leaves=self.leaves, learning_rate=0.05,
                                       subsample=0.5, subsample_freq=1, colsample_bytree=0.8, min_child_samples=50,
                                       verbose=-1, n_jobs=16)
        self.model.fit(X[m], y[m])
        return self

    def predict(self, d):
        X, _ = gbm_features(d)
        return self.model.predict(X)


def make(kind, target):
    return GBM(target) if kind == "gbm" else PerLevel(target, kind)


# ------------------------------------------------------------------ данные и метрики
def load():
    Z = np.load(OUT / "ds_points.npz")
    d = {k: Z[k] for k in Z.files if k not in ("case_loc", "case_id")}
    loc = Z["case_loc"][d["case"]]
    return d, loc, Z["case_id"]


def sub(d, m):
    return {k: v[m] for k, v in d.items()}


def scale_back(target, d, y):
    """В м/с (механика — × Ubg), остальное как есть."""
    return y * d["Ub"] if target in MECH else y


def metrics(target, d, y, p):
    m = np.isfinite(y) & np.isfinite(p)
    yt, pt = scale_back(target, d, y)[m], scale_back(target, d, p)[m]
    rmse = float(np.sqrt(np.mean((yt - pt) ** 2)))
    var = float(np.var(yt))
    base = {"t_mpar": 1.0}.get(target, 0.0)          # фон без рельефа / без нагрева
    yb = scale_back(target, d, np.full_like(y, base))[m]
    rmse_bg = float(np.sqrt(np.mean((yt - yb) ** 2)))
    out = dict(n=int(m.sum()), rmse=rmse, rmse_bg=rmse_bg, gain=1 - rmse ** 2 / rmse_bg ** 2 if rmse_bg > 0 else None, std=math.sqrt(var), skill=1 - rmse ** 2 / var if var > 0 else None,
               mae=float(np.mean(np.abs(yt - pt))))
    return out


def folds(loc, case, case_id, seed=7):
    rng = np.random.default_rng(seed)
    F = []
    for L in REAL:
        F.append((f"место {L}", loc != L, loc == L))
    synth = np.char.startswith(loc.astype(str), "s_")
    F.append(("синтетика", ~synth, synth))
    ucase = np.unique(case)
    hold = set(rng.choice(ucase, int(0.2 * len(ucase)), replace=False).tolist())
    hm = np.isin(case, list(hold))
    F.append(("новые условия", ~hm, hm))
    return F, sorted(hold)


FOLD_DIR = OUT / "folds"


def save_fold(name, target, kind, mdl):
    import pickle
    FOLD_DIR.mkdir(exist_ok=True)
    with open(FOLD_DIR / f"{name.replace(' ', '_')}|{target}|{kind}.pkl", "wb") as f:
        pickle.dump(mdl, f)


def load_fold(name, target, kind):
    import pickle
    with open(FOLD_DIR / f"{name.replace(' ', '_')}|{target}|{kind}.pkl", "rb") as f:
        return pickle.load(f)


def main():
    t0 = time.time()
    d, loc, case_id = load()
    F, hold = folds(loc, d["case"], case_id)
    res = dict(folds=[f[0] for f in F], hold_cases=[str(case_id[c]) for c in hold], m={})
    for target in TARGETS:
        y = d[target].astype(np.float64)
        for kind in ("phys", "lin", "gbm"):
            for name, tr, te in F:
                trm = tr & np.isfinite(y)
                if trm.sum() < 1000 or (te & np.isfinite(y)).sum() < 100:
                    continue
                mdl = make(kind, target).fit(sub(d, trm), y[trm])
                p = mdl.predict(sub(d, te))
                res["m"].setdefault(target, {}).setdefault(kind, {})[name] = metrics(target, sub(d, te), y[te], p)
                save_fold(name, target, kind, mdl)
                print(f"[{time.time() - t0:6.0f} с] {target} {kind} {name}: "
                      f"{res['m'][target][kind][name]['rmse']:.3f} (σ {res['m'][target][kind][name]['std']:.3f}, "
                      f"фон {res['m'][target][kind][name]['rmse_bg']:.3f}, skill {res['m'][target][kind][name]['skill']:.2f})", flush=True)
    (OUT / "fit_metrics.json").write_text(json.dumps(res, ensure_ascii=False, indent=1))
    # итоговые модели на всём наборе
    models = {}
    for target in TARGETS:
        y = d[target].astype(np.float64)
        m = np.isfinite(y)
        for kind in ("phys", "lin"):
            models[f"{target}|{kind}"] = make(kind, target).fit(sub(d, m), y[m]).to_json()
        g = GBM(target).fit(sub(d, m), y[m])
        g.model.booster_.save_model(str(OUT / f"gbm_{target}.txt"))
    (OUT / "models.json").write_text(json.dumps(models, ensure_ascii=False))
    print(f"готово за {time.time() - t0:.0f} с")


if __name__ == "__main__":
    main()
