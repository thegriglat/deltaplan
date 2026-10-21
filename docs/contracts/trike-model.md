---
type: "contract"
status: "active"
module: "trike-model"
area: "flight"
updated: "2026-10-22"
summary: "Размеры трайка trike_params.json (TK-K1), модель тележки trike.glb с узлом винта (TK-K2), поза пилота sit в pilot.glb (TK-K3)."
related: ["docs/plan/trike-model.md", "docs/guide/models.md", "docs/guide/models/pilot.md"]
contracts: [{"id": "TK-K1", "version": 2}, {"id": "TK-K2", "version": 2}, {"id": "TK-K3", "version": 1}]
---

# Контракты модуля trike-model

Оси: в Blender и в JSON — +X вправо, +Y вперёд, +Z вверх; в Godot — +X вправо, +Y вверх, вперёд −Z
(Godot = (x, z, −y) Blender). Единицы — м, °, об/мин. Начало координат тележки и пилота — точка подвески крыла `HangPoint`
(болт на вершине мачты; у пилота — карабин). Контрактные тесты — `tests/contracts/test_trike_model_k<n>.gd`
(фильтр `trike_model_k<n>`): версия в заголовке раздела; владелец стыка дописывает проверку интерфейса.

## TK-K1. Размеры трайка — tools/blender/trike_params.json (v2)

- Владелец: TK-1 (v2 — TK-7). Потребители: TK-2 (поза), TK-3/TK-8 (модель), TK-4/TK-6 (кадры, проверка посадки). Правка — только
  координатор. v2 (2026-10-22, замечания пользователя по кадрам TK-4): двухлопастный винт с хордой, двигатель по частям, тандем
  с задним сиденьем выше, бак-канистра под задним сиденьем, трубы крепления сидений.
- Файл JSON, ключи верхнего уровня:
  - `version`: 2.
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
    (str: тип редуктора, напр. `Rotax B/C/E`), `engine_exhaust_d` (диаметр выхлопной трубы/глушителя); `rear_seat_rise`
    (подушка заднего сиденья выше передней), `tank_volume_l` (л), `tank_l`, `tank_w`, `tank_h` (габарит бака-канистры); диаметры труб `tube_keel_d`, `tube_mast_d`,
    `tube_strut_d` (передний подкос), `tube_frame_d` (рама сидений и стойки шасси).
  - `seat_rear` (v2): как `seat`, без `eye`/`hip`/`hand_*`/`throttle_pedal` — `seat_pan`, `seat_pan_size`, `backrest_base`,
    `backrest_angle_deg`, `backrest_size`, `foot_l`, `foot_r` (подножки пассажира); `seat_pan.z` − `seat.seat_pan.z` = `rear_seat_rise`.
  - `tank` (v2): `{"center": [x,y,z], "size": [ширина, длина, высота], "filler": [x,y,z]}` — под задним сиденьем, форма
    канистры: высота ≥ 0,6 ширины, скруглённые рёбра, горловина с крышкой в точке `filler`; объём габарита ≈ `tank_volume_l` (± 15 %).
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

## TK-K2. Модель тележки — assets/models/trike/trike.glb (v2)

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
  (в игре `speed_scale = prop_rpm / 60`); направление — по `prop_cw_from_behind`.
- Материал: вершинные цвета; шина — материал с картинкой `wheel_tire` (`wheel_parts.tire_texture()`, внешний uri
  `assets/textures/wheel/tire.png`); новых текстур нет (`python3 tools/check_textures.py main` — код 0); без прозрачности.
- Размеры модели = `dims` (± 2 %): база, колея, диаметры колёс и винта, `hang_height`; сиденье, спинка, подножки и педаль —
  по `seat`; заднее сиденье, его спинка и подножки — по `seat_rear`; бак — по `tank` (v2). Каждое сиденье и спинка соединены
  с рамой трубами крепления (v2).
- Пилот: `pilot.glb` в начале тележки без смещения и поворота, анимация `sit` (TK-K3).

## TK-K3. Поза пилота sit — assets/models/pilot.glb (v1)

- Владелец: TK-2. Потребители: TK-4, будущий модуль trike.
- Анимация `sit` в `pilot.glb` (`build_pilot.py`), статичная (цикл), читает `seat` из `tools/blender/trike_params.json`.
  Прежние анимации (`stand`, `walk`, `run`, `run_air`, `climb_in`, `prone`, `climb_out`, `flare`), кости, узлы и бюджет
  треугольников пилота не меняются.
- В позе `sit` (в осях пилота = осях тележки, начало — карабин/точка подвески): узел `Head` (глаза; в игре за ним идёт маркер
  `PilotHead`) — в `seat.eye` ± 2 см, взгляд вперёд горизонтально ± 10°; середина голов костей `Thigh.L/R` — в `seat.hip` ± 3 см;
  подошвы — на `foot_l`/`foot_r` ± 3 см (правая — на `throttle_pedal`); кисти (`HandL`/`HandR`) — у `hand_l`/`hand_r` ± 5 см;
  спина — у спинки (`backrest_*`). Кокон (`PodTail`, `PodMid`, `PodEnd`) и фал `Strap` схлопнуты (масштаб кости ≤ 0,01).
