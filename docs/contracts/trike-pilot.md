---
type: contract
status: "active"
module: trike-pilot
area: flight
updated: "2026-10-22"
summary: "Стыки дельталёта игрока: эксплуатация двигателя (TP-К1), TrikeEngine (TP-К2), ввод (TP-К3), приборы (TP-К4), выбор старта (TP-К5)."
related: ["docs/plan/trike-pilot.md", "docs/contracts/trike-model.md", "docs/contracts/control-fix.md", "docs/contracts/pilot-view.md"]
contracts: [{"id": "TP-К1", "version": 2}, {"id": "TP-К2", "version": 1}, {"id": "TP-К3", "version": 2}, {"id": "TP-К4", "version": 2}, {"id": "TP-К5", "version": 1}]
---
# Контракты trike-pilot (код задач TP)

Правка интерфейса — только через координатора: версия +1, этот файл и контрактный тест — в том же шаге. Каждый
контрактный тест проверяет версию своего раздела по заголовку (шаблон — `tests/contracts/test_trike_model_k1.gd`:
`const DOC`, `const VERSION`, регулярка заголовка `^## (TP-К\d) v(\d+)\.`).

Форматы tow-trike (ещё не в `main`; читать в копии `~/deltaplan-tow-trike/docs/contracts/tow-trike.md`): TT-К1
(`configs/tow_tug.json`: `cart`, `engine`, `thrust`, `ground`, `wing`), TT-К3 (колёса в `PendulumModel`), TT-К4
(`TowTug`). До слияния код этого модуля их файлы не читает и не создаёт: числа TT-К1 — в тестовых словарях.

## TP-К1 v2. Эксплуатация двигателя — `configs/trike_pilot.json`
Владелец — TP-1. Потребители — TP-2 (`TrikeEngine`), TP-4 (шкала топлива), TP-6. Контрактный тест —
`tests/contracts/test_trike_pilot_k1.gd` (пишет TP-1).

- `"contract": "TP-К1 v1"`, `_doc` — что это и где расчёт (`docs/research/trike-pilot/engine-ops.md`). У каждого числа —
  ключ `<имя>_doc` (источник со ссылкой или вывод с расчётом; оценка — помечена «оценка» и разброс).
- `fuel`: `tank_l` (= `tools/blender/trike_params.json dims.tank_volume_l` ± 0,5), `start_l` (топливо на старте,
  0 < `start_l` ≤ `tank_l`), `density_kg_l` (смесь бензин+масло), `burn` — таблица расхода по оборотам **двигателя**:
  `rpm_engine` (по возрастанию, от ≤ холостых 2000 до ≥ 6800 об/мин), `lph` (л/ч, той же длины, ≥ 0, не убывает); между
  точками — линейно, вне — крайние значения.
- `starter`: `start_s` (от нажатия до холостых), `stop_s` (от выключения до остановки винта).
- `throttle`: `rate_per_s` (скорость рычага газа при зажатой W/S, доля хода в секунду; > 0; обоснование — время
  полного хода рычага).
- `tachometer`: `max_rpm` (конец шкалы), `green_rpm` `[от, до]`, `red_rpm` (≥ — красная зона): по руководству Rotax 582.
- **Инварианты теста:** все ключи есть и числовые, у каждого числа есть `_doc`; `burn.*` одной длины, `rpm_engine`
  возрастает, `lph` не убывает; `start_l` ∈ (0; `tank_l`]; `tank_l` = `trike_params.json` ± 0,5; `red_rpm` < `max_rpm`.
- v2 (2026-10-22, Q3): на старте полный бак — `start_l` = `tank_l` (53 л); инвариант теста: равенство.

## TP-К2 v1. Двигатель — `TrikeEngine`
Владелец — TP-2. Потребители — TP-4 (приборы), TP-6 (тяга в модели), TP-9 (звук). Контрактный тест —
`tests/contracts/test_trike_pilot_k2.gd` (пишет TP-2).

