---
type: plan
status: "closed"
module: roll-modes
area: flight
updated: "2026-10-22"
summary: "Игроку — только «Маятник»: убрать настройку «Управление креном» и режимы «Смещение веса»/«Простое»; FlightModel (rate) — только боты."
related: ["docs/contracts/roll-modes.md", "docs/contracts/pendulum-default.md", "docs/contracts/pendulum.md", "docs/contracts/control-fix.md", "docs/contracts/pilot-view.md", "docs/guide/flight.md"]
---
# Только «Маятник» для игрока (модуль `roll-modes`, код задач RM)

## 1. Цель
У игрока одна физика — «Маятник» (`PendulumModel`). Настройка «Управление креном» и режим «Смещение веса» (`FlightModel._roll_weight_shift`, `wing.weight_shift`) удаляются целиком; `FlightModel` с прямыми командами крена (rate) остаётся только для ботов. Раскладка ввода игрока не меняется.

## 2. Решения пользователя (не обсуждаются)
- Игроку — только «Маятник»: убрать из настроек «Управление креном» (все пункты) и режим «Смещение веса» целиком — ветка `_roll_weight_shift` в `FlightModel`, `wing.weight_shift` в конфигах крыльев, тесты, документация, сайт (2026-10-22). Почему: три режима неудобно поддерживать; в weight_shift/rate нет крыла и срыва, они нефизичны.
- `FlightModel` с прямыми командами крена (rate) — только для ботов, игроку недоступен (2026-10-22).
- Раскладку ввода не трогать: «Инверсия тангажа» (как ручка самолёта) и «Крен мышью» (как тело / как штанга) остаются и работают как сейчас в «Маятнике» (2026-10-22).
- Сеть: `PENDULUM` — люди, `RATE` — боты; совместимости не нужно (2026-10-22).
- Условие «проверить настройки отца» снято: слияние — по обычной приёмке; по «roll-modes done» главная сдаёт модуль в `main` (`deliver --into main`) без отдельного подтверждения (2026-10-22).

## 3. Задачи
### RM-1 Код: убрать режимы крена игрока
Исполнитель: `dp-engineer` (sonnet). Контракт RM-К1.
- `Glider` — всегда `PendulumModel`; `controls.roll_control_mode` — нигде не читается, ключ из `configs/controls.json` убрать.
- `FlightModel` — только rate: убрать `_roll_weight_shift`, `roll_authority`, `roll_stability`, `roll_input_for_bank`, `_ws` и поля режима; `bar_force` — без «держащего» ввода. Путь rate (боты) — без изменений в числах.
- `ControlInput.weight_shift` — удалить (и все записи в него: `InputController`, `BotAgent`, инструменты).
- `wing.weight_shift` — удалить из всех `configs/wings/*.json`.
- `InputController` — без `roll_mode`; поведение = нынешний «Маятник» (знак `roll_input`, «в центр» X); ветки rate игрока (выравнивание по телеметрии) — убрать.
- `SettingsPanel` — без строки «Управление креном» (`ROLL_MODES`, `_roll_mode`, запись ключа); `locale/ui.csv` — ключи пунктов удалить.
- Сеть: `CONTROL_MODE_WEIGHT_SHIFT` из `net.proto` убрать (`reserved`), Go перегенерировать; игрок шлёт `PENDULUM`.
- Тесты: `test_roll_weight_shift.gd` и проверки режима weight_shift — удалить; тесты rate-физики — на `FlightModel` напрямую (как у ботов); прочие — на «Маятник». Контрактный тест `tests/contracts/test_roll_modes_contracts.gd` вместо `test_pendulum_default_contracts.gd`.
- Инструменты `tools/flight/` и `tools/research/spin_recovery/sr1/sr1_run.gd` — без weight_shift / `roll_control_mode`.
Приёмка: тесты `roll_modes`, `pendulum`, `roll`, мышь/сеть/боты/настройки/«Аппарат» — 0 упало (кроме известных падений базы); `go test` сервера; в `scripts`, `configs`, `locale`, `tools/flight` нет `roll_control_mode`/`weight_shift`/`ROLL_MODES`; нет `WEIGHT_SHIFT` в `scripts`, `server/gen`.

### RM-2 Документация, контракты, сайт, CHANGELOG
Исполнитель: `dp-writer` (sonnet). Источник фактов — RM-К1 и решения §2; параллельно с RM-1.
- `docs/guide/` — убрать режимы «Смещение веса»/«Простое» и настройку «Управление креном»: «Маятник» — единственная физика игрока, `FlightModel` (rate) — боты.
- Контракты действующего кода (`pendulum-default`, `pendulum` PD-К1/PD-К3/PD-К4, `control-fix` С1, `pilot-view` PV1, прочие с упоминанием режимов) — в затронутых разделах строка «Заменено RM-К1 (`docs/contracts/roll-modes.md`)», без переписывания истории.
- Сайт `site/content/` (кроме `releases/`) — по факту; без продающего тона.
- `CHANGELOG.md` → «В работе».
Приёмка: `.dpcli/dpcli docs check`, `hugo` без ошибок; в `docs/guide` и `site/content` (кроме `releases/`) нет названий удалённых режимов и настройки.

## 4. Волны
1. RM-1 и RM-2 параллельно (разные файлы).
2. Приёмка обеих → `roll-modes done`.

## 5. Условия остановки
- Боту или иному не-игроку нужен путь weight_shift или `wing.weight_shift` — шлюз.
- Числа rate-пути ботов меняются (тесты ботов падают не из-за удалённого флага) — шлюз.
- Удаление меняет поведение ввода игрока в «Маятнике» (знак крена, инверсия тангажа, «в центр») — шлюз.
