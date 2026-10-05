#!/usr/bin/env python3
"""SY-12: рельеф мест дельтаплана по исправленной геометрии квадрата игры (air-square, C2 v7) -> корпус S1 v5 `real/hg_v2`, места игры -> `real/game_hg2`.

Конвейер П6 (как SY-6 real/pack_real.py): terrain_cut.grid_h (слой Terrarium z12, билинейно в узлах решётки мира 25 м, центр = старт) +
block_mean_400 (клетка = среднее 16 × 16 узлов, область ровно 38,4 км от −19 200 м); h100 = среднее 4 × 4 узлов, h400 = среднее 4 × 4 h100 (= hc400 П6).
Места, деление train/holdout и правила исключения — как hg_v1 (pack_hg.py, split_hg.py: те же site_id в тех же частях), без сдвига окна.
Команды: plan | fetch | pack | clean  (--data КАТАЛОГ, по умолчанию ~/sy12_data; сырьё — raw/terrarium/z/x/y.png)."""
import argparse, hashlib, json, os, shutil, subprocess, sys, time
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "corpus"))
sys.path.insert(0, str(ROOT / "tools/research/air_nn_pilot"))
import corpus_io as cio  # noqa: E402
import split_hg as SP    # noqa: E402
import pack_hg as PH     # noqa: E402  (places, пороги исключения, q)

YAML = PH.YAML
I0, NN = 32, 1536        # область ±19 200 м на сетке 25 м (узлы 32…1567)
# формат файла S1 v5 = S1 v4 (отличие — только геометрия рельефа); corpus_io (вне скоупа SY-12) принимает атрибут contract только S1 v3/v4,
# поэтому атрибут contract = "S1 v4", а версия геометрии — в generator_version "real-hg-v2" и атрибуте geometry (координатор: добавить "S1 v5" в CONTRACT_OK)
CONTRACT_ATTR, GEOMETRY = "S1 v4", "C2 v7: П6 grid_h (билинейно, узлы 25 м) + block_mean_400, область 38,4 км"
LO, HI = cio.OFFSET_M - 32768 * cio.SCALE_M, cio.OFFSET_M + 32767 * cio.SCALE_M


def data_dir(a):
    return Path(a.data or os.environ.get("SY12_DATA") or os.path.expanduser("~/sy12_data"))


def ctx_for(dd):
    import terrain_cut as TC
    return TC, TC.Ctx(YAML, str(dd))


def _one(args):
    dd, key, lat, lon = args
    TC, ctx = ctx_for(dd)
    plan = TC.place_plan(ctx, lat, lon)
    h = TC.grid_h(ctx, plan)
    hc = TC.block_mean_400(h)
    s = h.astype(np.float64)[I0:I0 + NN, I0:I0 + NN]
    z100 = s.reshape(384, 4, 384, 4).mean(axis=(1, 3))
    n_out = int(((z100 < LO) | (z100 > HI)).sum())
    clip = None
    if n_out:
        clip = dict(site_id=key, cells_g100=n_out, g100_min=float(z100.min()), g100_max=float(z100.max()))
        z100 = np.clip(z100, LO, HI)
    err = float(np.abs(cio.block_mean(z100, 4) - hc).max())
    if not n_out:
        assert err <= 1e-6, (key, err)
    sl = np.hypot(*np.gradient(hc, 400.0))[1:-1, 1:-1]
    ft = dict(h_min=float(hc.min()), h_max=float(hc.max()), relief_m=float(hc.max() - hc.min()), sea_frac=float((s <= 0.5).mean()),
              slope_p50=float(np.percentile(sl, 50)), slope_p95=float(np.percentile(sl, 95)), nan=int(np.isnan(h).sum()),
              sha256=hashlib.sha256(np.ascontiguousarray(h).tobytes()).hexdigest())
    g = dict(z=plan["z"], s=plan["spacing"], n_layer=plan["n"], g400_vs_hc400_max_abs_m=err)
    return key, z100, hc, ft, g, clip


def cmd_plan(a):
    TC, ctx = ctx_for(data_dir(a))
    sites, game = PH.places()
    tiles = set()
    for s in sites + game:
        pl = TC.place_plan(ctx, s["lat"], s["lon"])
        for t in pl["tiles"]:
            tiles.add(TC.wrap_tile(pl["z"], *t))
    dd = data_dir(a)
    dd.mkdir(parents=True, exist_ok=True)
    json.dump(sorted(tiles), open(dd / "tiles.json", "w"))
    print(len(sites) + len(game), "мест,", len(tiles), "тайлов")


