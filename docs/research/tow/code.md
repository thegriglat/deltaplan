---
type: research
status: active
module: tow
area: flight
updated: 2026-10-21
summary: "Трос — внешняя сила в PendulumModel._substep (на пилота и/или крыло с моментом); равнина — по height_at; Волжского в местах нет."
conclusion: "Силу троса добавлять в _substep до расчёта load_b (рук), иначе пилот «уедет» с нейтрали; равнину задавать через новый TowSite; старт — start_sites + launch_options."
data: []
applied_in: []
related: ["docs/plan/tow.md", "docs/contracts/tow.md", "docs/contracts/pendulum.md", "docs/research/pendulum/takeoff-ground.md", "docs/guide/flight.md", "docs/guide/game.md"]
---
# Буксировка: что есть в коде (TW-К2)

Ссылки `путь:строка` — на ветку `feature/tow` (копия TW-2, код не менялся). Прогонов нет, только чтение кода.
Решение пользователя 2026-10-21: трос — **внешняя сила** в точке с моментом, управление пилота сохраняется,
кинематики нет. Числа силы/длины/натяжения — из `kinds.md` (TW-1); здесь только то, что нужно коду.

Коротко: по умолчанию летит `PendulumModel` (`scripts/flight/glider.gd:76-80`), `FlightModel` — только при
`controls.roll_control_mode` = `weight_shift`/`rate` и у ботов (`scripts/game/bot_agent.gd:22`).
Внешней силы нет ни в одной из моделей; единственный «буксир» в игре — кинематический «Догнать».

## Старт и разбег

**Цепочка запуска.** `Game._choose_start()` (`scripts/game/game.gd:1461`) выбирает `_start_pos`/`_start_heading`:
точный старт (`settings.has_exact_start()`, проверка `StartSpot.check`, `game.gd:1464-1472`) → точка с карты
(`settings.has_pick()`, `StartPlacement.evaluate`, `game.gd:1473-1481`) → `terrain.get_start_sites()` (`game.gd:1483-1493`).
Затем `Game.restart()` (`game.gd:772`) ставит пилота: `glider.reset_in_air(...)` при `--air-start`
(`game.gd:787`), в сети — `net.queue_start_spot()` (`game.gd:789-790`), иначе `glider.reset_on_ground(_start_pos, _start_heading)`
(`game.gd:792`). `Glider.reset_on_ground` берёт высоту из `ground_fn` (`scripts/flight/glider.gd:102-106`).
Курс по ветру: `_align_start_heading()` (`game.gd:821`) — только при `wind_into_launch`, без точного старта и вне сети;
поворачивает курс к среднему ветру у старта (зонд ±15 м, `start_wind_align`).

**Старт на земле — PendulumModel.** `reset_on_ground` (`scripts/flight/pendulum/pendulum_model.gd:362`) ставит
`mode = GROUND`, `_uprights = true`: руки на стойках, ступни на пружине-демпфере `PendulumGround.legs`
(`pendulum_ground.gd:247`), хват — `grip_force` (`pendulum_ground.gd:296`, предел `grip_force_max_n` 600 Н,
вниз — `grip_down_max_n` 100 Н, `pendulum_model.gd:49`). Бег: сила ног `run_force` 420 Н, предел `run_vmax` 6,5 м/с
(`pendulum_ground.gd:44-45`, `configs/pilot.json` → `run`); сцепление ограничено `mu·N`, `mu = 0,8`
(`pendulum_ground.gd:28`), то есть при `m_пилота = 85 кг` (`configs/pilot.json:3`) ≈ 0,8·834 Н ≈ 670 Н на ровном
месте при полном весе на ногах. Бег идёт **по нормали склона**, вдоль склона — только сила бега и составляющие
аэродинамики (`pendulum_ground.gd:260-275`); на ровной земле скатывающей силы нет — разгон только ногами (420 Н,
эталон 15°/штиль — отрыв 11,7–15,9 м, `docs/research/pendulum/takeoff-ground.md`). Для равнины разгон придёт
от троса, а не от склона.

**Фазы и отрыв.** `_check_ground` (`pendulum_model.gd:555-575`): срыв `fell` (ЦМ ниже `fell_cm_height_m` 0,5 м,
`pendulum_model.gd:566`), касание крылом (`_wing_contact`, только после `flight_position_started`), отрыв
`took_off` — когда ступни выше `liftoff_feet_clear_m` 0,05 м и натяжение верхнего звена подвески
`_tension_avg > liftoff_strap_fraction(0,25)·m_пилота·g` (`pendulum_model.gd:570-575`, параметры
`pendulum_model.gd:52,304-306`). Дальше `_check_after_liftoff` (`pendulum_model.gd:577-592`): руки на стойках ещё
`bar_after_liftoff_s` = 1 с или пока ступни не выше `upright_clear_m` 1,0 м (`configs/flight.json:46`), потом
`_uprights = false`, руки на штанге, `start_flight_position()` (`pendulum_model.gd:352`). Касание ногами в
полёте — `_check_touchdown` (`pendulum_model.gd:977`).

