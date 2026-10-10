---
type: contract
status: active
module: pendulum
updated: 2026-10-11
summary: "Контракты модуля pendulum: поверхность модели полёта «Маятник» для Glider (PD-К1), конфиг маятника и блок pendulum в крыльях (PD-К2), настройки «Аппарат» (PD-К3), сеть — режим и положение пилота (PD-К4), поза пилота в визуале и у чужих (PD-К5)."
related: ["docs/plan/pendulum.md", "docs/research/pendulum.md", "docs/contracts/control-bar.md", "docs/contracts/motion-rig.md"]
contracts: [{"id": "PD-К1", "version": 2}, {"id": "PD-К2", "version": 3}, {"id": "PD-К3", "version": 2}, {"id": "PD-К4", "version": 1}, {"id": "PD-К5", "version": 2}]
---
# Контракты модуля pendulum

План — `docs/plan/pendulum.md`, числа — `docs/research/pendulum.md`, эталон — прототип `tools/research/pendulum/` (Python). Менять — только через координатора: версия +1, что изменилось, уведомить потребителей, их правка в том же шаге. Контрактные тесты — у владельца, отдельным файлом на контракт: `tests/contracts/test_pendulum_contracts_k<n>.gd` (проверяют заголовок «## PD-К<n>. … (v<версия>)» этого файла и форму данных).

Оси игры: X — восток, Y — вверх, −Z — север; оси крыла (Glider) — −Z вперёд по килю, +Y вверх, +X вправо; `Telemetry.basis = Basis.from_euler(Vector3(theta, -heading, -bank))`. Оси конфига крыла (PD-К2) — «оси киля»: `x` — назад вдоль киля от носового узла, м; `z` — вверх перпендикулярно килю в плоскости симметрии, м.

Не меняются: CB-К1/К2 (control-bar), MR-К1 v1 (motion-rig — маятник только заполняет `pilot_*`), `ControlInput`, `FlightModel`, `GroundRun`, `LandingFlare`, `LandingJudge` (пороги), боты.

## PD-К1. Поверхность модели полёта «Маятник» (v2)
v2 (11.10, PD-3): земля маятника — `reset_on_ground`, фазы на земле, взлёт и посадка из сил; `run`/`walk`/`turn` читаются; `flare_amount` — по выравниванию у земли; принудительный старт в воздухе в режиме «Маятник» (`Glider`, `Game`) убирается.
Владелец — PD-2 (ядро), PD-3 (земля, v2); потребители — PD-4 (`Glider`, телеметрия, автопилот), PD-6 (визуал, камера), PD-7 (сеть), PD-8.

`class_name PendulumModel extends RefCounted` — `scripts/flight/pendulum/pendulum_model.gd`. Та же поверхность, что у `FlightModel` для пилота-человека (что читают `Glider`, `Game`, `GliderVisual`, `FlightTelemetry`):

| Член | Тип, единицы | Смысл |
|---|---|---|
| `signal took_off`, `signal landed(result: Dictionary)`, `signal takeoff_failed(reason: String)` | | как у `FlightModel`; `result` — `LandingJudge.evaluate` + `position`, `flight_time_s` |
| `mode` | `FlightModel.Mode` (GROUND 0, AIR 1, LANDED 2, FAILED 3) | своего enum не заводить |
| `telemetry` | `Telemetry` | заполняется в конце каждого `step`/`reset_*`/`set_kinematic`, смысл полей — как у `FlightModel` (можно через `FlightTelemetry.fill`, тип параметра которого PD-4 делает нетипизированным) |
| `load` | `LoadMeter` | перегрузка пилота: \|сила стропы + сила рук\| / (m_п·g) через `load.update(...)` |
| `landing_result`, `takeoff_failure` | `Dictionary`, `String` | как у `FlightModel` |
| `wing`, `pilot`, `flight` | `Dictionary` | конфиг крыла, `pilot.json`, `flight.json` + override — как у `FlightModel` |
| `pendulum`, `apparatus` | `Dictionary` | `configs/pendulum.json` (PD-К2) и настройки «Аппарат» (PD-К3, пропуски — умолчания из `pendulum.apparatus_defaults`) |
| `pilot_mass`, `mass`, `area`, `span` | кг, кг, м², м | как у `FlightModel` (`mass` — пилот + крыло) |
| `position` | Vector3, м | начало узла `Glider`, жёстко связанное с крылом: `hang_position − basis·Vector3(0, flight.visual.hang_height_m, 0)` (`basis` — `telemetry.basis`); тогда HangPoint визуала совпадает с подвеской физики |
| `velocity` | Vector3, м/с | скорость точки `position` относительно земли |
| `heading`, `bank`, `theta` | рад | ориентация крыла (курс — направление киля, 0 — север, по часовой; крен + вправо; тангаж киля) — по ним строится `telemetry.basis` |
| `roll_rate` | рад/с | угловая скорость крыла по крену (+ вправо) |
| `alpha` | рад | угол атаки киля в центре крыла |
| `stalled` | bool | сорвана середина крыла (полосы у корня) |
| `time_s` | с | время модели |
| `hang_position` | Vector3, м | точка подвески на киле (мир) |
| `pilot_position`, `pilot_velocity` | Vector3, м, м/с | ЦМ пилота (последний узел цепи), мир |
| `pilot_basis` | Basis | оси пилота: оси крыла, повёрнутые кратчайшим поворотом так, что +Y — вдоль последнего звена от пилота к подвеске |
| `pilot_rel` | Vector3, м | `pilot_position − hang_position` в осях крыла (`basis.inverse()`) — для визуала и сети |
| `head_position` | Vector3, м | голова: ЦМ пилота + 0,75 м вперёд по `pilot_basis` (−Z) + 0,15 м к подвеске (+Y) (R9) |
| `bar_force` | Vector3, Н | сила рук на пилота (мир) |
| `strap_tension` | float, Н | натяжение верхнего звена (≥ 0) |
| `setup(wing_cfg, pilot_cfg, flight_override := {}, apparatus := {})` | | масса пилота уже ограничена `FlightModel.clamp_pilot_mass` (делает `Glider`) |
| `reset_in_air(pos, heading_deg, airspeed_ms := 0.0, wind := Vector3.ZERO)` | | `pos` — смысл `position`; установившееся планирование на триме (или `airspeed_ms`), пилот висит в равновесии, ω = 0, рыскание — по потоку |
| `reset_on_ground(pos, heading_deg)` | | v2 — абзац «Земля (v2)» ниже |
| `step(dt, input: ControlInput, air_fn: Callable, ground_fn: Callable)` | | `dt` любой из 1/240…1/30 с; подшагов XPBD — `max(substeps_min, ceil(dt·substeps_per_s))`; `air_fn(p: Vector3) -> Vector3` (ветер, м/с) — в точке каждой полосы и пилота; `ground_fn(x, z) -> float` |
| `phase() -> String` | | значения `Telemetry.phase` |
| `flare_amount() -> float`, `stall_amount() -> float` | 0…1 | `flare_amount` — доля «от себя» у земли (v2), иначе 0; `stall_amount` — доля сорванных полос |
| `set_kinematic(pos, vel, heading, bank, theta)` | | для буксира NET-42: крыло жёстко в заданное положение, пилот — в равновесии под подвеской, ω = 0, `mode = AIR` |

Ввод (`ControlInput`, без изменений): `roll` −1…1 → целевое положение пилота поперёк штанги `roll·arms.shift_y_max_m` (+ вправо); `pitch` +1 («от себя») → пилот назад на `arms.shift_x_push_m`, −1 («на себя») → вперёд на `arms.shift_x_pull_m`; `weight_shift` не читается; `run`, `walk`, `turn` — на земле (v2).

Земля (v2, владелец PD-3; R6 плана): `reset_on_ground(pos, heading_deg)` — `pos` в смысле `position` (узел `Glider`: на земле — у ступней стоящего пилота, как у `FlightModel`), пилот стоит, крыло на руках (стойки у плеч, нос — `wing.launch.alpha_neutral_deg`), `mode = GROUND`. На земле: ноги — пружина-демпфер (только толкают), ходьба/бег по `input.walk`/`input.run`/`input.turn` (бег F(1 − v/v_ног), числа `pilot.json → walk/run`), руки держат стойки (опора под ЦМ крыла; тангаж — `input.pitch`, момент до 300 Н·м; крен — `input.roll`, до 200 Н·м × доля веса на ногах), стропа провисает. `phase()` — standing/walking/running/flying/landed/failed. Отрыв — ступни перестали касаться земли под нагрузкой стропы (из сил, без порога скорости) → `mode = AIR`, `took_off`; руки на штангу через `flight.takeoff.upright_clear_m`/1 с после отрыва. Срыв разбега — крыло (нос, консоль, киль) коснулось земли или пилот упал → `mode = FAILED`, `takeoff_failed(reason)` с причинами как у `FlightModel` (`flight_model.gd`). Посадка: выравнивание — «от себя» (пилот назад), `flare_amount()` — доля «от себя» у земли (0…1); касание — ступни пилота (ЦМ − 1,0 м по +Y `pilot_basis`) у земли → `LandingJudge.evaluate` по скорости ступней (пороги не меняются) → `mode = LANDED`, `landed`; консоль/нос в землю до касания ногами — авария (`grade = "crash"`). Контакт крыла с землёй — точки нос, концы консолей, задний конец киля.

Члены `PendulumModel` вне этой таблицы (`arms_relaxed`, `hands_force_y`, `aero_hz`, `wing_basis()`, `solve_trim()`, `glide_balance()`) — служебные для тестов и PD-8, потребители на них не опираются.

Инварианты: нет NaN при `dt` 1/30…1/240; в штиле с руками в нейтрали после `reset_in_air` скорость и снижение — трим и поляра крыла (числа прототипа, ±15 %); телеметрия `pilot_*` — из маятника (MR-К1).

Выбор модели (PD-4): `Glider.setup(wing_id, pilot_mass, apparatus := {})` читает `controls.roll_control_mode`; `"pendulum"` → `PendulumModel`, иначе `FlightModel` (как сейчас); `Glider.model` — без статического типа. Боты, `BotAgent`, `remote_pilots` — только `FlightModel`.

## PD-К2. Конфиг маятника и блок pendulum в крыльях (v3)
v3 (11.10, ответы пилота): + `apparatus_defaults` в блоке крыла — умолчания «Аппарата» по классу крыла (офлайн-скрипт); `contract` блока — `"PD-К2 v3"`.
v2 (11.10, PD-2): + `strips.aero_hz` — частота пересчёта сил полос и выборки ветра; между пересчётами сила и момент полос заморожены в осях крыла, цепь и руки — на каждом подшаге.
Владелец — PD-1; потребители — PD-2, PD-3, PD-5, PD-8.

**`configs/pendulum.json`** (общие числа; у каждого ключа — `<ключ>_doc` по образцу `configs/wings`; значения — `tools/research/pendulum/pendulum/params.py`):

| Ключ | Тип, единицы | Умолчание |
|---|---|---|
| `contract` | `"PD-К2 v2"` | |
| `chain.links` | int | 3 |
| `chain.strap_mass_kg` | кг (на промежуточные узлы) | 1,0 |
| `chain.compliance_m_per_n` | м/Н | 4e-5 |
| `chain.substeps_per_s`, `chain.substeps_min` | 1/с, int | 480, 4 |
| `arms.force_max_n`, `arms.tau_s`, `arms.ti_s` | Н, с, с | 300, 0,30, 0,6 |
| `arms.shift_y_max_m`, `arms.shift_x_pull_m`, `arms.shift_x_push_m` | м | 0,45, 0,45, 0,30 |
| `strips.count`, `strips.cp_chord` | int (чётное), доля хорды | 16, 0,25 |
| `strips.aero_hz` | Гц (≤ 0 — на каждом подшаге, как прототип) | 60 |
| `yaw.cn_beta`, `yaw.fin_arm_m`, `yaw.fin_slope_per_rad` | 1/рад, м, 1/рад | 0,06, 1,6, 2,0 |
| `pilot_cda_m2` | м² | 0,21 |
| `apparent_roll` | bool | true |
| `billow_shift_deg` | ° | 0 |
| `head.forward_m`, `head.up_m` | м | 0,75, 0,15 |
| `apparatus_defaults` | словарь ключей PD-К3 | см. PD-К3 |

`ground.*` (v3) — числа земли маятника (ноги, бег, сцепление, руки на стойках, отрыв), владелец PD-3, ключи и `_doc` — в самом файле; `contract` файла — `"PD-К2 v3"`.

**`configs/wings/<id>.json → pendulum`** — во всех 48 крыльях; пишет только офлайн-скрипт `tools/flight/pendulum_params.py` (порт `params.py`/`geometry.py`/`trim.py` прототипа; источник геометрии — `tools/blender/glider_params.json` + сам конфиг); в рантайме не пересчитывается. Оси — «оси киля» (выше).

| Ключ | Тип, единицы | Смысл |
|---|---|---|
| `contract` | `"PD-К2 v1"` | |
| `_doc` | строка | «генерирует tools/flight/pendulum_params.py, руками не править» |
| `sweep_deg` | ° | стреловидность передней кромки = 90° − угол носа/2 |
| `root_chord_m`, `tip_chord_m` | м | трапеция (площадь полос = `area_m2`, масштаб — `chord_scale`) |
| `washout_deg` | ° | крутка корень→конец, линейно |
| `keel_len_m`, `crossbar_from_nose_m` | м | |
| `hang_from_nose_m` | м | подвеска игры (ЦМ труб − 1,5 см, AF) — паспортная точка, `hang_shift_cm = 0` |
| `bar_x_from_nose_m`, `bar_z_m` | м | середина базовой штанги (z < 0 — ниже киля) |
| `cg_x_from_nose_m`, `cg_z_m` | м | ЦМ крыла (трубы + парус) |
| `inertia_kgm2` | `{ixx, iyy, izz, ixz}`, кг·м² | инерция крыла около его ЦМ, оси x — вперёд, y — вправо, z — вниз (аэродинамические); `ixz` — элемент тензора I[0][2] = −Σ m·x·z (как `geometry.mass_model` прототипа), не произведение инерции; **без** присоединённой массы (её считает модель от ρ) |
| `dcm0` | безразм. | момент паруса под паспортный трим при `hang_from_nose_m` и эталонной массе |
| `cd_scale` | безразм. | множитель сопротивления полос: снижение на триме = поляре |
| `apparatus_defaults` | `{dihedral_eff_deg, sail_flex}` | умолчания «Аппарата» этого крыла по классу (учебные — устойчивая спираль, жёстче; безмачтовые — нейтральная спираль); `ref` посчитан при них |
| `ref` | словарь, справочно | `trim_kmh`, `sink_ms`, `alpha_trim_deg`, `neutral_point_from_nose_m`, `static_margin`, `kmh_per_cm_hang` (сдвиг подвески на 1 см вперёд) — для тестов и PD-5 |

Инварианты (тест PD-К2, все 48 крыльев): все ключи есть, числа конечны; `root_chord_m > tip_chord_m > 0`; 0 < `static_margin` < 0,4; `|ref.trim_kmh − trim_speed_kmh| ≤ 0,3`; `ref.sink_ms` = поляра на триме ±0,02 м/с; `inertia_kgm2.ixx, iyy, izz > 0`.

## PD-К3. Настройки «Аппарат» (v2)
v2 (11.10): настройки — у каждого крыла свои; умолчания — по крылу (PD-К2 v3).
Владелец — PD-5 (v1), PD-13 (v2); потребители — PD-4 (`Game` → `Glider.setup(…, apparatus)`), PD-2 (`PendulumModel.setup`).

Хранение — `FlightSettings.apparatus: Dictionary` = `{wing_id: {ключ: значение}}` — только то, что пилот менял (`to_dict`/`from_dict` → `user://last_flight.json`). `FlightSettings.resolved_apparatus(wing_id) -> Dictionary` — все 4 ключа: пилот → `configs/wings/<id>.json → pendulum.apparatus_defaults` → `configs/pendulum.json → apparatus_defaults`; `Game` передаёт в `Glider.setup` именно его. Экран «Аппарат» показывает значения выбранного крыла (при смене крыла — его значения).

| Ключ | Единицы | Диапазон, шаг | Умолчание | Подпись в UI | Смысл в модели |
|---|---|---|---|---|---|
| `hang_shift_cm` | см | −4…+4, 0,5 | 0 | «Подвеска вдоль киля» | + — вперёд (к носу): подвеска = `hang_from_nose_m − hang_shift_cm/100`; трим быстрее |
| `hang_length_m` | м | 1,0…1,4, 0,05 | 1,2 | «Длина подвески» | подвеска → ЦМ пилота, сумма звеньев |
| `sail_flex` | безразм. | 0,1…1,0, 0,05 | 0,2 (крыло — своё) | «Гибкость паруса» | `flex_relief` (1 — жёсткое) |
| `dihedral_eff_deg` | ° | −2…+6, 0,5 | 1 (крыло — своё) | «Поперечное V» | эффективное поперечное V полос |

UI: экран «Полёт…» (`scripts/ui/flight_setup_screen.gd`) делится на вкладки «Место» и «Аппарат» (в «Аппарат» — класс и модель крыла, масса пилота, эти 4 ползунка). У всех четырёх — подпись «Важно только при режиме управления «Маятник»». Строки — `locale/ui.csv`.

## PD-К4. Сеть: режим управления и положение пилота (v1)
Владелец — PD-7; потребители — `remote_pilots.gd`, PD-6 (поза чужих пилотов).

`server/proto/deltaplan/v1/net.proto`, `PilotState`: `ControlMode control_mode = 11;` (`enum ControlMode { CONTROL_MODE_UNSPECIFIED = 0; CONTROL_MODE_RATE = 1; CONTROL_MODE_WEIGHT_SHIFT = 2; CONTROL_MODE_PENDULUM = 3; }`), `Vec3 pilot_rel = 12;` (= `PendulumModel.pilot_rel`, оси крыла, м, округление 1 см; только при PENDULUM). JSON-ключи `net_messages.gd` — `controlMode`, `pilotRel` (оба nullable). Нет поля — поза по вводу, как сейчас. Прирост `PilotState` ≤ 16 байт.

## PD-К5. Поза пилота в визуале и у чужих пилотов (v2)
v2 (11.10, PD-3): на земле узел `Glider` (формула `position` PD-К1) стоит на 0,2–0,3 м выше и впереди ступней (подвеска физики выше ступней на ≈ 2,2 м, у визуала — `hang_height_m`), поэтому стоящий пилот рисуется ступнями в `pilot_position − 1,0 м·pilot_basis.y` (в осях узла), а не от начала узла.
Владелец — PD-6 (`GliderVisual`, `BotGlider`, камера); поставщики данных — PD-К1 (`pilot_rel`, `pilot_basis`, `head_position`), PD-7 (`BotAgent.pilot_rel`).

- `GliderVisual.set_hang_pose(pilot_rel: Vector3, on_ground: bool, dt: float)` — поза пилота по маятнику: тело висит вдоль направления HangPoint → пилот (`pilot_rel`, оси крыла = оси узла `Glider`, м), без сглаживания (решение 5); на земле — стоит, ступни — в `pilot_position − 1,0 м·pilot_basis.y` (v2). Режимы «Смещение веса»/«Упрощённый» — прежний `set_pose(roll, pitch, …)` без изменений.
- `Glider._update_pilot`: при `is_pendulum()` → `visual.set_hang_pose(model.pilot_rel, …)`; маркер `PilotHead` следует за телом, так что `head_position` модели и маркер совпадают в пределах 3 см; камера «из глаз» в «Маятнике» не добавляет `head_follow_body` и сглаживание поверх физики.
- Чужие пилоты: `BotAgent.pilot_rel: Vector3`, `BotAgent.pilot_rel_valid: bool` (по умолчанию false) — пишет `remote_pilots.gd` из `PilotState.pilot_rel` (PD-7); `BotGlider` при `pilot_rel_valid` вызывает `set_hang_pose`, иначе — прежняя поза по вводу. Боты (`pilot_rel_valid = false`) не меняются.
