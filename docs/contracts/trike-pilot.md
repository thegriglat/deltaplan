---
type: contract
status: "active"
module: trike-pilot
area: flight
updated: "2026-10-22"
summary: "Стыки дельталёта игрока: двигатель (TP-К1, К2), ввод (К3), приборы (К4), старт (К5), дельталёт в игре (К6), колёса и посадка (К7)."
related: ["docs/plan/trike-pilot.md", "docs/contracts/trike-model.md", "docs/contracts/control-fix.md", "docs/contracts/pilot-view.md"]
contracts: [{"id": "TP-К1", "version": 3}, {"id": "TP-К2", "version": 1}, {"id": "TP-К3", "version": 2}, {"id": "TP-К4", "version": 2}, {"id": "TP-К5", "version": 1}, {"id": "TP-К6", "version": 2}, {"id": "TP-К7", "version": 2}, {"id": "TP-К8", "version": 1}, {"id": "TP-К9", "version": 1}]
---
# Контракты trike-pilot (код задач TP)

Правка интерфейса — только через координатора: версия +1, этот файл и контрактный тест — в том же шаге. Каждый
контрактный тест проверяет версию своего раздела по заголовку (шаблон — `tests/contracts/test_trike_model_k1.gd`:
`const DOC`, `const VERSION`, регулярка заголовка `^## (TP-К\d) v(\d+)\.`).

Форматы tow-trike (ещё не в `main`; читать в копии `~/deltaplan-tow-trike/docs/contracts/tow-trike.md`): TT-К1
(`configs/tow_tug.json`: `cart`, `engine`, `thrust`, `ground`, `wing`), TT-К3 (колёса в `PendulumModel`), TT-К4
(`TowTug`). До слияния код этого модуля их файлы не читает и не создаёт: числа TT-К1 — в тестовых словарях.

## TP-К1 v3. Эксплуатация двигателя — `configs/trike_pilot.json`
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
- v3 (2026-10-23, владелец блока — TP-7): блок `wheels` (руление и тормоз, TP-К7) с `_doc` у каждого числа:
  `wheelbase_m` (= `tools/blender/trike_params.json dims.wheelbase` ± 0,01), `steer_max_deg` (наибольший угол
  носового колеса), `lat_mu` (предел боковой силы шин на траве, доля веса), `brake_mu` (замедление тормозом, доля веса).
  Инвариант теста: ключи есть, числа > 0, `wheelbase_m` = `trike_params.json`; `steer_max_deg` ∈ (0; 60].

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

## TP-К6 v2. Дельталёт игрока в игре: `TrikeRig`, `Glider`, `Game`
Владелец — TP-6. Потребители — TP-8 (вид, камера, приборы), TP-9 (звук), `TowTug`. Контрактный тест —
`tests/contracts/test_trike_pilot_k6.gd` (пишет TP-6). Основание — решения пользователя пп. 1–3, 7–9, Q3, Q4.

**`TrikeRig`** (`scripts/flight/trike_rig.gd`, `class_name TrikeRig extends RefCounted`) — общая «тележка на подвеске»
буксировщика и игрока, вынесенная из `TowTug` (числа и поведение `TowTug` — **без изменений**: тесты `tow` зелёные).
- `static func model_params(cfg: Dictionary, cart_mass_kg: float) -> Dictionary` → `{wing, pilot, apparatus}` для
  `PendulumModel.setup` (как в `TowTug` сейчас: крыло `Config "wings/"+cfg.wing`, `pilot.mass_kg = cart_mass_kg` без
  ограничения `pilot_mass_min/max`, `apparatus` = `hang_length_m`, `pilot_cda_m2`, `arms_force_max_n` из `cart`).
- `static func apply_arms(model: PendulumModel, cfg: Dictionary) -> void` — ходы штанги `cart.arms_shift_*_m`.
- `setup(model: PendulumModel, cfg: Dictionary) -> void`; `cfg` — формат TT-К1 (`configs/tow_tug.json`).
- Вход: `thrust_n: float` (Н, ≥ 0, ставит владелец каждый шаг), `extra_pilot_force: Vector3`, `extra_hang_force: Vector3`
  (Н, мир; трос буксировщика). `ext_force(s: Dictionary) -> Dictionary` — функция для `model.set_external_force`
  (TW-К4): тяга на `pilot` вдоль оси тележки с наклоном `engine.thrust_tilt_deg` (как `TowTug._ext_force`) + extra.
