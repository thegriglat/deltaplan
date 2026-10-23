---
type: contract
status: "closed"
module: roll-modes
area: flight
updated: "2026-10-22"
summary: "Игрок — только PendulumModel; FlightModel (rate) — боты; удалены roll_control_mode, ControlInput.weight_shift, wing.weight_shift (RM-К1)."
related: ["docs/plan/roll-modes.md", "docs/contracts/pendulum-default.md", "docs/contracts/pendulum.md", "docs/contracts/control-fix.md", "docs/contracts/pilot-view.md"]
contracts: [{"id": "RM-К1", "version": 1}]
---
# Контракты roll-modes

Контрактный тест — `tests/contracts/test_roll_modes_contracts.gd` (пишет RM-1). Правка интерфейса — только через координатора: версия +1, этот файл и тест — в том же шаге.

## RM-К1 v1. Одна физика игрока — «Маятник»
Владелец — RM-1. Потребители — `Glider`, `Game` (автопилот), `InputController`, `SettingsPanel`, `NetFlight`/`RemotePilots`/`NetMessages`, сервер (`server/proto`), `BotAgent`/`BotPilot`, инструменты `tools/flight/`, доки и сайт (RM-2).

Заменяет: PMD-К1 целиком (`docs/contracts/pendulum-default.md`); в PD-К1 — выбор модели `Glider` по настройке; в PD-К3 — подпись о «других режимах»; в PD-К4 — значение `WEIGHT_SHIFT` и выбор режима по настройке (`docs/contracts/pendulum.md`); в С1 — поле `weight_shift` (`docs/contracts/control-fix.md`); в PV1 v2 — условие «в режиме weight_shift» (`docs/contracts/pilot-view.md`).

**Модель игрока.**
- `Glider.model` после `setup` — всегда `PendulumModel`. Статический `Glider.is_pendulum_mode()` (чтение настройки) удалён; `Glider.is_pendulum()` остаётся (для игрока — `true`).
- `controls.roll_control_mode` нигде не читается; ключ и `roll_control_mode_doc` удалены из `configs/controls.json`. Значение в профиле пользователя (`user://configs/controls.json`) игнорируется, миграции нет.

**FlightModel — только rate, только боты и инструменты.**
- `input.roll` — угловая скорость крена (нынешняя ветка «как раньше» `_update_roll`, без изменений в числах).
- Удалены: `_roll_weight_shift`, `roll_authority`, `roll_stability`, `roll_input_for_bank`, `_ws`, `_tau_roll_ws`, `_roll_rate_max_ws`, `_roll_stability`, `_roll_stability_steep`, `_roll_overbank`, `OVERBANK_FADE_DEG`, `_last_weight_shift` (и всё, что используется только ими). Оценка усилия на трапеции (`bar_force` или как она названа) — «держащий» ввод 0, как сейчас в rate.
- Пользователи — `BotAgent`, `BotPilot`, инструменты; `Glider` её не создаёт.

**ControlInput.** Поле `weight_shift` удалено; остальные поля С1 — без изменений.

**Конфиги крыльев.** Блок `weight_shift` удалён из всех `configs/wings/*.json`; параметры rate-пути (`roll_*`, `air_roll_gain`, `stall`, `max_bank_deg` и т. п. вне блока) — без изменений.

**Ввод игрока (`InputController`).**
- Поле `roll_mode` и метод `weight_shift()` удалены. Поведение = нынешний режим `pendulum`: `ControlInput.roll` — положение пилота; знак — PV1: `roll_input = "bar"` → −1 в полёте и на земле, `"body"` → +1; `invert_pitch` — без изменений; «в центр» (X) — трапеция в нейтраль (ветка, которая сейчас работает при `weight_shift = true`). Выравнивание крыла по телеметрии (ветка rate: `_level_wing`, `_prev_bank`, `telemetry_fn`, если больше нигде не нужны) удалено.
- Инвариант: на одной и той же последовательности ввода (мышь, клавиши, стик/штанга; полёт и земля; с автопилотом и без) `ControlInput` (pitch, roll, run, walk) совпадает с нынешним режимом `pendulum`.

**Настройки.** В `SettingsPanel` нет строки «Управление креном» (`ROLL_MODES`, `_roll_mode`, запись `roll_control_mode`); «Крен мышью» (`roll_input`) и «Инверсия тангажа» (`invert_pitch`) — без изменений. Из `locale/ui.csv` удалены `settings_roll_control`, `settings_roll_pendulum`, `settings_roll_weight_shift`, `settings_roll_simple` (если не используются в другом месте). `setup_app_pendulum_only` («в других режимах не действуют») удалён вместе со своей подписью на вкладке «Аппарат»; если подпись несёт что-то ещё — исполнитель сообщает `contract:`.

**Сеть.**
- `server/proto/deltaplan/v1/net.proto`, `enum ControlMode`: `CONTROL_MODE_UNSPECIFIED = 0`, `CONTROL_MODE_RATE = 1` (боты), `CONTROL_MODE_PENDULUM = 3` (люди); `CONTROL_MODE_WEIGHT_SHIFT` удалён, `reserved 2; reserved "CONTROL_MODE_WEIGHT_SHIFT";`. `server/gen/` перегенерирован (`server/gen.sh`).
- `NetMessages` (`scripts/net/net_messages.gd`): номера 1 = RATE, 3 = PENDULUM сохраняются; имени `CONTROL_MODE_WEIGHT_SHIFT` нет.
- Локальный игрок всегда шлёт `PENDULUM` (+ `pilotRel`, PD-К4); `NetFlight.control_mode_name()` не читает конфиг. Боты, если их состояние шлётся, — `RATE`.
- Приём: значение, отличное от `PENDULUM`/`RATE` (в т. ч. номер 2), — как `""` (не передано): поза без `pilotRel`, как сейчас для не-маятника.

**Инварианты для контрактного теста.**
- `controls.roll_control_mode = "rate"` и `= "weight_shift"` в конфиге → `Glider` после `setup` держит `PendulumModel`.
- `ControlInput.new()` не имеет свойства `weight_shift`.
- `FlightModel` не имеет методов `_roll_weight_shift`, `roll_stability`, `roll_input_for_bank`.
- Ни один `configs/wings/*.json` не содержит ключа `weight_shift`; `configs/controls.json` — ключа `roll_control_mode`.
- `SettingsPanel` не имеет константы `ROLL_MODES`.
- `NetFlight.control_mode_name() == "PENDULUM"`; в списке `ControlMode` у `NetMessages` нет `CONTROL_MODE_WEIGHT_SHIFT`.
- `InputController` с `roll_input = "bar"`: мышь вправо → `ControlInput.roll < 0` в полёте и на земле; `"body"` → `> 0`.
