#!/usr/bin/env python3
"""SY-10: рельеф мест дельтаплана (каталог S6) -> корпус S1 v4 `real/hg_v1`, места игры -> `real/game_hg`.

Квадрат места строится КАК В ИГРЕ (scripts/terrain/terrarium_loader.gd + scripts/atmosphere/air_model/air_place.gd), а не как в
SY-6 (там — билинейная передискретизация на 25 м и точные клетки 400 м):
  центр области = координата старта (build_location(lat, lon) строит слой вокруг неё); слой Terrarium z (layer_zoom: z12, ниже на
  широтах, где шаг < 18 м), узлы = пиксели web-mercator (шаг s = 2πR·cos(φ)/(256·2^z), без сглаживания, без передискретизации);
  клетка решателя = блочное среднее f × f узлов, f = round(400/s) (AirPlace.block_mean), область 96 × 96 клеток от x0 = y0 = −19 200 м
  (узел i0 = round((x0 − origin_x)/s)). Клетка поэтому f·s м (≈ 380–420 м), а не 400 — игра подаёт решателю dx = 400 как есть;
  обучающий набор делает то же. h100 (384 × 384, нужен контракту S1) — точное площадное перебинирование тех же узлов на 4 × 4
  подъячеек клетки (блочное среднее h100 4 × 4 = h400 игры до квантования).
Команды: plan | fetch | pack | clean  (--data КАТАЛОГ, по умолчанию ~/sy10_data; сырьё — raw/terrarium/z/x/y.png)."""
import argparse, hashlib, json, math, os, shutil, sys, time
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

TILE = 256
DX, N, X0 = 400.0, 96, -19200.0
SITES = HERE.parent / "hg_sites/sites.json"
YAML = HERE.parent / "real/terrain_real.yaml"
SEA_MAX, RELIEF_MAX, HMIN_MAX = 0.05, 3000.0, 3000.0     # пороги П6 (terrain_real.yaml: sea_max, relief_max_m, hmin_max_m)
GAME = ["askarovo", "aushkul", "altai", "ongudai"]


def roundi(x):   # Godot roundi: половина — от нуля
    return int(math.floor(x + 0.5)) if x >= 0 else -int(math.floor(-x + 0.5))


def data_dir(a):
    return Path(a.data or os.environ.get("SY10_DATA") or os.path.expanduser("~/sy10_data"))


def layer_cfg():
    rt = json.loads((ROOT / "configs/world.json").read_text())["runtime_terrain"]
    return rt, next(l for l in rt["layers"] if l["id"] == "detail")


