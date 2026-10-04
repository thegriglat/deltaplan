#!/usr/bin/env python3
"""Набор условий p2c12 (S2 v2): 12 условий на рельеф ровно как набор `terrain` P2 (airlite_gen.plan_rows: час 9/12/15/20 ×
облачность по кругу, cond_id 5 — штиль U10 = 0, иначе U10 0,5–8 м/с, направление 0–360°, t_max 18–34 °C), без отбора.
Производные — conditions.derive (импорт, conditions.py не правится). Место (lat/lon/пояс): реальные — места, модельные — draw_place
(S2). Зерно: SeedSequence([20261004, relief_id]) (как sample_ex), порядок розыгрыша: место, затем 12 условий.
  make_p2c12.py --relief-corpus ~/air_synth_data/real/p6v3 --plan real --out ~/air_synth_data/conditions/p6v3_p2c12
  make_p2c12.py --relief-corpus ~/air_synth_data/corpus/fs1_10k --plan model --out ~/air_synth_data/conditions/fs1_360_p2c12"""
import argparse
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import s5_io as S5   # noqa: E402
import solve_corpus as SC   # noqa: E402

cio = S5.cio
sys.path.insert(0, str(HERE.parent / "corpus"))
import conditions as C   # noqa: E402

HOURS = (9.0, 12.0, 15.0, 20.0)
SKIES = ("clear", "partly", "overcast")
SEED = 20261004


def rows_for(seed, rid, summary, hc400, place, k=12):
    rng = np.random.Generator(np.random.PCG64(np.random.SeedSequence([int(seed), int(rid)])))
    lat, lon, utc = C.draw_place(rng)
    md = None
    if place is not None and place.get("name"):
        lat, lon = float(place["lat_deg"]), float(place["lon_deg"])
        utc = float(round(lon / 15.0))
        md = (1, 15) if lat < 0 else None
    import types
    ctx, hc = C._ctx(lat, lon, utc, hc400, types.SimpleNamespace(**summary), md)
    rows = np.zeros(k, cio.CONDITIONS_DTYPE)
    for c in range(k):
        U = 0.0 if c % 12 == 5 else float(np.round(rng.uniform(0.5, 8.0), 2))
        raw = dict(hour=HOURS[c % 4], sky=SKIES[(c // 4) % 3], U10=U, wdir=float(np.round(rng.uniform(0, 360), 1)),
                   t_max=float(np.round(rng.uniform(18.0, 34.0), 1)))
        d = C.derive(raw, ctx, hc, summary["relief_m"])
        r = rows[c]
        r["relief_id"], r["cond_id"] = int(rid), c
        r["u10_m_s"], r["wind_from_deg"], r["hour_local"], r["t_max_c"] = U, raw["wdir"], raw["hour"], raw["t_max"]
        r["lat_deg"], r["lon_deg"], r["utc_offset_h"] = lat, lon, utc
        r["sky"], r["month"], r["day"] = C.SKY_CODE[raw["sky"]], ctx["month"], ctx["day"]
        for f in rows.dtype.names:
            if f in d:
                r[f] = d[f]
        r["strat_override"], r["n_bv_override_s"], r["z_i_override_agl_m"] = False, np.nan, np.nan
    return rows


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--relief-corpus", required=True)
    ap.add_argument("--plan", choices=("real", "model"), required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--k-cond", type=int, default=12)
    ap.add_argument("--n-train", type=int, default=300)
    ap.add_argument("--n-holdout", type=int, default=60)
    ap.add_argument("--seed", type=int, default=SEED)
    a = ap.parse_args(argv)
    cor = cio.Corpus(a.relief_corpus)
    plan = SC.build_plan(a.plan, cor, a.k_cond, a.n_train, a.n_holdout)
    ids = sorted({p[0] for p in plan})
    S = 100
    import os
    os.makedirs(a.out, exist_ok=True)
    cio.clean_tmp(a.out)
    base = dict(relief_corpus=str(Path(a.relief_corpus).resolve()), cond_seed=np.uint64(a.seed), k_per_relief=a.k_cond, mechanical_only=False,
                shard_size=S, generator_version="p2c12", git_commit=SC.git_commit(), command=" ".join(sys.argv), reject_fraction=0.0)
    cio.write_manifest(a.out, dict(base, contract="S2 v2", kind="conditions", cond_seed=int(a.seed), n_total=len(ids) * a.k_cond,
                                   note="p2c12: 12 условий как terrain P2 (plan_rows), без отбора, cond_id 5 — штиль"))
    for part in sorted({i // S for i in ids}):
        tabs = []
        for rid in [i for i in ids if i // S == part]:
            place = cor.place(rid) if cor._has("place") else None
            tabs.append(rows_for(a.seed, rid, cor.summary(rid), cor.h400(rid, np.float64), place, a.k_cond))
        cio.write_conditions_part(a.out, part, np.concatenate(tabs), base)
    cor.close()
    info = cio.build_view(a.out, "conditions")
    m = cio.read_manifest(a.out); m.update(info); cio.write_manifest(a.out, m)
    print(info)


if __name__ == "__main__":
    main()
