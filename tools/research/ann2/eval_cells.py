"""AN-1, шаг 1: пересчёт ошибки сети P2 по клеткам (как pilotnn.evaluate.AreaAcc.add) с записью по случаю:
ошибка ветра на 60 м (медиана/p90/среднее по клеткам области без 5 клеток у края), ρ по клеткам (как evaluate: u_ref =
max(0,3; 0,15·|V|), у несошедшихся не меньше late_spread60_p90), собственный разброс цели, группы.
Запуск: .venv-пилота/python eval_cells.py  → out/cells_cases.json, out/cells_pooled.json
Замок GPU берётся на прогон сети (flock /tmp/heat_ca_gpu.lock)."""
import json
import time
from pathlib import Path
import numpy as np
import common  # noqa: F401  (путь к pilotnn)
from common import RUN, OUT
from pilotnn import common as C, evaluate as E, prep as P
from pilotnn.data import Datasets, case_groups
from pilotnn.train import enc_of, load_arrays_enc
import torch

NTRAIN = 600


def main():
    cfg = json.loads((RUN / "config.json").read_text()); ec = cfg["eval"]
    split = json.loads((RUN / "split.json").read_text())
    info = json.loads((RUN / "run_info.json").read_text())
    dss = Datasets([(d["name"], d["root"]) for d in info["datasets"]])
    prep = info["prep_dirs"]
    rows = {r["id"]: r for r in dss.case_rows()}
    agl = dss.agl
    lw = E.level_weights(agl, ec["agl_key_m"])
    dev = torch.device("cuda")
    model, task = E.load_net(Path(info.get("main_dir") or RUN / "main"), dev)
    enc = enc_of(task)
    rng = np.random.default_rng(0)
    tr = list(split["train_ids"])
    sets = dict(holdout_sys=split["holdout_sys_ids"], holdout_place=split["holdout_place_ids"],
                holdout_proc=split["holdout_proc_ids"], newcond_p6=split["newcond_p6_ids"],
                newcond_old=split["newcond_old_ids"],
                train=sorted(rng.choice(tr, NTRAIN, replace=False).tolist()))
    e = ec["edge_cells"]; s = (Ellipsis, slice(e, -e or None), slice(e, -e or None))
    rc = ec.get("replace", {})
    cases = []; pooled = {}
    lock = C.GpuLock(None)
    t0 = time.time()
    for sname, ids in sets.items():
        for i0 in range(0, len(ids), 32):
            part = ids[i0:i0 + 32]
            X, F, _, _, metas = load_arrays_enc(prep, enc, part, with_y=False)
            with lock:
                Yp = E.predict(model, X, F, dev)
            for i, cid in enumerate(part):
                row = rows[cid]; z = dss.load(cid)
                truth = dict(h=z["d400_h"].astype(np.float64))
                hc = z["d400_hc"].astype(np.float64)
                pf = E.to_phys_net(Yp[i], metas[i], agl, enc, hc)
                th, ph = E.at_level(truth["h"], lw)[s], E.at_level(pf["h"], lw)[s]
                vt = np.hypot(th[0], th[1]); dw = np.hypot(ph[0] - th[0], ph[1] - th[1])
                gr = case_groups(row)
                u = np.maximum(rc.get("u_ref_floor_ms", 0.3), rc.get("u_ref_rel", 0.15) * vt)
                u_nc = u
                if gr["gh"] == "nc" and gr["spread_h"]:
                    u_nc = np.maximum(u, float(gr["spread_h"]))
                rho = dw / u_nc
                it = ((row.get("runs") or {}).get("d400_h") or {}).get("iters")
                cases.append(dict(set=sname, case=cid, loc=row["loc"], U10=float(row["U10"]), gh=gr["gh"], conf=bool(gr["conf"]),
                                  target=gr["target_h"], spread=gr["spread_h"], iters=it,
                                  dw_med=float(np.median(dw)), dw_p90=float(np.percentile(dw, 90)), dw_mean=float(dw.mean()),
                                  vt_mean=float(vt.mean()), rho_med=float(np.median(rho)), rho_p90=float(np.percentile(rho, 90)),
                                  rho0_med=float(np.median(dw / u))))
        print(sname, len(ids), round(time.time() - t0), "s", flush=True)
    (OUT / "cells_cases.json").write_text(json.dumps(cases))


if __name__ == "__main__":
    import json
    from pathlib import Path
    main()
