"""Подготовка кодировки П2 v5 (контракт docs/contracts/air-nn-p3.md) — кеш рядом с кешем v4, по файлу на случай.

Кеш v5 хранит то, чего нет в кеше v4 (карты 0–8 и числа FiLM берутся из кеша v4 — они те же):
  Xe  (18, 96, 96) f32 — карты 9–26 входа v5 (`maps5.maps_v5`, порядок MAP_NAMES_V5[9:]);
  Y5  (117, 96, 96) f16 — цель выхода v5 при γ_a = 0 (каналы w_rel = w/S): γ_a подбирается по обучающим случаям
      прогона, w_rel = Y5[w] − γ_a·K собирается при загрузке (`train.load_arrays_enc`);
  K   (26, 96, 96) f16 — V·∇h_s(z_a)/S (V — ветер решателя в повёрнутой системе, ∇h_s — Б1 gx, gy): [0:13] без
      нагрева, [13:26] с нагревом;
  V   (26, 96, 96) f16 — max(‖V‖, ε)/S (вес скорости в ошибке разгона и поворота), тот же порядок;
  meta — как v4 + `gfit`: суммы по клеткам случая Σk², Σk·w (физические м²/с², k = V·∇h_s) по (m|h, высоте) —
      наименьшие квадраты γ_a = Σ k·w / Σ k² по обучающим случаям.

  python -m pilotnn.prep5 <каталог кеша v5> <каталог набора> <список id (json)> [процессов]
"""
from __future__ import annotations

import io
import json
import multiprocessing as mp
import os
import sys
import time
from pathlib import Path

import numpy as np

from . import base as B
from . import common as C
from . import maps5 as M5
from . import prep as P
from .data import Dataset

CODE_FILES = [Path(__file__), Path(B.__file__), Path(M5.__file__)]
N_XE = len(M5.MAP_NAMES_V5) - len(P.MAP_NAMES)          # 18
_DS = None
_OUT = None


def base_for(hc, meta, agl=P.AGL):
    """Линейная база Б1 случая (повёрнутый рельеф, профиль притока случая)."""
    hr = np.ascontiguousarray(P.rot_scalar(np.asarray(hc, np.float64), meta["k"]))
    return B.linear_base(hr, meta["r"], P.ubg(agl, meta["alpha"], meta["mp"], meta["U10"]), agl)


def prepare_case_v5(z, row, tile=None, agl=P.AGL):
    hc = np.asarray(z["d400_hc"], np.float64)
    meta = P.case_meta(row, hc)
    base = base_for(hc, meta, agl)
    X = M5.maps_v5(z, meta, row, tile=tile, base=base)
    Y = B.target_v5(z, meta, base, agl, gamma=0.0)
    S, k = meta["S"], meta["k"]
    Ks, Vs, kk, kw = [], [], [], []
    for key in ("d400_m", "d400_h"):
        f = np.asarray(z[key], np.float64)
        u, v = P.rot_vec(f[0], f[1], k)
        w = P.rot_scalar(f[2], k)
        kin = u * base["gx"] + v * base["gy"]
        Ks.append(kin / S)
        Vs.append(np.maximum(np.hypot(u, v), B.EPS) / S)
        kk.append((kin * kin).sum(axis=(-2, -1)))
        kw.append((kin * w).sum(axis=(-2, -1)))
    meta = dict(meta, gfit=dict(kk=np.stack(kk).tolist(), kw=np.stack(kw).tolist(), n=int(hc.size)),
                tile=tile is not None)
    return dict(Xe=X[len(P.MAP_NAMES):], Y5=Y.astype(np.float16), K=np.concatenate(Ks).astype(np.float16),
                V=np.concatenate(Vs).astype(np.float16), meta=meta)


def _one(row):
    out = _OUT / "cases" / f"{row['id']}.npz"
    if out.exists():
        return row["id"], False
    z = _DS.load(row["id"])
    d = prepare_case_v5(z, row, M5.load_tile(row["loc"]), _DS.agl)
    for key in ("Xe", "Y5", "K", "V"):
        if not np.isfinite(d[key].astype(np.float32)).all():
            raise ValueError(f"{row['id']}: нечисловые значения в {key}")
    buf = io.BytesIO()
    np.savez(buf, Xe=d["Xe"], Y5=d["Y5"], K=d["K"], V=d["V"], meta=np.array(json.dumps(d["meta"])))
    C.atomic_write_bytes(out, buf.getvalue())
    return row["id"], True


def gamma_fit(prep5_dirs, ids):
    """γ_a по обучающим случаям: dict(m=[13], h=[13]) = Σ k·w / Σ k² (суммы — из meta кеша v5)."""
    kk = kw = 0.0
    for cid in ids:
        with np.load(case_file5(prep5_dirs, cid)) as z:
            g = json.loads(str(z["meta"]))["gfit"]
        kk = kk + np.asarray(g["kk"]); kw = kw + np.asarray(g["kw"])
    g = kw / np.maximum(kk, 1e-12)
    return dict(m=g[0].tolist(), h=g[1].tolist())


def case_file5(dirs, cid):
    dirs = [dirs] if isinstance(dirs, (str, Path)) else dirs
    for d in dirs:
        p = Path(d) / "cases" / f"{cid}.npz"
        if p.exists():
            return p
    raise FileNotFoundError(f"нет кеша v5 случая {cid} в {list(map(str, dirs))}")


def main(out_dir, ds_root, ids_file, workers=None):
    global _DS, _OUT
    sig = C.Signals()
    _OUT = Path(out_dir)
    _DS = Dataset(ds_root)
    want = set(json.loads(Path(ids_file).read_text()))
    rows = [r for r in _DS.case_rows() if r["id"] in want]
    (_OUT / "cases").mkdir(parents=True, exist_ok=True)
    C.clean_tmp(_OUT / "cases")
    C.check_space(_OUT, 1.0 + 0.0042 * len(rows))
    todo = [r for r in rows if not (_OUT / "cases" / f"{r['id']}.npz").exists()]
    done, new, t_last = len(rows) - len(todo), 0, 0.0
    prog = dict(total=len(rows), unit="случаев", label="подготовка v5")
    nw = int(workers or max(1, (os.cpu_count() or 4) - 4))
    with mp.get_context("fork").Pool(nw) as pool:
        try:
            for cid, made in pool.imap_unordered(_one, todo, chunksize=2):
                done += 1
                new += made
                if time.time() - t_last > 5:
                    t_last = time.time()
                    C.atomic_write_json(_OUT / "progress.json", dict(prog, done=done, t=t_last))
                if sig.signum is not None:
                    pool.terminate()
                    sig.check()
        except C.StopRequested as e:
            print(f"подготовка v5 прервана: {done}/{len(rows)}", flush=True)
            return e.code
    C.atomic_write_json(_OUT / "progress.json", dict(prog, done=done, t=time.time()))
    C.write_manifest(_OUT, "кеш кодировки v5 (П2 v5): карты 9–26, цель v5 при γ = 0, K, V", C.sha(sorted(want)), True,
                     dataset=str(ds_root), n_cases=len(rows), maps=M5.MAP_NAMES_V5[len(P.MAP_NAMES):],
                     out=B.OUT_NAMES_V5, code=C.code_hash(*CODE_FILES))
    print(f"подготовка v5: {len(rows)} случаев (новых {new})", flush=True)
    return C.EXIT_OK


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:5]))
