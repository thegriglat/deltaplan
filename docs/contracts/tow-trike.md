---
type: "contract"
status: "active"
module: "tow-trike"
area: "flight"
updated: "2026-10-22"
summary: "Стыки буксировщика-дельталёта: параметры (tow_tug.json), крыло trike_ixess15, тележка в «Маятнике» (колёса, перегрузки), TowTug v4, вид."
related: ["docs/plan/tow-trike.md", "docs/contracts/tow.md", "docs/contracts/trike-model.md", "docs/contracts/pendulum.md"]
contracts: [{"id": "TT-К1", "version": 1}, {"id": "TT-К2", "version": 1}, {"id": "TT-К3", "version": 2}, {"id": "TT-К4", "version": 1}, {"id": "TT-К5", "version": 1}]
---
# Контракты модуля tow-trike (код задач TT)

Основание — решение пользователя 2026-10-22 (`.dpcli/dpcli plan tow-trike 3`). Мир игры: X восток, Y вверх, −Z север;
м, м/с, Н, с, если не сказано иное. Каждое число в конфигах — с ключом `<ключ>_doc`: источник (url/документ с
разделом) или «оценка: из чего». Подгонка под «нравится» запрещена.

## TT-К1 v1. Параметры буксировщика — `configs/tow_tug.json`
Владелец — TT-1 (блоки `cart`, `engine`, `thrust`, `ground`, `tow`, `away`, `wing`); TT-4 добавляет только блок
`autopilot` (коэффициенты регуляторов). Потребители — TT-2, TT-3 (тестовые числа), TT-4, TT-5. Контрактный тест —
`tests/contracts/test_tow_trike_k1.gd` (пишет TT-4).

- `"contract": "TT-К1 v1"`, `_doc` — что это, какие допущения, где расчёт (`docs/research/tow/trike-tug.md`).
- `wing`: строка — id крыла в `configs/wings/` (TT-К2): `"trike_ixess15"`.
- `cart` — тележка с пилотом как точечная масса «Маятника» (вместо пилота):
  `empty_mass_kg` (тележка дельталёта с Rotax 582 без крыла, сухая), `pilot_mass_kg`, `fuel_kg`, `mass_kg`
  (= сумма ± 0,5 кг; без крыла), `cg_below_hang_m` (расстояние ЦМ тележки с пилотом от точки подвески, вдоль мачты;
  идёт в `apparatus.hang_length_m`), `cda_m2` (лобовое сопротивление тележки с пилотом, м²; заменяет `pilot_cda_m2`),
  `arms_force_max_n` (предел силы на штанге у пилота дельталёта; заменяет 300 Н пилота дельтаплана),
  `tow_hook` `[x, y, z]` (точка крепления троса в осях `trike.glb`: от `HangPoint`, +Y вверх, нос −Z),
  `tow_hook_on` ∈ {`"pilot"`, `"hang"`} (куда в «Маятнике» прикладывать силу троса: тележка или крыло в точке подвески).
- `engine`: `name`, `gear_ratio`, `power_max_kw`, `prop_d_m`, `prop_blades` (int), `prop_rpm_idle`, `prop_rpm_max`
  (обороты винта, об/мин; совпадают с `tools/blender/trike_params.json` `dims.prop_rpm_idle/prop_rpm_max` ± 1 %),
  `thrust_tilt_deg` (ось тяги от продольной оси тележки, + нос вверх).
- `thrust`: таблица по воздушной скорости — `v_ms` (по возрастанию, от 0 до ≥ 30), `full_n`, `idle_n`, `rpm_full`
  (той же длины). Тяга `T(V, g) = idle_n(V) + g·(full_n(V) − idle_n(V))`, обороты винта
  `rpm(V, g) = prop_rpm_idle + g·(rpm_full(V) − prop_rpm_idle)`, `g` ∈ [0; 1] — газ; линейно по V, вне таблицы — крайние
  значения. `full_n(0)` — статическая тяга. Источник/расчёт — каждая строка (`_doc` на блок допустим).