- `refresh(dt: float) -> void` после шага модели; только чтение: `hang_pos`, `wing_basis`, `cart_basis` (TT-К4 v2: на
  колёсах по нормали земли и курсу, в воздухе по мачте, поворот ≤ 20°/с), `pilot_pos`, `agl_m` (низ колёс над землёй).

**`Glider`** (`scripts/flight/glider.gd`):
- `setup_trike(cfg: Dictionary, pilot_mass_kg: float, ops_cfg: Dictionary) -> void` — модель «Маятник» через
  `TrikeRig.model_params`; масса тележки = `cart.empty_mass_kg` + пилот (`pilot_mass_kg` ≤ 0 → `cart.pilot_mass_kg`) +
  топливо на старте (`TrikeEngine.fuel_mass_kg` после `reset`, TP-К1 `fuel.start_l`); расход топлива массу в полёте не
  меняет (граница модели, ≤ 40 кг из ≈ 325 кг). Создаёт `TrikeEngine` (TP-К2) из `cfg.engine`, `cfg.thrust`, `ops_cfg`.
- Только чтение: `is_trike() -> bool`, `trike: TrikeRig` (null у дельтаплана), `engine: TrikeEngine` (null у дельтаплана).
- `reset_on_wheels(pos: Vector3, heading_deg: float) -> void` — `model.reset_on_wheels(pos, heading_deg, wheels)`,
  `wheels` = `cfg.ground` + блок `ops_cfg.wheels` (TP-К1 v3, если есть) + `land_on_wheels: true` (TP-К7); двигатель —
  `engine.reset()` (заглушен, полный бак).
- `step(dt)` у дельталёта: `engine.step(dt, airspeed_ms, input.throttle_axis, input.engine_toggle)` (ввод — последний
  `set_input`), `trike.thrust_n = engine.thrust_n`, шаг модели, `trike.refresh(dt)`. У дельтаплана `step` — без изменений.
- Вид до TP-8 — как у дельтаплана с крылом `trike_ixess15` (временно).

**`Game`** (`scripts/game/game.gd`):
- `settings.vehicle == "trike"`, без сети и не старт в воздухе (TP-К5) → старт на полосе места буксировки (тот же
  `TowSite.check`, что у `_choose_tow_start`; начало полосы, курс полосы), без `TowSession`; `glider.setup_trike(Config
  "tow_tug", settings.pilot_mass_kg, Config "trike_pilot")`, `glider.reset_on_wheels(...)`; `input_controller.vehicle =
  "trike"`; заглушка TP-5 (`push_warning`) удаляется. «Ещё раз» (R) — снова `reset_on_wheels` в начале полосы.
- Конец полёта дельталёта: до первого отрыва — не заканчивается (стоит на колёсах сколько угодно); после посадки на
  колёса (TP-К7) — `"landed"`, когда путевая скорость < 0,5 м/с непрерывно ≥ 3 с (руление после посадки разрешено);
  столкновения — как у дельтаплана. У дельтаплана — без изменений.
- **Инварианты теста** (`Glider` в дереве без `Game` для физики; `Game` — по образцу `tests/game/test_tow_*`):
  (1) `TowTug` с `TrikeRig` — тесты `tow` зелёные, траектория `TowTug` за 20 с равна прежней (≤ 1 мм);
  (2) дельталёт на колёсах, двигатель заглушен, 10 с — неподвижен, `thrust_n` 0; (3) `engine_toggle` → через
  `start_s` холостые; (4) полный газ, штанга по простому регулятору (`pitch` 0 до 1,1·vs, затем «от себя» до отрыва,
  дальше скорость ≈ 1,3·vs) — отрыв на полосе ≤ `runway_length_m` места (610 м), набор в установившемся наборе > 0;
  числа (разбег, скорость отрыва, вертикальная, скорость горизонтального полёта на полном газе) — в отчёт;
  (5) `Game` с `vehicle "trike"` на `wilotree_park` — старт на колёсах на оси полосы, `input_controller.vehicle ==
  "trike"`, нет `TowSession`; `"glider"` — как раньше.