**FlightModel (легаси и боты).** `reset_on_ground` → `_stand_on_ground` (`scripts/flight/flight_model.gd:153-166`);
шаг на земле — `GroundRun.step` (`scripts/flight/ground_run.gd:62`): `_move` (`ground_run.gd:282`) считает
`_speed += (f_run + f_along)/m·dt`, где `f_along = aero·dir3 − weight·dir3.y` (скатывающая сила от склона — только
здесь). Отрыв: `aero.y ≥ weight·liftoff_lift_fraction` (`ground_run.gd:97`), срыв — `_check_failures`
(`ground_run.gd:327`). В воздухе — точечная масса (`flight_model.gd:367-432`): сумма сил
`lift_dir·q·CL − u·q·CD + вес` (`flight_model.gd:393`), `velocity += force/mass·dt` (`flight_model.gd:398`).

**Выводы для троса.** (1) Старт на ровном поле = разбег с тросом, который тянет по горизонтали/под малым углом;
механики «разгон без склона» в `PendulumModel` хватает (бег + внешняя сила). (2) Критерий отрыва в
`_check_ground` зависит от натяжения *подвески*, не от аэродинамики напрямую — это работает и с тросом
(трос поднимает крыло → подвеска нагружается). (3) Курс разбега задаёт `ground.heading_cmd`
(`pendulum_model.gd:387`) = курс старта; буксир идёт по оси полосы → курс старта = ось полосы, а не «вниз
по склону» (`StartPlacement.evaluate` на ровном возвращает север, `scripts/game/start_placement.gd:17`).

## Внешняя сила в модели полёта

### PendulumModel (основная)

**Что интегрируется.** Внутри — NED с локальным началом, пересчитываемым в ЦМ крыла каждый шаг
(`_recentre`, `pendulum_model.gd:930`); наружу — оси игры (X восток, Y вверх, −Z север), преобразования
`ned()`/`game()` (`pendulum_model.gd:195-201`). Шаг физики 120 Гц (`project.godot`), в нём
`n = max(substeps_min=4, ceil(dt·480))` = **4 подшага по h = 1/480 с** (`pendulum_model.gd:464`). Аэродинамика
крыла пересчитывается с `aero_hz` = 60 Гц и между пересчётами заморожена в осях B (`pendulum_model.gd:474-479`).
Тело — **твёрдое крыло (6 степеней свободы)** + **цепь из 3 звеньев** (`links`) от точки подвески `H = pos + R·_r_hang_b`
до ЦМ пилота (последний узел), связи XPBD (`scripts/flight/pendulum/pilot_chain.gd:62`, податливость
4·10⁻⁵ м/Н на всю подвеску ≈ 3 см под весом).

**Куда добавить силу — `_substep` (`pendulum_model.gd:784`).** Там собираются силы:
- на пилота: `f_p` = вес + сопротивление (`pendulum_model.gd:796`) + руки (`f_p += R·fb`, `:825`); на стойках
  (земля) ещё `−fw` хвата и `ground.legs` (`:812-813`);
- на крыло: `f_wb` (оси B: аэродинамика `_aero_f_b`), `tb` (момент около ЦМ, оси B) — `pendulum_model.gd:790-791`;
  по ним `_vel += (R·f_wb)·h/m_wing + g·h` (`:836`), `wb += I⁻¹(tb − ω×Iω)·h`, `R` поворачивается (`:838-843`);
- пилот: `chain.integrate(h, f_p)` (`:844`, `pilot_chain.gd:108`), затем `chain.project` (`:847`) подтягивает
  звенья и возвращает крыло через *реакцию* подвески (`wing_pos`, `wing_R`).

Из этого следует два способа приложить трос:

| вариант | куда | формула | когда |
|---|---|---|---|
| A. на пилота (подвеска/грудь/карабин у пилота) | `f_p += F_tow` перед `arms.compute` | момент на крыло — **сам** через цепь | трос на пилоте: лебёдка, ходовое крепление у пояса |
| B. на крыло в точке `r_B` (киль, подвеска `_r_hang_b`, трапеция `_r_bar_b`) | `f_wb += Rᵀ·F`, `tb += r_B × (Rᵀ·F)` (в осях B) | момент явный | трос на килевой подвеске или основании трапеции |
| C. оба (раздвоенный/V-образный трос) | сумма A и B по долям | | узел «ласточкин хвост» на пилоте и килевой точке |

