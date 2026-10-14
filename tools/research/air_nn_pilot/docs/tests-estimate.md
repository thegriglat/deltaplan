---
type: "research"
status: "closed"
module: "air-nn"
area: "air"
updated: "2026-10-15"
summary: "Тесты пилота, оценка стоимости полного прогона П-2 (проба на 20 случаях, интервал Уилсона) и тест прерываний конвейера"
related: ["tools/research/air_nn_pilot/README.md"]
---
# Тесты, оценка полного прогона и тест прерываний (NN-P7)

Часть пилота air-nn; вход и границы — [README](../README.md). Сеть заменена в игре фазовой сборкой (AP-21).

## Тесты
```bash
.venv/bin/python tests/test_prep.py [--dataset <каталог набора>]       # П2 v3: карты на аналитическом рельефе, поворот, обратное преобразование
.venv/bin/python tests/test_reflect.py                                 # П2 v4: отражение поперёк ветра
.venv/bin/python tests/test_split.py                                   # деление v3 на искусственном наборе размера П-2
.venv/bin/python tests/test_verdict.py                                 # вердикт ШП-2 (П3 v3) на синтетических числах
.venv/bin/python tests/make_mock_p6.py                                 # подставные П6 и terrain (+ метаданные решений П1 v3) для smoke П-2
.venv/bin/python tests/test_contract_sample.py --dataset smoke         # П1 v1 (smoke) и v2 (подставной terrain)
./run_pilot.sh --smoke && .venv/bin/python tests/check_report_v3.py --latest-smoke   # smoke П-2 до отчёта П3 v3
.venv/bin/python tests/test_interrupt_train.py --profile smoke         # kill -9 / SIGINT / kill -9 при записи чекпойнта / в кривой → как непрерванный
.venv/bin/python tests/bench_epoch.py <каталог кеша подготовки>          # время эпохи объёма П-2 (3697 образцов, батч 8, 9 карт)
```
Результаты — `tests/out/interrupt_train_<профиль>.json`, `tests/out/bench_epoch.json` (отчёт берёт из него оценку
полного прогона). Тест прерывания набора — `tests/test_interrupt.py` (NN-P1).

## Оценка полного прогона П-2 (NN-P7)

`.venv/bin/python estimate.py --full-p2` → `figures/estimate_p2_full.json`. Вход — проба на **настоящих** местах `tiles/v3`
(`dataset.py run --dataset probe`: 10 мест равномерно по рангу slope_p50 × 2 условия = 20 случаев, П1 v3, предел 1000 итераций,
late_mean 500…1000/50, 2 воркера; `tests/out/` и `figures/estimate_probe.json`) и замер эпохи NN-P5 (`tests/out/bench_epoch.json`).
Время случая GPU = длительность пачек / случаи (воркеры учтены); крутизна время почти не объясняет (случай «max» стоит ~5× дороже
«ok», а доля max от slope_p50 не монотонна: на 20 случаях 5 max, 0 % на самых крутых), поэтому оценка — по средним `ok` и `max`
отдельно × доля max, с интервалом Уилсона по ней (11–47 %). Обучение — верхняя граница (150 эпох без ранней остановки).
Старый кеш подготовки main P-1 (`pilot/prep/…/main_2922f6_p09f8cbf3`, 3,3 ГБ) после слияния не используется (код `prep.py` изменился) — можно удалить.

## Тест прерываний конвейера (NN-P7)

`.venv/bin/python tests/test_interrupt_pipeline.py` (долго — запускать фоном): `run_pilot.sh --smoke` в двух временных корнях
данных (вырезки — симлинк на настоящие, наборы и кеш с нуля): непрерванный и с прерыванием SIGINT и kill -9 на каждой стадии 2…7 с
повтором; сравнение `metrics.json` (все числа), побитно файлов наборов, отсутствие `*.tmp*`. Итог — `tests/out/interrupt_pipeline.json`.
Стадия 1 (рельеф) при готовом `tiles/v3` пропускается мгновенно; её прерывание — тест NN-P4/NN-P8.
