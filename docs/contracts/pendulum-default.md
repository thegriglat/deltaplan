---
type: contract
status: active
module: pendulum-default
area: flight
updated: "2026-10-22"
summary: "Режим управления по умолчанию — «Маятник» (pendulum): умолчание и подписи UI (PMD-К1; заменён RM-К1 — режимов у игрока нет)."
related: ["docs/plan/pendulum-default.md", "docs/contracts/pendulum.md"]
contracts: [{"id": "PMD-К1", "version": 1}]
---
# Контракты pendulum-default

Контрактный тест — `tests/contracts/test_pendulum_default_contracts.gd` (пишет PMD-1). Правка интерфейса — только через координатора: версия +1, этот файл и тест — в том же шаге.

## PMD-К1 v1. Режим управления по умолчанию
**Заменено RM-К1 (`docs/contracts/roll-modes.md`): контракт утрачивает силу целиком. Настройки «Управление креном» и значений `roll_control_mode` нет (ключ удалён из `configs/controls.json`, значение в профиле игнорируется); `SettingsPanel.ROLL_MODES` и `settings_roll_*` удалены; `Glider.model` игрока — всегда `PendulumModel`; `setup_app_pendulum_only` удалён. Текст ниже — история.**
Владелец — PMD-1; потребители — `Glider.setup` (выбор модели, PD-К1), `InputController`, `SettingsPanel`, `Game`, сеть (PD-К4 `controlMode`), сайт и доки (PMD-3, PMD-4).

- Значения `controls.roll_control_mode`: `"pendulum"` («Маятник», `PendulumModel`), `"weight_shift"` («Смещение веса», `FlightModel`), `"rate"` («Простое», `FlightModel`). Набор не меняется, все три выбираемы.
- Умолчание — `"pendulum"`: `configs/controls.json → roll_control_mode`; каждое чтение `roll_control_mode` в коде с запасным значением (нет ключа/нет конфига) даёт `"pendulum"`. Неизвестное значение → `"pendulum"` (не `FlightModel`).
- Список в настройках (`SettingsPanel.ROLL_MODES`) — порядок `["pendulum", "weight_shift", "rate"]`; выбранный пункт ↔ значение — через этот массив.
- Подписи (`locale/ui.csv`): `settings_roll_pendulum` — «Маятник» / «Pendulum» (без «экспериментальный»/«experimental»); `setup_app_pendulum_only` — ru «Настройки режима «Маятник»; в других режимах не действуют», en «Pendulum mode settings; other modes ignore them» (если по коду какой-то из 4 ключей «Аппарат» действует и в других режимах — подпись честно по факту, исполнитель сообщает `contract:`). Заменяет фразу о подписи в PD-К3.
- Боты и `BotAgent` — по-прежнему `FlightModel` (PD-К1); чужие пилоты — поза по `pilotRel` при `controlMode = PENDULUM` (PD-К4, PD-К5).
- Инвариант для теста: `controls.json` без правок → `Glider` после `setup` держит `PendulumModel`; `ROLL_MODES[0] == "pendulum"`; `ROLL_MODES` содержит `"weight_shift"` и `"rate"`; строка `settings_roll_pendulum` не содержит «эксперимент»/«experiment».