Точки в B уже заведены: `_r_hang_b` и `_r_bar_b` (`pendulum_model.gd:296-301`; для `sport`:
`hang_from_nose_m` 1,193 м, `bar_z_m` −1,6024 м, `keel_len_m` 2,35 м, `configs/wings/sport.json:176-182`);
высота подвески над ногами `hang_height_m` = 2,0 м (`configs/flight.json:129`).

**Ось и система координат.** Принять в API силу в **мире игры** (Н, Y вверх), внутри `ned(F)`; точку — либо
имя (`"pilot"`, `"hang"`, `"bar"`, `"keel"`), либо вектор в осях B. Ровно так `_substep` уже работает с `fb`
(руки): `R·fb` на пилота, `−fb` на крыло.

**Что остаётся управлением пилота.** Управление — только руки: `PendulumPilotArms.compute`
(`scripts/flight/pendulum/pilot_arms.gd:133`) — пружина-демпфер к цели `target = neutral_rel + (roll, pitch)·ход`
с жёсткостью `k = m/τ² = 85/0,09 ≈ 940 Н/м` и демпфированием `2m/τ` (`pilot_arms.gd:147-148`), прямая подача
(`pilot_arms.gd:159-161`) и предел `force_max` = 300 Н (`pilot_arms.gd:189-191`, `configs/pendulum.json`).
Ход цели: `shift_y_max_m` 0,45 м, `shift_x_pull_m` 0,45 м (до 0,7 с добором), `shift_x_push_m` 0,3 м.
**Если просто прибавить силу троса к `f_p` после `arms.compute`**, статического смещения нет в
прямой подаче → пилот «уезжает»: при `F` = 300 Н смещение `F/k ≈ 0,32 м` (≈ 70 % хода по крену) — выглядит как
постоянный ввод. Правильно:
1. добавить `F_tow` в `f_p` **до** `d_p`/`load_b` (`pendulum_model.gd:796` и `:818-819`) — `load_b` («кажущийся
   вес в осях B») тогда включает трос, и продольная прямая подача (`pilot_arms.gd:160`,
   `f.x += load_b.z·tgt.x/tgt.z − load_b.x`) его компенсирует;
2. поперечную прямую подачу (`pilot_arms.gd:161`, сейчас `(tgt.y − neutral.y)·m·g/L`) расширить на `load_b.y`
   (боковая составляющая троса — **не** ввод); без этого трос не по оси киля даёт ложный крен;
3. если трос на крыле (B/C), ускорение подвески в `load_b` должно включать `F_wing` — формула
   `(R·_aero_f_b + d_p)·(m_п/M)` (`pendulum_model.gd:819`) расширяется суммой всех внешних сил на систему.
Это три правки в `pendulum_model.gd` и `pilot_arms.gd` и контрактный тест «трос постоянной силы вдоль/поперёк
оси при нулевом вводе → `pilot_shift` ≈ нейтраль (FB-К1)»; цель — смещение < 0,02 хода. Предел 300 Н у рук остаётся и
ограничивает *удержание* смещения (поперёк стропы), а не саму тягу — тягу несёт подвеска и ноги.

**Состояние троса.** Сила — функция положений: `T(L, L̇) = k(L − L₀) + c·L̇` при `L > L₀`, иначе 0, направление к
точке лебёдки/буксировщика. Считать **в самом `_substep`** через вызываемую функцию
`tow_force_fn(p_game, v_game) -> Dictionary` (на подшаге 480 Гц, чтобы качание пилота видело трос), либо
раз в шаг (120 Гц) с замороженным результатом на 4 подшага (проще, но тянет фазовое запаздывание 1/120 с).
Данные для функции модель уже отдаёт: `hang_position`, `pilot_position`, `pilot_velocity`, `position`, `velocity`
(`pendulum_model.gd:88-97`) в мире игры.

**Телеметрия/HUD.** Заполняется в `_update_outputs`/`_fill_telemetry` (`pendulum_model.gd:1015`, `:1087`) → `Telemetry`
(`scripts/flight/flight_telemetry.gd:40-44`); натяжение подвески `strap_tension` (`pendulum_model.gd:106`, `:1045`).
Нужно добавить поля `tow_tension_n`, `tow_dir` (в `Telemetry`, через `flight_telemetry.gd`).

### FlightModel (точечная масса)

