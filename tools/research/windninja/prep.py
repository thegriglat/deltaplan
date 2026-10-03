"""Подготовка: выбор случаев, DEM для WindNinja (ASC в UTM + prj), эталонные поля решателя на 60 м.
Запуск: .venv/bin/python prep.py   (из tools/research/windninja, python — venv air_nn_pilot)"""
import json, subprocess
import numpy as np
from common import *
from pilotnn.data import Dataset, read_p6_index, solution_info
import places

WORK.mkdir(exist_ok=True); OUT.mkdir(exist_ok=True)
(WORK / "dem").mkdir(exist_ok=True)


def utm(lat, lon):
    zone = int((lon + 180) // 6) + 1
    epsg = (32600 if lat >= 0 else 32700) + zone
    r = subprocess.run([str(ENV / "bin/gdaltransform"), "-s_srs", "EPSG:4326", "-t_srs", f"EPSG:{epsg}"],
                       input=f"{lon} {lat}\n", capture_output=True, text=True, env=wn_env())
    e, n, _ = map(float, r.stdout.split())
    wkt = subprocess.run([str(ENV / "bin/gdalsrsinfo"), "-o", "wkt_esri", f"EPSG:{epsg}"], capture_output=True,
                         text=True, env=wn_env()).stdout.strip()
    return epsg, e, n, wkt


def write_asc(path, a, cell, xll, yll, wkt):
    """a[j (север), i (восток)] → ASC (строки сверху вниз) + prj."""
    with open(path, "w") as f:
        f.write(f"ncols {a.shape[1]}\nnrows {a.shape[0]}\nxllcorner {xll:.3f}\nyllcorner {yll:.3f}\n"
                f"cellsize {cell}\nNODATA_value -9999\n")
        np.savetxt(f, a[::-1], fmt="%.2f")
    Path(path).with_suffix(".prj").write_text(wkt + "\n")


def pick(rows, n):
    """n сошедшихся (m) случаев U10 4–8 с разбросом направлений: по 8 секторам, жадно, по возрастанию id."""
    ok = [r for r in rows if 4.0 <= r["U10"] <= 8.0 and solution_info(r, "d400_m")["converged"]]
    out, used = [], set()
    for r in sorted(ok, key=lambda r: (r["U10"] < 5, r["id"])):
        s = int(((r["wdir"] + 22.5) % 360) // 45)
        if s % 2 == len(out) % 2 and s in used:
            continue
        if s in used:
            continue
        out.append(r); used.add(s)
        if len(out) == n:
            break
    return out


def main():
    dm, dt = Dataset(DS_MAIN), Dataset(DS_TERR)
    idx = read_p6_index(P6_INDEX)
    cases, plc = [], {}
    for loc in PLACES:
        d = dm if not loc.startswith("t_") else dt
        rows = [r for r in d.case_rows() if r["loc"] == loc]
        sel = pick(rows, N_PER_PLACE)
        L = places.location(loc)
        lat, lon = L.meta["center_lat"], L.meta["center_lon"]
        epsg, E0, N0, wkt = utm(lat, lon)
        h25 = np.asarray(L.h, np.float64)                       # 1601², центр (800,800), j — север
        h = h25[32:32 + 1536, 32:32 + 1536]                    # 38,4 км = область d400 96×96
        hc400 = h.reshape(96, 16, 96, 16).mean((1, 3))
        h100 = h.reshape(384, 4, 384, 4).mean((1, 3))
        h50 = h.reshape(768, 2, 768, 2).mean((1, 3))
        half = 19200.0
        for tag, a, cell in (("d400", hc400, 400), ("d100", h100, 100), ("d50", h50, 50)):
            write_asc(WORK / "dem" / f"{loc}_{tag}.asc", a, cell, E0 - half, N0 - half, wkt)
        plc[loc] = dict(lat=lat, lon=lon, epsg=epsg, E0=E0, N0=N0, relief_m=float(hc400.max() - hc400.min()),
                        system=idx[loc]["system"] if loc in idx else "builtin")
        for r in sel:
            z = d.load(r["id"])
            hcz = z["d400_hc"].astype(float)
            dd = float(np.abs(hcz - hc400).max())
            assert dd < 1.0, (loc, dd)
            f = {k: z[k].astype(np.float32) for k in ("d400_m",)}
            u, v = f["d400_m"][0], f["d400_m"][1]                # (13, 96, 96); agl 25,50,75,...
            ref = {}
            for a in (10.0, 20.0, 40.0, 60.0, 100.0, 150.0, 200.0):
                agl = np.array(d.agl); k = int(np.searchsorted(agl, a)); 
                if a <= agl[0]:
                    w = 1.0; k0 = 0; k1 = 0
                else:
                    k0, k1 = k - 1, k; w = (agl[k1] - a) / (agl[k1] - agl[k0])
                ref[f"u{int(a)}"] = w * u[k0] + (1 - w) * u[k1]
                ref[f"v{int(a)}"] = w * v[k0] + (1 - w) * v[k1]
            np.savez_compressed(OUT / f"ref_{r['id']}.npz", hc=hcz, **ref)
            cases.append(dict(id=r["id"], loc=loc, U10=r["U10"], wdir=r["wdir"], hour=r["hour"],
                              t_solver_m=r["runs"]["d400_m"].get("t_solve")))
    json.dump(dict(places=plc, cases=cases, agl=list(dm.agl)), open(OUT / "cases.json", "w"), indent=1, ensure_ascii=False)
    print(len(cases), "случаев;", {l: [c["wdir"] for c in cases if c["loc"] == l] for l in PLACES})


main()