- `ground` (колёса, TT-К3): `keel_angle_deg` (тангаж крыла на земле при нейтральной штанге), `rotate_deg` (добавка
  тангажа при полностью отданной штанге), `rolling_crr` (качение по траве), `wheel_base_agl_m` (высота ЦМ тележки над
  землёй на колёсах).
- `tow`: `tow_speed_kmh` (∈ [55; 65], решение пользователя), `slack_speed_ms`, `glider_hold_agl_m` (≈3, BHPA §2.7.6 E),
  `rotate_speed_kmh` (скорость отрыва буксировщика), `power_reduce_agl_m` (≈152, BHPA §2.7.6 E 2e), `climb_limit_ms`
  (≈3,05, там же), `circuit_start_agl_m`, `circuit_bank_deg` (≤ 10 на тросе 75 ± 5 м и длиннее, BHPA §2.7.6 E 2e5).
- `away` (после отцепа, BHPA §2.7.6 E g «снижает мощность и уходит прямо»): `throttle`, `turn_deg`, `turn_s`, `away_s`
  (через сколько игра убирает модель).
- `autopilot` (TT-4): коэффициенты и ограничения регуляторов; каждое — с `_doc` (из чего выбрано).
- **Инварианты теста:** все ключи выше есть и числовые (кроме строк), у каждого числа есть `_doc`; `thrust.*` одной длины,
  `v_ms` возрастает, `full_n ≥ idle_n ≥ 0`; `mass_kg` = сумма; обороты = `trike_params.json` ± 1 %; `wing` есть в
  `configs/wings/`; `tow_speed_kmh` ∈ [55; 65].

## TT-К2 v1. Крыло буксировщика — `configs/wings/trike_ixess15.json`, группа `tug`
Владелец — TT-2; потребители — TT-4, TT-5. Контрактный тест — `tests/contracts/test_tow_trike_k2.gd` (пишет TT-2).

- Крыло дельталёта по числам `tools/research/trike-model/wings.json` (Air Creation iXess 15) и расчётам TT-1
  (`docs/research/tow/trike-tug.md`), тем же путём, что крылья игры: конфиг `configs/wings/trike_ixess15.json` (формат
  крыльев игры, блок `pendulum` — `tools/flight/pendulum_params.py`), форма — `tools/blender/glider_params.json →
  wings.trike_ixess15`, модель `assets/models/glider_trike_ixess15.glb` — `tools/blender/build_gliders.py`. Чего нет в
  источниках — оценка с обоснованием в `_doc` (`wings.json` → «н/д»).
- Массы «пилота» — масса тележки с пилотом: `pilot_mass_min_kg`/`max_kg`/`ref_kg` по MTOW и пустой массе (TT-1).
- Группа `tug` в `configs/wing_groups.json` с признаком `"player": false`: крылья группы **не видны** игроку (выбор
  крыла, экран старта, `WingCatalog` для игрока) и **не берутся ботами** (явный список `configs/bots.json` и запасной
  «все крылья» в `remote_pilots.gd`, `bot_pilots.gd`). Прочие тесты крыльев (`tests/flight/test_wings.gd`,
  `tests/game/test_wing_models_contract.gd`, `test_wing_catalog.gd`, `test_polar.gd`, `test_wing_passports.gd`,
  контракты `pendulum_k2`, `wing_physics`, `wind_limits`) проходят и для этого крыла.
- **Инварианты теста:** конфиг и glb есть; группа `tug` с `player: false`; крыло не в списке крыльев игрока и ботов;
  площадь/размах/масса = `wings.json` iXess 15 (± 1 %); скорость сваливания поляры при `pilot_mass_ref_kg` и паспортная
  `vs_kmh` при MTOW согласованы через √(m/MTOW) (± 10 %).

## TT-К3 v2. Тележка в «Маятнике»: колёса, сопротивление, предел рук
Владелец — TT-3; потребители — TT-4. Контрактный тест — `tests/contracts/test_tow_trike_k3.gd` (пишет TT-3).

