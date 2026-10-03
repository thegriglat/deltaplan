"""AN-1, шаг 6: чувствительность цели к малому сдвигу условий (U10 × 1,02; направление +1°) — нижняя граница «непредсказуемости»
цели для сети, которая видит те же входы. Путь решения — тот же, что у набора terrain (airlite_gen.solve_case с late_mean 500/50, max_outer 1000;
цель — d400_h). Сохраняет по случаю out/perturb/<id>.npz (поле 60 м, исходное и два возмущённых) и продолжает после прерывания.
Запуск: dp job --lock gpu start ... python perturb.py --list out/sample.json"""
import json
import os
import sys
from pathlib import Path
import numpy as np
import common
from common import DATA, OUT, PILOT_SRC
os.environ.setdefault("AIRNN_P6_DIR", str(DATA / "tiles" / "v3"))
sys.path.insert(0, str(PILOT_SRC)); sys.path.insert(0, str(PILOT_SRC.parent / "air3d"))
from snaps import rows
PO = OUT / "perturb"; PO.mkdir(exist_ok=True)
VARIANTS = dict(base=lambda c: c, u10=lambda c: dict(c, U10=round(c["U10"] * 1.02, 4)), wdir=lambda c: dict(c, wdir=(c["wdir"] + 1.0) % 360))


def main(ids):
    import airlite_gen as G
    rw = rows()
    for cid in ids:
        f = PO / f"{cid}.npz"
        if f.exists():
            print(cid, "готов", flush=True); continue
        row = rw[cid]; c0 = {k: row[k] for k in ("id", "loc", "hour", "U10", "wdir", "t_max", "sky")}
        late = dict(row["solver"]["late_mean"], edge_cells=5); out = {}
        for name, fn in VARIANTS.items():
            res, arr = G.solve_case(fn(c0), [], max_outer=int(row["solver"]["max_outer"]), late=late)
            out[name] = arr["d400_h"].astype(np.float32)               # (4, 13, 96, 96)
            out[name + "_status"] = res["runs"]["d400_h"]["status"]; out[name + "_iters"] = res["runs"]["d400_h"]["iters"]
        np.savez_compressed(f, **out); print(cid, {k: out[k] for k in out if k.endswith(("status", "iters"))}, flush=True)


if __name__ == "__main__":
    a = sys.argv[1:]
    if a and a[0] == "--list": a = json.loads(Path(a[1]).read_text())
    main(a)
