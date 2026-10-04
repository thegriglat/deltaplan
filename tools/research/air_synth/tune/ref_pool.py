"""Эталон — места пула air-nn v3 (S1 v3, $AIR_SYNTH_DATA/real/p6v3): part=pool, без t_0164 (артефакт); holdout не используется.
Запуск: ../corpus/.venv/bin/python ref_pool.py -> out/ref_obs_pool.json"""
import json, os, sys
import numpy as np, h5py
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import observables as ob  # noqa: E402

SRC = os.path.expanduser(os.environ.get("AIR_SYNTH_DATA", "~/air_synth_data")) + "/real/p6v3/corpus.h5"


def one(a):
    name, system, z = a
    return dict(name=name, kind="pool", place=system, obs=ob.observables(z))


if __name__ == "__main__":
    from multiprocessing import Pool
    with h5py.File(SRC) as f:
        pl = f["place"][:]
        at = dict(f["relief/h100"].attrs)
        keep = [i for i in range(len(pl)) if pl["part"][i].decode() == "pool" and pl["name"][i].decode() != "t_0164"]
        tasks = [(pl["name"][i].decode(), pl["system"][i].decode(),
                  at["offset_m"] + at["scale_m"] * f["relief/h100"][i].astype(np.float64)) for i in keep]
    with Pool(8) as p:
        R = p.map(one, tasks)
    json.dump(dict(names=ob.NAMES, source=SRC, squares=R), open(os.path.join(HERE, "out", "ref_obs_pool.json"), "w"))
    print(len(R), "pool squares")
