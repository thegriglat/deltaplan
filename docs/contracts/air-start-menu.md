---
type: contract
status: active
module: air-start-menu
area: game
updated: 2026-11-05
summary: "Старт в воздухе: настройка и пределы (К1), постановка в Game (К2), пункт в окне «Старт» (К3), цели и рекорды (К4)."
related: ["docs/plan/air-start-menu.md", "docs/contracts/start-pick.md", "docs/guide/game/launch.md", "docs/contracts/trike-anywhere.md", "docs/contracts/goals.md"]
contracts: [{"id": "ASM-К1", "version": 1}, {"id": "ASM-К2", "version": 1}, {"id": "ASM-К3", "version": 1}, {"id": "ASM-К4", "version": 1}]
---
# Контракты air-start-menu

Контрактный тест — `tests/contracts/test_air_start_menu_contracts.gd` (пишет владелец ASM-1; версии — здесь). Правка интерфейса — только через координатора: версия +1, этот файл и тест — в том же шаге, потребителям — `task note`.

Координаты — как в SP-К1 (`docs/contracts/start-pick.md`): мир X восток, Z юг, Y — м над уровнем моря; курс — градусы, 0 = север, по часовой, `[0, 360)`; «вперёд» `(sin h, 0, −cos h)`.

## ASM-К1 v1
Выбор старта в воздухе в настройках полёта.

- Владелец: ASM-1. Потребители: окно выбора (UI-задача модуля), `Favorites` и `UserSettings.save_last_flight` (через `to_dict`), scenic-places (SCP).
- `FlightSettings` (`scripts/game/flight_settings.gd`):
  - `var air_start_agl_m: float = -1.0` — высота старта в воздухе над рельефом в точке старта, м; `< 0` — старт с земли (как сейчас);
  - `func has_air_start() -> bool` — `air_start_agl_m >= 0.0`;
  - `static func normalize_air_start(v: float) -> float` — нечисло или `< 0` → `-1.0`; иначе `clampf(v, agl_min_m, agl_max_m)` из конфига;
  - `to_dict`/`from_dict` — ключ `air_start_agl_m` (нет ключа → `-1.0`), значение через `normalize_air_start`; `duplicate` переносит поле.
- Совместимость (в `from_dict` и при любой установке поля через `set_air_start(v)`): старт в воздухе только у `vehicle == "glider"`; при `has_air_start()` → `tow_kind = ""`; `vehicle == "trike"` → `air_start_agl_m = -1.0`.
  - `func set_air_start(v: float) -> void` — `air_start_agl_m = normalize_air_start(v)`, затем правило совместимости; `set_air_start(-1)` — старт с земли.
- Конфиг `configs/game.json → air_start`: `agl_min_m` 50 (выше крон: деревья `configs/vegetation.json` до 22 м, ≥ 2× с запасом; если `configs/world_objects.json` даёт объект выше 25 м — владелец поднимает минимум и пишет почему), `agl_max_m` 1000 (граница выбора — решение координатора, не физика; правится конфигом), `agl_default_m` 300 (как у `--air-start`), `agl_step_m` 10; ключи `_doc` — по-русски.
- Инварианты: `from_dict(to_dict(s))` сохраняет `air_start_agl_m`; `normalize_air_start` идемпотентна; при `has_air_start()` всегда `vehicle == "glider"` и `tow_kind == ""`.

## ASM-К2 v1
Постановка старта в воздухе в игре — один путь для `--air-start`, выбора игрока и scenic-places.

- Владелец: ASM-1. Потребители: `Main._fly`, `Game.restart` («Ещё раз» R, «На старт»), scenic-places (SCP: точный старт `set_exact_start(lat, lon, heading)` + `set_air_start(h)`), цели и рекорды (вторая волна модуля, после Q2).
- Источник старта в воздухе на полёт (`Game.start(s)`): флаг `--air-start` (`LaunchOptions.air_start_m >= 0`) — главнее; иначе `s.has_air_start()` → `Game.air_start_m = 0.0`, `Game.air_start_agl_m = s.air_start_agl_m`; иначе — с земли (`air_start_m = -1`). Повторный `start()` с наземными настройками после воздушных — с земли (поле `Game.air_start_m` не «залипает»). В сети (`net != null`), в «Тренировке» (свои настройки — как сейчас) и в осмотре карты (`inspect_mode`) настройки воздуха не применяются.
- Точка: `Game.air_start_position()` — как сейчас: `_start_pos + forward·air_start_m`, `y = terrain.height_at(x, z) + air_start_agl_m`; для выбора игрока `air_start_m = 0` — над стартом. Курс — `_start_heading` (тот же, что у наземного старта: площадка, точка с карты, точный старт, поворот к ветру `_align_start_heading`).
- Состояние: `Glider.reset_in_air(pos, heading)` — трим, пилот в равновесии на штанге, ω = 0, фаза `flying`, `stats.armed` (касание — посадка). «Ещё раз»/«На старт» — снова так же на той же высоте.
- Точный старт при старте в воздухе: из причин `StartSpot.check` (SP-К2) отказ только `"outside"`; `"water"`, `"built"`, `"steep"` — допустимы (над озером, кратером, обрывом). Поляна `add_start_clearing` при старте в воздухе не вырубается (ни для точного старта, ни для точки с карты, ни для площадки).
- Буксировка и дельталёт при старте в воздухе не выбираются (`_choose_tow_start` → `false`, как сейчас при `air_start_m >= 0`).
- Инварианты (проверяет тест ASM-1, спокойный однородный воздух без поля и при однородном ветре 6 м/с, крыло по умолчанию): сразу после постановки XZ — в 1 м от `get_start().position` (при `air_start_m = 0`), `|altitude_agl − h| < 1 м`, воздушная скорость — трим ±1 м/с; за 20 с без управления: воздушная скорость в пределах ±5 % трима, тангаж в пределах ±3° от значения в момент постановки, |крен| < 2°, перегрузка n в [0,9; 1,1] (нет рывка), угол атаки ниже срыва крыла, фаза всё время `flying`.