`class_name TrikeEngine extends RefCounted`, файл `scripts/flight/trike_engine.gd`.
- `setup(engine_cfg: Dictionary, thrust_cfg: Dictionary, ops_cfg: Dictionary) -> void`: `engine_cfg`, `thrust_cfg` —
  блоки `engine` и `thrust` формата TT-К1; `ops_cfg` — весь словарь TP-К1. После `setup` — `reset()`.
- `reset(fuel_l: float = -1.0) -> void`: состояние `"off"`, `throttle` 0, `prop_rpm` 0, топливо `fuel_l` (< 0 →
  `fuel.start_l`), `out_of_fuel` = (`fuel_l` ≤ 0).
- `step(dt: float, airspeed_ms: float, throttle_axis: float, toggle_pressed: bool) -> void`.
  - Рычаг: `throttle = clamp(throttle + throttle_axis·throttle.rate_per_s·dt, 0, 1)` во всех состояниях
    (`throttle_axis` ∈ [−1; 1]: +1 — W, −1 — S).
  - Целевые обороты винта `rpm_t = rpm(V, throttle)` по TT-К1 (`prop_rpm_idle + g·(rpm_full(V) − prop_rpm_idle)`,
    линейно по V, вне таблицы — крайние); целевая тяга `T_t = idle_n(V) + g·(full_n(V) − idle_n(V))`.
  - Состояния: `"off"` → (`toggle_pressed`, топливо > 0) → `"starting"`: `prop_rpm` растёт линейно от текущего до
    `rpm_t` за `starter.start_s` (наклон `prop_rpm_idle / start_s`), достиг — `"running"`: `prop_rpm = rpm_t`.
    `"running"`/`"starting"` → (`toggle_pressed` или топливо кончилось) → `"stopping"`: `prop_rpm` падает линейно с
    наклоном `prop_rpm_idle / stop_s` до 0 → `"off"`. В `"stopping"` `toggle_pressed` не действует.
  - Тяга `thrust_n`: `"running"` — `T_t`; `"starting"`/`"stopping"` — `T_t·(prop_rpm/rpm_t)²` (тяга винта ∝ n²);
    `"off"` — 0. Сопротивление остановленного винта не моделируется (граница модели).
  - Топливо: в `"starting"` и `"running"` `fuel_l −= burn.lph(engine_rpm)/3600·dt`; ≤ 0 → `fuel_l` = 0,
    `out_of_fuel` = true, переход в `"stopping"`; при `out_of_fuel` запуск невозможен.
- Только чтение: `state: String` ∈ {`"off"`, `"starting"`, `"running"`, `"stopping"`}, `running: bool`
  (= `state == "running"`), `throttle: float` [0; 1], `prop_rpm: float` (об/мин винта), `engine_rpm: float`
  (= `prop_rpm·engine.gear_ratio`), `thrust_n: float` (Н, ≥ 0), `fuel_l: float`, `tank_l: float`, `fuel_frac: float`
  (= `fuel_l/tank_l`), `fuel_mass_kg: float` (= `fuel_l·density_kg_l`), `out_of_fuel: bool`.
