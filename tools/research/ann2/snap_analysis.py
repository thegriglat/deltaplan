"""AN-1, шаг 4: для случаев с пересчитанными снимками (snaps.py) — ошибка сети P2 против разброса цели по клеткам
(60 м, область без 5 клеток у края, |Δ(u,v)|). → out/snap_cases.json, out/snap_tables.md
Проверка воспроизведения: цель, собранная из снимков (среднее late_its у нс / состояние на итерации сходимости у сошедшихся),
против d400_h набора (float16)."""
import json
import time
from pathlib import Path

import numpy as np
import torch

import common
from common import RUN, OUT
from snaps import SNAP, rows
from pilotnn import common as C, evaluate as E
from pilotnn.data import Datasets, case_groups
from pilotnn.train import enc_of, load_arrays_enc


def sc(a, p): return float(np.percentile(a, p))


def main(ids):
    cfg = json.loads((RUN / "config.json").read_text()); ec = cfg["eval"]
    info = json.loads((RUN / "run_info.json").read_text())
    dss = Datasets([(d["name"], d["root"]) for d in info["datasets"]])
    prep = info["prep_dirs"]; agl = dss.agl; lw = E.level_weights(agl, ec["agl_key_m"])
    dev = torch.device("cuda"); model, task = E.load_net(Path(info.get("main_dir") or RUN / "main"), dev); enc = enc_of(task)
    e = ec["edge_cells"]; s = (Ellipsis, slice(e, -e or None), slice(e, -e or None))
    rw = rows(); sp = json.loads((RUN / "split.json").read_text())
    setof = {i: "holdout_sys" for i in sp["holdout_sys_ids"]}; setof.update({i: "train" for i in sp["train_ids"]})
    lock = C.GpuLock(None); out = []
    for cid in ids:
        z = np.load(SNAP / f"{cid}.npz"); its = z["it"]; uv = z["uv60"].astype(np.float64)   # (n, 2, 96, 96)
        row = rw[cid]; gr = case_groups(row)
        X, F, _, _, metas = load_arrays_enc(prep, enc, [cid], with_y=False)
        with lock:
            Yp = E.predict(model, X, F, dev)
        ds = dss.load(cid); hc = ds["d400_hc"].astype(np.float64)
        pf = E.to_phys_net(Yp[0], metas[0], agl, enc, hc)
        net = E.at_level(pf["h"], lw)[:2].astype(np.float64)
        tds = E.at_level(ds["d400_h"].astype(np.float64), lw)[:2]
        conv_it = int(z["conv_it"]); nc = conv_it < 0
        lateits = row["runs"]["d400_h"].get("late_its") if nc else None
        idx = lambda itlist: [int(np.where(its == k)[0][0]) for k in itlist]
        if nc:
            tgt = uv[idx(lateits)].mean(0)
        else:
            tgt = uv[idx([conv_it])[0]]
        # at60 дано по AGL-уровням 50/75 той же линейной формулой, что at_level (весы 0,6/0,4) — одинаково
        crop = lambda a: a[s]
        repro = float(np.abs(crop(tgt) - crop(tds)).max())
        mag = lambda d: np.hypot(d[0], d[1])
        late_all = uv[(its >= 500)]                       # все снимки 500…1000 (каждые 10 итераций)
        lm_all = late_all.mean(0)
        sel = [i for i, k in enumerate(its) if k >= 500 and (k - 501) % 50 == 0]
        late11 = uv[sel]; lm11 = late11.mean(0)
        sig11 = np.sqrt(((late11 - lm11) ** 2).sum(1).mean(0))      # RMS |Δ(u,v)| по снимкам (как late_spread60_p90)
        sig_all = np.sqrt(((late_all - lm_all) ** 2).sum(1).mean(0))
        half = mag(late_all[: len(late_all) // 2].mean(0) - late_all[len(late_all) // 2:].mean(0)) / 2   # шум среднего (половины)
        d = dict(case=cid, set=setof.get(cid), U10=row["U10"], nc=nc, conv_it=conv_it,
                 repro_max_abs=repro, vt_med=float(np.median(mag(tgt)[e:-e, e:-e])),
                 err_med=float(np.median(crop(mag(net - tgt)))), err_p90=sc(crop(mag(net - tgt)), 90),
                 sigma11_med=float(np.median(crop(sig11))), sigma11_p90=sc(crop(sig11), 90),
                 sigma_all_med=float(np.median(crop(sig_all))), sigma_all_p90=sc(crop(sig_all), 90),
                 tgt11_vs_all_med=float(np.median(crop(mag(lm11 - lm_all)))), tgt11_vs_all_p90=sc(crop(mag(lm11 - lm_all)), 90),
                 half_noise_med=float(np.median(crop(half))), half_noise_p90=sc(crop(half), 90),
                 err_to_longrun_med=float(np.median(crop(mag(net - lm_all)))), err_to_longrun_p90=sc(crop(mag(net - lm_all)), 90),
                 err_to_snap_med=float(np.median([np.median(crop(mag(net - u))) for u in late_all])))
        if not nc:
            d.update(drift_conv_to_longrun_med=float(np.median(crop(mag(tgt - lm_all)))), drift_conv_to_longrun_p90=sc(crop(mag(tgt - lm_all)), 90),
                     drift_conv_plus100_med=float(np.median(crop(mag(tgt - uv[idx([conv_it + 100])[0]])))) if conv_it + 100 <= its[-1] else None,
                     drift_conv_plus100_p90=sc(crop(mag(tgt - uv[idx([conv_it + 100])[0]])), 90) if conv_it + 100 <= its[-1] else None,
                     drift_conv_plus10_med=float(np.median(crop(mag(tgt - uv[idx([conv_it + 10])[0]])))))
        out.append(d); print(cid, {k: (round(v, 3) if isinstance(v, float) else v) for k, v in d.items() if k in ("nc", "err_med", "sigma11_p90", "repro_max_abs")}, flush=True)
    (OUT / "snap_cases.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    import sys
    ids = json.loads(Path(sys.argv[1]).read_text()) if len(sys.argv) > 1 else sorted(p.stem for p in SNAP.glob("*.npz"))
    main(ids)