Одна сила: в `_step_air` прибавить `+ F_tow` к `force` (`flight_model.gd:393`); момента нет — момент и положение
точки крепления не моделируются, вынос в боковое = внешняя сила + крен через `_update_roll`
(`flight_model.gd:475`). Управление там — прямые команды (`ControlInput`, `scripts/core/control_input.gd:7-30`),
внешняя сила их не затрагивает. На земле: `GroundRun._move` — прибавить проекцию `F_tow` на `dir3` к `f_along`
(`ground_run.gd:~310`). **Рекомендация:** для `weight_shift`/`rate` дать только эту силу без моментов (режимы
исторические, `Glider.is_pendulum_mode()` — «Маятник» по умолчанию, `glider.gd:76-80`). Боты используют именно
`FlightModel` (`bot_agent.gd:22`), поэтому буксировку ботов (если нужна) можно сделать этой же силой.

### Разбег и переход «земля → полёт» с тросом

1. **Земля:** трос на пилоте → `f_p` до `legs`; `legs` проверяет `mu·fz` (`pendulum_ground.gd:260`): при тяге выше ≈
   670 Н (850 Н с крылом, нагружающим ноги) ноги проскальзывают — это нужный эффект «поволок»; **риск**: при большом `F` ноги
   `anchor` (`pendulum_ground.gd:285-291`) могут «ехать» — проверить, что бег (`running`) и тяга складываются,
   а не конкурируют (`run_force·(1 − v_f/v_cap)` убывает до нуля при `v_f → v_cap`).
2. **Отрыв:** критерий `_tension_avg > 0,25·m·g` (`pendulum_model.gd:571-574`) сработает от подъёмной силы крыла,
   вертикальная составляющая троса его **ускорит**; на лебёдке с большим углом троса отрыв «рывком». Если
   тяга чисто вертикальная — отрыв возможен с нулевой воздушной скоростью (сорвётся в `_check_after_liftoff`, ступни
   снова касаются → `GROUND`, `pendulum_model.gd:577-581`). Надо принять: до `upright_clear_m` трос считается
   «на земле» (у лебёдки — угол малый, `rope_angle_deg` из TW-1).
3. **Руки на штангу:** переход через 1 с или `upright_clear` (`pendulum_model.gd:589-592`); трос не должен
   зависеть от `_uprights`: на стойках (`f_p -= fw`) формулы `fw` не знают о тросе → добавить трос и в
   равновесие хвата (иначе `grip_force` растягивается пружиной и хват «плывёт»).
4. **Отцеп** — удалить силу (гладко: `F` → 0 за 0,2–0,5 с, иначе скачок момента); крыло уже в подвеске.

## Экран старта

**Структура.** `FlightSetupScreen` (`scripts/ui/flight_setup_screen.gd:1`): `TabContainer` с вкладками
«Место» (`box_place`), «Аппарат» (крыло, масса, «Аппарат» — `_build_apparatus`, `:193`) и «Цели» (`:134-139`);
`_build()` (`:126-179`). Погода/время — `_build_forecast` (`:394`), `_build_time` (`:363`); выбор места —
`PlacePickRow` (`scripts/ui/place_pick_row.gd:29`): «Выбрать на карте», «Популярные места», подпись. Сбор настроек —
`_collect()` (`flight_setup_screen.gd:487-510`) → `FlightSettings` (`scripts/game/flight_settings.gd`), сохранение —
`to_dict()`/`from_dict()` (`flight_settings.gd:195-250`), в сеть — `zone` (`:280-311`).

**Где добавить выбор буксировки.** Новая строка (OptionButton «Способ старта»: пешком / лебёдка / машина /
аэробуксировка) во вкладку «Место» **после** `PlacePickRow` (`flight_setup_screen.gd:141-148`) —
способ зависит от места (на горе лебёдка не нужна) — либо под «Аппарат». Поля в `FlightSettings`:
`tow_kind: String` (`""` — пешком), `tow_params: Dictionary` (длина троса, слабое звено; умолчания места).
`_apply_settings()` (`:211-232`) читает, `_collect()` пишет. Как `apparatus` (`flight_settings.gd:51`).

**`launch_options`.** CLI-флаги разбирает `LaunchOptions.parse()` (`scripts/game/launch_options.gd:120`), в
настройки накладывает `apply_to()` (`:219-262`): `--wing/--mass/--site/--location/--latlon...`. Нужны флаги
`--tow=<вид>` (кадры, тесты, `--smoke`) и `--tow-len=<м>`; без флага — из настроек.

**Недоступность.** Если для места/вида `TowSite` не подходит (не равнина, нет полосы) — вариант в списке
серый с причиной (как `StartSpot.check` → `reason`, `scripts/game/start_spot.gd:12-35`).

## Равнина

