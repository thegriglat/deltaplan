---
type: "contract"
status: "active"
module: "trike-model"
area: "flight"
updated: "2026-10-22"
summary: "Размеры трайка trike_params.json (TK-K1), модель тележки trike.glb с узлом винта (TK-K2), поза пилота sit в pilot.glb (TK-K3)."
related: ["docs/plan/trike-model.md", "docs/guide/models.md", "docs/guide/models/pilot.md"]
contracts: [{"id": "TK-K1", "version": 4}, {"id": "TK-K2", "version": 4}, {"id": "TK-K3", "version": 2}]
---

# Контракты модуля trike-model

Оси: в Blender и в JSON — +X вправо, +Y вперёд, +Z вверх; в Godot — +X вправо, +Y вверх, вперёд −Z
(Godot = (x, z, −y) Blender). Единицы — м, °, об/мин. Начало координат тележки и пилота — точка подвески крыла `HangPoint`
(болт на вершине мачты; у пилота — карабин). Контрактные тесты — `tests/contracts/test_trike_model_k<n>.gd`
(фильтр `trike_model_k<n>`): версия в заголовке раздела; владелец стыка дописывает проверку интерфейса.

## TK-K1. Размеры трайка — tools/blender/trike_params.json (v4)

- Владелец: TK-1 (v2 — TK-7). Потребители: TK-2 (поза), TK-3/TK-8 (модель), TK-4/TK-6 (кадры, проверка посадки). Правка — только
  координатор. v2 (2026-10-22, замечания пользователя по кадрам TK-4): двухлопастный винт с хордой, двигатель по частям, тандем
  с задним сиденьем выше, бак-канистра под задним сиденьем, трубы крепления сидений.