`PendulumModel` (`scripts/flight/pendulum/pendulum_model.gd`), `setup(wing_cfg, pilot_cfg, flight_override, apparatus_cfg)`:
- `apparatus_cfg` новые необязательные ключи: `pilot_cda_m2` (вместо глобального `pendulum.pilot_cda_m2`),
  `arms_force_max_n` (вместо `arms.force_max_n` 300 Н). Нет ключа — как до правки **бит в бит**.
- `reset_on_wheels(pos: Vector3, heading_deg: float, wheels: Dictionary) -> void` — дельталёт на колёсах;
  `wheels` = `{keel_angle_deg, rotate_deg, rolling_crr, wheel_base_agl_m}` (TT-К1 `ground`); `pos` — точка земли под ЦМ
  тележки. Тележка (узел ЦМ пилота) на высоте `wheel_base_agl_m` над землёй, точка подвески над ней на
  `hang_length_m` (мачта вертикальна в осях тележки), крен 0, курс `heading_deg`. Тангаж крыла
  `keel_angle_deg + max(0, pitch)·rotate_deg` (ввод `pitch` штанги; меняется с постоянной времени рук `arms.tau`),
  ввод `roll` на земле не действует. Связка движется вдоль курса (1 степень свободы): внешние силы (TW-К4: явные и
  звено — проекция на курс), аэродинамика крыла и тележки (`pilot_cda_m2`), вес, качение `rolling_crr·N`, уклон
  `terrain` из `ground_fn`. Можно сделать на основе `reset_on_dolly` (TW-К10), тележка уходит вместе с крылом.
  `phase()` = `"wheels"`; только чтение `on_wheels: bool`.
- Отрыв: `N ≤ 0` → режим полёта (`AIR`), сигнал `took_off`, состояние непрерывно (без скачка скорости и углов);
  дальше обычный «Маятник» с точечной массой тележки. Посадки на колёса нет (граница модели: буксировщик после отцепа
  не садится, его убирают через `away_s`).
- Без `reset_on_wheels` и новых ключей — существующие тесты `tests/flight/` и `tests/contracts/` зелёные.
- **Инварианты теста** (крыло — любое из `configs/wings/`, масса «пилота» 350 кг, `hang_length_m` 1,2, числа колёс —
  разумные тестовые): (1) без новых ключей позиция и скорость после 10 с полёта равны прежним (равенство);
  (2) `pilot_cda_m2` ×3 — установившаяся скорость при том же вводе ниже; (3) `arms_force_max_n` 2000 Н при 350 кг —
  полный ввод по крену даёт ≥ 90 % хода (установившееся за первую 1 с); при 300 Н — меньше; (4) на колёсах без сил
  10 с — неподвижно, конечно, `"wheels"`; (5) постоянная сила вперёд 1500 Н на `pilot`, `pitch` 0: разгон, `N > 0` до
  скорости, где подъёмная сила при `keel_angle_deg` равна весу; `pitch` +1 на скорости ≥ 1,1·vs (vs — из поляры при этой
  массе) — отрыв за ≤ 5 с без скачка скорости (|Δv| за шаг ≤ ускорение·dt + 0,05 м/с) и углов (≤ 1° за шаг).
- v2 (2026-10-22, ревью TT-3): уточнение (5). (5а) `pitch` 0 на всём разбеге (отдельный прогон, без `break` до
  отрыва): пока `N > 0`, подъёмная сила модели при `keel_angle_deg` (сама модель, не поляра) меньше веса; отрыв с
  `pitch` 0 — не раньше 0,95·`v_l`, где `v_l` — скорость равенства этой подъёмной силы весу. (5б) Непрерывность при
  отрыве — для **обоих тел**: тележки (узел ЦМ пилота) и ЦМ крыла: |Δv| за шаг ≤ 0,15 м/с (≈ 2 g·dt) на всём интервале
  1 с после отрыва, тангаж и крен крыла ≤ 1° за шаг. Скачок рук при отрыве (`arms.reset()` и т. п.) — артефакт, не
  физика: состояние рук на колёсах должно совпадать с тем, с которого продолжается полёт. Если остаток переходного
  процесса крыла физический (аэродинамический момент вне трима при данных `Iyy`) — числа момента и ускорения в отчёт,
  `TT-3 contract: …`, не ослаблять порог самому. (5в) После отрыва с колёс ложемента нет: `dolly_attached` = false,
  `dolly_pos/dolly_vel` не меняются (или не существуют для колёс), проверка касания земли не откладывается на 3 с —
  возобновляется, как только низ колёс (ЦМ тележки − `wheel_base_agl_m`) выше земли на 0,05 м.

