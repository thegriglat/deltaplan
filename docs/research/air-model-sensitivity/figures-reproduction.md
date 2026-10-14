---
type: "research"
status: "active"
module: "air-model"
area: "air"
updated: "2026-10-03"
summary: "Список картинок и таблиц tools/research/morris/out, команды воспроизведения (5,3 ч GPU, SALib), источники"
related: ["docs/research/air-model-sensitivity.md"]
conclusion: "Список картинок и таблиц tools/research/morris/out, команды воспроизведения (5,3 ч GPU, SALib), источники"
data: ""
applied_in: ""
---
# Картинки, воспроизведение, источники

> Часть исследования [Чувствительность модели воздуха: отбор по Моррису](../air-model-sensitivity.md).

## Картинки
- `tools/research/morris/out/fig_heatmap_key.png` — матрица «фактор × ключевая наблюдаемая», S; `fig_heatmap_key_conv.png` — только сошедшиеся шаги;
- `out/fig_heatmap_askervein.png` — все 39 точек Askervein и χ² по группам;
- `out/fig_heatmap_pilot_heat.png` — проверки пилота, нагрев, итерации;
- `out/fig_mu_sigma.png` — μ\*–σ по 16 наблюдаемым;
- `out/fig_askervein_alpha_lamfrac.png` — χ² Askervein на плоскости (α притока, λ/h);
- `out/fig_scatter_lamfrac.png` — χ², HT, AANE10, разгон 2H, ротор, подъём против λ/h по всем точкам;
- `out/fig_degeneracy.png` — сходство действия факторов (cos);
- `out/fig_status.png` — какие факторы меняют сходимость;
- `out/fig_heatmap_s3.png` — масштаб 3.

Таблицы: `out/morris_table.csv` (все наблюдаемые × факторы, варианты «все» и «сошедшиеся»), `out/lists.md` («что двигает» по каждой наблюдаемой и по каждому фактору), `out/morris.json` (эффекты, SVD, лучшие точки, статусы и время).

## Воспроизведение
Из корня копии. Venv — `tools/research/tune/.venv`:
`uv venv; uv pip install "cupy-cuda12x[ctk]==14.2.0" numpy matplotlib scipy iminuit zstandard brotli SALib` (`[ctk]` нужен для заголовков CUDA при сборке ядер).
```bash
sh tools/research/morris/run_all.sh 12          # план (r = 12) + пачки «morris» (GPU) и «morris-s3» (Godot)
.dpcli/dpcli job wait morris 28800
.dpcli/dpcli job wait morris-s3 7200
tools/research/tune/.venv/bin/python tools/research/morris/analyze.py   # все таблицы и картинки
```
Прогоны дописываются в `out/runs/<случай>.jsonl` (по строке на точку, с параметрами, статусом, итерациями, временем и всеми наблюдаемыми). Прерванную серию можно продолжить повторным запуском. Замок GPU `/tmp/heat_ca_gpu.lock` берётся на каждую точку. Поля масштаба 3 (`tools/research/morris/fields/`, ≈ 180 МБ) — вне git, пересоздаются `run_s3.sh`. Для масштаба 3 нужен один раз `godot --headless --import` в новой копии (кеш классов).

## Источники
Beljaars A.C.M., Viterbo P. (1998) in: Clear and Cloudy Boundary Layers, KNAW · Bell J.H., Mehta R.D. (1990) AIAA J. 28:2034 · Blackadar A.K. (1962) JGR 67:3095 · Businger J.A. et al. (1971) JAS 28:181 · Campolongo F., Cariboni J., Saltelli A. (2007) Env. Model. Softw. 22:1509 · Counihan J. (1975) Atmos. Env. 9:871 · Herman J., Usher W. (2017) SALib, JOSS 2(9):97 · Hernández-Aguayo C. et al. (2026) arXiv:2608.00241 · Högström U. (1996) BLM 78:215 · Holtslag A.A.M., Boville B.A. (1993) J. Climate 6:1825 · Lenschow D.H., Stephens P.L. (1980) BLM 19:509 · Li D. (2019) Atmos. Res. 216:86 (Pr_t, обзор) · Lilly D.K. (1967) IBM Sci. Comp. Symp. · Mellor G.L., Yamada T. (1982) Rev. Geophys. 20:851 · Morris M.D. (1991) Technometrics 33:161 · Panofsky H.A., Dutton J.A. (1984) Atmospheric Turbulence · Pope S.B. (2000) Turbulent Flows · Skamarock W.C. et al. (2019) NCAR/TN-556+STR · Stull R.B. (1988) An Introduction to Boundary Layer Meteorology · Taylor P.A., Teunissen H.W. (1987) BLM 39:15; данные — Zenodo 4095052 (CC BY 4.0) · Wieringa J. (1993) BLM 63:323 · Perdigão: Fernando H.J.S. et al. (2019) BAMS 100:799 · Bolund: Berg J. et al. (2011) BLM 141:219.
