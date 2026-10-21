---
type: "contract"
status: "active"
module: "trike-model"
area: "flight"
updated: "2026-10-22"
summary: "Размеры трайка trike_params.json (TK-K1), модель тележки trike.glb с узлом винта (TK-K2), поза пилота sit в pilot.glb (TK-K3)."
related: ["docs/plan/trike-model.md", "docs/guide/models.md", "docs/guide/models/pilot.md"]
contracts: [{"id": "TK-K1", "version": 1}, {"id": "TK-K2", "version": 1}, {"id": "TK-K3", "version": 1}]
---

# Контракты модуля trike-model

Оси: в Blender и в JSON — +X вправо, +Y вперёд, +Z вверх; в Godot — +X вправо, +Y вверх, вперёд −Z
(Godot = (x, z, −y) Blender). Единицы — м, °, об/мин. Начало координат тележки и пилота — точка подвески крыла `HangPoint`
(болт на вершине мачты; у пилота — карабин). Контрактные тесты — `tests/contracts/test_trike_model_k<n>.gd`
(фильтр `trike_model_k<n>`): версия в заголовке раздела; владелец стыка дописывает проверку интерфейса.

## TK-K1. Размеры трайка — tools/blender/trike_params.json (v1)

- Владелец: TK-1. Потребители: TK-2 (поза), TK-3 (модель), TK-4 (кадры, проверка посадки). Правка — только координатор.
- Файл JSON, ключи верхнего уровня:
  - `version`: 1.
  - `prototype`: `{"name": str, "seats": 1|2, "sources": [url, …]}` — по чему строится.
  - `dims`: словарь `<ключ>: {"value": число|str, "src": str}`; `src` — url/документ со страницей или «вывод: …» (как получено
    из других чисел/фото). Обязательные ключи (м, если не указано): `length`, `width`, `hang_height` (точка подвески над землёй,
    стоя на колёсах без нагрузки), `wheelbase`, `track`, `wheel_front_d`, `wheel_rear_d`, `tire_front_w`, `tire_rear_w`,
    `mast_tilt_deg` (наклон мачты вперёд от вертикали, °), `seat_height` (подушка переднего сиденья над землёй),
    `engine` (str, модель), `engine_l`, `engine_w`, `engine_h`, `prop_d`, `prop_blades` (int), `prop_axis_height`
    (ось винта над землёй), `prop_tilt_deg` (ось винта от горизонтали, + нос вверх), `prop_rpm` (обороты винта на крейсерском),
    `prop_cw_from_behind` (bool).
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

## TK-K2. Модель тележки — assets/models/trike/trike.glb (v1)

- Владелец: TK-3. Потребители: TK-4, будущий модуль trike (игра).
- Сборка: `blender --background --python tools/blender/build_trike.py` (Blender 4.3) читает `tools/blender/trike_params.json`;
  исходник `assets/source/trike/trike.blend`; общие функции — `tools/blender/bl_util.py`, `wheel_parts.py`, `frame_parts.py`
  (не ломать чужое). Затем `godot --headless --path . --import`.
- Оси Godot: +Y вверх, нос к −Z, 1 = 1 м; начало координат — точка подвески крыла (вершина мачты); земля — y = `ground_z`
  (низ колёс ± 1 см).
- Узлы (поиск `find_child` по дереву):
  - `Trike_LOD0` (≤ 5500 треугольников), `Trike_LOD1` (≤ 1200), `Trike_LOD2` (≤ 250) — `MeshInstance3D`, всё кроме винта;
  - `Propeller` — `Node3D` на ступице винта, его локальная ось Z — ось двигателя (вращение винта — поворот вокруг `basis.z`
    узла `Propeller`); дети `Prop_LOD0` (≤ 500), `Prop_LOD1` (≤ 80) — `MeshInstance3D`, центр ступицы в начале узла;
  - маркеры `Node3D`: `HangPoint` (0,0,0), `WheelFront`, `WheelRearL`, `WheelRearR` (центры осей колёс).
- Анимация: `AnimationPlayer` с `prop_spin` — один оборот `Propeller` вокруг его локальной Z, линейно, длина 1,0 с, цикл
  (в игре `speed_scale = prop_rpm / 60`); направление — по `prop_cw_from_behind`.
- Материал: вершинные цвета; шина — материал с картинкой `wheel_tire` (`wheel_parts.tire_texture()`, внешний uri
  `assets/textures/wheel/tire.png`); новых текстур нет (`python3 tools/check_textures.py main` — код 0); без прозрачности.
- Размеры модели = `dims` (± 2 %): база, колея, диаметры колёс и винта, `hang_height`; сиденье, спинка, подножки и педаль —
  по `seat`.
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