## TT-К4 v1. Буксировщик-дельталёт: `TowTug` (заменяет TW-К9 v3)
Владелец — TT-4; потребители — TT-5 (игра: модели, звук). Контрактный тест — `tests/contracts/test_tow_k9.gd`
(переписывает TT-4 под эту версию). Основание — решение пользователя 2026-10-22 (п. 2, 3, 6), TT-К1, BHPA
(`docs/research/tow/kinds-bhpa.md#Аэробуксировка`).

- `class_name TowTug extends RefCounted` (`scripts/game/tow_tug.gd`) — **модель полёта**, не кинематика: внутри
  `PendulumModel` с крылом TT-К2 и тележкой TT-К1 (`pilot_cfg.mass_kg = cart.mass_kg`, `apparatus` —
  `hang_length_m = cart.cg_below_hang_m`, `pilot_cda_m2 = cart.cda_m2`, `arms_force_max_n = cart.arms_force_max_n`),
  тяга винта и сила троса — через `set_external_force` (TW-К4): тяга — на `pilot` (тележка), вдоль продольной оси
  тележки с наклоном `engine.thrust_tilt_deg`; продольная ось тележки — курс крыла, ортогонализованный к мачте
  (точка подвески → ЦМ тележки); сила троса — на `cart.tow_hook_on`.
- API: `setup(runway_start: Vector3, heading_deg: float, rope_length_m: float, terrain_height: Callable,
  cfg: Dictionary = {})` (`cfg` пустой → `configs/tow_tug.json`) — на колёсах (TT-К3) на оси полосы впереди начала на
  `rope_length_m` (по точке `tow_hook`); `set_air(fn: Callable)` — ветер, та же сигнатура, что `air_fn` у
  `PendulumModel.step` (нет — штиль); `start()` — по W; `set_rope_force(f: Vector3)` — сила троса на буксировщик
  (Н, мир; игра: `tension_n · (точка крепления на дельтаплане − pos).normalized()`; заменяет `set_rope_tension`);
  `release()` — отцеп/обрыв → `away`; `step(dt: float, glider_height_agl_m: float)`.
- Только чтение: `pos` (точка `tow_hook` в мире — конец троса), `vel` (её скорость), `hang_pos: Vector3` (точка
  подвески — начало `trike.glb`), `wing_basis: Basis` (оси крыла, как у `PendulumModel`), `cart_basis: Basis` (оси
  тележки: +Y — от ЦМ тележки к точке подвески, −Z — продольная ось вперёд), `basis` (= `cart_basis`), `phase` ∈
  {`idle`, `slack`, `roll`, `climb`, `circuit`, `away`}, `agl_m` (высота низа колёс над землёй), `gone`, `throttle`
  ∈ [0; 1], `prop_rpm` (TT-К1 `thrust`), `airspeed_ms`, `model: PendulumModel`.
- Автопилот (вход модели — `ControlInput.pitch/roll` и газ): `idle` — на колёсах, газ 0 (холостые); `slack` — руление
  малым газом со скоростью `slack_speed_ms` до натяжения > 0; `roll` — полный газ, штанга нейтральна, на колёсах, пока
  дельтаплан ниже `glider_hold_agl_m` или скорость ниже `rotate_speed_kmh`, затем отдаёт штангу → отрыв; `climb` —
  полный газ, тангаж штангой держит `tow_speed_kmh`, крыло без крена; выше `power_reduce_agl_m` газ снижается так, чтобы
  набор не превышал `climb_limit_ms`; `circuit` — с `circuit_start_agl_m` левые круги с креном `circuit_bank_deg`, скорость
  та же; `away` — газ `away.throttle`, поворот на `away.turn_deg` за `away.turn_s`, снижение, `gone` через `away.away_s`.
  Набор — результат физики (тяга, сопротивление, нагрузка троса), не задаётся.
