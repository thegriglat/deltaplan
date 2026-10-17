---
type: "contract"
status: "active"
module: "takeoff-wind"
area: "flight"
updated: "2026-10-17"
summary: "Стыки модуля takeoff-wind: формат итогов исследования TW-1/TW-2, неизменные интерфейсы погоды старта и запечённых полей."
related: ["docs/plan/takeoff-wind.md", "docs/contracts/training-island.md", "docs/contracts/volcano-island.md"]
contracts: [{"id": "TW-К1", "version": 1}, {"id": "TW-К2", "version": 1}]
---

# Контракты модуля takeoff-wind

## TW-К1. Итог исследования — версия 1

- Владельцы: TW-1, TW-2. Потребитель: координатор (карточки волны 2).
- Каталог `tools/research/takeoff_wind/<ID>/` (ID — TW-1, TW-2): `README.md` с frontmatter (`type: research`, `module: takeoff-wind`, `conclusion`, `data`, `applied_in`),
  разделы «Вывод», «Причины», «Предложение правки», «Воспроизведение»; данные — `runs.csv` или `*.jsonl` (строка на прогон/замер), сводка — таблица в README;
  скрипты прогонов — там же; прототипы правок — `*.patch` там же (не применены в ветке).
- Таблица причин: `случай | прогонов | падений | класс (autopilot|run_physics|ground_wind|other) | доказательство (числа) | правка (файл:функция)`.
- Предложение правки: что меняется, ожидаемый эффект в числах (замер прототипа), что затрагивает (тесты, `model_hash`, места/старты).
- Числа — только из замеров, с командой воспроизведения.

## TW-К2. Неизменные интерфейсы (ссылки)

- Погода старта — TI-К2 v2 (`docs/contracts/training-island.md`): набор `weather` стартов и `wind_ref` этим модулем не меняются (иначе шлюз).
- Запечённое поле — TI-К3 v3, запекание — VI-К3 v1: формат не меняется; при смене `model_hash` поля перепекаются `tools/terrain/bake_all.sh`.
  Контрактные тесты — `tests/contracts/test_training_island_k3.gd`, проверка свежести — `bash tools/terrain/bake_all.sh --check`.
- Порог `takeoff_failed` (`scripts/game/flight_stats.gd`) и ожидания `tests/game/test_e2e.gd`, `tests/stability/test_matrix.gd` не ослабляются (иначе шлюз).