def cmd_fetch(a):
    dd = data_dir(a)
    TC, ctx = ctx_for(dd)
    tiles = [tuple(t) for t in json.loads((dd / "tiles.json").read_text())]
    ctx.cfg["source"]["workers"] = min(8, int(ctx.cfg["source"]["workers"]))   # как игра: max_parallel_requests 8
    n, nb, missing = TC.fetch_tiles(ctx, tiles, throttle=a.throttle)
    json.dump(dict(requested=len(tiles), downloaded=n, bytes=nb, missing=[(list(t), e) for t, e in missing]), open(dd / "fetch.json", "w"))
    print("скачано", n, nb // 10**6, "МБ, нет данных:", len(missing))


def cmd_pack(a):
    t0 = time.time()
    dd = data_dir(a)
    sites, game = PH.places()
    out_root = Path(a.out or os.environ.get("AIR_SYNTH_DATA") or os.path.expanduser("~/air_synth_data")) / "real"
    jobs = [(str(dd), s["site_id"], s["lat"], s["lon"]) for s in sites + game]
    with ProcessPoolExecutor(a.workers) as ex:
        res = {k: (z, hc, ft, g, clip) for k, z, hc, ft, g, clip in ex.map(_one, jobs, chunksize=4)}
    keep, excluded = [], []
    for s in sites:
        ft = res[s["site_id"]][2]
        why = []
        if ft["nan"]:
            why.append("нет данных (NaN)")
        if ft["sea_frac"] > PH.SEA_MAX:
            why.append(f"море: доля узлов ≤ 0,5 м {ft['sea_frac']:.3f} > {PH.SEA_MAX}")
        if ft["relief_m"] > PH.RELIEF_MAX:
            why.append(f"перепад {ft['relief_m']:.0f} м > {PH.RELIEF_MAX:.0f}")
        if ft["h_min"] > PH.HMIN_MAX:
            why.append(f"дно {ft['h_min']:.0f} м > {PH.HMIN_MAX:.0f}")
        (excluded.append(dict(site_id=s["site_id"], name=s["name"], country=s["country"], lat=s["lat"], lon=s["lon"], reasons=why,
                              relief_m=round(ft["relief_m"], 1), sea_frac=round(ft["sea_frac"], 4))) if why else keep.append(s))
    clipped = [res[s_][4] for s_ in [x["site_id"] for x in keep] + [g_["site_id"] for g_ in game] if res[s_][4]]   # обрезанные выбросы — только у вошедших в корпус
    parts = SP.split(keep)
    near = [k for k, v in parts.items() if v[1] == "near_game"]
    hold = [s for s in keep if parts[s["site_id"]][0] == "holdout" and parts[s["site_id"]][1] != "near_game"]
    train = [s for s in keep if parts[s["site_id"]][0] == "train"]
    mind = min((SP.dist_km(h["lat"], h["lon"], t["lat"], t["lon"]) for h in hold for t in train), default=None)

    def place(s, part, stratum, key):
        _, _, ft, g, _ = res[key]
        return dict(name=s["site_id"][:16], lat_deg=float(s["lat"]), lon_deg=float(s["lon"]), system=s["country"], part=part,
                    stratum=stratum[:32], source=f"terrarium z{g['z']}", zoom=g["z"], src_spacing_m=g["s"], source_sha256=ft["sha256"])
    gc = subprocess.run(["git", "-C", str(HERE), "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
    rel = [dict(z100=res[s["site_id"]][0], place=place(s, *parts[s["site_id"]], s["site_id"])) for s in keep]
    hg = out_root / "hg_v2"
    shutil.rmtree(hg, ignore_errors=True)
    cio.write_reliefs(str(hg), rel, generator_version="real-hg-v2", corpus_seed=0, command="pack_hg2.py pack", git_commit=gc,
                      extra_attrs=dict(contract=CONTRACT_ATTR, geometry=GEOMETRY, train_order="", split_seed=np.uint64(SP.SPLIT_SEED)))
    grel = [dict(z100=res[g_["site_id"]][0], place=place(g_, "game", "game", g_["site_id"])) for g_ in game]
    gp = out_root / "game_hg2"
    shutil.rmtree(gp, ignore_errors=True)
    cio.write_reliefs(str(gp), grel, generator_version="real-game-hg2", corpus_seed=0, command="pack_hg2.py pack", git_commit=gc,
                      extra_attrs=dict(contract=CONTRACT_ATTR, geometry=GEOMETRY))
    # чтение обратно: h400 корпуса = hc400 П6 до квантования (0,075 м), кроме обрезанных выбросов
    cl = {c["site_id"] for c in clipped}
    c = cio.Corpus(str(hg))
    qerr = max(float(np.abs(c.h400(i, np.float64) - res[s["site_id"]][1]).max()) for i, s in enumerate(keep) if s["site_id"] not in cl)
    c.close()
    assert qerr <= cio.SCALE_M / 2 + 1e-9, qerr
    kept_ids = {x["site_id"] for x in keep} | {g_["site_id"] for g_ in game}
    size = lambda d: sum(f.stat().st_size for f in Path(d).rglob("*") if f.is_file())
    qn = lambda rows: PH.q([res[s["site_id"]][2]["relief_m"] for s in rows])
    # сравнение с hg_v1: состав
    old = json.loads((HERE / "out/split_summary.json").read_text()) if (HERE / "out/split_summary.json").exists() else {}
    old_ex = {e["site_id"] for e in json.loads((HERE / "out/excluded.json").read_text())} if (HERE / "out/excluded.json").exists() else set()
    new_ex = {e["site_id"] for e in excluded}
    old_hold = {s["site_id"] for s in old.get("holdout_sites", [])}
    comp = dict(excluded_v1=len(old_ex), excluded_v2=len(new_ex), newly_excluded=sorted(new_ex - old_ex), newly_included=sorted(old_ex - new_ex),
                holdout_v1=sorted(old_hold), holdout_v2=sorted(s["site_id"] for s in hold), holdout_same=sorted(old_hold) == sorted(s["site_id"] for s in hold))
    split_summary = dict(
        n_catalog=len(sites), n_excluded=len(excluded), n_sites=len(keep), n_train=len(train), n_holdout=len(hold) + len(near),
        n_holdout_regional=len(hold), n_near_game=len(near), split_seed=SP.SPLIT_SEED, sep_km=SP.SEP_KM, near_game_km=SP.NEAR_GAME_KM,
        min_dist_holdout_to_train_km=round(mind, 1) if mind else None, holdout_regions=sorted({parts[s["site_id"]][1] for s in hold}),
        holdout_sites=[dict(site_id=s["site_id"], name=s["name"], country=s["country"], region=parts[s["site_id"]][1], lat=s["lat"], lon=s["lon"],
                            relief_m=round(res[s["site_id"]][2]["relief_m"], 1)) for s in hold],
        near_game_sites=near, relief_quantiles_m=dict(train=qn(train), holdout=qn(hold), all=qn(keep)),
        excluded_by_reason={r: sum(1 for e in excluded if any(x.startswith(r) for x in e["reasons"])) for r in ("море", "перепад", "дно", "нет данных")},
        vs_hg_v1=comp)
    (HERE / "out").mkdir(exist_ok=True)
    (HERE / "out/split_summary_v2.json").write_text(json.dumps(split_summary, ensure_ascii=False, indent=1))
    (HERE / "out/excluded_v2.json").write_text(json.dumps(excluded, ensure_ascii=False, indent=1))
    summ = dict(n_places=len(keep), n_game=len(game), corpus_path=str(hg), game_corpus_path=str(gp), corpus_bytes=size(hg), game_corpus_bytes=size(gp),
                g400_vs_hc400_max_abs_m=max(r[3]["g400_vs_hc400_max_abs_m"] for k, r in res.items() if k not in cl and (k in kept_ids)),
                readback_h400_vs_hc400_max_abs_m=qerr, clipped_places=clipped,
                zoom_counts={str(z): sum(1 for r in res.values() if r[3]["z"] == z) for z in sorted({r[3]["z"] for r in res.values()})},
                raw_deleted=False, pack_seconds=round(time.time() - t0, 1), source="Terrain Tiles (Mapzen/AWS Open Data, Terrarium)")
    (HERE / "out/hg_summary_v2.json").write_text(json.dumps(summ, ensure_ascii=False, indent=1))
    # h400 (float64, до квантования) 5+5 мест для сверки с игрой
    np.savez_compressed(dd / "hc400_all.npz", **{k: r[1] for k, r in res.items()})
    print(json.dumps(dict(split_summary, holdout_sites=None, vs_hg_v1=comp), ensure_ascii=False))
    print(json.dumps(summ, ensure_ascii=False))


def cmd_clean(a):
    dd = data_dir(a)
    freed = 0
    for sub in ("raw", "tmp", "work", "tiles"):
        p = dd / sub
        if p.exists():
            freed += sum(f.stat().st_size for f in p.rglob("*") if f.is_file())
            shutil.rmtree(p)
    sp = HERE / "out/hg_summary_v2.json"
    s = json.loads(sp.read_text())
    s["raw_deleted"], s["raw_freed_mb"] = True, freed // 10**6
    sp.write_text(json.dumps(s, ensure_ascii=False, indent=1))
    print("удалено ~", freed // 10**6, "МБ")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["plan", "fetch", "pack", "clean"])
    ap.add_argument("--data"); ap.add_argument("--out")
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--throttle", type=float, default=0.02)
    a = ap.parse_args()
    {"plan": cmd_plan, "fetch": cmd_fetch, "pack": cmd_pack, "clean": cmd_clean}[a.cmd](a)
