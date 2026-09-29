# air3d: 3D-Пикар на рельефе Онгудая (оценка для библиотеки опорных полей)

Прикидка к плану `docs/plan/air_model.md` (масштаб 1 «среднее поле Пикаром», раздел «Библиотека
опорных полей»): грубое, но честное 3D-решение на реальном рельефе, чтобы получить числа —
время решения, итерации, сходимость, размер поля, эффект тёплого старта, ошибка интерполяции по
часам. Итог и таблицы — `summary.md`. Игра не тронута.

Основа — 2D-прототип `tools/research/heat_ca/` (схема опыта 2, `exp2_picard/`); решатель написан
заново для 3D.

## Файлы

- `terrain.py` — чтение слоя detail (`data/terrain/ongudai/detail.f32.gz`, 25 м, 40×40 км),
  блочное осреднение в клетки, старт Каянча из `configs/locations/ongudai.json`;
- `solver.py` — решатель `Air3D` (CuPy + CUDA RawKernel): шаблоны импульса и тепла, прогонки
  по линиям (зебра), многосеточный Пуассон (полуогрубление по x, y, прогонки по вертикали),
  граничные условия, баланс тепла; положение солнца (NOAA, упрощённо);
- `common.py` — сетки (область 400/200 м, окна 100/50 м 64×64 вокруг старта), запуск, критерий
  остановки, ключевые числа, запись полей;
- `study.py` — опыты: `conv`, `matrix`, `warm`, `cells`, `size`;
- `report.py` — `interp` (ошибка интерполяции по часам), `figs` (картинки);
- `export3d.py` — интерактивные 3D-страницы (plotly.js с cdnjs) → `out/3d/*.html`.

## Как воспроизвести

venv — общий с прототипом: `tools/research/heat_ca/.venv` (cupy-cuda12x, matplotlib) + `zstandard`
(`uv pip install --python ../heat_ca/.venv/bin/python zstandard`). Все замеры времени — под общим
замком GPU.

```bash
cd tools/research/air3d
PY=../heat_ca/.venv/bin/python
LOCK="flock /tmp/heat_ca_gpu.lock"
$LOCK $PY study.py conv   --dx 400,200 --max-outer 400   # ошибка против итераций → out/conv.json      (~2 мин)
$LOCK $PY study.py matrix --dx 400,200                   # 6 часов + без нагрева × 13 ветров → out/matrix.json,
                                                         #   поля fields/d400, fields/d200 (~8 мин)
$LOCK $PY study.py warm   --dx 200,400                   # тёплый старт → out/warm.json               (~6 мин)
$LOCK $PY study.py cells                                 # 400/200 м, окна 100/50 м → out/cells.json   (~3 мин)
$PY study.py size                                        # размер полей → out/size.json (CPU)
$PY report.py interp                                     # интерполяция по часам → out/interp.json (CPU)
$PY report.py figs                                       # out/fig_*.png
$PY export3d.py                                          # out/3d/*.html
```

## Данные

- в git: `out/*.json` (все числа, история невязок), `out/*.png`, `out/fields/W*.npz`, `out/fields/D200_*.npz`
  (окна и несколько полей 200 м, fp16), `out/3d/*.html`;
- вне git (`.gitignore`): `fields/d400/*.npz`, `fields/d200/*.npz` — все поля матрицы, fp16,
  ~0,5 ГБ; пересчитываются `study.py matrix`. Локальный путь: `tools/research/air3d/fields/`.
