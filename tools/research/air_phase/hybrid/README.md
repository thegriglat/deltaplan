---
type: "research"
status: "closed"
module: "air-phase"
updated: "2026-10-06"
summary: "Прототип «фазы + Пикар» (AP-18, P9 v1): классификатор → веса фаз, карта ω, маска механизмов; сборка P8 + G (вечерний сток); тёплый старт Пикара (P4 v6); сшивка проекцией — против холодного Пикара на SY-12."
conclusion: "Код шагов P9 готов и покрыт CPU-тестами; счёт против Пикара не проводился (решение пользователя — не доводить прототип); спецификация для переноса в игру — analysis/AP-18/section.md. GPU-тесты P4 v6 написаны, не запускались."
data: "не создано: $AIR_SYNTH_DATA/phase/hybrid_v1 удалён (счёт снят из очереди)"
applied_in: "вход для AP-19 (перенос в игру)"
---
# «Фазы + Пикар» — прототип (AP-18, контракт P9 v1)

Поле масштаба 1 без сети: Пикар считает фазы A (обтекание), B (срыв), C (переход у Fr ≈ 1) и слабое D. Он стартует тёпло
от сборки по фазам, ω берётся по карте фаз. Механизмы закрывают H (штиль), сильное D, F (свободная конвекция) и G
(вечерний сток). Сшивка — проекцией.

- `pipeline.py` — шаги на случай на CPU: классификатор (веса A, D, LEE, EF, H, G; карта ω; маска механизмов), сборка
  (P8 `assembly.assemble` + G), опции решателя по вариантам, сшивка. Правила и пороги — в docstring.
- `drainage.py` — механизм G, построенный заново. Сток по склону — модель Прандтля с замыканием по потоку выхолаживания.
  Накопление в долинах — объёмный баланс гидравлического слоя по D8-водосбору. Формулы, источники и границы — в docstring.
- `run_hybrid.py` — счёт по выборке AP-17 (782 случая SY-12). Стадии: prep → gpu → final → clean.
- `../batch_solver.py` (P4 v6) — `omega_map`, `freeze_mask`, `omega_fallback`, старт из сборки `init = {"agl": …}`.
- Разбор — `../analysis/AP-18/` (P7).

## Воспроизведение
```
PY=/home/greg/deltaplan-air-synth/tools/research/air_nn_pilot/.venv/bin/python
$PY -m pytest -q tools/research/air_phase/tests/test_hybrid.py           # CPU, заглушка решателя
dp lock gpu t -- $PY -m pytest -q tools/research/air_phase/tests/test_batch_solver.py -k v6   # GPU
bash tools/research/air_phase/hybrid/run_all.sh prep                      # CPU, ≈ 5 мин на 14 процессах
dp job --lock gpu start ap18-run 43200 bash tools/research/air_phase/hybrid/run_all.sh gpu
bash tools/research/air_phase/hybrid/run_all.sh final                     # CPU: сшивка, метрики слоёв
bash tools/research/air_phase/hybrid/run_all.sh analysis                  # → analysis/AP-18/summary.json, tables.md, fig_*.png
bash tools/research/air_phase/hybrid/run_all.sh clean                     # удалить _prep и raw (≈ 3 ГБ)
```
Сухой прогон конвейера без GPU: `run_hybrid.py prep --out D --prep-from $AIR_SYNTH_DATA/phase/hybrid_v1 --limit 2`, затем
`run_hybrid.py gpu --out D --stub --limit 2` и `run_hybrid.py final --out D --limit 2`.

## Данные (локально, не в git; счёт не проводился — каталог hybrid_v1 удалён, ниже — формат, который даст `run_all.sh`)
- Вход — как у AP-17. Рельеф S1 `~/air_synth_data/real/hg_v2`: открытые DEM, лицензии — в ASSETS.md. Условия S2
  `conditions/hg_v2_hgw24`, поля S5 `solve/hg_v2__hgw24__s0-939a467` — наш счёт; поля S5 нужны только для сравнения.
- Выход — `$AIR_SYNTH_DATA/phase/hybrid_v1/`:
  - `part-*.h5` — P9 v1: `cases`, `fields/f` f2, `fields/m` f2, `weights` u1 ×255, `omega_map` u1 ×255, `freeze_mask` u1;
  - `metrics-*.jsonl` — метрики слоёв P6 по случаю: гибрид, холодный, S5, только механизмы, варианты;
  - `cold/part-*.h5` — холодный Пикар нынешней версии;
  - `runs_summary.json` — время;
  - `manifest.json`.