**Данные рельефа.** `Terrain.height_at(x, z)` (`scripts/terrain/terrain.gd:643`): самый детальный слой,
покрывающий точку; шаг сетки детального слоя 25 м (Copernicus GLO-30, 30 м источник), дальний 100 м
(`configs/locations/askarovo.json`, `dem.layers`). Нормаль — `normal_at` (`terrain.gd:653`), класс поверхности —
`surface_at` (`terrain.gd:679`: FOREST, GRASS, CROP, SHRUB, BARE, WATER, BUILT, SNOW — `surface_layer.gd:9-17`).
Границы детального рельефа — `detail_bounds()` (`terrain.gd:1035`). Для воздуха и объектов мира есть
OSM-аэродромы: `OsmData.aeroways` с `t` ∈ {aerodrome, airstrip, helipad, runway} и полилиниями
(`scripts/world_objects/osm_data.gd:18`, `:192-200`), рисуются лентами 30/18 м (`osm_pilot.gd:512-537`,
`configs/world_objects.json:1176-1190`) — **источник оси полосы** (курс и длина), но в физику не подключён.

**Критерий равнины (предложение, функция `TowSite.check(terrain, x, z, heading, length, width)`).** Выборка
вдоль оси полосы (шаг ≈ сетка 25 м, но не реже 10 м, билинейно) и по бокам ±`width/2`:
1. уклон: `StartPlacement.evaluate` даёт `slope_deg` по базе `probe_m` = 25 м (`start_placement.gd:13-20`,
   `configs/game.json:79-90`); критерий равнины — `slope_deg ≤ flat_max_deg` (по умолчанию малое, напр. 2°,
   параметр `configs/game.json` → `tow_site`; сейчас обратное условие `min_slope_deg` = 12°);
2. перепад по длине `max(h) − min(h) ≤ dh_max` (напр. 0,02·`length`), без обратного уклона;
3. поверхность вдоль полосы: не `WATER` и не `FOREST` (`BUILT` — допустим для аэродрома по OSM; `StartSpot.check`
   сейчас отбраковывает `BUILT`, `start_spot.gd:25-26` — аэродром с застройкой/ВПП в классе «built» не пройдёт);
4. в границах `detail_bounds().grow(−edge_margin_m)` (200 м, `configs/game.json:95`).
Возврат — словарь как у `StartSpot.check` (`ok`, `reason`, ...) + `flat_length_m`, `heading_deg`, `slope_deg`.

**Что решает сейчас, где стоит пилот.** Лес/кусты/пологий склон допустимы (`start_spot.gd:3-4`); точка с карты:
`StartPlacement.evaluate` (`game.gd:1474-1477`) — результат `ok` **не используется** (позиция берётся всегда, курс
вниз по склону; на равнине курс 0° = север, `start_placement.gd:17`); поляна вокруг старта —
`terrain.add_start_clearing(x, z, R)` (`terrain.gd:1190`), R = 160 м (`start_clearing_radius_m`, `configs/game.json:88`) —
лес → луг, **круг**, а не полоса: для полосы 300+ м с тросом нужен прямоугольный/капсульный вариант
(`_clear_forest`, `terrain.gd:1173`).

**Волжский (T-47, T-49).** Среди встроенных мест его **нет**: `configs/locations/` — altai, askarovo, aushkul, ongudai,
training_island, volcano_island; в каталоге «Популярные места» (`data/places/hg_takeoffs.json`, 700 стартов, `format:
deltaplan.hg_takeoffs`) записей про Волжский/Волгоград нет. Сегодня Волжский можно выбрать только **точкой на
карте**: `Locations.builtin_at` не найдёт места (
`scripts/terrain/build/locations.gd:106`), будет `LocationCache.key_for(lat, lon)` (`pt_±…`) +
`Terrain.load_point(lat, lon)` (`game.gd:1423-1433`, `terrain.gd:172`) — рельеф и OSM из сети/кеша, старт в точке,
курс север, без полосы.

**Как добавить место с полосой вместо склона.** Без правок кода (данные):
1. `configs/locations/volzhsky.json` по образцу `askarovo.json`: `center_lat/lon`, `dem.layers`, `start_sites`
   `[{id, name, lat, lon, heading_deg}]` — `heading_deg` = ось полосы (по OSM-ВПП); `start_position_agl_m` 0;
   `start_clearing_radius_m` (`terrain.gd:1233-1250` читает `start_sites`, `get_start_sites()` — `terrain.gd:661`);
2. запись в `data/places/hg_takeoffs.json` (`id: builtin/volzhsky/…`, `location`, `site`, `heading_deg`) — тогда
   «Популярные места» открывают его (`place_pick_row.gd:184`, `world_key.gd:118-145` — ключ мира/сети);
