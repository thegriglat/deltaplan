---
type: "research"
status: "active"
module: "sw-charges"
area: "air"
updated: "2026-11-08"
summary: "Прототип A (SWC-6): вихревые частицы с плавучестью, 2D, прямая сумма на CuPy — термик-пятно и сдвиговой слой; код, команды, таблицы."
related: ["docs/research/sw_charges/proto-a.md", "docs/research/sw_charges/unified-scales.md", "docs/plan/sw-charges.md"]
conclusion: "docs/research/sw_charges/proto-a.md"
data: "tools/research/sw_charges/proto_a/out/"
applied_in: ""
---
# Прототип A: вихревые частицы с плавучестью (SWC-6)

Вывод, числа и сравнение с нынешней моделью — `docs/research/sw_charges/proto-a.md`. Здесь — код и воспроизведение.

## Файлы
- `pa_core.py` — ядро Лэмба — Озеена, RawKernel (прямая сумма O(N²), изображения стенок/периода), RK2, решётка пятна, блочный CuPy-эталон.
- `step1.py` — шаг 1 (пятно R = 100 м, Δθ = 1 К, земля и крышка — изображения), сходимость по N и σ, длинный прогон 10 мин (Δθ = 0,1 К).
- `step1b.py` — тот же длинный прогон без стенок (N = 10⁴, 2·10⁴, σ = 2,5·h).
- `step2.py`, `step2b.py` — шаг 2: сдвиговой слой ΔU = 3 м/с, период по x; `step2b` — сетка 3 м вместо 4 м.
- `timing.py` — время вычисления скоростей: RawKernel и блочный CuPy, N = 10³…4·10⁴; наивный N×N.
- `collect.py` — собирает `out/results.json` (step1, step2, criterion, timing) и PNG.
- `out/` — `results.json` (итог), `*_raw.json` (сырьё, < 3 МБ), `step12_summary.png`, `step2_profiles.png`, логи.

## Воспроизведение (GPU, без замка; около 30 мин суммарно)
```
cd tools/research/sw_charges/proto_a
PY=../../cascade_2d/py        # venv cascade_2d: numpy, scipy, matplotlib, cupy
$PY step1.py                  # ~6 мин
$PY step1b.py                 # ~12 мин
$PY step2.py                  # ~4 мин
$PY step2b.py                 # ~12 мин
$PY timing.py                 # ~1 мин, на свободном GPU
$PY collect.py
```
Среда: RTX 4070 SUPER (12 ГБ), CuPy 14.2.0, двойная точность. Данные синтетические, внешних нет; лицензий данных нет. Литература — в `docs/research/sw_charges/unified-scales.md`.

## Шаг 3: над линией рельефа, земля — панели panels2d (SWC-13)
Вывод и сравнение — `docs/research/sw_charges/proto-a-terrain.md`; числа — `out/step3/results.json` (`thermal_slope`, `rotor`, `criterion`, `timing`), рисунок `out/step3/step3_summary.png`, сырьё `out/step3/thermal_*.json`, `rotor_*.json`.
- `step3_core.py` — `Ground` (панели `panels2d`, обратная матрица влияния один раз, скорость источников панелей на GPU), `Run` (RK2 частиц: фон + панели + частицы; σ из `solve` = обратная матрица × (−(фон + частицы)·n) на каждом вычислении скорости или раз в k шагов; частицы под землёй — `reflect` (зеркало по вертикали) или `delete`; рождение вихря Γ = −½u_s²dt как в `panels2d.step`; `x_max` — удаление далеко ушедших).
- `step3_terrain.py` — Agnesi и разрез Perdigão (линия через гребни tse13 и tse04, NE-случай, как `sections/run_perd.py`; `cases/perdigao.py` только импортируется).
- `step3_thermal.py` — опыты (а): пятно R = 100 м, Δθ = 1 К, N ≈ 10⁴, dt = 1 с, T = 90 с; контроль на плоской земле, подножие и середина склона, U = 0 и 2,5–3 м/с, зазор до земли 15 м и 0 («прижатое»), чувствительность (reflect/delete, k = 1/2/4, ds_min, N).
- `step3_rotor.py` — опыты (б): Agnesi H = 200, L = 300 (подветренный уклон 0,43) и Perdigão, U100 = 5 и 8 м/с, T = 900 с, среднее по t ≥ 450 с (90 снимков), сход вихрей с бровки; контроль без схода; чувствительность (высота точки схода, k = 4, затухание τ).
- `step3_collect.py` — собирает `results.json` и PNG.
```
cd tools/research/sw_charges/proto_a
PY=../../cascade_2d/py                         # venv cascade_2d (cupy, numpy, scipy, matplotlib)
$PY step3_thermal.py                           # все опыты (а), ~15 мин на свободном GPU
$PY step3_rotor.py                             # все опыты (б), ~15 мин
$PY step3_collect.py
```
Данные Perdigão — `tools/research/data/perdigao/` (лицензия и цитирование — README данных); остальное синтетическое.
