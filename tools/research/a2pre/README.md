# Разведка перед А2: сходимость и цена решателя воздуха на новых параметрах

Записка с выводом — `docs/plan/air_model_a2pre.md`. Решатель (`tools/research/air3d/air.py`, после А1:
Pr_t = 0,85, θ′_d, h при const) не правился: меняются только `A.Params`.

| Файл | Что |
|---|---|
| `run.py` | драйвер одной пачки: `matrix` (наборы параметров × цепочка 400 → 100 → 50 м и область 200 м × условия × heat_mode), `morris` (несошедшиеся точки Морриса heat0, подвыборка, old и new), `trial` (оценка времени) |
| `analyze.py` | одна обработка: `out/tables.md`, `out/summary.json`, `out/fig_*.png` |
| `out/matrix.jsonl` | по строке на сценарий: по каждому решению статус, итерации, время, мс/итер, история невязок (каждые 10 итераций), плато, баланс тепла, ключевые числа, где невязка |
| `out/morris_rerun.jsonl` | то же для точек Морриса (+ исходные статусы из `~/deltaplan-wf-morris/tools/research/morris/out/runs/heat0.jsonl`) |
| `out/matrix_maps.npz`, `out/morris_maps.npz` | карты max по z невязки θ′ и w, профиль невязки θ′ по высоте в конце каждого решения |
| `out/trial.jsonl` | 2 пробные точки Морриса (оценка времени: тяжёлая цепочка 94–111 с) |

**Моррис отложен** (решение пользователя, 30.09.2026): стадия `morris` остановлена после 2 из 64 цепочек;
`out/morris_rerun.jsonl` (2 строки) и `out/morris_maps.npz` — прерванные данные, не обрабатываются. Повторный
анализ несошедшихся точек Морриса — в волне Б после совместной калибровки Askervein + Perdigão, если её итог
будет неудовлетворительным (код `run.py morris`, `analyze.py: morris()` оставлен).

Наборы (прочее — `Params()` = `AirCase.p` игры: 1-й порядок, hb, local_k, k_relax 0,5, heat_sweeps 4):
`old` — λ/h 0,25, α 0,14, z0 0,1 м, max_profile 1,8 (игра сейчас); `new` — λ/h 0,031, α 0,235, z0 0,09 м,
max_profile 2,0 (перекалибровка Askervein, `tools/research/recal`); `lam` — только λ/h 0,031; `new_z003` — `new` с
z0 0,03 м.

Воспроизведение (из этого каталога; venv с CuPy — `tools/research/morris/README.md`):
```bash
PY=/home/greg/deltaplan-wf-morris/tools/research/tune/.venv/bin/python
$PY run.py trial                                                   # ~3,5 мин GPU
/home/greg/deltaplan/tools/job.sh start a2pre 3600 $PY run.py matrix   # 36 сценариев, 18 мин GPU; замок GPU на сценарий
/home/greg/deltaplan/tools/job.sh wait a2pre 3600
$PY analyze.py        # только матрица → out/tables.md, out/summary.json, out/fig_*.png
```
Прерванная пачка продолжается повторным запуском (готовые ключи пропускаются).

Данные: рельеф Онгудая — `data/terrain/` (ASSETS.md); погода часа — `configs/` игры через `air3d/weather.py`.
Исходные прогоны Морриса — вне этой ветки, `~/deltaplan-wf-morris/tools/research/morris/out/runs/` (не трогать).
