"""Шаг «подготовка тензоров»: образцы набора → кеш входа/цели сети (контракт П2), по файлу на случай.

  python -m pilotnn.prepstep <каталог кеша> <каталог набора> <список id (json)>

Кеш: <каталог кеша>/cases/<id>.npz (X карты f32, F числа f32, Y цель f16, meta json) — пишется атомарно;
готовый файл не пересчитывается (идемпотентно, продолжение после обрыва — с места). Каталог кеша зависит от
хеша кода подготовки (prep.py) и набора — новая подготовка уходит в новый каталог.
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

from . import common as C
from . import prep as P
from .data import Dataset

_DS = None
_OUT = None


def _one(row):
    out = _OUT / "cases" / f"{row['id']}.npz"
    if out.exists():
        return row["id"], False
    z = _DS.load(row["id"])
    d = P.prepare_case(z, row, _DS.agl)
    if not (np.isfinite(d["X"]).all() and np.isfinite(d["F"]).all() and np.isfinite(d["Y"].astype(np.float32)).all()):
        raise ValueError(f"{row['id']}: нечисловые значения во входе/цели")
    buf = io.BytesIO()
    np.savez(buf, X=d["X"], F=d["F"], Y=d["Y"], meta=np.array(json.dumps(d["meta"])))
    C.atomic_write_bytes(out, buf.getvalue())
    return row["id"], True


def main(out_dir, ds_root, ids_file):
    global _DS, _OUT
    sig = C.Signals()
    _OUT = Path(out_dir)
    _DS = Dataset(ds_root)
    want = set(json.loads(Path(ids_file).read_text()))
    rows = [r for r in _DS.case_rows() if r["id"] in want]
    (_OUT / "cases").mkdir(parents=True, exist_ok=True)
    C.clean_tmp(_OUT / "cases")
    C.check_space(_OUT, 1.0 + 0.002 * len(rows))
    have = sum((_OUT / "cases" / f"{r['id']}.npz").exists() for r in rows)
    prog = dict(total=len(rows), unit="случаев", label="подготовка")
    C.atomic_write_json(_OUT / "progress.json", dict(prog, done=have, t=time.time()))
    done, new = have, 0
    todo = [r for r in rows if not (_OUT / "cases" / f"{r['id']}.npz").exists()]
    t_last = 0.0
    with mp.get_context("fork").Pool(os.cpu_count() or 12) as pool:
        try:
            for cid, made in pool.imap_unordered(_one, todo, chunksize=2):
                done += 1
                new += made
                if time.time() - t_last > 1:
                    t_last = time.time()
                    C.atomic_write_json(_OUT / "progress.json", dict(prog, done=done, t=t_last))
                if sig.signum is not None:
                    pool.terminate()
                    sig.check()
        except C.StopRequested as e:
            print(f"подготовка прервана: {done}/{len(rows)}", flush=True)
            return e.code
    C.atomic_write_json(_OUT / "progress.json", dict(prog, done=done, t=time.time()))
    C.write_manifest(_OUT, "кеш входа/цели сети пилота (контракт П2)", C.sha(sorted(want)), True,
                     dataset=str(ds_root), n_cases=len(rows), maps=P.MAP_NAMES, film=P.FILM_NAMES, agl=_DS.agl)
    print(f"подготовка: {len(rows)} случаев (новых {new})", flush=True)
    return C.EXIT_OK


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:4]))
