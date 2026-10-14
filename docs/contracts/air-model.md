---
type: "contract"
status: "closed"
module: "air-model"
area: "air"
updated: "2026-10-15"
summary: "Модель воздуха, стыки C1–C10: правило изменения, общие соглашения, список стыков и ссылки на части (эталон, вход, WindField, AirRuntime)."
related: ["docs/contracts/air-model/input-solver.md", "docs/contracts/air-model/field-consumers.md", "docs/contracts/air-model/runtime-calibration.md", "docs/contracts/air-model/divergences-journal.md"]
contracts: [{"id": "C1", "version": 2}, {"id": "C2", "version": 9}, {"id": "C3", "version": 2}, {"id": "C4", "version": 4}, {"id": "C5", "version": 1}, {"id": "C6", "version": 1}, {"id": "C7", "version": 4}, {"id": "C8", "version": 2}, {"id": "C9", "version": 3}, {"id": "C10", "version": 3}]
---
# Модель воздуха: контракты систем

Интерфейсы на стыках задач плана `docs/archive/plan/air-model.md` (AM-00…AM-12). Зафиксировано **то, что
есть в коде** на 29.09.2026 (ветка `feature/air-model`); то, чего ещё нет, помечено «проект».
Контрактные тесты — `tests/contracts/test_air_contracts.gd` (headless, без GPU):
`godot --headless --path . res://tests/run_tests.tscn -- --filter=test_air_contracts`.

## Правило изменения контракта
- Исполнитель работает **в рамках контракта**. Нужен другой интерфейс — только через К0:
  1. правка раздела контракта: версия +1, строка в «Журнале версий» (что изменилось, дата, кто);
  2. уведомление всех задач-потребителей из таблицы раздела;
  3. их правка — в том же шаге или сразу после (до следующей задачи в очереди);
  4. контрактные тесты (`tests/contracts/`) меняются **в том же коммите**, что контракт.
- Версия раздела — в заголовке (`## C3 v1 — …`); тест `test_contract_versions` сверяет их с
  константой в тесте — правка контракта без правки теста (или наоборот) ломает прогон.
- Исправление внутри реализации, не меняющее интерфейс (числа, скорость, внутренняя раскладка
  буферов GPU), контракт не трогает.

## Общие соглашения (действуют во всех разделах)
| Что | Соглашение |
|---|---|
| Мир игры | x — восток, y — вверх (м над морем), z — **юг** (−Z — север); `net.proto` — то же |
| Сетка решателя | i — восток, j — **север** (y_решателя = −Z мира), k — вверх; x0, y0 — западный и южный края внутренней области, z_bot — низ внутренней области (м над морем) |
| Скорость мир ↔ сетка | мир (x, y, z) = (u, w, −v) |
| Раскладка без ореола | (nz, ny, nx), индекс `(k·ny + j)·nx + i`; центр `x0 + (i + ½)dx`, `y0 + (j + ½)dx`, `z_bot + (k + ½)dz` |
| Раскладка с ореолом | (NZ, NY, NX) = (nz + 2, ny + 2, nx + 2), индекс `(k·NY + j)·NX + i`; центр `x0 + (i − ½)dx`, `z_bot + (k − ½)dz` (та же точка, что без ореола при i_без = i − 1) |
| Грани MAC (с ореолом) | `u[k,j,i]` — западная грань клетки i (между i − 1 и i), `v` — южная, `w` — нижняя |
| Столбцы | hc и 2D-массивы — (ny, nx), индекс `j·nx + i` |
| `dims` в JSON | всегда [x, y, z]-размеры (`[NX, NY, NZ]`), хотя индекс идёт k, j, i |
| Маска земли | клетка — земля, если z её центра < hc столбца (ореол: весь слой k = 0 — земля) |
| Ветер «откуда» | `wdir` / `wind_from_deg`, ° от севера по часовой; направление «куда» в сетке (ex, ey) = (−sin, −cos), в мире `WindModel.dir` = (−sin, 0, cos) |
| Единицы | м, с, м/с; θ′ и θ̄ — К; dθ̄/dz (`gam`) — К/м; поток тепла H — Вт/м² на горизонтальную площадь; z_i — м **над морем** |
| Числа на стыке | float32 LE (файлы, буферы GPU); CPU-вход решателя (`AirCase`) — float64 |
| Нечисловые | на входе `WindField` NaN/∞ → 0 |

## Стыки и части

Контракт разбит по D4 (`docs/contracts/docs-rework.md`): каждый стык целиком в одной части, номера C1…C10 и версии не менялись (на них ссылаются код и тесты).

| Стык | Версия | Что | Часть |
|---|---|---|---|
| C1 | v2 | эталон AM-01 → GPU AM-03: дискретизация, фикстуры `ref/` | [input-solver](air-model/input-solver.md) |
| C2 | v9 | вход места `AirPlace` / `AirCase` (AM-03) ← рельеф, поверхность, погода, солнце | [input-solver](air-model/input-solver.md) |
| C3 | v2 | выход решателя → `WindField` (AM-05) | [input-solver](air-model/input-solver.md) |
| C4 | v4 | `WindField` / `AirFieldSet` → атмосфера, термики, возмущения, визуал | [field-consumers](air-model/field-consumers.md) |
| C5 | v1 | источники термиков → сеть (AM-07) | [field-consumers](air-model/field-consumers.md) |
| C6 | v1 | часы старта и файл поля (библиотеки нет) | [field-consumers](air-model/field-consumers.md) |
| C7 | v4 | клипмапы AM-04 → `WindField` / `AirFieldSet` | [field-consumers](air-model/field-consumers.md) |
| C8 | v2 | фоновый пересчёт / подмена (AM-06Б) → `set_field` | [field-consumers](air-model/field-consumers.md) |
| C9 | v3 | жизненный цикл поля в игре `AirRuntime` (AM-06Б, окна — AM-04) | [runtime-calibration](air-model/runtime-calibration.md) |
| C10 | v3 | случай калибровки (обёртка прогона air.py) → совместная калибровка | [runtime-calibration](air-model/runtime-calibration.md) |

- [air-model/input-solver.md](air-model/input-solver.md) — C1–C3: эталон → GPU, вход места, выход решателя.
- [air-model/field-consumers.md](air-model/field-consumers.md) — C4–C8: WindField и его потребители.
- [air-model/runtime-calibration.md](air-model/runtime-calibration.md) — C9–C10: AirRuntime и калибровка.
- [air-model/divergences-journal.md](air-model/divergences-journal.md) — Расхождения и журнал версий.
