#!/usr/bin/env python3
"""RW-6a: размер окон 100/50 м и оценка времени picard_rs на CPU (расчёт, не замер).

Входы (источники):
- сетки окон: tests/atmosphere/fixtures/air_model/window/ongudai_w{100,50}_h12.json (nx=ny=64, nz=62/112, dz=dx/2);
- область: 98*98*52 с ореолом (rust/picard_rs/INTEGRATION.md, "Память"); мс/итерацию u3_heat/u3_mech —
  rust/picard_rs/out/final/README.md, "мс/итерацию" (tol 1, итоговый код, Xeon E5-2666 v3);
- итерации окон: docs/guide/air-model-gpu/clipmap.md, таблица "Время" (GPU f32, tol 1 игры).
Допущения: время итерации линейно по числу клеток (мс/клетку·итерацию области); тот же счётчик итераций,
что у GPU-игры (верхняя оценка) и его доля 0,58 (отношение tol5/tol1 области u3: 111/191) как нижняя.
"""
import json, pathlib, sys

root = pathlib.Path(__file__).resolve().parents[3]
HALO = 2
dom_cells = (96 + HALO) * (96 + HALO) * (50 + HALO)  # 98*98*52
ms_it = {  # потоков -> (heat, mech), мс/итерацию области, tol 1
    8: (50.7, 40.2), 6: (62.8, 49.3), 3: (115.9, 90.5), 2: (155.1, 119.8)}
win = {}
for dx in (100, 50):
    m = json.load(open(root / f"tests/atmosphere/fixtures/air_model/window/ongudai_w{dx}_h12.json"))
    nx, ny, nz = m["nx"], m["ny"], m["nz"]
    win[dx] = dict(nx=nx, ny=ny, nz=nz, dz=m["dz"],
                   cells_halo=(nx + HALO) * (ny + HALO) * (nz + HALO),
                   side_km=nx * dx / 1000)
# плоский рельеф: nz = (перепад + 2000)/dz + 2 (air_window_case.gd: TOP_ABOVE=2000, z_bot = floor(lo/dz)*dz - dz)
flat = {dx: (64 + HALO) ** 2 * (int(2000 / (dx / 2)) + 2 + 2 + HALO) for dx in (100, 50)}
iters = {  # (mech, heat) GPU-игры: загрузка / сдвиг в полёте; tol 1
    100: dict(load=(40, 40), shift=(50, 40)), 50: dict(load=(40, 50), shift=(35, 65))}
out = {"domain_cells_halo": dom_cells, "windows": {}}
for dx in (100, 50):
    w = win[dx]
    k = w["cells_halo"] / dom_cells
    row = dict(w, rel_to_domain=round(k, 3), cells_flat_relief=flat[dx], times_s={})
    for thr, (h, m_) in ms_it.items():
        for mode in ("load", "shift"):
            nm, nh = iters[dx][mode]
            hi = k * (nm * m_ + nh * h) / 1000
            lo = 0.58 * hi
            row["times_s"][f"{thr}thr_{mode}"] = [round(lo, 2), round(hi, 2)]
    out["windows"][dx] = row
# период сдвига: пилот уходит от центра дальше 0,25 стороны окна (air_model.window_shift_frac)
side = {100: 6.4e3, 50: 3.2e3}
out["shift_period_s"] = {f"{dx}m_at_{v}ms": round(0.25 * side[dx] / v) for dx in (100, 50) for v in (8, 10, 15, 25)}
json.dump(out, open(pathlib.Path(__file__).with_name("window_estimate.json"), "w"), indent=1, ensure_ascii=False)
print(json.dumps(out, indent=1, ensure_ascii=False))