- v2 (2026-10-23, TP-19, `docs/research/trike-pilot/pitch-oscillation.md`; решение координатора 2026-10-23): тяга
  действует по оси винта, а не в ЦМ тележки. `configs/tow_tug.json cart.prop_axis_below_hang_m` (расстояние оси винта от
  подвески вдоль мачты, с `_doc`; сейчас оценка `tools/research/tow-trike/cart.py` ≈ 1,24 м). `TrikeRig.ext_force`
  делит силу тяги между `pilot` и `hang` по правилу рычага: доля на `pilot` `a = prop_axis_below_hang_m /
  cg_below_hang_m`, на `hang` — `1 − a` (то же направление); момент тяги относительно подвески = `T·prop_axis_below_hang_m`.
  Одна физика у игрока и буксировщика (через `TrikeRig`); инвариант (1) v1 «траектория `TowTug` равна прежней» снят —
  тесты `tow`/`tow_trike` должны пройти по своим порогам (числа набора/скорости — в отчёт). Режим «штанга от себя на
  упоре + полный газ» не ограничивается (слабое затухание у порога сваливания — граница модели, Gratton).
  **Инварианты v2:** (6) полный газ, штанга на упоре «на себя» (ход TT-8), толчок по скорости — отношение размахов
  скорости за период ≤ 0,6 (TP-19: 0,49), период 9–14 с; (7) газ 0 — как v1 в пределах 1 % по установившейся скорости
  (`a` не влияет без тяги); (8) сумма сил тяги на `pilot` и `hang` = `T` по модулю и направлению.

## TP-К7 v2. Колёса дельталёта: руление, тормоз, посадка (`PendulumModel`)
Владелец — TP-7. Потребитель — TP-6 (`Glider.reset_on_wheels`). Контрактный тест — `tests/contracts/test_trike_pilot_k7.gd`
(пишет TP-7). Дополняет TT-К3 v6 (`docs/contracts/tow-trike.md`); без новых ключей — TT-К3 **бит в бит** (тесты
`tow_trike`, `tow` зелёные). Основание — пп. 1, Q2, Q4 (касание и руление, аварии нет).

- `reset_on_wheels(pos, heading_deg, wheels)` — необязательные ключи `wheels`: `wheelbase_m`, `steer_max_deg`,
  `lat_mu`, `brake_mu` (TP-К1 v3), `land_on_wheels: bool`.
- Руление (есть `steer_max_deg`): на колёсах курс меняется: `dψ/dt = v·tan(turn·steer_max)/wheelbase` (`turn` —
  `ControlInput.turn` ∈ [−1; 1], +1 — вправо, курс по часовой), ограничение `|v·dψ/dt| ≤ lat_mu·g`; крыло и тележка
  поворачиваются вместе (курс крыла = курс связки); на месте (v = 0) не поворачивает; заднего хода нет.
- Тормоз (есть `brake_mu`): `ControlInput.brake` на колёсах — замедление `brake_mu·N/m` в добавок к качению, до 0, не
  назад.
- Посадка (`land_on_wheels` true): касание низом колёс после полёта → снова режим колёс (`phase()` = `"wheels"`,
  `on_wheels`), положение непрерывно, курс — текущий курс крыла, скорость — горизонтальная проекция на курс (боковая
  теряется — граница модели), вертикальная гасится; сигнал `landed(result)` (результат `PendulumTouchdown` с ключом
  `on_wheels: true`), **аварии нет** (`_crash_start` не вызывается при любой вертикальной скорости, Q4); пилот не встаёт на
  ноги. С колёс снова можно взлететь (то же правило отрыва, `took_off`).