def geometry(lat, lon):
    """Геометрия квадрата как в игре -> dict (z, s, f, окно узлов, список тайлов)."""
    import terrain_cut as TC
    _, lc = layer_cfg()
    z = TC.layer_zoom(lc, lat)
    pl = TC.plan_layer(lat, lon, z, float(lc["size_km"]) * 1000.0, int(lc["chunk_cells"]))
    s, n, (ox, oz) = pl["spacing"], pl["n"], pl["origin"]
    f = roundi(DX / s)
    i0 = roundi((X0 - ox) / s)
    yl = -(oz + (n - 1) * s)
    j0 = roundi((X0 - yl) / s)
    L = f * N
    # игра на 5 из 367 точек (широты 50,7–51,0° и −33,7°, f·s > 400 м) не нашла бы область в слое 40 км: AirPlace.block_mean -> «область вне
    # слоя», пустой случай. Для набора окно сдвигается внутрь слоя (≤ 7 узлов ≈ 170 м), флаг clamped_px в out/geometry.json.
    clamped = max(i0 + L - n, j0 + L - n, 0)
    i0, j0 = min(i0, n - L), min(j0, n - L)
    assert i0 >= 0 and j0 >= 0, ("слой меньше области", lat, lon, n, L)
    px0 = pl["t0"][0] * TILE + pl["crop"][0]            # абсолютный пиксель узла (0, 0)
    py0 = pl["t0"][1] * TILE + pl["crop"][1]
    c0, c1 = px0 + i0, px0 + i0 + L                     # столбцы окна [c0, c1)
    r0, r1 = py0 + (n - j0 - L), py0 + (n - j0)         # строки окна [r0, r1) (с севера)
    tiles = [(z, tx, ty) for ty in range(r0 // TILE, (r1 - 1) // TILE + 1) for tx in range(c0 // TILE, (c1 - 1) // TILE + 1)]
    return dict(clamped_px=int(clamped), z=z, s=s, f=f, cell_m=f * s, i0=i0, j0=j0, L=L, n_layer=n, c0=c0, c1=c1, r0=r0, r1=r1, tiles=tiles,
                window_km=L * s / 1000.0, center_offset_m=(i0 * s + ox + L * s / 2.0))


def tile_file(raw, z, x, y):
    return raw / "terrarium" / str(z) / str(x % (1 << z)) / f"{min(max(y, 0), (1 << z) - 1)}.png"


def window(raw, g):
    """Окно узлов (L × L, float32), строки с юга (j = 0 — южный), столбцы с запада."""
    import terrain_cut as TC
    L = g["L"]
    mos = np.empty((L, L), np.float32)
    for z, tx, ty in g["tiles"]:
        t = TC.decode_png(tile_file(raw, z, tx, ty))
        a0, b0 = tx * TILE, ty * TILE
        xs, xe = max(a0, g["c0"]), min(a0 + TILE, g["c1"])
        ys, ye = max(b0, g["r0"]), min(b0 + TILE, g["r1"])
        mos[ys - g["r0"]:ye - g["r0"], xs - g["c0"]:xe - g["c0"]] = t[ys - b0:ye - b0, xs - a0:xe - a0]
    return mos[::-1]


def rebin_matrix(L, f, n_out=384):
    """Площадное перебинирование L узлов в n_out подъячеек (ширина L/n_out узлов): (n_out, L), строки — доли узлов."""
    w = L / n_out
    a = np.arange(n_out)[:, None] * w
    b = a + w
    p = np.arange(L)[None, :]
    return np.clip(np.minimum(p + 1, b) - np.maximum(p, a), 0, None) / w


def build_relief(A, f):
    """A (L × L, юг сверху) -> (z100 float64 (384, 384), hc400 float64 (96, 96) — блочное среднее f × f, как AirPlace.block_mean)."""
    A = A.astype(np.float64)
    L = A.shape[0]
    hc = A.reshape(N, f, N, f).mean(axis=(1, 3))
    M = rebin_matrix(L, f)
    z100 = M @ A @ M.T
    return z100, hc


def features(A, hc):
    gy, gx = np.gradient(hc, DX)
    sl = np.hypot(gx, gy)[1:-1, 1:-1]
    return dict(h_min=float(hc.min()), h_max=float(hc.max()), relief_m=float(hc.max() - hc.min()),
                sea_frac=float((A <= 0.5).mean()), slope_p50=float(np.percentile(sl, 50)), slope_p95=float(np.percentile(sl, 95)))


def _one(args):
    raw, key, lat, lon = args
    g = geometry(lat, lon)
    A = window(Path(raw), g)
    z100, hc = build_relief(A, g["f"])
    ft = features(A, hc)
    ft["sha256"] = hashlib.sha256(np.ascontiguousarray(A).tobytes()).hexdigest()
    ft["nan"] = int(np.isnan(A).sum())
    return key, z100, ft, {k: g[k] for k in ("z", "s", "f", "cell_m", "window_km", "i0", "j0", "clamped_px", "center_offset_m")}


def places():
    sites = json.loads(SITES.read_text())
    game = []
    for n in GAME:
        loc = json.loads((ROOT / f"configs/locations/{n}.json").read_text())
        game.append(dict(site_id=n, lat=loc["center_lat"], lon=loc["center_lon"], country="game", name=n))
    return sites, game


def cmd_plan(a):
    sites, game = places()
    tiles = set()
    for s in sites + game:
        for z, x, y in geometry(s["lat"], s["lon"])["tiles"]:
            tiles.add((z, x % (1 << z), min(max(y, 0), (1 << z) - 1)))
    dd = data_dir(a)
    dd.mkdir(parents=True, exist_ok=True)
    json.dump(sorted(tiles), open(dd / "tiles.json", "w"))
    print(len(sites) + len(game), "мест,", len(tiles), "тайлов")


def cmd_fetch(a):
    import terrain_cut as TC
    dd = data_dir(a)
    tiles = [tuple(t) for t in json.loads((dd / "tiles.json").read_text())]
    ctx = TC.Ctx(YAML, str(dd))               # raw = dd/raw
    ctx.cfg["source"]["workers"] = min(8, int(ctx.cfg["source"]["workers"]))   # как игра: max_parallel_requests 8
    TC.setup_log(ctx, "sy10_fetch") if hasattr(TC, "setup_log") else None
    n, nb, missing = TC.fetch_tiles(ctx, tiles, throttle=a.throttle)
    json.dump(dict(requested=len(tiles), downloaded=n, bytes=nb, missing=[(list(t), e) for t, e in missing]), open(dd / "fetch.json", "w"))
    print("скачано", n, nb // 10**6, "МБ, нет данных:", len(missing))


def region_stat(sites, parts):
    out = {}
    for s in sites:
        p = parts[s["site_id"]]
        out.setdefault(p[0], {}).setdefault(p[1], 0)
        out[p[0]][p[1]] += 1
    return out


def q(a):
    return {f"p{p}": round(float(np.percentile(a, p)), 1) for p in (0, 10, 25, 50, 75, 90, 100)} if len(a) else {}


def cmd_pack(a):
    t0 = time.time()
    dd = data_dir(a)
    raw = dd / "raw"
    sites, game = places()
    out_root = Path(a.out or os.environ.get("AIR_SYNTH_DATA") or os.path.expanduser("~/air_synth_data")) / "real"
    jobs = [(str(raw), s["site_id"], s["lat"], s["lon"]) for s in sites + game]
    with ProcessPoolExecutor(a.workers) as ex:
        res = {k: (z, ft, g) for k, z, ft, g in ex.map(_one, jobs, chunksize=4)}
    # --- исключения (пороги П6)
    keep, excluded = [], []
    for s in sites:
        ft = res[s["site_id"]][1]
        why = []
        if ft["nan"]:
            why.append("нет данных (NaN)")
        if ft["sea_frac"] > SEA_MAX:
            why.append(f"море: доля узлов ≤ 0,5 м {ft['sea_frac']:.3f} > {SEA_MAX}")
        if ft["relief_m"] > RELIEF_MAX:
            why.append(f"перепад {ft['relief_m']:.0f} м > {RELIEF_MAX:.0f}")
        if ft["h_min"] > HMIN_MAX:
            why.append(f"дно {ft['h_min']:.0f} м > {HMIN_MAX:.0f}")
        (excluded.append(dict(site_id=s["site_id"], name=s["name"], country=s["country"], lat=s["lat"], lon=s["lon"], reasons=why,
                              relief_m=round(ft["relief_m"], 1), sea_frac=round(ft["sea_frac"], 4))) if why else keep.append(s))
    parts = SP.split(keep)
    near = [k for k, v in parts.items() if v[1] == "near_game"]
    hold = [s for s in keep if parts[s["site_id"]][0] == "holdout" and parts[s["site_id"]][1] != "near_game"]
    train = [s for s in keep if parts[s["site_id"]][0] == "train"]
    mind = min((SP.dist_km(h["lat"], h["lon"], t["lat"], t["lon"]) for h in hold for t in train), default=None)
    # --- запись S1 v4
    def place(s, part, stratum, key):
        z, ft, g = res[key]
        return dict(name=s["site_id"][:16], lat_deg=float(s["lat"]), lon_deg=float(s["lon"]), system=s["country"], part=part,
                    stratum=stratum[:32], source=f"terrarium z{g['z']}", zoom=g["z"], src_spacing_m=g["s"], source_sha256=ft["sha256"])
    rel, geo = [], {}
    import subprocess
    gc = subprocess.run(["git", "-C", str(HERE), "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
    for s in keep:   # порядок id — по site_id
        part, stratum = parts[s["site_id"]]
        rel.append(dict(z100=res[s["site_id"]][0], place=place(s, part, stratum, s["site_id"])))
        geo[s["site_id"]] = res[s["site_id"]][2]
    hg = out_root / "hg_v1"
    shutil.rmtree(hg, ignore_errors=True)
    cio.write_reliefs(str(hg), rel, generator_version="real-hg-v1", corpus_seed=0, command="pack_hg.py pack", git_commit=gc,
                      extra_attrs=dict(contract="S1 v4", train_order="", split_seed=np.uint64(SP.SPLIT_SEED)))
    grel = []
    for g_ in game:
        grel.append(dict(z100=res[g_["site_id"]][0], place=place(g_, "game", "game", g_["site_id"])))
        geo[g_["site_id"]] = res[g_["site_id"]][2]
    gp = out_root / "game_hg"
    shutil.rmtree(gp, ignore_errors=True)
    cio.write_reliefs(str(gp), grel, generator_version="real-game-hg", corpus_seed=0, command="pack_hg.py pack", git_commit=gc)
    # --- сверка записанного с игрой: блочное среднее h100 = hc400 игры
    c = cio.Corpus(str(hg))
    err = max(float(np.abs(c.h400(i, np.float64) - res[s["site_id"]][0].reshape(N, 4, N, 4).mean(axis=(1, 3))).max()) for i, s in enumerate(keep))
    c.close()
    # --- сводки
    size = lambda d: sum(f.stat().st_size for f in Path(d).rglob("*") if f.is_file())
    qn = lambda rows: q([res[s["site_id"]][1]["relief_m"] for s in rows])
    split_summary = dict(
        n_catalog=len(sites), n_excluded=len(excluded), n_sites=len(keep), n_train=len(train), n_holdout=len(hold) + len(near),
        n_holdout_regional=len(hold), n_near_game=len(near), split_seed=SP.SPLIT_SEED, sep_km=SP.SEP_KM, near_game_km=SP.NEAR_GAME_KM,
        min_dist_holdout_to_train_km=round(mind, 1) if mind else None,
        holdout_regions=sorted({parts[s["site_id"]][1] for s in hold}), holdout_countries=sorted({s["country"] for s in hold}),
        train_countries={k: sum(1 for s in train if s["country"] == k) for k in sorted({s["country"] for s in train})},
        train_regions={k: sum(1 for s in train if parts[s["site_id"]][1] == k) for k in sorted({parts[s["site_id"]][1] for s in train})},
        holdout_sites=[dict(site_id=s["site_id"], name=s["name"], country=s["country"], region=parts[s["site_id"]][1], lat=s["lat"], lon=s["lon"],
                            relief_m=round(res[s["site_id"]][1]["relief_m"], 1)) for s in hold],
        near_game_sites=near, relief_quantiles_m=dict(train=qn(train), holdout=qn(hold), all=qn(keep)),
        excluded_by_reason={r: sum(1 for e in excluded if any(x.startswith(r) for x in e["reasons"])) for r in ("море", "перепад", "дно", "нет данных")})
    (HERE / "out").mkdir(exist_ok=True)
    (HERE / "out/split_summary.json").write_text(json.dumps(split_summary, ensure_ascii=False, indent=1))
    (HERE / "out/excluded.json").write_text(json.dumps(excluded, ensure_ascii=False, indent=1))
    (HERE / "out/geometry.json").write_text(json.dumps(geo, indent=1))
    summ = dict(n_places=len(keep), n_game=len(game), corpus_path=str(hg), game_corpus_path=str(gp), corpus_bytes=size(hg), game_corpus_bytes=size(gp),
                h400_vs_game_blockmean_max_abs_m=err, cell_m_quantiles=q([g["cell_m"] for g in geo.values()]),
                f_counts={str(f): sum(1 for g in geo.values() if g["f"] == f) for f in sorted({g["f"] for g in geo.values()})},
                zoom_counts={str(z): sum(1 for g in geo.values() if g["z"] == z) for z in sorted({g["z"] for g in geo.values()})},
                raw_deleted=False, pack_seconds=round(time.time() - t0, 1), source="Terrain Tiles (Mapzen/AWS Open Data, Terrarium)")
    (HERE / "out/hg_summary.json").write_text(json.dumps(summ, ensure_ascii=False, indent=1))
    print(json.dumps(dict(split_summary, holdout_sites=None, train_countries=None, train_regions=None, near_game_sites=near), ensure_ascii=False))
    print(json.dumps(summ, ensure_ascii=False))


def cmd_clean(a):
    dd = data_dir(a)
    freed = 0
    for sub in ("raw", "tmp", "work"):
        p = dd / sub
        if p.exists():
            freed += sum(f.stat().st_size for f in p.rglob("*") if f.is_file())
            shutil.rmtree(p)
    sp = HERE / "out/hg_summary.json"
    s = json.loads(sp.read_text())
    s["raw_deleted"], s["raw_freed_mb"] = True, freed // 10**6
    sp.write_text(json.dumps(s, ensure_ascii=False, indent=1))
    print("удалено ~", freed // 10**6, "МБ")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["plan", "fetch", "pack", "clean"])
    ap.add_argument("--data"); ap.add_argument("--out")
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--throttle", type=float, default=0.02, help="пауза перед запросом тайла, с (вежливо к серверу)")
    a = ap.parse_args()
    {"plan": cmd_plan, "fetch": cmd_fetch, "pack": cmd_pack, "clean": cmd_clean}[a.cmd](a)
