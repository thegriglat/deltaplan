---
type: "research"
status: "closed"
module: ""
updated: "2026-09-29"
summary: "Опыты 1, 3, 6: линейность, ядра, «ядро струи» — Можно ли «схлопнуть» тысячи шагов клеточного автомата тепла и массы (../model.py, каждый шаг — свёрточный слой с фиксированными весами) в одну свёртку или короткую цепочку фильтров."
related: []
conclusion: ""
data: "tools/research/heat_ca/exp1_3_6_kernels/"
applied_in: ""
---
# Опыты 1, 3, 6: линейность, ядра, «ядро струи»

Можно ли «схлопнуть» тысячи шагов клеточного автомата тепла и массы (`../model.py`, каждый шаг —
свёрточный слой с фиксированными весами) в одну свёртку или короткую цепочку фильтров.
Итоги и вердикт — `summary.md`.

## Файлы

- `model.py`, `plots.py` — копии базы (`../`), без изменений.
- `exp13.py` — опыт 1 (линейность) и опыт 3 (ядра, сборка сценария 1 из ядер).
- `jet.py` — опыт 6: «ядро струи» (CuPy RawKernel + CUDA Graph).
- `exp6.py` — опыт 6: калибровка, сравнение с эталоном, формы ядер, время на GPU.
- `out/` — картинки, таблицы (`*.md`), числа (`*.json`), журналы прогонов (`*.log`);
  `out/cache/` — сырые поля автомата через 8 ч модели (`t8h_*.npz`, сжатые), через 7 ч (`t7h_*`,
  проверка недоустановления).

## Как воспроизвести

Из этой папки, venv общий (`../.venv`, numpy + matplotlib + cupy-cuda12x). Эталон — `../out/refs/`
(делается `../refs.py`).

```bash
../.venv/bin/python exp13.py linear    # exp1_linearity_map.png, exp1_linearity_vs_strength.png, exp1_linear.md/json
../.venv/bin/python exp13.py kernels   # exp3_kernels.png, exp3_kernel_decay.png, exp3_kernel_reconstruction*.png,
                                       # exp3_kernels.md/json (64 прогона точечного нагрева по 100 м, ~3 мин)
../.venv/bin/python exp6.py calib      # exp6_calib.json (β — расслоение бассейна)
../.venv/bin/python exp6.py compare    # exp6_compare_<сценарий>.png (50 м), exp6_errors_vs_cell.png,
                                       # exp6_compare.md/json; досчитывает автомат до 8 ч для 4×4 сеток (кеш)
../.venv/bin/python exp6.py kernels    # exp6_kernel_shapes.png, exp6_jet_anatomy.png, exp6_kernels.json
flock /tmp/heat_ca_gpu.lock ../.venv/bin/python exp6.py time   # exp6_time.md/json (замеры — под замком GPU)
```

Прогоны автомата в опытах 1, 3 и 6 (колонка «8 ч») — `Params(cell, t_max=8 ч, steady_dv=0, steady_dT=0)`:
до одного и того же модельного времени без досрочной остановки (почему — `summary.md`, опыт 1).
Параметры «ядра струи» — значения по умолчанию в `jet.Jet` (Cb = 1, L = 700 м, a = 250 м, σ0 = 50 м,
lmax = 150 м, 8 V-циклов) и β из `out/exp6_calib.json`.

В игре такой счёт пойдёт вычислительными шейдерами Vulkan (AMD обязательно); CuPy — только прототип.