## ASM-К3 v1
Выбор старта в воздухе в окне «Старт» по «Лететь» (Q1: пункт рядом с буксировкой + высота).

- Владелец: ASM-2. Потребители: `StartMenu._on_fly`/`_on_start_chosen` (`scripts/ui/start_menu.gd`), «Лететь отсюда» в осмотре (`scenes/main.gd`, лямбда на `chosen`), тесты TA-К1 (`tests/contracts/test_trike_anywhere_k1.gd`) — не ломать.
- `StartChoiceDialog` (`scripts/ui/start_choice_dialog.gd`):
  - `var air_check: CheckBox` (имя узла `AirCheck`), подпись `start_choice_air` — «В воздухе» / «In the air»; строка сразу под строкой буксировки;
  - `var air_height: HSlider` (имя `AirHeight`, через `UiKit.slider_row`, подпись `start_choice_air_height` — «Высота над стартом» / «Height above launch», формат «%.0f м» / `unit_m`), пределы и шаг — `configs/game.json → air_start` (ASM-К1); виден/доступен только при отмеченном `air_check`;
  - при отмеченном `air_check` `tow_opt` недоступен (`disabled`), выбор буксировки не теряется;
  - `var air_start_agl_m: float` — итог выбора: `air_height.value` при «Дельтаплан» с отмеченным `air_check`, иначе `-1.0` («Дельталёт», без отметки); ставится до `chosen.emit`;
  - `open(settings, site)`: `air_check` отмечен ⇔ `settings.has_air_start()`; `air_height.value` = `settings.air_start_agl_m` при `has_air_start()`, иначе `agl_default_m`;
  - сигнал `chosen(vehicle: String, tow_kind: String)` — как в TA-К1 (не меняется); при старте в воздухе `chosen("glider", "")`; `tow_ids()` и пункты `tow_opt` — как в TA-К1.
- Потребители после `chosen`: `settings.vehicle = vehicle`, `settings.tow_kind = tow_kind`, затем `settings.set_air_start(d.air_start_agl_m)` (ASM-К1 сам сбросит буксировку/дельталёт). Ветку сети в `_on_fly` не трогать (решение 2026-11-05: сетевую игру не трогаем; в сети настройку воздуха игнорирует Game, ASM-К2).
- Выбор сохраняется в «последний полёт» и избранное через `to_dict` (ASM-К1); окно при следующем открытии показывает прошлый выбор.
- Переводы — `locale/ui.csv`, обе колонки.

## ASM-К4 v1
Цели, рекорды и достижения полёта со стартом в воздухе (Q2).

- Владелец: ASM-3. Потребители: `GoalTracker` (GL-К3, `scripts/goals/goal_tracker.gd`), `FlightRecords` (`scripts/tasks/flight_records.gd`), итог полёта (`info.new_records`).
- `Game.is_air_start() -> bool` — у текущего полёта старт в воздухе (`air_start_m >= 0`: флаг или настройки, ASM-К2).
- Цели: контекст `Game._goals_ctx()` при старте в воздухе — `start_pos = air_start_position()` (точка постановки, `y` — её высота MSL); набор высоты — от высоты постановки, дальность — от её проекции, время — с постановки. При наземном старте — как сейчас.
- Рекорды: при `is_air_start()` `FlightRecords.add_flight` не вызывается; `info.new_records = {}` (итог — как у полёта без новых рекордов). Файл рекордов не меняется.
- Достижения — по ответу на Q3 (до карточки ASM-3 здесь будет правило; версия не меняется, пока ASM-3 не начата).
