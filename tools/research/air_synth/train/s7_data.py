"""S7 (SY-11): загрузчик S5 v4 -> тензоры сети P2, восстановление чисел FiLM, кеш подготовки.

Что делает:
  recover_case   — условия случая из таблицы S2 v4 -> тем же кодом, что строил случай решателя (solve_corpus.solve_one:
                   model_place.register + context + подмена weather.CFG через S5.weather_override + real.case),
                   -> метаданные `profile`/`day` (как airlite_gen.solve_case) и поток тепла H (после гашения у края, как
                   air.Air) — тот, что решатель записал в inputs/heat_flux (проверка: tests/test_recover.py);
  prepare_case   — карты (9), числа FiLM (18), цель (91 канал) и числа обратного преобразования — функциями P2
                   (air_nn_pilot/pilotnn/prep.py, без правок);
  build_cache    — подготовка частей набора S5 в `.npy` (X, F, Y) + `.meta.npz`; продолжение — по готовым частям;
  Cache          — чтение кеша: индексация по случаю, деление «проверка по месту».

Кеш: <корень>/<набор>/p<k>.{X,F,Y}.npy (float32 (n,9,96,96), float32 (n,18), float16 (n,91,96,96)) и p<k>.meta.npz.
"""
from __future__ import annotations

import hashlib
import json
import math
import multiprocessing as mp
import os
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
RESEARCH = HERE.parents[1]
for _p in (RESEARCH / "air_synth/solver", RESEARCH / "air_synth/corpus", RESEARCH / "air_nn_pilot", RESEARCH / "air3d"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

import corpus_io as cio  # noqa: E402
import s5_io as S5  # noqa: E402
from pilotnn import prep as P  # noqa: E402

NY = NX = 96
DX = 400.0
META_FLOAT = ("k", "r", "S", "alpha", "mp", "U10", "hc_mean", "heat_dev", "hc_dev")
SKY_HG = S5.HG_SKY


# ------------------------------------------------------------------ восстановление случая
def heat_taper(H, dx=DX):
    """Гашение потока тепла у края области — как air.Air.__init__ (nest=None): H·(sin(π/2·ey)·sin(π/2·ex))², шкала `heat_taper_m`."""
    import air as A
    ny, nx = H.shape
    Lx, Ly = nx * dx, ny * dx
    L = A.Params().heat_taper_m
    xe, ye = (np.arange(nx) + 0.5) * dx, (np.arange(ny) + 0.5) * dx
    exx = np.clip(np.minimum(xe, Lx - xe) / L, 0, 1)
    eyy = np.clip(np.minimum(ye, Ly - ye) / L, 0, 1)
    return H * (np.sin(0.5 * np.pi * eyy)[:, None] * np.sin(0.5 * np.pi * exx)[None, :]) ** 2


class Recover:
    """Восстановление условий случая решателя. Один экземпляр на процесс; место регистрируется один раз на рельеф."""

    def __init__(self):
        import model_place as M
        import real as RL
        self.M, self.R = M, RL
        self._rid = None

    def case(self, rid, g100, c):
        """rid, g100 (384,384) рельеф, c — dict строки условий S2 v4 -> dict(row, H, hc). row — как строка метаданных P2
        (`id, loc, hour, U10, wdir, t_max, profile, day`), пригоден для prep.film / prep.case_meta."""
        M, RL = self.M, self.R
        name = f"c_{rid:06d}"
        if self._rid != rid:
            M.register(name, np.asarray(g100, np.float64), 0.0)
            self._rid = rid
        ctx = M.context(name)        # кеш контекста места; поправки рельефа (ground_context) — по рельефу, остальное — из условий S2
        ctx.update(month=int(c["month"]), day=int(c["day"]), lat=float(c["lat_deg"]), lon=float(c["lon_deg"]),
                   utc_offset_h=float(c["utc_offset_h"]))
        cfg = S5.cfg_from_row(c)
        sky = SKY_HG if cfg is not None else {0: "clear", 1: "partly", 2: "overcast"}[int(c["sky"])]
        with S5.weather_override(cfg):
            G, hc = RL.grid_domain(name, 400)
            cond = RL.case(name, G, hc, float(c["hour_local"]), float(c["u10_m_s"]), float(c["wind_from_deg"]),
                           float(c["t_max_c"]), sky, True)
        dsum = cond.day.summary()
        day = {k: (v if not isinstance(v, float) or math.isfinite(v) else None) for k, v in dsum.items()}
        profile = dict(alpha=cond.alpha, max_profile=cond.max_profile, stab=cond.stab_class, sun_el=cond.sun_elev, sun_az=cond.sun[0])
        row = dict(id=f"{name}_{int(c['cond_id']):03d}", loc=name, hour=float(c["hour_local"]), U10=float(c["u10_m_s"]),
                   wdir=float(c["wind_from_deg"]), t_max=float(c["t_max_c"]), sky=sky, day=day, profile=profile)
        return dict(row=row, H=heat_taper(np.asarray(cond.H, np.float64)), hc=np.asarray(hc, np.float64))


def prepare_case(rec, f_m, f_h, hc_stored=None, H_stored=None):
    """Подготовка одного случая функциями P2: X (9,96,96) f32, F (18,) f32, Y (91,96,96) f16, meta (dict чисел).
    Карты — по hc и потоку тепла, которые записал решатель (hc_stored, H_stored), если заданы, иначе по восстановленным."""
    hc = np.asarray(hc_stored if hc_stored is not None else rec["hc"], np.float64)
    H = np.asarray(H_stored if H_stored is not None else rec["H"], np.float64)
    z = dict(d400_hc=hc, d400_H=H, d400_m=np.asarray(f_m, np.float64), d400_h=np.asarray(f_h, np.float64))
    meta = P.case_meta(rec["row"], hc)
    X = P.maps(z, meta, rec["row"]).astype(np.float32)
    F = P.film(rec["row"], meta).astype(np.float32)
    Y = P.target(z, meta).astype(np.float16)
    return X, F, Y, meta


# ------------------------------------------------------------------ кеш подготовки
_W = {}


def _open(solve_dir):
    """Ресурсы работника: решение (части), корпус, условия, словарь (relief_id, cond_id) -> строка."""
    if _W.get("dir") != solve_dir:
        sol = S5.Solve(solve_dir)
        man = json.loads((Path(solve_dir) / "manifest.json").read_text())
        corpus = cio.Corpus(man["relief_corpus"])
        conds = cio.Conditions(man["conditions"])
        cmap = {(int(r["relief_id"]), int(r["cond_id"])): r for r in conds.table}
        _W.update(dir=solve_dir, sol=sol, corpus=corpus, cmap=cmap, rec=Recover(), g100={})
    return _W


def prep_range(args):
    """(solve_dir, i0, i1) -> X, F, Y, meta-массивы для случаев [i0, i1) файла (по порядку `case` в виде solve.h5)."""
    solve_dir, i0, i1 = args
    os.environ.setdefault("OMP_NUM_THREADS", "1")
    w = _open(solve_dir)
    sol, cmap = w["sol"], w["cmap"]
    Xs, Fs, Ys, rows = [], [], [], []
    for i in range(i0, i1):
        cs = sol.cases[i]
        rid, cid = int(cs["relief_id"]), int(cs["cond_id"])
        if rid not in w["g100"]:
            if len(w["g100"]) > 8:
                w["g100"].clear()
            w["g100"][rid] = w["corpus"].h100(rid, np.float32)
        c = cio._dec(cmap[(rid, cid)], cmap[(rid, cid)].dtype)
        rec = w["rec"].case(rid, w["g100"][rid], c)
        hc_s = sol.get("inputs/hc", i)
        H_s = sol.get("inputs/heat_flux", i).astype(np.float64)
        X, F, Y, meta = prepare_case(rec, sol.get("fields/m", i), sol.get("fields/h", i), hc_s, H_s)
        Xs.append(X); Fs.append(F); Ys.append(Y)
        rows.append(dict(
            case=int(cs["case"]), relief_id=rid, cond_id=cid, group=int(cs["group"]), status_m=int(cs["status_m"]), status_h=int(cs["status_h"]),
            k=meta["k"], r=meta["r"], S=meta["S"], alpha=meta["alpha"], mp=meta["mp"], U10=meta["U10"], hc_mean=meta["hc_mean"],
            heat_dev=float(np.abs(rec["H"].astype(np.float16).astype(np.float64) - H_s).max()),
            hc_dev=float(np.abs(rec["hc"] - hc_s).max()),
            mechanical=bool(c["mechanical"]), froude=float(c["froude"]), dtheta=float(c["dtheta_dz_k_per_km"]) if "dtheta_dz_k_per_km" in c else float("nan"),
            u10=float(c["u10_m_s"]), w_star_over_u=float(c["w_star_over_u"]), lat=float(c["lat_deg"]), lon=float(c["lon_deg"]),
            hour=float(c["hour_local"]), month=int(c["month"])))
    meta = {k: np.array([r[k] for r in rows]) for k in rows[0]}
    return np.stack(Xs), np.stack(Fs), np.stack(Ys), meta


def part_files(cache_dir, k):
    d = Path(cache_dir)
    return d / f"p{k:05d}.X.npy", d / f"p{k:05d}.F.npy", d / f"p{k:05d}.Y.npy", d / f"p{k:05d}.meta.npz"


def build_cache(solve_dir, cache_dir, workers=4, chunk=8, log=print):
    """Подготовка всех готовых частей набора S5 (части solve_dir/part-*.h5); готовые части кеша пропускаются. Атомарно по части."""
    solve_dir, cache_dir = str(solve_dir), Path(cache_dir)
    cache_dir.mkdir(parents=True, exist_ok=True)
    parts = cio.list_parts(solve_dir)
    done = []
    pool = mp.get_context("fork").Pool(workers) if workers > 1 else None
    try:
        off = 0
        for k in parts:
            import h5py
            with h5py.File(cio.part_path(solve_dir, k), "r") as f:
                n = int(f["cases"].shape[0])
            fx, ff, fy, fm = part_files(cache_dir, k)
            if fm.exists():
                done.append(k); off += n
                continue
            t0 = time.time()
            tasks = [(solve_dir, off + a, off + min(a + chunk, n)) for a in range(0, n, chunk)]
            res = pool.map(prep_range, tasks) if pool else [prep_range(t) for t in tasks]
            X = np.concatenate([r[0] for r in res]); F = np.concatenate([r[1] for r in res]); Y = np.concatenate([r[2] for r in res])
            meta = {key: np.concatenate([r[3][key] for r in res]) for key in res[0][3]}
            for p, a in ((fx, X), (ff, F), (fy, Y)):
                np.save(str(p) + ".tmp.npy", a); os.replace(str(p) + ".tmp.npy", p)
            np.savez(str(fm) + ".tmp.npz", **meta); os.replace(str(fm) + ".tmp.npz", fm)   # meta — последним: признак готовности части
            log(f"{Path(solve_dir).name} часть {k}: {n} случаев, {time.time() - t0:.0f} с, "
                f"max|Δ heat_flux| {meta['heat_dev'].max():.3g}, max|Δ hc| {meta['hc_dev'].max():.3g}")
            done.append(k); off += n
    finally:
        if pool:
            pool.close(); pool.join()
    return done


class Cache:
    """Чтение кеша набора(ов): X, F — в ОЗУ по запросу (`load_xf`), Y — `np.load(mmap_mode='r')` по частям.
    Индекс случая — сквозной по частям (в порядке перечисления наборов и частей); таблицы метаданных — `.meta`."""

    def __init__(self, cache_dirs):
        self.parts, metas = [], []
        for d in ([cache_dirs] if isinstance(cache_dirs, (str, Path)) else cache_dirs):
            for fm in sorted(Path(d).glob("p*.meta.npz")):
                k = int(fm.name[1:6])
                fx, ff, fy, _ = part_files(d, k)
                with np.load(fm) as z:
                    m = {key: z[key] for key in z.files}
                self.parts.append((fx, ff, fy)); metas.append(m)
        if not self.parts:
            raise FileNotFoundError(f"в кеше {cache_dirs} нет готовых частей")
        self.meta = {key: np.concatenate([m[key] for m in metas]) for key in metas[0]}
        self.n = len(self.meta["case"])
        sizes = [len(m["case"]) for m in metas]
        self.off = np.concatenate([[0], np.cumsum(sizes)])
        self._Y = [np.load(fy, mmap_mode="r") for _, _, fy in self.parts]

    def __len__(self):
        return self.n

    def load_xf(self, idx):
        """X (n,9,96,96) f32, F (n,18) f32 по индексам (в ОЗУ)."""
        idx = np.asarray(idx)
        X = np.empty((len(idx), 9, NY, NX), np.float32)
        F = np.empty((len(idx), 18), np.float32)
        pa = np.searchsorted(self.off, idx, side="right") - 1
        for p in np.unique(pa):
            sel = np.nonzero(pa == p)[0]
            loc = idx[sel] - self.off[p]
            fx, ff, _ = self.parts[p]
            xm, fm_ = np.load(fx, mmap_mode="r"), np.load(ff, mmap_mode="r")
            X[sel] = xm[loc]; F[sel] = fm_[loc]
        return X, F

    def gather_y(self, idx, out=None):
        """Y (len(idx),91,96,96) f16 по индексам (любой порядок); out — готовый буфер (закреплённая память)."""
        idx = np.asarray(idx)
        if out is None:
            out = np.empty((len(idx), 91, NY, NX), np.float16)
        pa = np.searchsorted(self.off, idx, side="right") - 1
        for j, (i, p) in enumerate(zip(idx, pa)):
            out[j] = self._Y[p][i - self.off[p]]
        return out

    def select(self, group=None, ok_only=True):
        """Индексы случаев группы (S5 `group`: 0 train, 1 holdout, 2 game; список — объединение); ok_only — без разошедшихся (status 2)."""
        m = np.ones(self.n, bool)
        if group is not None:
            gs = [group] if isinstance(group, int) else list(group)
            m &= np.isin(self.meta["group"], gs)
        if ok_only:
            m &= (self.meta["status_m"] != 2) & (self.meta["status_h"] != 2)
        return np.nonzero(m)[0]


# ------------------------------------------------------------------ деление: проверка — по месту
def u01(*parts):
    h = hashlib.sha256("|".join(str(p) for p in parts).encode()).digest()
    return int.from_bytes(h[:8], "big") / 2.0 ** 64


def split_val(relief_ids, frac=0.10, seed=1):
    """Проверка для ранней остановки: места (relief_id) с u01(seed, id) < порог так, чтобы доля мест ≈ frac. Целиком по месту.
    Порог — frac-квантиль хешей мест среди переданных (детерминированно по набору мест). -> маска проверки по случаям."""
    relief_ids = np.asarray(relief_ids)
    places = np.unique(relief_ids)
    u = np.array([u01("sy11-val", seed, int(p)) for p in places])
    n_val = max(1, int(round(frac * len(places))))
    val_places = set(places[np.argsort(u)[:n_val]].tolist())
    return np.array([int(r) in val_places for r in relief_ids])
