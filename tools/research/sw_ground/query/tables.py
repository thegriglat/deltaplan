"""SWG-6: таблицы из timing.json (v2): метод × окно × стадия × variant. tables.py <timing.json> > tables.md"""
import json
import sys

d = json.load(open(sys.argv[1]))
rows = d["rows"]


def key(r):
    return (r["window_dx"], r["stage"])


def fmt(x, n=1):
    return "—" if x is None else f"{x:.{n}f}"


pic = {}
for r in rows:
    if r["method"] == "picard" and r["threads"] == 8 and r["tol_scale"] == 5.0:
        pic[key(r)] = r["t_total_s"]
base = {key(r): r["t_total_s"] for r in rows if r["method"] == "panels" and r["variant"] == "fp64"}
order = ["fp64", "above_ground", "vert_interp", "fp32", "fused64", "far_cluster_t07", "far_cluster", "far_cluster_t03",
         "fp32+above_ground", "fp32+above_ground+vert_interp", "fp32+above_ground+far_cluster",
         "fp32+above_ground+far_cluster+vert_interp"]
print("| Окно | Стадия | variant | точек | t, с | ×быстрее fp64 | ×к Пикару (8 пот., tol 5) | LU+сборка | опрос | rms_rel | max_rel | max_abs, м/с | в допуске игры, % | макс. превышение допуска, м/с |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
for dx in (100, 50):
    for st in ("cold", "wind_change"):
        rs = {r["variant"]: r for r in rows if r["method"] == "panels" and key(r) == (dx, st)}
        for v in order:
            if v not in rs:
                continue
            r = rs[v]
            p = r["parts"]
            fixed = (p.get("assemble", 0) + p.get("lu", 0))
            q = p.get("query_jh", 0) + p.get("select", 0) + p.get("interp", 0)
            e = r["err"]
            sp = base[key(r)] / r["t_total_s"]
            print(f"| {dx} м | {'холодный' if st == 'cold' else 'смена ветра'} | {v} | {r['n_points']} | {r['t_total_s']:.1f} | {sp:.1f} | "
                  f"{r['t_total_s'] / pic[key(r)]:.1f} | {fixed:.1f} | {q:.1f} | "
                  + (f"{e['rms_rel']:.1e} | {e['max_rel']:.1e} | {e['max_abs_ms']:.2g} | {100 * e['frac_game_ok']:.3f} | {max(e['game_excess_ms'], 0):.3f}" if e else "— | — | — | — | —") + " |")
print()
print("Пикар (8 потоков, tol 5), с: " + "; ".join(f"{k[0]} м {k[1]}: {v:.1f}" for k, v in sorted(pic.items())))