- Файл JSON, ключи верхнего уровня:
  - `version`: 4.
  - `prototype`: `{"name": str, "seats": 1|2, "sources": [url, …]}` — по чему строится.
  - `dims`: словарь `<ключ>: {"value": число|str, "src": str}`; `src` — url/документ со страницей или «вывод: …» (как получено
    из других чисел/фото). Обязательные ключи (м, если не указано): `length`, `width`, `hang_height` (точка подвески над землёй,
    стоя на колёсах без нагрузки), `wheelbase`, `track`, `wheel_front_d`, `wheel_rear_d`, `tire_front_w`, `tire_rear_w`,
    `mast_tilt_deg` (наклон мачты вперёд от вертикали, °), `seat_height` (подушка переднего сиденья над землёй),
    `engine` (str, модель), `engine_l`, `engine_w`, `engine_h`, `prop_d`, `prop_blades` (int), `prop_axis_height`
    (ось винта над землёй), `prop_tilt_deg` (ось винта от горизонтали, + нос вверх), `prop_rpm` (обороты винта на крейсерском),
    `prop_cw_from_behind` (bool). С v2 ещё: `prop_blades` — 2 или 3 по выбранному двигателю с источником (решение пользователя 2026-10-22: мощный — 3), `prop_chord_max` (наибольшая хорда
    лопасти), `prop_chord_tip` (хорда у законцовки), `prop_hub_d` (диаметр ступицы/кока); двигатель — `engine_cyl_count` (int),
    `engine_cyl_layout` (str: `inline` | `boxer`), `engine_cyl_d` (диаметр рубашки/оребрения цилиндра), `engine_gearbox`
    (str: тип редуктора, напр. `Rotax B/C/E`), `engine_exhaust_d` (v3: наибольший диаметр резонансной трубы), `engine_exhaust_l` (v3: её длина), `muffler_d`,
    `muffler_l` (v3: глушитель); `rear_seat_rise`
    (подушка заднего сиденья выше передней), `tank_volume_l` (л), `tank_l`, `tank_w`, `tank_h` (габарит бака-канистры); диаметры труб `tube_keel_d`, `tube_mast_d`,
    `tube_strut_d` (передний подкос), `tube_frame_d` (рама сидений и стойки шасси); обороты винта после редуктора
    `prop_rpm_idle` (холостые; дельталёт на стоянке не глушат) и `prop_rpm_max` (полный газ), `prop_spin_period_s` = 1,0
    (длительность клипа `prop_spin` — один оборот; в игре `speed_scale = rpm · prop_spin_period_s / 60`).
  - `seat_rear` (v2): как `seat`, без `eye`/`hip`/`hand_*`/`throttle_pedal` — `seat_pan`, `seat_pan_size`, `backrest_base`,
    `backrest_angle_deg`, `backrest_size`, `foot_l`, `foot_r` (подножки пассажира); `seat_pan.z` − `seat.seat_pan.z` = `rear_seat_rise`.
  - `tank` (v2): `{"center": [x,y,z], "size": [ширина, длина, высота], "filler": [x,y,z]}` — под задним сиденьем, форма
    канистры: высота ≥ 0,6 ширины, скруглённые рёбра, горловина с крышкой в точке `filler`; объём габарита ≈ `tank_volume_l` (± 15 %).
    v3 (ответ пользователя на Q1, 2026-10-22): бак меньше (объём — по источникам трайков с Rotax 582) и поднят над килем:
    `tank.keel_clear` — зазор от низа бака до верха киля, ≥ 0,03 м.
  - v4 (замечания пользователя 2026-10-22, принципиальные): `seat.pedal_angle_deg` = 45 — подножки и педаль газа под 45° к
    горизонту, передний край выше, нормаль к пилоту (Blender `(0, −sin a, cos a)`); `seat.foot_l`/`foot_r`/`throttle_pedal` — центр
    опоры подошвы на плоскости педали; `seat.pedal_size` `[ширина, длина]`.
  - `bar` (v4): `{"wing": "training", "d": м, "half_width": м, "trim": [x,y,z], "full_pull": [x,y,z], "full_push": [x,y,z],
    "how": str}` — центр базовой штанги трапеции в осях тележки (Blender, от точки подвески) в триме и на крайних положениях хода
    по тангажу; крыло — то же, что у `eye_measured` (training); замер в игре.
  - `panel` (v4): `{"center": [x,y,z], "size": [ширина, высота], "normal": [x,y,z]}` — приборная панель между пилотом и штангой
    (ближе к пилоту), нормаль к глазам. Инвариант: отрезки от `seat.eye` до центра и углов панели не пересекают цилиндр штанги
    (радиус `d/2` + 0,01 м, длина `2·half_width`) ни в одном положении хода (trim, full_pull, full_push и промежуточные по дуге
    вокруг точки подвески с шагом ≤ 2°); панель не пересекает колени пилота в позе sit.
  - `ground_z`: высота земли в осях тележки (= −`hang_height`).
  - `eye_measured`: `{"training": [x,y,z], "apogee": [x,y,z], "how": str}` — замер точки камеры «Сидячая поза» (глаза `PilotHead`
    + `cockpit.back_offset_m`) относительно `HangPoint` в осях пилота, горизонтальный полёт.
  - `seat`: точки в осях тележки (Blender, от точки подвески), `[x,y,z]`: `eye` (глаза сидящего — из `eye_measured`, крыло
    `training`), `hip` (центр тазобедренных суставов), `seat_pan` (центр подушки сиденья, верх), `seat_pan_size` `[ширина, глубина]`,
    `backrest_base` (низ спинки по центру), `backrest_angle_deg` (от вертикали назад), `backrest_size` `[ширина, высота]`,
    `foot_l`, `foot_r` (точка опоры подошвы на подножке), `throttle_pedal` (точка педали газа под правой стопой), `hand_l`, `hand_r`
    (кисти на коленях).
- Инварианты: x всех симметричных точек `_l`/`_r` — противоположны (± 1 см); `seat.eye` = `eye_measured.training` (± 1 см);
  у каждого `dims.*` непустой `src`.

## TK-K2. Модель тележки — assets/models/trike/trike.glb (v4)

- Владелец: TK-3 (v2 — TK-8). Потребители: TK-4/TK-6, будущий модуль trike (игра).
- Сборка: `blender --background --python tools/blender/build_trike.py` (Blender 4.3) читает `tools/blender/trike_params.json`;
  исходник `assets/source/trike/trike.blend`; общие функции — `tools/blender/bl_util.py`, `wheel_parts.py`, `frame_parts.py`
  (не ломать чужое). Затем `godot --headless --path . --import`.
- Оси Godot: +Y вверх, нос к −Z, 1 = 1 м; начало координат — точка подвески крыла (вершина мачты); земля — y = `ground_z`
  (низ колёс ± 1 см).
