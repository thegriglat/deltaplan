#!/usr/bin/env python3
"""3D-просмотр поля: интерактивный HTML (plotly.js с cdnjs), один файл на случай.

  ../heat_ca/.venv/bin/python export3d.py   → out/3d/*.html

В файле: рельеф поверхностью (25 м для окна, 200 м для области), линии тока с цветом по скорости
(посев у земли ~50 м и на 300 м над землёй), для окна — изоповерхности w = +1 и −0,5 м/с
(полупрозрачные; если поле до них не доходит — уровни 99,5 % и 0,5 % перцентиля, подписаны),
кнопки масштаба высоты ×1/×2/×3/×5.
"""
from __future__ import annotations

import json
import math
from pathlib import Path

import numpy as np

import common as C
import terrain as T
from report import Field

OUT3 = C.OUT / "3d"
OUT3.mkdir(exist_ok=True, parents=True)
CDN = "https://cdnjs.cloudflare.com/ajax/libs/plotly.js/2.34.0/plotly.min.js"


def sampler(fld):
    u, v, w, th = [np.nan_to_num(a) for a in fld.F]
    solid = fld.solid

    def at(p):
        x, y, z = p
        fi = (x - fld.x0) / fld.dx - 0.5
        fj = (y - fld.y0) / fld.dx - 0.5
        fk = (z - fld.z_bot) / fld.dz - 0.5
        if not (0 <= fi < fld.nx - 1 and 0 <= fj < fld.ny - 1 and 0 <= fk < fld.nz - 1):
            return None
        i0, j0, k0 = int(fi), int(fj), int(fk)
        a, b, c = fi - i0, fj - j0, fk - k0
        # под землёй — стоп
        hz = hterr(fld, x, y)
        if z < hz + 2:
            return None
        out = []
        for F in (u, v, w):
            s = 0.0
            for dk in (0, 1):
                for dj in (0, 1):
                    for di in (0, 1):
                        wt = (c if dk else 1 - c) * (b if dj else 1 - b) * (a if di else 1 - a)
                        s += wt * F[k0 + dk, j0 + dj, i0 + di]
            out.append(s)
        return np.array(out)
    return at


def hterr(fld, x, y):
    fi = np.clip((x - fld.x0) / fld.dx - 0.5, 0, fld.nx - 1.001)
    fj = np.clip((y - fld.y0) / fld.dx - 0.5, 0, fld.ny - 1.001)
    i0, j0 = int(fi), int(fj)
    a, b = fi - i0, fj - j0
    h = fld.hc
    return ((1 - b) * ((1 - a) * h[j0, i0] + a * h[j0, i0 + 1]) + b * ((1 - a) * h[j0 + 1, i0] + a * h[j0 + 1, i0 + 1]))


def streamline(at, p0, ds, nmax, vmin=0.05, region=None):
    pts, sp = [p0.copy()], []
    p = p0.copy()
    v0 = at(p)
    if v0 is None:
        return None
    sp.append(float(np.linalg.norm(v0)))
    for _ in range(nmax):
        v1 = at(p)
        if v1 is None:
            break
        n1 = np.linalg.norm(v1)
        if n1 < vmin:
            break
        pm = p + 0.5 * ds * v1 / n1
        v2 = at(pm)
        if v2 is None:
            break
        n2 = np.linalg.norm(v2)
        if n2 < vmin:
            break
        p = p + ds * v2 / n2
        if region is not None and not (region[0] <= p[0] <= region[1] and region[2] <= p[1] <= region[3]):
            break
        pts.append(p.copy())
        sp.append(float(n2))
    if len(pts) < 5:
        return None
    return np.array(pts), np.array(sp)


def seeds(fld, region, n, agl):
    x0, x1, y0, y1 = region
    xs = np.linspace(x0, x1, n + 2)[1:-1]
    ys = np.linspace(y0, y1, n + 2)[1:-1]
    out = []
    for y in ys:
        for x in xs:
            out.append(np.array([x, y, hterr(fld, x, y) + agl]))
    return out


def terrain_surface(region, step_m):
    t = C.ter()
    h, info = t["h"], t["info"]
    x0, x1, y0, y1 = region
    s = info["spacing"]
    i0, i1 = int((x0 - info["x0"]) / s), int((x1 - info["x0"]) / s)
    j0, j1 = int((y0 - info["y0"]) / s), int((y1 - info["y0"]) / s)
    st = max(1, int(round(step_m / s)))
    H = h[j0:j1 + 1:st, i0:i1 + 1:st]
    X = info["x0"] + np.arange(i0, i1 + 1, st) * s
    Y = info["y0"] + np.arange(j0, j1 + 1, st) * s
    return X, Y, H


def r1(a, nd=1):
    return np.round(np.asarray(a, float), nd).tolist()


