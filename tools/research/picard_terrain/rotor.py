"""PT-5: ротор Perdigao (NE, SW) и мачты по полям R4 вариантов Пикара. Один запуск -> out/PT-5/{rows.jsonl, rotor.json, table.md}.

  tools/research/sw_charges_3d/py tools/research/picard_terrain/rotor.py

Критерий ротора - SWD5 v7 (docs/contracts/sw-charges-3d.md; образец compare/core.py rotor_scan, повторён): u|| < -0,5 м/с на z_agl 15 м вдоль
разреза (шаг 10 м), самый длинный участок > 50 м; глубина - max z_agl (шаг 15 м) области, связной с этим участком. u|| = (u, v) . e_ветра * u_scale,
u_scale = U_ref.S / S_модели в опорной точке pt.U_ref (tse13 / tse04, 100 м). Разрезы - menke_T1..3 из sw_charges_3d/out/refs/points.json (SWD1).
Выборка поля - sample.py (PT5): колонны над рельефом подсетки PT1, билинейно по 4 колоннам, линейно по z_agl; z_agl берётся от растра PT1.
Мачты: RMSE s_norm = (S/S_ref)_модель - s_norm_данные по строкам role mast SWD1 на z_agl >= 30 м.
"""
from __future__ import annotations

import glob
import json
import math
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE))
import sample as SM  # noqa: E402

OUT = HERE / "out" / "PT-5"
POINTS = ROOT / "tools/research/sw_charges_3d/out/refs/points.json"
MENKE = ROOT / "tools/research/data/perdigao/menke2019/fig8_zones_approx.csv"
D = SM.data_dir()
SITES = {"perdigao_ne": ("PERD_NE", "NE"), "perdigao_sw": ("PERD_SW", "SW")}
TRANSECTS = ("menke_T1", "menke_T2", "menke_T3")
ZS = np.arange(15.0, 601.0, 15.0)
PAST = {"perdigao_ne": [430, 170, 0], "perdigao_sw": [0, 0, 0]}    # прошлый Пикар (cases/README.md, refs/tables.md), справка


class Field:
    """Поле R4 с выборкой по правилу PT5 в произвольных (x, y, z_agl)."""

    def __init__(self, case_json, state_json):
        self.meta, self.sm, mask, uc, vc, wc = SM.load_centers(case_json, state_json)
        t = self.meta["pt"]["terrain"]
        self.raster = SM.Raster(D / t["path"], t["dataset"])
        self.mask, self.uc, self.vc = mask, uc, vc
        self.Sc = np.sqrt(uc ** 2 + vc ** 2)
        self.cache = {}

    def col(self, ii, jj):
        key = (ii, jj)
        if key not in self.cache:
            za, fl = SM.column_profiles(self.meta, self.raster, self.mask, [self.Sc, self.uc, self.vc], ii, jj)
            self.cache[key] = (za, fl)
        return self.cache[key]

    def at(self, x, y, z_agl):
        """-> S, u, v в точке (x, y) на массиве z_agl (форма (nz,))."""
        m = self.meta
        nx, ny = m["dims"][0], m["dims"][1]
        dx = m["dx"]
        fi = np.clip((x - m["x0"]) / dx + 0.5, 1.0, nx - 2 + 1e-9)
        fj = np.clip((y - m["y0"]) / dx + 0.5, 1.0, ny - 2 + 1e-9)
        i0, j0 = min(int(np.floor(fi)), nx - 3), min(int(np.floor(fj)), ny - 3)
        a, b = fi - i0, fj - j0
        acc = np.zeros((3, len(z_agl)))
        for dj, wj in ((0, 1 - b), (1, b)):
            for di, wi in ((0, 1 - a), (1, a)):
                za, fl = self.col(i0 + di, j0 + dj)
                for q in range(3):
                    acc[q] += wj * wi * np.interp(z_agl, za, fl[q])
        return acc