- Узлы (поиск `find_child` по дереву):
  - `Trike_LOD0` (≤ 4500 треугольников), `Trike_LOD1` (≤ 1200), `Trike_LOD2` (≤ 250) — `MeshInstance3D`, всё кроме винта
    (в LOD0 — и кроме двигателя; в LOD1/LOD2 двигатель упрощён и входит в меш);
  - `Engine_LOD0` (v2, ≤ 1500) — `MeshInstance3D`, двигатель отдельным мешем: картер, цилиндры с головками по
    `engine_cyl_count`/`engine_cyl_layout`, редуктор, выхлоп с глушителем, карбюраторы; развёртка UV0 без наложений в [0, 1]
    (под будущую текстуру), пока вершинные цвета;
  - `Propeller` — `Node3D` на ступице винта, его локальная ось Z — ось двигателя (вращение винта — поворот вокруг `basis.z`
    узла `Propeller`); дети `Prop_LOD0` (≤ 500), `Prop_LOD1` (≤ 80) — `MeshInstance3D`, центр ступицы в начале узла;
    лопастей `prop_blades`, хорда по `prop_chord_max`/`prop_chord_tip` (± 10 %);
  - маркеры `Node3D`: `HangPoint` (0,0,0), `WheelFront`, `WheelRearL`, `WheelRearR` (центры осей колёс).
- Анимация: `AnimationPlayer` с `prop_spin` — один оборот `Propeller` вокруг его локальной Z, линейно, длина 1,0 с, цикл
  (в игре `speed_scale = rpm · prop_spin_period_s / 60`, rpm от `prop_rpm_idle` до `prop_rpm_max`, решение пользователя
  2026-10-22); направление — по `prop_cw_from_behind`; поворот за клип ровно 360° вокруг оси двигателя, без ускорения на концах.
- Материал: вершинные цвета; шина — материал с картинкой `wheel_tire` (`wheel_parts.tire_texture()`, внешний uri
  `assets/textures/wheel/tire.png`); новых текстур нет (`python3 tools/check_textures.py main` — код 0); без прозрачности.
- Размеры модели = `dims` (± 2 %): база, колея, диаметры колёс и винта, `hang_height`; сиденье, спинка, подножки и педаль —
  по `seat` (v4: подножки и педаль газа — плоские площадки `pedal_size` под `pedal_angle_deg`, плоскость через `foot_*` ± 1 см);
  заднее сиденье, его спинка и подножки — по `seat_rear`; бак — по `tank` (v2). Каждое сиденье и спинка соединены
  с рамой трубами крепления (v2).
- v3 (ответ пользователя на Q1, 2026-10-22): трубы рамы (киль, мачта, передний подкос) — 60 мм (`tube_keel_d`, `tube_mast_d`,
  `tube_strut_d` = 0,06); пружины амортизаторов — витая спираль (круглая проволока, ≥ 5 витков), не зигзаг; резонансная труба
  выхлопа и глушитель — крупные, по `engine_exhaust_d/l`, `muffler_d/l`; низ бака выше верха киля на `tank.keel_clear`.
- v4: приборная панель — меш по `panel` (в `Trike_LOD0`, упрощённо в LOD1) и маркер `Node3D` `InstrumentPanel` в `panel.center`,
  его `basis.z` (Godot) — `panel.normal`; прежний приборный обтекатель над носом — без приборов (или убрать), за штангой
  приборов нет.
- Пилот: `pilot.glb` в начале тележки без смещения и поворота, анимация `sit` (TK-K3).

## TK-K3. Поза пилота sit — assets/models/pilot.glb (v2)

- Владелец: TK-2. Потребители: TK-4, будущий модуль trike.
- Анимация `sit` в `pilot.glb` (`build_pilot.py`), статичная (цикл), читает `seat` из `tools/blender/trike_params.json`.
  Прежние анимации (`stand`, `walk`, `run`, `run_air`, `climb_in`, `prone`, `climb_out`, `flare`), кости, узлы и бюджет
  треугольников пилота не меняются.
- В позе `sit` (в осях пилота = осях тележки, начало — карабин/точка подвески): узел `Head` (глаза; в игре за ним идёт маркер
  `PilotHead`) — в `seat.eye` ± 2 см, взгляд вперёд горизонтально ± 10°; середина голов костей `Thigh.L/R` — в `seat.hip` ± 3 см;
  подошвы — на `foot_l`/`foot_r` ± 3 см (правая — на `throttle_pedal`; v2: плоскость подошвы параллельна педали — угол
  нормалей ≤ 5°, центр подошвы у `foot_*` ± 2 см, вершины подошвы от пятки до носка не дальше 1 см от плоскости педали — опора всей
  стопой, не носком); кисти (`HandL`/`HandR`) — у `hand_l`/`hand_r` ± 5 см;
  спина — у спинки (`backrest_*`). Кокон (`PodTail`, `PodMid`, `PodEnd`) и фал `Strap` схлопнуты (масштаб кости ≤ 0,01).