- **Инварианты теста:** до `start()` неподвижен (|vel| < 0,01), `throttle` 0, `prop_rpm` = `prop_rpm_idle`; траектория
  непрерывна (|Δpos| ≤ |vel|·dt + 1 см); в `roll` `agl_m` < 0,05, пока `glider_height_agl_m` < `glider_hold_agl_m`;
  без троса (`set_rope_force` 0) отрывается и набирает; в `climb` с постоянной силой троса 300 Н назад-вниз 5° за
  последние 10 с из 30 воздушная скорость = `tow_speed_kmh` ± 3 км/ч и крен < 5°; в `circuit` крен =
  `circuit_bank_deg` ± 3°; после `release()` — `away`, `throttle` = `away.throttle`, `gone` через `away_s`.
- **Связка (шлюз модуля)** — `tests/game/test_tow_trike_climb.gd` (пишет TT-4): `Glider` `sport` в «Маятнике» на тележке
  (TW-К10), `TowLine` `aerotow` (TW-К5), `TowTug`, пилот держит тангаж простым регулятором (как TW-К4 инв. 10), без
  ветра, до 300 м: отрыв буксировщика (`agl_m` > 0,5) — не дальше `configs/tow.json aerotow.runway_length_m` от места
  старта; в наборе ниже `power_reduce_agl_m` (средние за ≥ 10 с после выхода на режим) воздушная скорость буксировщика ∈
  [55; 65] км/ч и вертикальная ≥ 2,54 м/с (BHPA §2.7.5 B, 500 фт/мин); натяжение < `weak_link_daN` (125 даН). Числа
  — в отчёт задачи; не выполнено — `TT-4 blocked: …` с числами, без подгонки (шлюз Q модуля).

## TT-К5 v1. Вид и звук буксировщика в игре
Владелец — TT-5; потребитель — игра. Контрактный тест — в `tests/game/test_tow_aerotow.gd` (`test_models`, правит TT-5).

- `TowSession` (`scripts/game/tow_session.gd`): узел буксировщика — `assets/models/trike/trike.glb` (начало —
  `HangPoint` = `tug.hang_pos`, поворот = `tug.cart_basis`) + крыло `assets/models/glider_trike_ixess15.glb` в точке
  подвески с `tug.wing_basis` (как модель крыла игрока относительно точки подвески) + `pilot.glb` в начале тележки,
  анимация `sit` (TK-К3). `AnimationPlayer` тележки: `prop_spin` играет всегда, `speed_scale = tug.prop_rpm ·
  prop_spin_period_s / 60` (TK-К1; `prop_spin_period_s` = 1,0).
- Звук двигателя — синтез (как `EggAn2.engine_sound`, своим кодом): основная частота — вспышки двухтактного
  двухцилиндрового двигателя `rpm_двигателя/60 · 2` (`rpm_двигателя = prop_rpm · gear_ratio`) плюс частота лопастей
  `prop_rpm/60 · prop_blades`; высота (`pitch_scale`) и громкость — от `prop_rpm`/`throttle`. Без Ан-2.
- Ан-2 в буксировке нет: `EggAn2` не используется в `tow_session.gd`, `tow_tug.gd`, `configs/tow_tug.json`,
  `tests/game/test_tow_*`; `EggAn2` остаётся пасхалкой (`configs/easter_eggs.json eggs.an2`, её тесты не меняются).
- Конец троса у буксировщика — `tug.pos` (`tow_hook`); дрог и трос — как в TW-К5/TW-К8.
- **Инварианты теста:** в узле буксировщика есть `Propeller` и `AnimationPlayer` с `prop_spin`, играющей;
  `speed_scale` = `prop_rpm/60` ± 1 % в `idle` и `climb`; конец троса = `tug.pos` (± 1 см); в узле нет `EggAn2`.
