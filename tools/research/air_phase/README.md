---
type: "reference"
status: "active"
module: "air-model"
updated: "2026-10-05"
summary: "air-phase: код и команды воспроизведения эмпирической фазовой карты по полям решателя SY-12 (признаки на случай, таблицы, рисунки) и схемы фазовой диаграммы"
related: ["docs/research/air_phase.md", "docs/research/air_phase_experts.md", "docs/research/air_phase_refs.md"]
---
# air-phase: воспроизведение

Итог и выводы — `docs/research/air_phase.md` (+ `air_phase_experts.md`, `air_phase_refs.md`). Здесь — код. Только CPU, Godot и GPU не нужны.

```bash
PY=/home/greg/deltaplan-air-synth-SY-11/tools/research/air_nn_pilot/.venv/bin/python   # numpy, scipy, h5py, matplotlib
$PY tools/research/air_phase/phase_stats.py --recompute   # признаки из полей (7320 + 96 случаев) → out/per_case*.npz, tables.md, summary.json, fig_*.png
$PY tools/research/air_phase/phase_stats.py               # таблицы и рисунки из кэша
$PY tools/research/air_phase/phase_diagram.py             # схема диаграммы → out/fig_phase_schematic.png
cp tools/research/air_phase/out/fig_{phase_schematic,nonconv_fr_hg,slowing_hg,order_hg,cases_hg,local_phase}.png docs/research/air_phase/
```

Данные (только чтение, `$AIR_SYNTH_DATA` или `~/air_synth_data`): `solve/hg_v2__hgw24__s0-939a467` (S5 v4), `conditions/hg_v2_hgw24` (S2 v4), `real/hg_v2` (S1 v4); места игры — `solve/game2__hgw24__s0-939a467`, `conditions/game2_hgw24`, `real/game_hg2`.

Файлы: `phase_stats.py` — признаки на случай (параметры порядка по полям m/h: застой, поворот, обратное течение, разгон, σ_w, конвективная добавка; оси Fr, w*/U, −z_i/L, крутизна, Δh/z_i), статистика сходимости Пикара по осям, логистическая регрессия, сигмоиды, разделимость, карта фаз одного случая; `phase_diagram.py` — схематические диаграммы по порогам из литературы. `out/` — результаты (per_case.npz ~2 МБ, рисунки).