def rotor_scan(F, tr, ex, ey, u_scale):
    L = math.hypot(tr["x1"] - tr["x0"], tr["y1"] - tr["y0"])
    n = int(L // 10) + 1
    s = np.linspace(0, L, n)
    X = tr["x0"] + (tr["x1"] - tr["x0"]) * s / L
    Y = tr["y0"] + (tr["y1"] - tr["y0"]) * s / L
    upar = np.empty((len(ZS), n))
    for i in range(n):
        _, u, v = F.at(X[i], Y[i], ZS)
        upar[:, i] = (u * ex + v * ey) * u_scale
    bad = np.isfinite(upar) & (upar < -0.5)
    row0 = bad[0]
    best, bi, i = 0.0, None, 0
    while i < n:
        if row0[i]:
            j = i
            while j + 1 < n and row0[j + 1]:
                j += 1
            ln = (j - i + 1) * 10.0
            if ln > 50.0 and ln > best:
                best, bi = ln, (i, j)
            i = j + 1
        else:
            i += 1
    extra = dict(min_upar_15=float(upar[0].min()), x_start_s=None)
    if bi is None:
        return dict(present=False, L_m=0.0, depth_m=0.0, **extra)
    cols = np.zeros(n, bool)
    cols[bi[0]:bi[1] + 1] = True
    depth = 15.0
    for k in range(1, len(ZS)):
        if not (bad[k] & cols).any():
            break
        depth = ZS[k]
    extra["x_start_s"] = float(s[bi[0]])        # м от начала разреза (против ветра)
    return dict(present=True, L_m=float(best), depth_m=float(depth), **extra)


def sample_probes(F):
    out = {}
    for p in F.meta["pt"]["probes"]:
        S, _, _ = F.at(p["x"], p["y"], np.array([p["z_agl"]]))
        out[p["name"]] = float(S[0])
    return out


def source_rows():
    """state -> строка задачи-источника (PT-1..PT-4)."""
    m = {}
    for f in sorted(glob.glob(str(HERE / "out/PT-[1-4]/rows*.jsonl")) + [str(OUT / "src_pt4_combo.jsonl")]):
        for line in open(f):
            if line.strip():
                r = json.loads(line)
                if r["state"] and r["site"].startswith("perdigao"):
                    m[r["state"]] = r
    return m


def main():
    pts = json.loads(POINTS.read_text())
    trs = {(t["case"], t["name"]): t for t in pts["transects"]}
    data_s = {}
    for r in pts["rows"]:
        if r["ref_kind"] == "mast" and r["z_agl"] >= 30:
            data_s[(r["case"], f"{r['name']}_{int(r['z_agl'])}")] = r["s_norm"]
    menke = {}
    for line in open(MENKE).read().splitlines()[1:]:
        c = line.split(",")
        menke.setdefault(c[2], {})[int(c[1])] = float(c[5])
    src = source_rows()
    states = sorted(glob.glob(str(D / "states/perdigao_*_d30_*.json")))
    rows, res = [], []
    for sj in states:
        st = Path(sj).relative_to(D).as_posix()
        if st not in src:
            print("нет строки-источника для", st, "- пропуск", file=sys.stderr)
            continue
        s0 = src[st]
        site = s0["site"]
        swd, mdir = SITES[site]
        sm = json.loads(Path(sj).read_text())
        cj = Path(sm["input"]).name if Path(sm["input"]).exists() else Path(sm["input"]).name
        case_json = D / "cases" / cj
        F = Field(case_json, sj)
        pt = F.meta["pt"]
        wd = math.radians(pt["wdir_deg"])
        ex, ey = -math.sin(wd), -math.cos(wd)
        ref = pt["U_ref"]
        Sp = sample_probes(F)
        s_ref_model = Sp[f"{ref['mast']}_{int(ref['z_agl'])}"]
        u_scale = ref["S"] / s_ref_model
        rot = []
        for tn in TRANSECTS:
            r = rotor_scan(F, trs[(swd, tn)], ex, ey, u_scale)
            rot.append(dict(transect=tn, **r))
        errs = []
        for nm, S in Sp.items():
            if (swd, nm) in data_s:
                errs.append(S / s_ref_model - data_s[(swd, nm)])
        rmse = float(np.sqrt(np.mean(np.square(errs))))
        bias = float(np.mean(errs))
        row = {k: s0[k] for k in ("format", "version", "task", "case", "site", "dx", "solver", "dtype", "cut_cells", "adv2", "limiter",
                                  "status", "iters", "max_iters", "final", "time", "r2", "state")}
        row["task"] = "PT-5"
        row["probes"] = []
        row["rotor"] = [{k: t[k] for k in ("transect", "present", "L_m", "depth_m")} for t in rot]
        row["masts_rmse"] = rmse
        row["note"] = (f"источник {s0['task']}; u_scale {u_scale:.4f}; мачт {len(errs)}, bias s_norm {bias:+.3f}"
                       + ("; справочно (air3d f64, 1-й порядок)" if s0["solver"] == "air3d" else ""))
        rows.append(row)
        res.append(dict(state=st, site=site, rows=rot, masts_rmse=rmse, masts_bias=bias, n_masts=len(errs), u_scale=u_scale,
                        s_ref_model=s_ref_model, variant=variant_name(s0)))
        print(st, [(t["transect"], t["L_m"], t["depth_m"]) for t in rot], f"rmse {rmse:.3f}", flush=True)
    OUT.mkdir(parents=True, exist_ok=True)
    with open(OUT / "rows.jsonl", "w") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    (OUT / "rotor.json").write_text(json.dumps(dict(menke=menke, past_picard=PAST, results=res), ensure_ascii=False, indent=1))
    write_table(res, menke)


def variant_name(r):
    if r["solver"] == "air3d":
        return "air3d (справ.)"
    v = []
    if r["cut_cells"]:
        v.append("cut")
    if r["adv2"]:
        v.append({1: "van Leer", 3: "minmod"}.get(r["limiter"], f"lim{r['limiter']}"))
    return "+".join(v) if v else "база"


ORDER = ["база", "cut", "van Leer", "minmod", "cut+van Leer", "cut+minmod", "air3d (справ.)"]


def write_table(res, menke):
    lines = ["# PT-5: ротор Perdigão и мачты по вариантам Пикара", "",
             "Критерий SWD5 v7: u∥ < −0,5 м/с на z_agl 15 м, участок > 50 м (шаг 10 м); разрезы menke_T1..3 (SWD1, условная нумерация — сравнивать средние, не попарно); "
             "глубина — max z_agl связной области (шаг 15 м). RMSE — s_norm по мачтам SWD1, z_agl ≥ 30 м (bias — среднее модель − данные). Menke 2019: L по трём разрезам ±50 м.", ""]
    for site, (_, md) in SITES.items():
        mk = [menke[md][k] for k in (1, 2, 3)]
        lines += [f"## {site.split('_')[1].upper()} (Menke: {', '.join(f'{x:.0f}' for x in mk)} м, среднее {np.mean(mk):.0f} м, глубина ~157 м)", "",
                  "| вариант | ротор (разрезов из 3) | L T1/T2/T3, м | L среднее, м | depth T1/T2/T3, м | L ср. / Menke | RMSE s_norm | bias |",
                  "|---|---|---|---|---|---|---|---|"]
        rr = sorted([r for r in res if r["site"] == site], key=lambda r: ORDER.index(r["variant"]) if r["variant"] in ORDER else 99)
        for r in rr:
            L = [t["L_m"] for t in r["rows"]]
            d = [t["depth_m"] for t in r["rows"]]
            n = sum(t["present"] for t in r["rows"])
            lines.append(f"| {r['variant']} | {n}/3 | {' / '.join(f'{x:.0f}' for x in L)} | {np.mean(L):.0f} | {' / '.join(f'{x:.0f}' for x in d)} "
                         f"| {np.mean(L) / np.mean(mk):.2f} | {r['masts_rmse']:.3f} | {r['masts_bias']:+.3f} |")
        p = PAST[site]
        lines += [f"| прошлый Пикар (справка) | — | {' / '.join(str(x) for x in p)} | {np.mean(p):.0f} | — | {np.mean(p) / np.mean(mk):.2f} | — | — |", ""]
    (OUT / "table.md").write_text("\n".join(lines))


if __name__ == "__main__":
    main()