- Направление тяги и точка приложения — не здесь (TP-6, как TT-К4: на тележку вдоль её оси с `engine.thrust_tilt_deg`).
- **Инварианты теста** (тестовые словари: TT-К1-подобные `engine`/`thrust` — `gear_ratio` 3,47, `prop_rpm_idle` 576,
  таблица на 2–3 точки; TP-К1-подобный `ops` с `start_s` 1, `stop_s` 2): (1) после `reset` — `"off"`, `prop_rpm` 0,
  `thrust_n` 0, расход 0 за 10 с; (2) toggle → через `start_s` + 1 шаг `"running"`, `prop_rpm` = `prop_rpm_idle` ± 1 %
  при `throttle` 0 и V = 0, `thrust_n` = `idle_n(0)`; (3) `throttle_axis` +1 на `1/rate_per_s` с → `throttle` = 1,
  `prop_rpm` = `rpm_full(V)`, `thrust_n` = `full_n(V)` (± 1 %) при V = 0 и V из таблицы; −1 — обратно к 0, не ниже;
  (4) toggle в `"running"` → `"stopping"` → `"off"` за `stop_s` ± шаг, `prop_rpm` монотонно падает, `thrust_n` → 0;
  (5) расход за 60 с на холостых = `lph(idle·gear)/60` ± 1 %; (6) `fuel_l` 0,01 → кончилось, `"stopping"`,
  `out_of_fuel`, toggle не запускает; (7) обороты и тяга непрерывны на всех переходах (|Δ`prop_rpm`| за шаг ≤
  max(наклон старта, наклон остановки, наклон рычага·(rpm_full − idle))·dt + 1).

## TP-К3 v2. Ввод дельталёта
Владелец — TP-3. Потребители — TP-6 (газ, двигатель, руление), TP-7 (тормоз), `CameraRig` (взгляд). Контрактный тест —
`tests/contracts/test_trike_pilot_k3.gd` (пишет TP-3). Дополняет С1 (`docs/contracts/control-fix.md`) и С2/У2.

- `ControlInput` (`scripts/core/control_input.gd`) — новые поля: `throttle_axis: float` (∈ [−1; 1], W +1, S −1,
  обе/ни одной — 0), `engine_toggle: bool` (true ровно в одном `update` после нажатия), `brake: bool`. В режиме
  `"glider"` они всегда 0/false.
- `InputController` (`scripts/game/input_controller.gd`) — поле `vehicle: String` ∈ {`"glider"`, `"trike"`}, по
  умолчанию `"glider"` (поведение `"glider"` — **без изменений**, все существующие тесты ввода зелёные). В `"trike"`:
  - W/S (действия `throttle_up`/`throttle_down`) → `throttle_axis` на земле и в воздухе; `walk`, `run`, `look_up`,
    `look_down` от W/S не срабатывают; `ControlInput.walk` = 0, `run` = false (пилот сидит, разбега нет).
  - Пробел (`engine_toggle`) → `ControlInput.engine_toggle`.
  - На земле (`on_ground`) A/D → `ControlInput.turn` (руление носовым колесом; знак — как сейчас у `turn`:
    `turn_right − turn_left`); в воздухе A/D — взгляд влево/вправо, как в `"glider"`.
  - Тормоз (`trike_brake`) на земле → `brake`; в воздухе `brake` = false.
  - Штанга (мышь/джойстик → `pitch`, `roll`), `pull_full` (Shift в воздухе), X, C, V, Q, Tab, 1–5, R, Esc, M, F12 — как
    в `"glider"`.
  - Взгляд вверх/вниз в `"trike"` — действия `look_up`/`look_down` с клавишами без W/S (см. ниже).
- `configs/controls.json → keys` (с `_doc` у каждого): `throttle_up` `["W"]`, `throttle_down` `["S"]`,
  `engine_toggle` `["Space"]`, `trike_brake` `["Shift"]` (предложение до ответа пользователя), к `look_up`/`look_down`/
  `look_left`/`look_right` добавить `Up`/`Down`/`Left`/`Right` (предложение до ответа пользователя; в `"glider"` W/S/A/D
  остаются). `InputController.register_actions` регистрирует новые действия. Правка по ответу пользователя — только
  значения в `controls.json` (код от конкретных клавиш не зависит, кроме того, что W/S в `"trike"` — газ).
- Справка: `configs/ui.json → controls_help` — строки дельталёта (газ, двигатель, руление, тормоз) с ключами
  `locale/ui.csv` (`controls_trike_*`, ru и en).
