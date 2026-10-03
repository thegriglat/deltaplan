#!/usr/bin/env python3
"""Таблица P3E7: E0 (v0_ctrl) / E1 (v1_wide) / E7 (U-FNO) на отложенных горных системах, 60 м; сошедшиеся и несошедшиеся
отдельно; обучающие места; по системам и корзинам уклона. → <rep>/p3e7.md, p3e7.json
  .venv_fno/bin/python p3/p3e7_table.py --rep <отчёт E7> --p3rep <отчёт P3> --name v7_fno"""
from __future__ import annotations

import argparse, json, sys
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE)); sys.path.insert(0, str(HERE / "p3"))
from pilotnn import common as C  # noqa: E402
from variants_table import row_of, f  # noqa: E402


def grp(rep, name):
    p = rep / name / "metrics.json"
    m = json.loads(p.read_text())
    out = {}
    for g, d in (m["sets"]["holdout_sys"].get("groups") or {}).items():
        r = {}
        for k in ("conv", "nc"):
            c = (d.get("net") or {}).get(k) or {}
            a = c.get("area") or {}
            w = a.get("wind") or {}
            r[k] = dict(n=c.get("n_cases"), med=w.get("median"), p90=w.get("p90"), ok=a.get("frac_wind_ok"),
                        rho=(a.get("rho") or {}).get("median"))
        out[g] = r
    nc = (m["sets"]["holdout_sys"]["net"].get("nc") or {}).get("area") or {}
    return out, dict(nc_n=m["sets"]["holdout_sys"]["net"].get("nc", {}).get("n_cases"),
                     nc_med=(nc.get("wind") or {}).get("median"), nc_p90=(nc.get("wind") or {}).get("p90"),
                     nc_ok=nc.get("frac_wind_ok"), nc_rho=(nc.get("rho") or {}).get("median"),
                     nc_rho_p90=(nc.get("rho") or {}).get("p90"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rep", required=True); ap.add_argument("--p3rep", required=True); ap.add_argument("--name", default="v7_fno")
    a = ap.parse_args()
    rep, p3rep = Path(a.rep), Path(a.p3rep)
    cfg = C.load_config(HERE / "config.yaml")
    rc = cfg["eval"]["replace"]
    src = [("E0", "(0) U-Net, 3,2 M", p3rep, "v0_ctrl"), ("E1", "(1) U-Net ×2 ширина, 12,3 M", p3rep, "v1_wide"),
           ("E7", "E7 U-FNO", rep, a.name)]
    R, G, N = {}, {}, {}
    for k, lab, rp, nm in src:
        r = row_of(rp, nm, rc)
        if r is None:
            continue
        R[k] = r
        G[k], N[k] = grp(rp, nm)
    L = ["# P3E7: U-FNO против U-Net (E0, E1)", "",
         "Отложенные горные системы, 60 м, все клетки области без края. Кодировка П-2 (v4), 100 мест, сплит и гиперпараметры E0.", "",
         "## Сошедшиеся решения", "",
         "| сеть | параметров | случаев | ветер медиана | p90 | «ок» ветра | «ок» подъёма m / h | ρ медиана / p90 | заменима | ветер на обучающих (медиана / p90 / «ок») | эпоха, с | эпох (лучшая) | ONNX МБ | ONNX мс (4 потока) |",
         "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for k, lab, _, _ in src:
        r = R.get(k)
        if not r:
            continue
        t = r.get("train_set")
        ts = f"{f(t['wind_median'])} / {f(t['wind_p90'])} / {f(t['frac_wind_ok'], pct=True)}" if t else "—"
        L.append(f"| {lab} | {r['n_params'] / 1e6:.2f} M | {r['n_cases_conv']} | {f(r['wind_median'])} | {f(r['wind_p90'])} | {f(r['frac_wind_ok'], pct=True)} | "
                 f"{f(r['frac_lift_m_ok'], pct=True)} / {f(r['frac_lift_h_ok'], pct=True)} | {f(r['rho_median'], 2)} / {f(r['rho_p90'], 2)} | "
                 f"{'да' if r['replaceable'] else 'нет'} | {ts} | {f(r['t_epoch_s'], 1)} | {r['epochs']} ({(r['best_epoch'] or 0) + 1}) | "
                 f"{r['onnx']['size_mb']:.1f} | {f(r['onnx']['time_ms_4'], 1)} |")
    L += ["", "## Несошедшиеся решения (цель — late_mean)", "",
          "| сеть | случаев | ветер медиана | p90 | «ок» ветра | ρ медиана / p90 |", "|---|---|---|---|---|---|"]
    for k, lab, _, _ in src:
        if k in N:
            n = N[k]
            L.append(f"| {lab} | {n['nc_n']} | {f(n['nc_med'])} | {f(n['nc_p90'])} | {f(n['nc_ok'], pct=True)} | {f(n['nc_rho'], 2)} / {f(n['nc_rho_p90'], 2)} |")
    gs = list(G[next(iter(G))])
    for key, title in (("conv", "сошедшиеся"), ("nc", "несошедшиеся")):
        L += ["", f"## По типу рельефа, {title}: ветер медиана / p90, м/с (случаев)", "",
              "| сеть | " + " | ".join(gs) + " |", "|---|" + "---|" * len(gs)]
        for k, lab, _, _ in src:
            if k in G:
                L.append(f"| {lab} | " + " | ".join(
                    f"{f(G[k][g][key]['med'])} / {f(G[k][g][key]['p90'])} ({G[k][g][key]['n']})" for g in gs) + " |")
        if "E7" in G and "E0" in G:
            L.append("| E7 / E0 по медиане | " + " | ".join(
                (f"{G['E7'][g][key]['med'] / G['E0'][g][key]['med']:.2f}" if G['E7'][g][key]['med'] and G['E0'][g][key]['med'] else "—") for g in gs) + " |")
    (rep / "p3e7.md").write_text("\n".join(L) + "\n")
    C.atomic_write_json(rep / "p3e7.json", dict(rows=R, groups=G, nc=N))
    print("\n".join(L))
    return 0


if __name__ == "__main__":
    sys.exit(main())
