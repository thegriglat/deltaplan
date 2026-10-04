"""AN-4 (шаг 0): проверка данных ДО запуска. Печатает `data_check_errors <n>` (после исправлений — 0), подробности — в
`out/an4/data_check.json` и stdout. Выборка: --n случаев из обучения, проверки и каждой группы оценки.
Проверки: (1) кеш подготовки P2 против исходных решений (`cases/*.npz`): X, F, Y пересчитываются `prep.prepare_case` из
сырых полей и сравниваются (`Y` — f16 точно), `to_physical(Y)` = исходные d400_h/d400_m; (2) формы, NaN/inf, диапазоны;
(3) знаки после поворота и отражения (карты и цель отражения — независимо от `prep.reflect`, из сырых полей); (4) соответствие
случаю: meta.id/U10/k/r/α/mp/S, числа F (U10, z_i, heat) — строке случая и Day; (5) деление: нет пересечения обучения с
отложенными (id, места, горные системы, Онгудай, процедурные); (6) θ̄ (bg_theta.npz): выровнено по id, у случая свой, равен
пересчёту из Day.gamma; N случая (case_table) = пересчёту; режим (w*/U) = пересчёту из сырого потока тепла;
(7) входы сети (`inputs_from`): форма, конечность, heated=0 → нулевой поток тепла и числа нагрева."""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

import numpy as np

import common as C
import data as D
import phys
import regime as RG
from phys import P
from pilotnn import film_bg as FB
from pilotnn.data import Datasets
from pilotnn.train import case_file

errs: list[str] = []
notes: list[str] = []


def bad(msg):
    errs.append(msg)
    print("ОШИБКА", msg, flush=True)