- **Инварианты теста** (через `Input.action_press`/`action_release` и `InputController.update`): `"glider"` — W в воздухе
  даёт взгляд, не газ, `throttle_axis` 0; `"trike"` — W → `throttle_axis` +1, S → −1, W+S → 0, на земле `walk` 0 и
  `run` false; пробел → `engine_toggle` true один раз, при удержании дальше false; A на земле → `turn` < 0, в воздухе
  `turn` 0; тормоз на земле → `brake`, в воздухе — нет; все новые действия есть в `controls.json` с `_doc` и
  зарегистрированы (`InputMap.has_action`); у `engine_toggle` нет клавиш, занятых другими действиями (кроме
  `ui_accept` меню).
- v2 (2026-10-22, Q1, Q2, ревью TP-3). Заменяет пункты v1 о взгляде и Shift:
  - Q1: в `"trike"` взгляд — **только мышью** (правая кнопка в кабине, как сейчас, `CameraRig._mouse_looks`): клавишного
    взгляда нет — `InputController.keys_look()` в `"trike"` = false; A/D в воздухе ничего не делают (`turn` 0).
    Стрелки у `look_*` убрать: `look_up`/`look_down`/`look_left`/`look_right` — снова только W/S/A/D (как до TP-3),
    `tests/game/test_ui_controls_contracts.gd` — прежние ожидания. Правку общего `InputMap` по режиму
    (`_apply_look_keys`) убрать: режим не меняет привязки клавиш.
  - Q2: тормоз — Shift (`trike_brake`). В `"trike"` на земле Shift — только `brake` (`pull_full` = false, `run` =
    false); в воздухе Shift — `pull_full`, `brake` = false.
  - Инварианты теста v2: `"trike"` в воздухе — W/S/A/D/стрелки не дают взгляда (`keys_look()` false), W → газ;
    `"glider"` в воздухе — `keys_look()` true, W не газ; привязки `look_*` = W/S/A/D и не зависят от `vehicle`
    (переключение `vehicle` туда-обратно не меняет `InputMap`); Shift на земле в `"trike"` → `brake` true, `pull_full`
    false; в воздухе → `pull_full` true, `brake` false; тест проверяет версию раздела TP-К3.

## TP-К4 v2. Приборы: обороты и топливо
Владелец — TP-4. Потребители — TP-8 (монтаж в кабине и HUD в игре). Контрактный тест —
`tests/contracts/test_trike_pilot_k4.gd` (пишет TP-4).

- Общий вход обоих приборов: `update_readout(engine_rpm: float, fuel_l: float, tank_l: float, running: bool) -> void`
  (значения — из `TrikeEngine`, TP-К2; прибор от `TrikeEngine` не зависит).
- Шкалы — `configs/instruments.json → trike_gauges` (с `_doc`): тахометр `0…tachometer.max_rpm`, зелёная и красная зоны
  — из TP-К1 `tachometer` (до TP-1 — числа руководства Rotax 582: холостые ≈ 2000, макс. продолжительный 6500, взлётный
  6800, шкала до 8000; после TP-1 — читать `configs/trike_pilot.json`, свои копии чисел не держать); топливо `0…tank_l`
  (метки «E»/«F» или литры). Подписи — `locale/ui.csv` (`trike_rpm`, `trike_fuel`, ru/en).
- Стрелка: статическая `needle_angle_deg(value: float, v_min: float, v_max: float, a_min: float, a_max: float) -> float`
  — линейно, вне шкалы — упор. Один класс/функция для обоих приборов.
- 3D: `scenes/instruments/trike_gauges_3d.tscn` (корень `TrikeGauges3D`, `Node3D`, скрипт
  `scripts/instruments/trike_gauges_3d.gd`) — два круглых прибора рядом, лицом вдоль +Z корня (TP-8 ставит корень в
  маркер `InstrumentPanel` тележки, `basis.z` маркера = нормаль панели, TK-К1 v4), общий габарит ≤
  `tools/blender/trike_params.json panel.size`; стрелки — отдельные узлы `RpmNeedle`, `FuelNeedle` (поворот вокруг Z).
