---
type: contract
status: active
module: control-bar
updated: 2026-10-10
summary: "Контракты модуля control-bar: настройки устройства трапеции в controls.json → gamepad (CB-К1), ход ручки → управление, класс BarAxis (CB-К2)."
related: ["docs/plan/control-bar.md", "docs/research/control-bar-input.md"]
contracts: [{"id": "CB-К1", "version": 1}, {"id": "CB-К2", "version": 1}]
---
# Контракты модуля control-bar

План — `docs/plan/control-bar.md`. Менять — только через координатора (версия +1, что изменилось, уведомить потребителей).
Контрактный тест — `tests/contracts/test_control_bar_contracts.gd` (headless, без устройства): заголовки «## CB-К<n>. … (v<n>)»,
ключи и значения по умолчанию в `configs/controls.json`, форма и инварианты `BarAxis`. До CB-2 он красный — это ожидаемо
(класса и ключей ещё нет); тест грузит `bar_axis.gd` через `load()`, чтобы не ломать разбор раннера.

Основа — уже работающий ввод геймпада (`scripts/game/input_controller.gd`, `_apply_gamepad`, `_stick`): трапеция — это любой
HID-джойстик (записка CB-1), Godot 4.5+ (SDL3) даёт его оси без маппинга по индексу в −1…1 (`Input.get_joy_axis`).

## CB-К1. Настройки устройства трапеции (v1)
Владелец: CB-2. Потребители: `input_controller.gd` (CB-2), вкладка «Управление» настроек (CB-2), инструкция (CB-3).

Раздел `gamepad` в `configs/controls.json`; пилот меняет его через настройки — `UserSettings.save_patch("controls", {"gamepad": {…}})`
в `user://configs/controls.json` поверх `res://`. Существующие ключи (`enabled`, `roll_axis`, `pitch_axis`, `deadzone`, `expo`,
`sensitivity`, `run_button`, `action_buttons`) — смысл прежний. Новые ключи (у каждого — `*_doc` по-русски, как у соседей):
- `device_guid: String` — `""` (по умолчанию) — первое подключённое устройство, как сейчас; иначе — первое подключённое
  с `Input.get_joy_guid(id) == device_guid`. Выбранного устройства нет — ввода с джойстика нет (мышь и клавиатура работают),
  **не** подменять другим устройством: у него другая калибровка.
- `device_name: String` — имя устройства на момент выбора (`Input.get_joy_name`), только для показа («не подключено: …»).
- `invert_roll: bool`, `invert_pitch: bool` — `false`; направление проводки/датчика конкретного устройства. Общая
  `controls.invert_pitch` (предпочтение пилота для всех способов ввода) остаётся и действует поверх.
- `calibration: {"roll": [min, center, max], "pitch": [min, center, max]}` — сырые значения оси в единицах Godot (−1…1),
  `min < center < max`; по умолчанию `[-1.0, 0.0, 1.0]` — калибровки нет, поведение геймпада не меняется.

## CB-К2. Ход ручки → управление (v1)
Владелец: CB-2. Потребители: `input_controller.gd`, индикатор вкладки «Управление» (тот же расчёт, что в полёте).

`class_name BarAxis extends RefCounted`, файл `scripts/game/bar_axis.gd`; статические чистые функции (кроме `find_device`):
- `normalize(raw: float, cal: Array) -> float` — кусочно-линейно по `cal = [min, center, max]`:
  `raw ≥ center → (raw − center) / (max − center)`, иначе `(raw − center) / (center − min)`; итог в [−1, 1] (зажим).
  Вырожденная сторона (размах < 1e-3) — 0 на этой стороне; NaN/inf не возвращать никогда. `cal` неверной формы — как `[-1, 0, 1]`.
- `shape(x: float, gp: Dictionary) -> float` — нынешний `_stick` (мёртвая зона `deadzone`, `expo`, `sensitivity`), перенесён
  без изменения формулы; `input_controller._stick` удалить или сделать вызовом `BarAxis.shape`.
- `axis_value(raw: float, cal: Array, invert: bool, gp: Dictionary) -> float` = `shape(normalize(raw, cal) · (−1 если invert), gp)`.
- `find_device(guid: String) -> int` — `""` → первый из `Input.get_connected_joypads()`, иначе первый с таким GUID; нет → −1.

Порядок: сырое значение → калибровка → инверсия устройства → мёртвая зона/экспонента/чувствительность → как сейчас в
`_apply_gamepad`: `control.roll = x_roll · _roll_sign()`, `control.pitch = −y_pitch · (−1 если controls.invert_pitch)`.
Знаки — как у стика Godot: крен + — ручка вправо; тангаж − — ручка вперёд (от себя, `control.pitch` +).

Инварианты (контрактный тест):
- `normalize(center) = 0`, `normalize(min) = −1`, `normalize(max) = 1`, монотонно не убывает, за краями — ±1;
- при `cal = [-1, 0, 1]` и `invert = false`: `axis_value(raw, …) == shape(raw, gp)` == прежний `_stick(raw, gp)` — геймпад без
  калибровки ведёт себя как раньше;
- `invert = true` меняет знак итога; вырожденная калибровка (`[0, 0, 0]`, `[0.2, 0.2, 0.9]`) — конечные числа;
- `find_device("нет-такого-guid") == −1`.
