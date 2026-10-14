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

Контракт разбит по D4 (`docs/contracts/docs-rework.md`): каждый стык целиком в одной части, номера и версии не менялись (на них ссылаются код и тесты). Во входе — заголовки стыков с версиями (их читают контрактные тесты игры), подробности — в частях.

- [air-phase/experiments-solver.md](air-phase/experiments-solver.md) — P1–P7: опыты, пакетный решатель, метрики.
- [air-phase/assembly-game.md](air-phase/assembly-game.md) — P8–P15: сборка по фазам, Пикар, перенос в игру.

## P1. Идеальные рельефы (версия 1)

**Владелец:** AP-2. **Потребители:** AP-3 (P5), разбор.

Подробности — [air-phase/experiments-solver.md](air-phase/experiments-solver.md).

## P2. План опытов — манифест protobuf (версия 6)

**Владелец:** AP-2 (`.proto` — координатор, `tools/research/air_phase/proto/phase_plan.proto`). **Потребители:** AP-3, разбор.

Подробности — [air-phase/experiments-solver.md](air-phase/experiments-solver.md).

## P3. Результаты замеров — HDF5 + jsonl (версия 3)

**Владелец:** AP-3. **Потребители:** разбор (следующий этап), отчёт на шлюзе.

Подробности — [air-phase/experiments-solver.md](air-phase/experiments-solver.md).

## P4. Решатель: пакетный вызов и опции (версия 6)

**Владелец:** AP-1 (`tools/research/air_phase/batch_solver.py`; правки `air3d` допустимы при соблюдении инварианта 1).

Подробности — [air-phase/experiments-solver.md](air-phase/experiments-solver.md).

## P5. Скрипт прогона `run_phase.py` (версия 1)

**Владелец:** AP-3. **Потребители:** большой запуск, координатор (шлюз).

Подробности — [air-phase/experiments-solver.md](air-phase/experiments-solver.md).

## P6. Метрики слоёв и таблица признаков (версия 2)

**Владелец:** AP-6 (`tools/research/air_phase/layer_metrics.py`, `features.py`). **Потребители:** AP-7…AP-11.

Подробности — [air-phase/experiments-solver.md](air-phase/experiments-solver.md).

## P7. Выход задач разбора (версия 1)

**Владелец:** каждая задача AP-7…AP-11. **Потребитель:** AP-12 (сборка `docs/research/air_phase_results.md`).

Подробности — [air-phase/experiments-solver.md](air-phase/experiments-solver.md).

## P8. Прототип сборки поля по фазам (версия 1)

**Владелец:** AP-17 (`tools/research/air_phase/assembly/`). **Потребители:** шлюз «можно ли убрать сеть», будущий модуль сборки на GPU.

Подробности — [air-phase/assembly-game.md](air-phase/assembly-game.md).

## P9. Прототип «фазы + Пикар» (версия 2)

**Владелец:** AP-18 (`tools/research/air_phase/assembly/` + `hybrid/`). **Потребители:** шлюз пользователя, AP-19 (перенос в игру).

Подробности — [air-phase/assembly-game.md](air-phase/assembly-game.md).

## P10. Классификатор и механизмы фаз в игре (версия 5)

**Владелец:** AP-19 (`air_phase_job.gd` + `air_phase.glsl` — GPU на каркасе `AirGpu`; `air_phase_cpu.gd` — тот же код на CPU).

Подробности — [air-phase/assembly-game.md](air-phase/assembly-game.md).

## P11. GPU-Пикар: тёплый старт от сборки, карта ω, заморозка колонн (версия 3)

**Владелец:** AP-20 (`air_picard_job.gd`, `air_picard.glsl`). **Потребители:** `AirRuntime` (P12), проверки P14.

Подробности — [air-phase/assembly-game.md](air-phase/assembly-game.md).

## P12. `AirRuntime` без сети: фазы → Пикар → проекция (версия 4, заменяет O5)

**Владелец:** AP-20 (`air_runtime.gd`, `settings_panel.gd`, `configs/atmosphere.json → air_model`). **Потребители:** игра.

Подробности — [air-phase/assembly-game.md](air-phase/assembly-game.md).

## P13. Удаление нейросети из игры (версия 2)

**Владелец:** AP-21. **Потребители:** сборка, пользователь.

Подробности — [air-phase/assembly-game.md](air-phase/assembly-game.md).

## P14. Проверки в игре (версия 2)

**Владелец:** AP-19 (F/G/H против литературы), AP-20 (A/B/C, время). **Потребители:** приёмка, облёт.

Подробности — [air-phase/assembly-game.md](air-phase/assembly-game.md).

## P15. Проверка классификатора фаз (версия 1) — шлюз перед облётом

**Владелец:** AP-23 (`tools/research/air_phase/analysis/AP-23/`). **Потребители:** конфиг `air_phase` (пороги и ширины), шлюз.

Подробности — [air-phase/assembly-game.md](air-phase/assembly-game.md).