- HUD: `TrikeGaugesHud` (`scripts/ui/trike_gauges_hud.gd`, `CanvasLayer`, слой как у `ClockLabel`) — два прибора справа
  в колонке, где планшет `InstrumentOverlay` и `ClockLabel` (над часами или слева от планшета — на выбор исполнителя),
  статическая `anchor_px(win: Vector2, …) -> Vector2` по образцу `ClockLabel.anchor_px`. Видимость задаёт игра (TP-8):
  только в `"trike"` и при `camera.mode != "cockpit"`.
- **Инварианты теста:** `needle_angle_deg` — концы, середина, упоры; 3D-сцена грузится, есть `RpmNeedle` и
  `FuelNeedle`, после `update_readout(6800, …)` поворот `RpmNeedle` = `needle_angle_deg(6800, …)` ± 0,5°, габарит AABB ≤
  `panel.size` (+ 1 см); HUD: при окнах 1280×720, 1920×1080, 2560×1440 прямоугольник приборов внутри окна, не
  пересекает рамку `InstrumentOverlay` и `ClockLabel` (их `anchor_px`/параметры `configs/instruments.json → overlay`);
  `running` false → тахометр показывает фактические обороты (0 у заглушённого).
- v2 (2026-10-22, после TP-1): шкалы тахометра и бака — только из `configs/trike_pilot.json` (`tachometer`, `fuel.tank_l`);
  запасные копии этих чисел в `configs/instruments.json → trike_gauges` убрать (там — только вид: углы, размеры, цвета).
  Инвариант: шкала тахометра теста = `trike_pilot.json tachometer`, бак = `fuel.tank_l`.

## TP-К5 v1. Выбор старта «дельталёт»
Владелец — TP-5. Потребители — TP-6 (`Game` выбирает аппарат). Контрактный тест — `tests/contracts/test_trike_pilot_k5.gd`
(пишет TP-5).

- `FlightSettings` (`scripts/game/flight_settings.gd`): `var vehicle: String = "glider"` ∈ {`"glider"`, `"trike"`};
  сохраняется и читается вместе с прочими полями (как `tow_kind`); неизвестное значение → `"glider"`. При
  `vehicle == "trike"` — `tow_kind = ""`. `static func trike_allowed(site: Dictionary, multiplayer: bool) -> bool` —
  у места есть блок `tow` (как у `tow_kinds_for_site`) и не сеть.
- Меню (`FlightSetupScreen`, `scripts/ui/flight_setup_screen.gd`): в выборе буксировки (`_build_tow`) на местах с блоком
  `tow` — пункт «Дельталёт» (ключ `setup_start_trike`, ru/en) после видов буксировки; на местах без `tow` пункта нет;
  в сети (`GoalsTab.net_blocked()`) — выключен с подсказкой (как `setup_tow_mp_off`). Выбран — `settings.vehicle =
  "trike"`, `tow_kind = ""`; выбор крыла выключен (крыло дельталёта — TT-К2, выбирать нечего). Другой пункт —
  `"glider"`.
- CLI (`scripts/game/launch_options.gd`): `vehicle=trike` (как `tow`).
- `Game` до TP-6: `vehicle == "trike"` → обычный старт дельтапланом и `push_warning` (полёта дельталёта ещё нет);
  в сети или со стартом в воздухе — всегда `"glider"` (как `_choose_tow_start`).
- **Инварианты теста:** `trike_allowed` — true для места с `tow` без сети, false в сети и без `tow` (`wilotree_park` и
  место без буксировки из `configs/locations/`); `FlightSettings` с `vehicle "trike"` → после сохранения и чтения
  `"trike"`, `tow_kind` пуст; `"bogus"` → `"glider"`; `launch_options` `vehicle=trike` → `"trike"`.
