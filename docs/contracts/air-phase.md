---
type: "contract"
status: "closed"
module: "air-phase"
area: "air"
updated: "2026-10-15"
summary: "Контракты air-phase P1–P15: общие правила (данные, оси, изменение интерфейса), список стыков и ссылки на части (опыты, сборка, игра)."
related: ["docs/archive/plan/air-phase.md", "docs/archive/rejected/air-synth-contracts.md", "docs/research/air_phase.md", "docs/contracts/air-phase/experiments-solver.md", "docs/contracts/air-phase/assembly-game.md"]
contracts: [{"id": "P1", "version": 1}, {"id": "P2", "version": 6}, {"id": "P3", "version": 3}, {"id": "P4", "version": 6}, {"id": "P5", "version": 1}, {"id": "P6", "version": 2}, {"id": "P7", "version": 1}, {"id": "P8", "version": 1}, {"id": "P9", "version": 2}, {"id": "P10", "version": 5}, {"id": "P11", "version": 3}, {"id": "P12", "version": 4}, {"id": "P13", "version": 2}, {"id": "P14", "version": 2}, {"id": "P15", "version": 1}]
---

# Контракты модуля air-phase

Общее: каталог данных `$AIR_SYNTH_DATA` (по умолчанию `~/air_synth_data`); код — `tools/research/air_phase/`
(кроме P1 — `tools/research/air_synth/solver/reliefs.py`); оси полей — как S5/П1 `d400_*`: `[случай, канал, высота AGL,
j, i]`, j — север, i — восток, u — на восток, v — на север; x0 = y0 = −19 200 м (центр области — (0, 0)). Файлы HDF5
пишутся один раз (временное имя → `os.replace`), `*.tmp` читатель игнорирует. Менять интерфейс — только через
координатора: версия +1, запись «что изменилось» здесь, правка потребителей в том же шаге.
Контрактный тест: `tools/research/air_phase/tests/test_contract_phase.py` (запуск — venv air_nn_pilot,
`python -m pytest -q tools/research/air_phase/tests`).

## Стыки и части

Контракт разбит по D4 (`docs/contracts/docs-rework.md`): каждый стык целиком в одной части, номера P1…P15 и версии не менялись.

| Стык | Версия | Что | Часть |
|---|---|---|---|
| P1 | v1 | идеальные рельефы (`reliefs.py`, корпус `ideal_v1`) | [experiments-solver](air-phase/experiments-solver.md) |
| P2 | v6 | план опытов — манифест protobuf | [experiments-solver](air-phase/experiments-solver.md) |
| P3 | v3 | результаты замеров — HDF5 + jsonl | [experiments-solver](air-phase/experiments-solver.md) |
| P4 | v6 | решатель: пакетный вызов и опции | [experiments-solver](air-phase/experiments-solver.md) |
| P5 | v1 | скрипт прогона `run_phase.py` | [experiments-solver](air-phase/experiments-solver.md) |
| P6 | v2 | метрики слоёв и таблица признаков | [experiments-solver](air-phase/experiments-solver.md) |
| P7 | v1 | выход задач разбора | [experiments-solver](air-phase/experiments-solver.md) |
| P8 | v1 | прототип сборки поля по фазам | [assembly-game](air-phase/assembly-game.md) |
| P9 | v2 | прототип «фазы + Пикар» | [assembly-game](air-phase/assembly-game.md) |
| P10 | v5 | классификатор и механизмы фаз в игре | [assembly-game](air-phase/assembly-game.md) |
| P11 | v3 | GPU-Пикар: тёплый старт от сборки, карта ω, заморозка колонн | [assembly-game](air-phase/assembly-game.md) |
| P12 | v4 | `AirRuntime` без сети: фазы → Пикар → проекция (заменяет O5) | [assembly-game](air-phase/assembly-game.md) |
| P13 | v2 | удаление нейросети из игры | [assembly-game](air-phase/assembly-game.md) |
| P14 | v2 | проверки в игре | [assembly-game](air-phase/assembly-game.md) |
| P15 | v1 | проверка классификатора фаз — шлюз перед облётом | [assembly-game](air-phase/assembly-game.md) |

- [air-phase/experiments-solver.md](air-phase/experiments-solver.md) — P1–P7: опыты, пакетный решатель, метрики.
- [air-phase/assembly-game.md](air-phase/assembly-game.md) — P8–P15: сборка по фазам, Пикар, перенос в игру.