3. локация собирается при первом выборе (`Locations.data_dir`, `locations.gd:65-72`), сборщик берёт DEM и OSM.
С правкой кода нужно одно: `Terrain._build_sites()` (`terrain.gd:1215-1250`) копирует из `start_sites` только
`id, name, position, heading_deg, lat, lon` → добавить сквозной блок `tow` (виды, длина полосы, ширина,
рекомендуемый `kind`) и использовать в `TowSite`. Площадка-аэродром — одна запись `start_sites` с `tow`;
горный склон остаётся без него (пешком).

## Сеть и боты

**Что уходит.** Пакет `PilotState` (`server/proto/deltaplan/v1/net.proto:304-329`; зеркало
`scripts/net/net_messages.gd:111-125`): `pilotId, isBot, name, t, pos, rot, vel, phase, wing, colors, controlMode,
pilotRel`. Свой — `NetFlight.send_local()` (`scripts/game/net_flight.gd:325-340`): фаза `TOW` при
`game.is_towing()` (**это «Догнать»**, не буксировка), `controlMode` + `pilotRel` — в «Маятнике» (PD-К4, `docs/contracts/pendulum.md`,
17 + 2 байта). Приём — `RemotePilotState.push/sample` (`scripts/net/remote_pilot_state.gd:70,114`), `feed_remote`
(`net_flight.gd:353-383`) → `RemotePilots.set_pose` (`scripts/game/remote_pilots.gd:152`). Зона несёт место и старт
(`Zone`: `locationId, siteId, pickLat/Lon, startLat/Lon/HeadingDeg`, `net_messages.gd:69-86`), никаких
полей буксировки. **Другие пилоты буксировку НЕ видят**: ни троса, ни лебёдки, ни тягача (рисуют только крыло и
пилот по `pos/rot/vel/phase`); при буксировке они увидят «FLY»/«STAND/RUN» без объяснения скорости. Положение
отстающего пилота (в воздухе на тросе) для них корректно (позиция, скорость), но «рывок» отцепа — нет.

**Очередь на старт.** `NetQueue.spots_for` (`scripts/game/net_queue.gd:189-197`) ставит места ожидания вокруг
старта (`BotPilots.find_spots`, `bot_pilots.gd:484`, склоновой сетки 3 м); фазы `FLY, TOW, LANDED, CRASHED` = «ушёл»
(`net_queue.gd:34`). С буксировкой лебёдке нужно место вне очереди; решить в контракте TW-К.

**Минимальный сетевой вариант (предложение).** В `PilotState` добавить поле `TowState tow = 13` (вид, длина,
натяжение 0–1 по слабому звену, точка лебёдки `Vec3` — раз в секунду, остальное по `pos`) и фазу `TOWED`
(не `TOW`, она занята под «Догнать»: `net.proto` enum `PilotPhase`, `net_messages.gd:173-176`). Старый клиент
пропускает незнакомые поля (`net_messages.gd:40-41`). Визуал: `RemotePilots` рисует трос между пилотом и точкой
лебёдки (`BotGlider`, `scripts/game/bot_glider.gd`). Лебёдка/тягач — объект сцены, видимый всем в месте `TowSite`
(одинаково у всех клиентов, как лагерь `world_link.place_camp`).

**Боты.** Боты — `BotAgent` со своей `FlightModel` (`bot_agent.gd:22`, `:181`), стартуют ходьбой/разбегом со склона
(`State.WALK→READY→RUN`, `bot_agent.gd:14-17`); в сети ботов считает ведущий (`net_bots.gd`). На равнине без склона
боты **не взлетят** (нужна подъёмная сила от бега и склона). Варианты: (a) на буксирных местах ботов нет
(`bots=0` для `TowSite`); (b) боты получают ту же внешнюю силу `FlightModel` — «клиентская» лебёдка; (c) боты
стартуют в воздухе на высоте отцепа (`start_in_air`, `net_bots.gd:264-267` уже так делает для `FLY`/`TOW`).
Рекомендация: (c) для видимого неба, (b) отложить.

## Догнать

`CatchUpTow` (`scripts/game/catch_up_tow.gd:1`): **кинематика без физики**, не стартовая буксировка — перелёт к другу
по «куполу» скорости с подъёмом над рельефом (`_lift_required`, `catch_up_tow.gd:128-160`). API: `start(own_pos,
own_vel, target_fn, own_heading)`, `step(dt)` → `position, velocity, heading, bank, basis, speed, active`
(`catch_up_tow.gd:1-30`). В игре: `Game.tow: CatchUpTow` (`game.gd:72`), `start_catch_up` (`game.gd:1277-1293`),
`_tow_step` (`:1332`) → `glider.set_kinematic` (`glider.gd:122-146`, `PendulumModel.set_kinematic`
`pendulum_model.gd:408`), `_end_catch_up` (`:1345`: ниже `TOW_GROUND_AGL_M` = 8 м — `reset_on_ground`, иначе
`reset_in_air`). Сеть: фаза `TOW` (`net_flight.gd:330`, `net_queue.gd:34`, `catch_up_menu.gd:390`).