- **Инварианты теста** (крыло `trike_ixess15`, тележка из `configs/tow_tug.json` через `TrikeRig.model_params`, если
  TP-6 ещё не влит — те же числа вручную): (1) без новых ключей — равенство с TT-К3 за 10 с на колёсах и при отрыве;
  (2) руление: v = 5 м/с, `turn` +1 — `dψ/dt` = формула ± 5 %, `turn` −1 — зеркально, v = 0 — курс не меняется;
  (3) v = 15 м/с, `turn` +1 — боковое ускорение ≤ `lat_mu·g` + 1 %; (4) тормоз с 10 м/с без тяги — остановка, путь =
  v²/(2·(`brake_mu`+`rolling_crr`)·g) ± 10 % (без аэродинамики допуск шире — в отчёт), скорость не уходит < 0;
  (5) планирование без тяги на скорости трима до касания — `"wheels"`, `landed` с `on_wheels`, путевая скорость в шаг
  касания меняется ≤ 0,5 м/с сверх потери боковой, затем с тормозом — остановка; (6) касание с вертикальной −4 м/с —
  `"wheels"`, не авария; (7) после посадки тяга 1500 Н на `pilot` и `pitch` +1 после 1,1·vs — снова отрыв;
  (8) смена штанги на колёсах −1 → +1 на `trike_ixess15` (открытый вопрос tow-trike: 0,177 м/с при пороге 0,15) —
  |Δv| ЦМ крыла за шаг измерить и записать в отчёт; > 0,15 — `TP-7 contract: …` с числами, порог не ослаблять.
- v2 (2026-10-23, отчёт TP-7). (а) Инвариант (2) — на v = 2 м/с (на 5 м/с при `steer_max_deg` 35° действует предел
  (3)); на 5 м/с — формула с пределом шин ± 5 %. (б) Штанга на колёсах при ключах `wheels` дельталёта (`steer_max_deg`
  задан): тангаж крыла следует за вводом **вторым порядком** (критическое затухание, постоянная времени `arms.tau`;
  угловая скорость крыла непрерывна) — ступенчатый ввод −1 → +1 даёт |Δv| ЦМ крыла за шаг ≤ 0,15 м/с (инвариант (8),
  было 0,256 при первом порядке); без новых ключей — первый порядок TT-К3 бит в бит (буксировщик не меняется; его
  открытый вопрос решает главная). (в) Касание: тангаж и крен крыла переходят к колёсному положению непрерывно (тем же
  вторым порядком), ≤ 1° за шаг; гашение вертикальной скорости в шаг касания — граница модели (удар шасси), число — в
  отчёт. (г) Числа `wheels` — со ссылками на источники; без источника — «оценка» с разбросом и обоснованием.
  Граница (ревью TP-7): на колёса возвращает только касание тележкой (`contact == "feet"` у `PendulumTouchdown`);
  касание крылом или килем — как у дельтаплана (авария), Q4 касается грубой посадки на колёса.

## TP-К8 v1. Вид, камера и приборы дельталёта игрока
Владелец — TP-8. Потребитель — игра. Контрактный тест — `tests/contracts/test_trike_pilot_k8.gd` (пишет TP-8). Основание —
пп. 5, 6, 9; TT-К5 (вид буксировщика), TK-К1 v4 (`InstrumentPanel`), TP-К4 (приборы), TP-К6 (`Glider.trike/engine`).

- `TowTrikeVisual` (`scripts/game/tow_trike_visual.gd`): новый `update_parts(hang_pos: Vector3, cart_basis: Basis,
  wing_basis: Basis, prop_rpm: float, throttle: float) -> void`; `update(tug: TowTug)` вызывает его (буксировщик — без
  изменений, тесты `tow` зелёные). Узлы: тележка `trike.glb` (`HangPoint` = `hang_pos`), крыло
  `glider_trike_ixess15.glb`, `pilot.glb` с `sit`, `prop_spin` `speed_scale = prop_rpm·prop_spin_period_s/60`.
- `Glider` дельталёта (`is_trike()`): вместо вида дельтаплана — `TowTrikeVisual` (`setup(engine_cfg, false)` — звук в
  TP-9), каждый кадр `update_parts(trike.hang_pos, trike.cart_basis, trike.wing_basis, engine.prop_rpm,
  engine.throttle)`. `get_marker("PilotHead")` — голова сидящего пилота (кость `Head` `pilot.glb` в `sit`),
  `get_marker("InstrumentPanel")` — маркер `trike.glb`; маркеры крыла дельтаплана (`InstrumentMount`, `VarioMount`) у
  дельталёта отсутствуют → `null`, `Game` их не монтирует (планшет в виде от третьего лица — `InstrumentOverlay` — как
  сейчас). У дельтаплана — без изменений.