def build(path_npz, title, out_name, region=None, terrain_step=25.0, nseed=14, iso=True, ds=None, nmax=500):
    fld = Field(path_npz)
    at = sampler(fld)
    if region is None:
        region = (fld.x0 + fld.dx, fld.x0 + (fld.nx - 1) * fld.dx, fld.y0 + fld.dx, fld.y0 + (fld.ny - 1) * fld.dx)
    ds = ds or 0.5 * fld.dx
    traces = []
    X, Y, H = terrain_surface(region, terrain_step)
    traces.append(dict(type="surface", x=r1(X, 0), y=r1(Y, 0), z=r1(H, 0), colorscale="Earth", showscale=False,
                       opacity=1.0, name="рельеф", hoverinfo="skip",
                       lighting=dict(ambient=0.55, diffuse=0.8, roughness=0.9, specular=0.05)))
    vmax = 0.0
    lines = []
    for agl, lab in ((50.0, "у земли (~50 м)"), (300.0, "300 м над землёй")):
        for p0 in seeds(fld, region, nseed, agl):
            r = streamline(at, p0, ds, nmax, region=region)
            if r is None:
                continue
            P, sp = r
            vmax = max(vmax, float(sp.max()))
            lines.append((P, sp, lab))
    first = {}
    for P, sp, lab in lines:
        traces.append(dict(type="scatter3d", mode="lines", x=r1(P[:, 0], 0), y=r1(P[:, 1], 0), z=r1(P[:, 2], 0),
                           line=dict(color=r1(sp, 2), colorscale="Viridis", cmin=0, cmax=round(vmax, 1), width=3,
                                     showscale=lab not in first,
                                     **({"colorbar": dict(title="м/с", x=1.02)} if lab not in first else {})),
                           name=f"линии тока: {lab}", legendgroup=lab, showlegend=lab not in first,
                           hoverinfo="skip"))
        first[lab] = True
    notes = []
    if iso:
        w = np.nan_to_num(fld.F[2])
        # подрезать объём до области и не выше 2 км над рельефом
        ztop = fld.hc.max() + 2000
        kk = fld.z < ztop
        Z3, Y3, X3 = np.meshgrid(fld.z[kk], fld.y, fld.x, indexing="ij")
        W3 = w[kk]
        for lev, col, sgn in ((1.0, "red", 1), (-0.5, "blue", -1)):
            reach = (W3.max() >= lev) if sgn > 0 else (W3.min() <= lev)
            lv = lev if reach else float(np.percentile(W3, 99.5 if sgn > 0 else 0.5))
            lab = f"w = {lv:+.2f} м/с" + ("" if reach else f" (поле не доходит до {lev:+.1f})")
            notes.append(lab)
            traces.append(dict(type="isosurface", x=r1(X3.ravel(), 0), y=r1(Y3.ravel(), 0), z=r1(Z3.ravel(), 0),
                               value=r1(W3.ravel(), 3), isomin=lv - 0.005, isomax=lv + 0.005,
                               surface=dict(count=1, fill=1.0), caps=dict(x=dict(show=False), y=dict(show=False),
                                                                           z=dict(show=False)),
                               colorscale=[[0, col], [1, col]], showscale=False, opacity=0.35, name=lab,
                               showlegend=True, hoverinfo="skip"))
    xr = region[1] - region[0]
    yr = region[3] - region[2]
    zr = float(H.max() - H.min() + 2000)
    base = zr / max(xr, yr)
    def aspect(k):
        return dict(x=xr / max(xr, yr), y=yr / max(xr, yr), z=base * k)
    buttons = [dict(label=f"высота ×{k}", method="relayout", args=[{"scene.aspectratio": aspect(k)}]) for k in (1, 2, 3, 5)]
    layout = dict(title=dict(text=title + ("<br><sub>" + "; ".join(notes) + "</sub>" if notes else ""), x=0.02),
                  scene=dict(aspectmode="manual", aspectratio=aspect(2),
                             xaxis=dict(title="x, м (восток)", range=[region[0], region[1]]),
                             yaxis=dict(title="y, м (север)", range=[region[2], region[3]]),
                             zaxis=dict(title="м над морем", range=[float(H.min()) - 50, float(H.max()) + 2000]),
                             camera=dict(eye=dict(x=-0.6, y=-1.6, z=0.9))),
                  updatemenus=[dict(type="buttons", direction="right", x=0.02, y=1.0, xanchor="left", buttons=buttons,
                                    active=1)],
                  legend=dict(x=0.0, y=0.02), margin=dict(l=0, r=0, t=60, b=0), paper_bgcolor="#f4f4f4")
    html = f"""<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<script src="{CDN}"></script>
<style>html,body{{margin:0;height:100%;background:#f4f4f4;font-family:sans-serif}}#p{{width:100vw;height:100vh}}</style>
</head><body><div id="p"></div>
<script>
const data = {json.dumps(traces, ensure_ascii=False, separators=(',', ':'))};
const layout = {json.dumps(layout, ensure_ascii=False, separators=(',', ':'))};
Plotly.newPlot('p', data, layout, {{responsive: true, displaylogo: false}});
</script></body></html>"""
    p = OUT3 / out_name
    p.write_text(html)
    print(p, f"{p.stat().st_size / 2 ** 20:.1f} МБ, линий {len(lines)}")
    return p


def main():
    F = C.OUT / "fields"
    for key, lab in (("h13_U0_d0", "штиль"), ("h13_U3_d180", "южный ветер 3 м/с")):
        w100 = F / f"W100_{key}.npz"
        if w100.exists():
            build(w100, f"Каянча, окно 100 м, 13:00, {lab}", f"kayancha_w100_{key}.html", terrain_step=25.0,
                  nseed=12)
        d200 = C.FIELDS / "d200" / f"{key}.npz"
        if d200.exists():
            s = C.probes()["start"]
            reg = (s[0] - 9000, s[0] + 9000, s[1] - 9000, s[1] + 9000)
            build(d200, f"Онгудай, область 200 м (18×18 км вокруг старта), 13:00, {lab}",
                  f"ongudai_d200_{key}.html", region=reg, terrain_step=100.0, nseed=14, iso=False, nmax=400)


if __name__ == "__main__":
    main()