**Коллизии имён.** `Game.tow`, `is_towing()`, `abort_catch_up()`, `PilotPhase.TOW`, `TOW_FLOW_CAP_MS` — всё про «Догнать». Новую буксировку называть иначе: `TowLine`, `tow_line`, фаза `TOWED` (иначе `is_towing()` отключит физику, `game.gd:289-291`, и спрячет индикатор смещения, `game.gd:1589`). Переиспользовать можно паттерн `target_fn() -> {position, velocity}` (тягач = цель). Физику «Догнать» не менять.

## Предлагаемые стыки

| стык | владелец (файл, функция) | интерфейс (сигнатура, поля, единицы, оси) | потребители | что менять |
|---|---|---|---|---|
| сила троса → модель полёта | `PendulumModel` (`pendulum_model.gd:784` `_substep`); новый `TowForce` (RefCounted) | `set_external_force_fn(f: Callable)`; `f(t: float, p_hang: Vector3, v_hang: Vector3, p_pilot: Vector3, v_pilot: Vector3) -> Dictionary {on_pilot: Vector3, on_wing: Vector3, wing_point_b: Vector3}`; Н, оси игры (X восток, Y вверх, −Z север); `wing_point_b` — оси B, м; вызов раз в подшаг (480 Гц) или шаг; пусто — как сейчас | `Glider.step`, тесты, `TowLine` | `_substep`: `f_p += ned(on_pilot)` до `d_p` (`:818`), `f_wb += Rᵀ·ned(on_wing)`, `tb += r×…`; `PilotArms.compute` `:159-161` — поперечная подача с `load_b.y` |
| то же, FlightModel | `FlightModel._step_air` (`flight_model.gd:393`), `GroundRun._move` (`ground_run.gd:282`) | `external_force: Vector3` (Н, мир игры) | боты, легаси | `force += external_force`; `f_along += external·dir3` |
| состояние буксировки → HUD/подсказки | `Telemetry` (`flight_telemetry.gd:40-44`) + `Game._update_overlay` (`game.gd:1585`) | поля: `tow_kind: String`, `tow_tension_n: float`, `tow_length_m: float`, `tow_state: String` ("slack"/"taut"/"released"/"broken"), `tow_release_ready: bool`; сигналы `tow_released(reason)`, `tow_broken` | `instrument_page_flight.gd`, `wrist_instruments.gd`, подсказки, `GoalTracker` | добавить поля в `Telemetry`/`FlightTelemetry.fill`; страница/индикатор натяжения; клавиша отцепа в `controls.json` (`input_controller.gd:57`) |
| выбор буксировки → экран старта/`launch_options` | `FlightSetupScreen` (`flight_setup_screen.gd:141-148`, `_collect :487`), `FlightSettings` (`flight_settings.gd:51,195`), `LaunchOptions.apply_to` (`launch_options.gd:219`) | `tow_kind: String` ("", "winch_static", "winch_payout", "vehicle", "aerotow"), `tow_params: Dictionary` {rope_length_m, weak_link_daN}; CLI `--tow=<kind>`, `--tow-len=<м>`; в `to_dict`/`zone` | `Game._choose_start`, сеть, избранное | новая строка вкладки «Место»; сериализация; `StartSpot`-подобная проверка пригодности, серый пункт с причиной |
| размещение лебёдки/полосы → старт | `TowSite.check` (новый, рядом с `start_spot.gd`), `Terrain._build_sites` (`terrain.gd:1215`), `Game._choose_start` (`game.gd:1461`) | `TowSite.check(terrain, x, z, heading_deg, length_m, width_m) -> {ok, reason, flat_length_m, heading_deg, slope_deg, winch_pos: Vector3, release_pos: Vector3}`; `start_sites[].tow = {kinds[], runway_length_m, runway_width_m}` | `Game`, `NetQueue.spots_for`, лебёдка (сцена) | `_choose_start`: при `tow_kind != ""` — старт по оси полосы, курс = ось, лебёдка/тягач в начале/конце полосы; прямоугольная поляна вместо круга `add_start_clearing` |
| буксировка → сеть | `NetFlight.send_local` (`net_flight.gd:325`), `net.proto` `PilotState` (`:304`), `NetMessages` (`net_messages.gd:111`), `RemotePilots.set_pose` (`remote_pilots.gd:152`) | `PilotState.tow {kind, anchor: Vec3, length_m, tension_01}`, фаза `TOWED`; точка лебёдки `anchor` — мир игры, м; частота — раз в 1 с + по смене | `RemotePilots`, `BotGlider`, `NetQueue` (`GONE_PHASES`) | поле в proto и зеркале; рисование троса и лебёдки у других; `GONE_PHASES` без `TOWED` до отцепа; новую фазу не называть `TOW` |

