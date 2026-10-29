#!/usr/bin/env python3
"""RW-6u: сравнение поля крейта (сырьё stab_run, f32) с запечённым эталоном по классам клеток W8 v2.

  compare.py <каталог_сырья/base/loc__site> <эталон.json> [--label имя]
Допуски v2 (docs/contracts/rust-wind/fixtures-tolerances.md): mech |Δ| <= 1 % |U_loc| + 0,01;
conv <= 1e-3*u0 + полкванта f16; nonconv <= 15 % |U_loc|; θ' во всех классах 0,05 К + полкванта.
Класс: mech — клетка замороженной колонны (маска с нагревом для u, v, w_conv, θ'; без нагрева — для w_mech);
иначе nonconv, если решение (с нагревом; для w_mech — без нагрева) не сошлось у крейта или у эталона
(AllFrozen считается сошедшимся), иначе conv. Колонна окна — колонна области, её содержащая.
Печатает JSON: по уровню и классу, по каналам — max |Δ|, rms, n, n вне допуска.
"""
import json, subprocess, sys
import numpy as np

CH = ["u", "v", "w_mech", "w_conv", "theta"]


def half_ulp(x):
    if x == 0:
        return 0.0
    e = max(np.floor(np.log2(abs(x))), -14.0)
    return 0.5 * 2.0 ** (e - 10.0)


def load_ref(jpath):
    h = json.load(open(jpath))
    raw = subprocess.run(["zstd", "-dc", jpath[:-5] + ".bin"], capture_output=True, check=True).stdout
    out = []
    for lv in h["levels"]:
        g = lv["grid"]
        n = g["nx"] * g["ny"] * g["nz"]
        ch = {}
        for nm, key in zip(CH, ["u", "v", "w_mech", "w_conv", "theta"]):
            off, nbytes, ty = lv["arrays"][key]
            cnt = nbytes // 2  # второе число — длина в байтах
            assert cnt == n and ty == "f16", (key, cnt, n, ty)
            ch[nm] = np.frombuffer(raw, dtype="<f2", count=cnt, offset=off).astype(np.float64)
        out.append((lv, ch))
    return h, out


def main():
    d, jpath = sys.argv[1], sys.argv[2]
    label = sys.argv[sys.argv.index("--label") + 1] if "--label" in sys.argv else jpath
    meta = json.load(open(f"{d}/meta.json"))
    masks = np.frombuffer(open(f"{d}/masks.bin", "rb").read(), dtype=np.uint8)
    h, refs = load_ref(jpath)
    area = meta["levels"][-1]
    ncol = area["nx"] * area["ny"]
    fm_heat, fm_mech = masks[:ncol], masks[ncol:2 * ncol]
    res = {"label": label, "levels": []}
    for li, ml in enumerate(meta["levels"]):
        lv, ref = refs[li]
        g = lv["grid"]
        nx, ny, nz = g["nx"], g["ny"], g["nz"]
        plane = nx * ny
        raw = np.fromfile(f"{d}/{ml['name']}.f32", dtype="<f4").reshape(5, -1).astype(np.float64)
        assert raw.shape[1] == nx * ny * nz
        cr = dict(zip(CH, raw))
        u_loc = np.hypot(ref["u"], ref["v"])
        u0 = u_loc.max()
        # колонна области для каждой клетки плоскости
        j, i = np.divmod(np.arange(plane), nx)
        x = g["x0"] + (i + 0.5) * g["dx"]
        y = g["y0"] + (j + 0.5) * g["dx"]
        ia = np.clip(np.floor((x - area["x0"]) / area["dx"]).astype(int), 0, area["nx"] - 1)
        ja = np.clip(np.floor((y - area["y0"]) / area["dx"]).astype(int), 0, area["ny"] - 1)
        col = np.tile(ja * area["nx"] + ia, nz)
        # статус решений: крейт (meta.levels[].stop = [mech, heat]) и эталон (meta.solver)
        ok = lambda s: s in ("Converged", "AllFrozen", "converged")
        sol = lv["meta"].get("solver")
        conv = {}
        for sk, si in (("mech", 0), ("heat", 1)):
            c_ok = ok(ml["stop"][si])
            r_ok = ok(sol[sk]["stop"]) if sol else True
            conv[sk] = c_ok and r_ok
        lvres = {"name": ml["name"], "u0": u0, "crate_stop": ml["stop"], "ref_solver": sol, "classes": {}}
        for cn in CH:
            heat_ch = cn != "w_mech"
            frozen = (fm_heat if heat_ch else fm_mech)[col] != 0
            nonconv = (not conv["heat"]) if heat_ch else (not conv["mech"])
            cls = np.where(frozen, "mech", "nonconv" if nonconv else "conv")
            d_ = np.abs(cr[cn] - ref[cn])
            q = half_ulp(np.abs(ref[cn]).max())
            if cn == "theta":
                tol = np.full_like(d_, 0.05 + q)
            else:
                v1 = 1e-3 * u0 + q
                tol = np.where(cls == "mech", 0.01 * u_loc + 0.01, np.where(cls == "nonconv", 0.15 * u_loc, v1))
            for c in ("mech", "conv", "nonconv"):
                m = cls == c
                n = int(m.sum())
                e = lvres["classes"].setdefault(c, {})
                e[cn] = {
                    "n": n,
                    "max": float(d_[m].max()) if n else 0.0,
                    "rms": float(np.sqrt((d_[m] ** 2).mean())) if n else 0.0,
                    "n_over": int((d_[m] > tol[m]).sum()),
                    "frac_over": float((d_[m] > tol[m]).mean()) if n else 0.0,
                }
        res["levels"].append(lvres)
    print(json.dumps(res, indent=1))


main()
