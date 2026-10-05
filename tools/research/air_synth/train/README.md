---
type: "reference"
status: "active"
module: "air-synth"
updated: "2026-10-05"
summary: "SY-11: обучение сети P2 (U-Net + FiLM, без изменений) на счёте решателя по местам дельтаплана (S7 v1): загрузчик S5 v4, ускоренный цикл, оценка, ONNX"
related: ["docs/contracts/air-synth.md", "docs/plan/air-synth.md", "tools/research/air_nn_pilot/README.md", "tools/research/air_synth/solver/README.md"]
---
# SY-11: обучение P2 на местах дельтаплана (S7 v1)

Сеть, вход, выход, потери и гиперпараметры — P2 без изменений (`air_nn_pilot/pilotnn`, импортируется, не правится): U-Net 96→6 с FiLM, 3,2 млн параметров,
9 карт + 18 чисел → 91 канал; AdamW lr 2e-3, wd 1e-4, прогрев 3 % + косинус, bf16, EMA 0,999, клип 1, batch 8, ≤ 150 эпох, терпение 30, отражение поперёк ветра.
Меняются только данные (S5 v4: `hg_v1__hgw24` — 284 обучающих места × 24 условия = 6816 случаев, 20 отложенных мест = 480, и `game__hgw24` — 4 места игры = 96).

## Файлы
| файл | что |
|---|---|
| `s7_data.py` | загрузчик S5 v4 → тензоры P2; восстановление условий случая (`Recover`); кеш подготовки (`build_cache`, `Cache`); деление «проверка по месту» (`split_val`) |
| `s7_cache.py` | кеш подготовки всех наборов в `$AIR_SYNTH_DATA/train/<имя>/cache/` (по готовым частям, повторяемо по ходу счёта) |
| `s7_train.py` | ускоренный цикл (режимы `val` и `final`) |
| `s7_eval.py` | метрики S7 (60 м) по срезам, `out/eval_holdout.{json,md}`; функции ONNX |
| `s7_export.py` | ONNX финальной сети `out/model_hg.onnx` + `out/onnx_report.json` (совпадение интерфейса с `data/air_nn/model.onnx`) |
| `run_all.sh` | весь конвейер (кеш → обучение (1) → оценка → обучение (2) → ONNX) |
| `tests/` | `test_recover.py` (FiLM и поток тепла против решателя), `test_train.py`, `test_eval.py`, `test_onnx.py` (`onnx_io_match`) |

## Как восстанавливаются числа FiLM и карты
Решатель получил случай из таблицы условий S2 v4 (`solve_corpus.solve_one`): `model_place.register` рельефа → `context` (поправки `ground_context`) с месяцем, датой,
широтой, долготой, поясом из таблицы → подмена `weather.CFG` возмущениями дня (`s5_io.cfg_from_row/weather_override`) → `real.case`. `Recover.case` делает то же самое
(не вызывая решатель) и берёт `day = cond.day.summary()` и `profile = (alpha, max_profile, stab, sun_el, sun_az)` — как `airlite_gen.solve_case` для P2. Далее `prep.case_meta`,
`prep.film`, `prep.maps`, `prep.target` — функции P2.
Проверки (`tests/test_recover.py`, по каждому случаю кеша — поле `heat_dev` в `.meta.npz`):
- поток тепла `real.case` с гашением у края (`air.Air`: (sin·sin)² на 2 км, `heat_taper_m`) **равен** `inputs/heat_flux` решателя (float16): max|Δ| = 0 на всех случаях пробного счёта;
- `hc` равен `inputs/hc` (float32 → float64, < 1e-3 м);
- 18 чисел FiLM согласованы с таблицей S2 v4 (другим кодом — `conditions.derive`) в пределах округления `day.summary()` (целые метры z_i, z_lcl; 0,001 heat/brk);
- `to_physical(цель)` = поля решателя (float16).
Карты входа берутся по `hc` и `heat_flux`, записанным решателем (то есть без зависимости от восстановления); восстановление нужно только для 18 чисел FiLM, поворота и профиля притока.

**Числа FiLM — 18 как у P2.** Добавление N/Fr и dθ/dz (S2 v4 допускает «решение задачи обучения») не сделано: S7 требует тот же интерфейс ONNX (`nums` = (1, 18)), и сеть
должна заменять `data/air_nn/model.onnx` без правок игры. Эти числа (и `w*/U`) используются только для срезов оценки. Запись в контракт — для координатора.

## Оценка (S7)
|ΔV| на 60 м (линейно 50–75 м, веса 0,6/0,4), клетки без 5 у края; относительная = |ΔV|/max(U10, 1). Через кодировку цели |ΔV| = S·|(Δy∥, Δy⊥)| точно (профиль притока вычитается
из обоих полей, поворот не меняет модуль; сверка с `to_physical` — `tests/test_recover.py::test_error_through_target_equals_physical`). Срезы: поле с нагревом (главное, как П3) / без;
mechanical (w*/U < 0,5) / конвективный; терцили Fr и dθ/dz (пороги — по условиям обучающих случаев, записаны в json). Базовая линия — профиль притока без поправки. Статистика — пулом клеток
по случаям группы (`median_60m`, `p90_60m`, `rel_median_60m`) и по случаям (медиана медиан случая); по местам — `by_place`.

## Ускоренный цикл (результат обучения не меняет)
Y (1,7 МБ на случай) не помещается на GPU (6 тыс. случаев ≈ 11 ГБ при 12 ГБ карты и чужих задачах) — лежит в `np.load(mmap_mode='r')` кеша, батчи собирает поток в закреплённые буферы,
копия на GPU асинхронно (события буферов); X, F и проверочный Y — на GPU, батч индексируется на GPU; потери копятся на GPU и читаются раз в 200 шагов; EMA — `torch._foreach_mul_/add_`;
fused AdamW; `.item()` на шаге нет. Строгая детерминированность (`use_deterministic_algorithms`, как у пилота) оставлена. Загрузка GPU — `nvidia-smi` (см. `summary.md`).

## Воспроизведение
```bash
cd tools/research/air_synth/train; PY=../../air_nn_pilot/.venv/bin/python        # venv пилота (torch, onnxruntime, h5py)
$PY -m pytest -q tests                                                           # тесты (CPU; test_recover — на пробном каталоге SY-10)
$PY s7_cache.py --name hgw24_p2 --workers 8                                      # кеш по готовым частям счёта (повторять по ходу счёта)
$PY s7_train.py --mode val --cache $AIR_SYNTH_DATA/train/hgw24_p2/cache/hg_v1__hgw24__s0-939a467 --run $AIR_SYNTH_DATA/train/hgw24_p2/val --bench 200   # оценка времени по 200 шагам
tools/dp job --lock gpu start sy11-all 40000 tools/research/air_synth/train/run_all.sh                                    # весь конвейер (после конца счёта)
```
Результат: `$AIR_SYNTH_DATA/train/hgw24_p2/{cache,val,final}` (веса, журнал, история); в git — `out/` (оценка json/md, ONNX, отчёт ONNX).