Порядок реализации по зависимостям: (1) `TowForce` + правки `_substep`/`PilotArms` + контрактный тест «нулевой ввод —
нейтраль» → (2) `TowSite`/`start_sites.tow` + `_choose_start` → (3) экран/CLI → (4) Telemetry/HUD → (5) сеть.

## Риски

1. **Смещение пилота от нейтрали от постоянной силы** (см. «Внешняя сила»): без правки `load_b` и поперечной
   подачи `pilot_arms.gd:161` постоянная сила `F` смещает цель на `F/k` (≈ 0,11 м на 100 Н); управление по
   крену/тангажу «сдвинется» — главный риск «сохранения управления».
2. **Предел рук 300 Н** (`pilot_arms.gd:189-191`): сила тросa поперёк стропы (по килю при тяге с боку) насыщает
   руки; при насыщении `_int` антинасыщения не нужен (`ti = 0`), но пилот теряет удержание. Проверить на максимальном
   `tension_daN` из TW-1.
3. **Жёсткость троса и шаг.** Явная сила на подшаге `h = 1/480 с` устойчива при `k·h²/m_eff ≲ 2` (`m_eff ≈ 85 кг` пилота)
   → `k ≲ 4·10⁷ Н/м`; при шаге 1/120 с — `k ≲ 2,4·10⁶ Н/м`. Реальный трос `k = EA/L`; на коротком конце
   (`L → 0`, начало разбега) `k → ∞`: ограничить `L ≥ L_min` или **неявная** форма (как XPBD-звено в
   `pilot_chain.gd:62`: податливость `α/h²`) — трос ещё одним звеном цепи (несовместимо с «внешняя сила»
   только если кинематика; XPBD-звено — тоже сила в точке, подходит). Демпфирование `c` ввести обязательно
   (трос без демпфера «звенит» с частотой √(k/m)).
4. **Цепь подвески провисает** (`C ≤ 0 → continue`, `pilot_chain.gd:72`) — трос подтянет пилота, цепь затянется;
   при отцепе внезапный сброс силы даёт «хлопок» крыла: плавный срез `F → 0` (0,2–0,5 с).
5. **Земля:** `legs()` ограничивает горизонтальную силу `mu·fz` (`pendulum_ground.gd:260`): при тяге выше
   предела пилота «потащит» (проскальзывание), а `anchor` смещается (`:285-291`); проверить, что отрыв не
   срабатывает в `_check_ground` при `contact=false` и малой `strap_tension`. На стойках (`_uprights`) сила
   хвата `fw` не знает о тросе (`pendulum_model.gd:806-812`) — вертикаль тросa на крыле не компенсируется
   пружиной хвата (`grip_k` 3000 Н/м): хват «растягивается»; отдельный тест на старт с тросом на земле.
6. **Крыло на земле:** `_wing_ground_force` (`pendulum_model.gd:877`) держит крыло пружиной до `flight_position_started`;
   сила троса на крыло ниже земли «вдавит» консоль/нос — учесть угол `rope_angle_deg`.
7. **Рыскание и lock-out:** момент троса на крыле (`tb`) вводит рыскание/крен у не-V-образного крепления;
   «эквивалентный киль» (`pendulum.yaw`, `configs/pendulum.json`: `fin_arm_m` 1,6, `cn_beta` 0,05) рассчитан на
   свободный полёт — демпфирование по рысканию при тросе нужно проверить на lock-out из TW-1; лёгкие
   крылья (учебные) качает сильнее.
8. **Режимы управления:** `weight_shift`/`rate` (`FlightModel`) без моментов: тест на оба режима, иначе настройка
    «Режим крена» (`settings_panel.gd:340`) ломает буксировку.
9. **Сеть/боты:** `GONE_PHASES` (`net_queue.gd:34`) сочтёт «TOW» (Догнать) и новую фазу «ушёл» — до отцепа на
    полосе очередь прыгнет; фаза `TOW` занята.
10. **Равнина:** `StartSpot.check` отбракует `BUILT` (`start_spot.gd:25-26`), `StartPlacement` ставит курс «север»
    (`start_placement.gd:17`); `_align_start_heading` крутит курс по ветру (`game.gd:821`) — для полосы курс
    фиксируется осью, ветер учитывается выбором конца полосы.

Не проверялось (чтение кода без прогонов): устойчивость при реальной жёсткости; фактическое смещение `pilot_shift`
от силы (оценка `F/k` по формуле рук); поведение `legs` при большой тяге.