- Приборы: `Game` у дельталёта ставит `TrikeGauges3D` (TP-К4) в `InstrumentPanel` и `TrikeGaugesHud`; каждый кадр
  `update_readout(engine.engine_rpm, engine.fuel_l, engine.tank_l, engine.running)` обоим; HUD виден только у дельталёта
  и при `camera.mode != "cockpit"`.
- Камера (п. 6): у дельталёта кабина — от головы сидящего пилота (`set_head(PilotHead)`), без смещения назад
  (`back_offset_m` «сидячей позы» не применяется: позади головы — двигатель и винт); тело пилота скрыто от кабинной камеры,
  как у дельтаплана; настройка позы глаз на дельталёт не влияет. `CameraRig._apply_body_mode/_follow_body`, рассчитанные
  на `GliderVisual`, у дельталёта пропускаются (уже безопасно).
- Поза: у дельталёта пилот всегда `sit` (`PilotAnimator` не переключает на `prone`/`run`/`flare`); фаза `"wheels"` —
  наземная (TP-6 временно считал её `flying` — вернуть, если влияет только на позу).
- **Инварианты теста** (`Game` или `Glider` в дереве, `vehicle "trike"`): у визуала есть `trike.glb`-тележка,
  `Propeller`, `AnimationPlayer` с `prop_spin` и `speed_scale` = `prop_rpm/60` ± 1 % (заглушен → 0); `pilot.glb` играет
  `sit`; `TrikeGauges3D` — потомок `InstrumentPanel`; HUD виден в `chase`, скрыт в `cockpit`; глаз кабинной камеры ≤
  0,15 м от `PilotHead`; `vehicle "glider"` — прежний вид и маркеры (тесты `pilot_hud`, `cockpit` зелёные).
- Уточнение (2026-10-23, после TP-9, TP-16): `TowTrikeVisual.setup` уже красит трубы/тросы `FrameMetal` (TP-16) — не
  дублировать. Звук игрока — `TowTrikeSound.setup_player(engine_cfg, Config "trike_pilot".sound)` у двигателя в виде
  дельталёта и каждый кадр `update_engine(engine.state, engine.prop_rpm, engine.throttle)` (TP-К9); у буксировщика —
  прежний `setup`/`update`.

## TP-К9 v1. Звук двигателя дельталёта игрока
Владелец — TP-9. Контрактный тест — `tests/contracts/test_trike_pilot_k9.gd` (пишет TP-9). Основание — п. 4 и уточнение
пользователя 2026-10-23: процедурный синтез, как TT-К5 (вспышки Rotax 582 `rpm_двигателя/60·2`, лопастная частота
`prop_rpm/60·prop_blades`, выхлоп), плавно от оборотов; генерации нейросетью нет.

- `TowTrikeSound` (`scripts/game/tow_trike_sound.gd`) — общий синтез; буксировщик — без изменений (тесты `tow`).
  Для игрока — тот же класс с настройками слышимости из кабины (громкость/затухание — параметры в `setup`, числа в
  `configs/trike_pilot.json → sound` с `_doc`), узел — потомок вида дельталёта у двигателя.
- Состояние двигателя (TP-К2): `"off"` — тишина (не играет); `"starting"`/`"stopping"` — звук идёт за `prop_rpm`
  (высота и громкость от оборотов, без скачков); `"running"` — от `prop_rpm` и `throttle`, как TT-К5.
- Плавность: высота (`pitch_scale`) и громкость меняются не быстрее, чем обороты (без щелчков при смене газа).
- Файлы для прослушивания (холостые, 50 %, полный газ, запуск, остановка) — WAV в
  `/home/greg/deltaplan/build/screenshots/trike-pilot/` (вне репозитория).
- **Инварианты теста:** `"off"` — не играет; после запуска — играет, `pitch_scale` монотонно растёт с `prop_rpm` и = TT-К5
  при тех же оборотах ± 1 %; изменение `pitch_scale` за кадр ≤ относительного изменения оборотов + 1 %; буксировщик —
  тест `tow_aerotow` (TT-К5) зелёный.
