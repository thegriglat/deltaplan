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
$PY report.py tables                                     # out/tables.md, out/library.json
$PY export3d.py                                          # out/3d/*.html
```

## Данные

- в git: `out/*.json` (все числа, история невязок), `out/*.log`, `out/*.png`, `out/tables.md`,
  `out/fields/W100_*.npz` (окна 100 м, fp16, u, v, w, θ′, p), `out/3d/*.html` (≤ 14 МБ);
- вне git (`.gitignore`, ~1 ГБ): `fields/d400/*.npz`, `fields/d200/*.npz` — все 182 поля матрицы (fp16),
  `fields/cells/` — окна 50 м и поля 200 м опыта cells. Локальный путь:
  `/home/greg/deltaplan/tools/research/air3d/fields/`; пересчёт — `study.py matrix` и `study.py cells`.

---

# Эталон AM-01 (поверх прикидки)

Спецификация дискретизации и все таблицы приёмки — `reference.md`. Прикидка (`solver.py`,
`common.py`, `study.py`, `report.py`) оставлена как была — для воспроизведения чисел `summary.md`.

## Файлы эталона
- `air.py` — решатель `Air` (CuPy, float32/float64): маска, K(z) Троена–Марта/Холтслага–Бовилля +
  местная длина перемешивания, профиль фонового ветра, губки, окна от родителя, поправка переноса
  2-го порядка (выключена, см. reference.md → «Перенос»), баланс тепла;
- `weather.py` — погода игры (weather_model.gd/json): суточный ход, утренняя инверсия, z_i, θ̄(z), поток тепла;
- `real.py` — сетки места (область 400/200 м, окна 100/50 м у старта), условия на час из погоды;
- `synth.py` — синтетика: проверки пилота 3–7 (`pilot`), тепловые сценарии (`heat`), потенциальное обтекание;
- `askervein.py` — Askervein: разгон против измерений;
- `ref_study.py` — реальный рельеф: `cells`, `windows`, `hours`, `library`, `weather`, `aushkul`, `adv`, `precision`;
- `fixtures.py` — эталоны для тестов GPU → `tests/atmosphere/fixtures/air_model/ref/` (float64 → f32 .bin + .json);
- `ref_figs.py` — картинки `out/ref/fig_*.png`.

## Как воспроизвести
```bash
cd tools/research/air3d
PY=../heat_ca/.venv/bin/python          # или /home/greg/deltaplan/tools/research/heat_ca/.venv/bin/python
LOCK="flock /tmp/heat_ca_gpu.lock"
$PY weather.py                           # θ̄, z_i, прогрев по часам и классам погоды (CPU, печать)
$PY fixtures.py                          # эталоны GPU (~1 мин, без замеров времени)
$LOCK $PY synth.py pilot 34567           # проверки пилота → out/ref/pilot.json (~40 мин)
$LOCK $PY synth.py heat                  # тепловые сценарии → out/ref/heat.json, fields/heat_*.npz (~10 мин)
$LOCK $PY askervein.py --dx 50,25        # → out/ref/askervein.json, fig_askervein.png (~10 мин)
for c in cells windows hours library weather aushkul adv precision; do $LOCK $PY ref_study.py $c; done
$PY ref_figs.py                          # out/ref/fig_*.png
```
Данные: в git — `out/ref/*.json`, `out/ref/*.png`, малые срезы `out/ref/*.npz`; вне git (`fields/`) —
3D-поля тепловых сценариев, вечера и Аушкуля (пересчёт — команды выше).