def close(a, b, rtol=1e-4, atol=1e-5):
    return bool(np.allclose(np.asarray(a, np.float64), np.asarray(b, np.float64), rtol=rtol, atol=atol))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=20)
    ap.add_argument("--seed", type=int, default=7)
    a = ap.parse_args()
    split = D.p2_split()
    info = D.p2_info()
    prep = info["prep_dirs"]
    dss = Datasets([(d["name"], d["root"]) for d in info["datasets"]])
    rows = {r["id"]: r for r in dss.case_rows()}
    import procedural as PR  # процедурные места: seed из plan.json (как bg_theta.py)
    for d in info["datasets"]:
        plan = json.loads((Path(d["root"]) / "plan.json").read_text())
        if any(str(x).startswith("p_") for x in plan.get("places", [])):
            PR.configure(plan["proc"]["seed"])
    rng = np.random.default_rng(a.seed)
    sets = {k: list(split[k + "_ids"]) for k in ("train", "val", "newcond_p6", "newcond_old", "holdout_sys",
                                                   "holdout_place", "holdout_proc")}
    sample = {k: sorted(rng.choice(v, min(a.n, len(v)), replace=False).tolist()) for k, v in sets.items()}
    stats = dict(X=[], Y=[])
    bgz = np.load(RG.AIR / "ann2" / "bg_theta.npz")
    bg = dict(zip(bgz["ids"].tolist(), bgz["th"]))
    tab = RG.table()
    n_checked = 0
    for sname, ids in sample.items():
        for cid in ids:
            n_checked += 1
            row = rows[cid]
            with np.load(case_file(prep, cid)) as z:
                X, F, Y, meta = z["X"], z["F"], z["Y"], json.loads(str(z["meta"]))
            raw = dss.load(cid)
            tag = f"{sname}/{cid}"
            # (2) формы, конечность
            if X.shape != (9, 96, 96) or F.shape != (18,) or Y.shape != (91, 96, 96):
                bad(f"{tag}: формы X{X.shape} F{F.shape} Y{Y.shape}")
                continue
            if X.dtype != np.float32 or Y.dtype != np.float16:
                bad(f"{tag}: dtype X {X.dtype} Y {Y.dtype}")
            Yf = Y.astype(np.float32)
            if not (np.isfinite(X).all() and np.isfinite(F).all() and np.isfinite(Yf).all()):
                bad(f"{tag}: NaN/inf в кеше")
            for k in ("d400_h", "d400_m", "d400_hc", "d400_H"):
                if not np.isfinite(raw[k].astype(np.float32)).all():
                    bad(f"{tag}: NaN/inf в исходном {k}")
            # диапазоны (физические границы): карты (нормированные), цель (доли S), θ′, F
            mx = np.abs(X).reshape(9, -1).max(1)
            lim = np.array([3.0, 3.0, 1.01, 1.01, 20.0, 20.0, 20.0, 20.0, 5.0])
            if (mx > lim).any():
                bad(f"{tag}: карты вне диапазона {dict(zip(P.MAP_NAMES, np.round(mx, 2)))}")
            Yr = Yf.reshape(7, 13, 96, 96)
            if np.abs(Yr[[0, 1, 2, 3, 4, 5]]).max() > 30 or np.abs(Yr[6]).max() > 40:
                bad(f"{tag}: цель вне диапазона: max|u,w|/S {np.abs(Yr[:6]).max():.1f}, |θ′| {np.abs(Yr[6]).max():.1f} К")
            if np.abs(F).max() > 8:   # α до 0,88 (устойчивая ночь) → (α−0,2)/0,1 = 6,8 — допустимо
                bad(f"{tag}: числа F вне диапазона {np.abs(F).max():.2f}")
            stats["X"].append(mx); stats["Y"].append([np.abs(Yr[:6]).max(), np.abs(Yr[6]).max()])
            # (1) кеш против пересчёта из сырого
            d = P.prepare_case(raw, row, dss.agl)
            if not close(d["X"], X, 1e-4, 1e-5):
                bad(f"{tag}: кеш X ≠ пересчёт из сырого (макс. {np.abs(d['X'] - X).max():.2e})")
            if not close(d["F"], F, 1e-5, 1e-6):
                bad(f"{tag}: кеш F ≠ пересчёт ({np.abs(d['F'] - F).max():.2e})")
            if not np.array_equal(d["Y"], Y):
                bad(f"{tag}: кеш Y ≠ пересчёт из сырого (макс. {np.abs(d['Y'].astype(np.float32) - Yf).max():.2e})")
            if {k: d["meta"][k] for k in ("id", "k", "r", "U10", "alpha", "mp", "S")} != \
               {k: meta[k] for k in ("id", "k", "r", "U10", "alpha", "mp", "S")}:
                bad(f"{tag}: meta ≠ пересчёт")
            # to_physical(Y) = исходные решения (потеря f16 — относительная 1e-3 · S)
            ph = P.to_physical(Y.astype(np.float64), meta, dss.agl)
            for key, rk in (("h", "d400_h"), ("m", "d400_m")):
                e = np.abs(ph[key] - raw[rk].astype(np.float64)).max()
                if e > 2e-3 * max(meta["S"], 1) * 30:
                    bad(f"{tag}: to_physical({key}) ≠ исходное решение: {e:.3e}")
            # (4) соответствие случаю
            if meta["id"] != cid:
                bad(f"{tag}: meta.id {meta['id']}")
            if abs(meta["U10"] - float(row["U10"])) > 1e-9 or abs(meta["S"] - max(float(row["U10"]), 1.0)) > 1e-9:
                bad(f"{tag}: U10/S")
            k_, r_ = P.rotation_of(float(row["wdir"]))
            if k_ != meta["k"] or abs(r_ - meta["r"]) > 1e-9 or not (-math.pi / 4 - 1e-9 <= meta["r"] < math.pi / 4 + 1e-9):
                bad(f"{tag}: поворот k,r")
            if abs(F[0] - meta["U10"] / 10) > 1e-6 or abs(F[1] - math.cos(meta["r"])) > 1e-6 or abs(F[2] - math.sin(meta["r"])) > 1e-6:
                bad(f"{tag}: F[U10, cos r, sin r]")
            Dy = FB.day_of(row)
            hm = float(raw["d400_hc"].astype(np.float64).mean())
            if abs(meta["hc_mean"] - hm) > 1e-6:
                bad(f"{tag}: hc_mean")
            if abs(F[5] - (Dy.z_i - hm) / 1000.0) > 2e-3 and not (row.get("day") or {}).get("z_i_msl") is None:
                bad(f"{tag}: F[z_i] {F[5]:.4f} против Day {(Dy.z_i - hm) / 1000:.4f}")
            if FB.check_day(Dy, row):
                bad(f"{tag}: Day ≠ метаданные {FB.check_day(Dy, row)}")
            # (3) знаки после поворота: поток тепла и рельеф в карте = повёрнутый исходный
            hr = np.ascontiguousarray(P.rot_scalar(raw["d400_hc"].astype(np.float64), meta["k"]))
            if not close((hr - hr.mean()) / P.NORM_TERRAIN_M, X[0], 1e-4, 1e-5):
                bad(f"{tag}: terrain в карте ≠ повёрнутый рельеф")
            # знак «вдоль ветра»: уклон вдоль ê′ против явного градиента повёрнутого рельефа
            gy, gx = np.gradient(hr, 400.0)
            sa = (gx * math.cos(meta["r"]) + gy * math.sin(meta["r"])) / P.NORM_SLOPE
            if not close(sa, X[4], 1e-4, 1e-5):
                bad(f"{tag}: slope_along ≠ ∇h·ê′")
            # отражение: независимо — по зеркальному рельефу и r → −r, цель — по зеркальному сырому полю
            Xr, Fr, Yr_ = P.reflect(X, F, Y)
            hf = hr[::-1].copy()
            sa_f, sc_f = P.slopes(hf, -meta["r"])
            sh_f = P.shelter(hf, -meta["r"]) / P.NORM_SX_RAD
            ok = (close(sa_f / P.NORM_SLOPE, Xr[4], 1e-4, 1e-5) and close(sc_f / P.NORM_SLOPE, Xr[5], 1e-4, 1e-5)
                  and close(sh_f, Xr[8], 1e-3, 1e-4) and close(hf - hf.mean(), Xr[0] * P.NORM_TERRAIN_M, 1e-4, 1e-3))
            if not ok:
                bad(f"{tag}: отражение карт ≠ карты зеркального рельефа с r → −r")
            if abs(Fr[2] + F[2]) > 1e-7 or abs(Fr[1] - F[1]) > 1e-7:
                bad(f"{tag}: отражение F")
            # цель отражения: из сырого поля — повернуть, отразить, пересчитать относительно притока при (cos r, −sin r)
            ub = P.ubg(dss.agl, meta["alpha"], meta["mp"], meta["U10"])[:, None, None]
            S = meta["S"]
            for key, c0, n in (("d400_m", 0, 3), ("d400_h", 3, 4)):
                f = raw[key].astype(np.float64)
                u, v = P.rot_vec(f[0], f[1], meta["k"])
                u, v = u[..., ::-1, :], -v[..., ::-1, :]
                ex = [(u - ub * math.cos(meta["r"])) / S, (v + ub * math.sin(meta["r"])) / S,
                      P.rot_scalar(f[2], meta["k"])[..., ::-1, :] / S]
                if n == 4:
                    ex.append(P.rot_scalar(f[3], meta["k"])[..., ::-1, :])
                got = Yr_.astype(np.float64).reshape(7, 13, 96, 96)[c0:c0 + n]
                e = max(np.abs(got[j] - ex[j]).max() for j in range(n))
                if e > 2e-2:
                    bad(f"{tag}: цель отражения {key} ≠ зеркальное сырое поле: {e:.3e}")
            # (6) θ̄ и N, режим
            th = bg.get(cid)
            if th is None:
                bad(f"{tag}: нет в bg_theta.npz")
            else:
                zz = hm + np.arange(0.0, 2000.0 + 1e-6, 2.0)
                g = np.asarray(Dy.gamma(zz), float)
                cum = np.concatenate([[0.0], np.cumsum(0.5 * (g[1:] + g[:-1]) * 2.0)])
                if not close(np.interp(P.AGL, zz - hm, cum), th, 1e-4, 1e-4):
                    bad(f"{tag}: θ̄(bg_theta.npz) ≠ пересчёту из Day.gamma")
                if not close(phys.profile_input(phys.case_par(meta), phys.bg_theta_of(meta))[1], th / 5.0):
                    bad(f"{tag}: канал θ̄ профиля ≠ bg_theta случая")
            rawb = FB.bg_raw(Dy, raw["d400_hc"], row["U10"], row["profile"]["max_profile"])
            if abs(rawb["N_bl"] - RG.n_bl(cid)) > 1e-9:
                bad(f"{tag}: N случая в таблице {RG.n_bl(cid)} ≠ пересчёт {rawb['N_bl']}")
            Hs = float(np.maximum(raw["d400_H"].astype(np.float64), 0).mean())
            i = RG.case_row(cid)
            ws = RG.wstar(Hs, rawb["z_i_agl"])
            if abs(ws - tab["wstar"][i]) > 1e-3 * max(1, ws) or abs(tab["wsu"][i] - ws / max(rawb["U"], 0.1)) > 2e-3:
                bad(f"{tag}: w*/U таблицы ≠ пересчёт ({tab['wsu'][i]:.3f} против {ws / max(rawb['U'], 0.1):.3f})")
            # (7) вход сети
            for heated in (True, False):
                B = 2
                inp = D.inputs_from(X[None].repeat(B, 0), F[None].repeat(B, 0), np.stack([phys.case_par(meta)] * B),
                                    np.stack([phys.profile_input(phys.case_par(meta), phys.bg_theta_of(meta))] * B),
                                    np.full(B, heated), "cpu", N=np.full(B, RG.n_bl(cid), np.float32))
                shp = dict(maps=(B, phys.N_MAPS, 96, 96), scal=(B, phys.N_SCAL), prof=(B, phys.N_PROF_CH, 13), par=(B, 4))
                for kk, s in shp.items():
                    if tuple(inp[kk].shape) != s or not bool(np.isfinite(inp[kk].numpy()).all()):
                        bad(f"{tag}: вход {kk} форма/конечность")
                if not heated:
                    if float(inp["maps"][:, phys.MAP_NAMES.index("heat_flux")].abs().max()) != 0 or \
                       any(float(inp["scal"][0, j]) != 0 for j in phys.HEAT_ZERO):
                        bad(f"{tag}: heated=0, а поток тепла/числа нагрева ≠ 0")
                else:
                    if abs(float(inp["scal"][0, 21]) * phys.NORM_N - RG.n_bl(cid)) > 1e-7:
                        bad(f"{tag}: скаляр N ≠ N случая")
    print(f"проверено случаев: {n_checked}", flush=True)
    # (5) деление
    tr, va = set(split["train_ids"]), set(split["val_ids"])
    hold = {k: set(split[k + "_ids"]) for k in ("holdout_sys", "holdout_place", "holdout_proc")}
    new = set(split["newcond_ids"])
    for k, v in hold.items():
        if tr & v or va & v or new & v:
            bad(f"деление: обучение/проверка/новые условия пересекаются с {k}: {len(tr & v)}")
    if tr & va or tr & new or va & new:
        bad("деление: обучение, проверка, новые условия пересекаются")
    loc = lambda i: i.rsplit("_", 1)[0]  # noqa: E731
    tr_loc = {loc(i) for i in tr | va}
    for k, v in hold.items():
        if tr_loc & {loc(i) for i in v}:
            bad(f"деление: места {k} есть среди мест обучения/проверки: {sorted(tr_loc & {loc(i) for i in v})[:5]}")
    if any(i.startswith("ongudai") for i in tr | va | new):
        bad("деление: Онгудай в обучении/проверке/новых условиях")
    p6 = json.loads((C.RUN / "p6.json").read_text())["places"]
    hs_sys = {p6[l]["system"] for l in {loc(i) for i in hold["holdout_sys"]}}
    pool_sys = {p6[l]["system"] for l in tr_loc if l in p6}
    if hs_sys & pool_sys:
        bad(f"деление: горные системы (г) {sorted(hs_sys & pool_sys)} есть в обучении")
    if any(p6[l]["part"] != "holdout" for l in {loc(i) for i in hold["holdout_sys"]}) or any(
            l in p6 and p6[l]["part"] == "holdout" for l in tr_loc):
        bad("деление: part ≠ holdout у (г) или holdout у обучения")
    # минимальное расстояние от мест обучения до мест (г)
    def ll(l):
        return np.radians([p6[l]["lat"], p6[l]["lon"]])
    h_l = np.array([ll(l) for l in {loc(i) for i in hold["holdout_sys"]}])
    t_l = np.array([ll(l) for l in tr_loc if l in p6])
    dd = np.arccos(np.clip(np.sin(h_l[:, None, 0]) * np.sin(t_l[None, :, 0]) + np.cos(h_l[:, None, 0]) * np.cos(t_l[None, :, 0])
                           * np.cos(h_l[:, None, 1] - t_l[None, :, 1]), -1, 1)) * 6371.0
    notes.append(f"мин. расстояние место (г) — место обучения: {dd.min():.0f} км")
    print(notes[-1])
    # режим: обучение — без конвективных
    tr_mech = [i for i in split["train_ids"] if RG.regime(i) == "mech"]
    notes.append(f"обучение: механических {len(tr_mech)} из {len(tr)}; (г): конвективных "
                 f"{sum(RG.regime(i) == 'conv' for i in hold['holdout_sys'])} из {len(hold['holdout_sys'])}")
    print(notes[-1])
    # θ̄ после bg_theta: у случаев разные и поле ids не повторяется; профили 2000 м: число разных
    allids = bgz["ids"].tolist()
    if len(set(allids)) != len(allids) or set(rows) != set(allids):
        bad("bg_theta.npz: ids повторяются или не равны набору случаев")
    notes.append(f"bg_theta: {len(allids)} случаев, различных профилей θ̄ {len({tuple(np.round(t, 3)) for t in bgz['th']})}")
    print(notes[-1])
    out = dict(errors=errs, n_errors=len(errs), n_checked=n_checked, sample={k: len(v) for k, v in sample.items()}, notes=notes,
               map_abs_max_over_sample=dict(zip(P.MAP_NAMES, np.max(stats["X"], 0).round(3).tolist())),
               target_abs_max=dict(u_w_over_S=float(np.max([s[0] for s in stats["Y"]])),
                                   theta_K=float(np.max([s[1] for s in stats["Y"]]))))
    (C.OUT / "an4").mkdir(exist_ok=True)
    (C.OUT / "an4" / "data_check.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))
    print(f"data_check_errors {len(errs)}")
    sys.exit(0 if not errs else 1)


if __name__ == "__main__":
    main()
