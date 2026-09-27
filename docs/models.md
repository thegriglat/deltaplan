# Модели (крылья, пилот, приборы, деревья)

Все модели генерируются скриптами Blender 4.3 (воспроизводимо, параметры в JSON рядом со скриптами),
исходники `.blend` и текстуры — в `assets/source/` (там `.gdignore`), готовые `.glb` — в `assets/models/`.
Сторонних ассетов нет, всё «сгенерировано» (ASSETS.md → «Модели и текстуры»).

| Файл | Что | Треугольников |
|---|---|---|
| `assets/models/glider_training.glb` | учебное однообшивочное крыло с кингпостом (в духе Wills Wing Falcon / Aeros Target) | 9 784 |
| `assets/models/glider_kingpost.glb` | килевое двухобшивочное крыло с кингпостом (в духе Wills Wing Sport 2) | 9 088 |
| `assets/models/glider_sport.glb` | спортивное бескилевое (topless) крыло, обтекатели стоек, спидбар (в духе T3 / Combat / Litespeed) | 8 660 |
| `assets/models/pilot.glb` | манекен пилота со скелетом и 8 анимациями (стоя, ходьба, разбег, бег в воздухе, заползание в кокон, лёжа, выход, выравнивание) | 3 540 |
| `assets/models/instrument.glb` | планшет-полётный компьютер (e-reader/телефон в чехле) на кронштейне в центре базовой штанги | 742 |
| `assets/models/vario_90s.glb` | обобщённый вариометр 1990-х (коробочка со стрелочной шкалой и кнопками) на хомуте левой стойки | 1 078 |
| `assets/models/trees/tree_<вид>.glb` | деревья Алтая: `pine`, `cedar`, `larch`, `birch`, `spruce`, по 3 LOD | LOD0 ≤ 2k, LOD1 ≤ 200, LOD2 = 4 |

Крыло + пилот ≈ 13,3k треугольников (бюджет 30k), приборы < 1,1k (бюджет 3k).
Никаких логотипов и названий брендов на моделях нет; фото конкретных моделей — только референсы стиля.

## Как перегенерировать

```bash
blender --background --python tools/blender/build_gliders.py      # три крыла (или -- sport)
blender --background --python tools/blender/build_pilot.py
blender --background --python tools/blender/build_instrument.py   # планшет
blender --background --python tools/blender/build_vario90s.py
xvfb-run -a blender --background --python tools/blender/build_trees.py   # Eevee печёт импосторы
tools/blender/render_all.sh                                        # скриншоты → docs/models/screenshots/
xvfb-run -a blender --background --python tools/blender/render_trees.py
godot --headless --path . --import
godot --headless --path . --script res://scenes/models_preview/check_models.gd   # контракт имён
```

Файлы: `bl_util.py` (MeshBuilder, материалы, экспорт), `glider_params.json` (форма крыльев, трапеция,
глаза пилота), `sail_texture.py` (раскраска паруса), `tree_params.json`, `tree_textures.py`,
`render_views.py` (приёмочные рендеры из готовых .glb), `render_trees.py`, `compress_png.py`.

**Параметры крыла** (`glider_params.json → wings.<id>`; размах и площадь берутся из `configs/wings/<id>.json`):
`nose_angle_deg` (угол носа, 122/126/132°), `root_chord_m`/`tip_chord_m`, `nose_forward_m` (нос впереди
подвеса), `dihedral_deg` (у спортивного −4,5° — «чайка» в полёте), `washout_deg` (крутка), `camber`
(серп профиля у корня/в середине/на конце), `double_surface`/`lower_cover` (доля хорды под нижней
обшивкой), `battens_per_side`, `kingpost_m` (0 — бескилевое), `crossbar_u`, `luff_lines`,
`basebar_width_m`, `faired_uprights`, `wheels`, цвета труб и `design` (раскраска паруса).
**Трапеция** (`control_frame`): верх стоек на 0,25 м впереди подвеса, базовая штанга на 0,9 м впереди и
1,55 м ниже киля; `vario_on_upright` — место вариометра на левой стойке. `pilot_eye` — глаза пилота
(общие для пилота, маркеров приборов и кабинного рендера).

## Контракт имён и осей

Оси в Godot: вперёд (нос) **−Z**, вверх **+Y**, вправо +X, 1 ед. = 1 м (glTF «+Y up»; в Blender вперёд
+Y, вверх +Z). Проверка — `scenes/models_preview/check_models.gd` (печатает найденные/отсутствующие ноды,
ориентацию и бюджеты; сейчас **ИТОГ: OK**).

**Крыло** `glider_<id>.glb` (начало координат = точка подвеса):
- `Sail` — меш паруса, один материал `Sail_<id>` (двусторонний, текстура 1024²: низ картинки — верхняя
  обшивка, верх — нижняя; под будущий шейдер просвечивания);
- `Frame` — передние кромки, киль, поперечина, кингпост и верхние тросы;
- `ControlFrame` — трапеция: стойки, базовая штанга, нижние тросы; её дети-пустышки:
  - `BaseBar` — центр базовой штанги;
  - `InstrumentMount` — центр базовой штанги (на оси трубы), **−Z смотрит на глаза пилота** — сюда
    крепится `instrument.glb` без смещения;
  - `VarioMount` — ось левой стойки (≈ 0,78 длины от верха), −Z смотрит на глаза пилота — сюда `vario_90s.glb`;
- `HangPoint` — точка подвеса (= начало координат), сюда крепится `pilot.glb`;
- `WingTipL`, `WingTipR` — концы передних кромок.

Ноды `Pilot`/`PilotHead` в крыле нет — пилот отдельной моделью.

**Пилот** `pilot.glb` — манекен со скелетом. Начало координат = карабин (крепится в `HangPoint`
крыла без смещения во всех позах), вперёд −Z. В Godot:
`pilot` → `Pilot` → `Skeleton3D` (меши `PilotBody` и `Helmet`, `BoneAttachment3D` с пустышками) и
`AnimationPlayer`.
- Меши: `PilotBody` (корпус, подвеска, руки, ноги, ботинки, кокон, фал; замкнутые оболочки с
  нормалями наружу — смотрится изнутри/сверху из глаз) и `Helmet` (голова, шлем и шея — прятать в
  виде от первого лица).
- Кости (`Skeleton3D`): `Hips`, `Spine`, `Chest`, `Head`, `UpperArm.L/R`, `Forearm.L/R`,
  `Hand.L/R` (кисти — ищите их, если нужна своя IK рук), `Thigh.L/R`, `Shin.L/R`, `Foot.L/R`,
  `PodTail` (кокон ног), `Strap` (фал). В Godot точки в именах костей заменяются: `Hand_L` и т. п.
  (см. `Skeleton3D.find_bone`).
- Пустышки (следуют за костями через `BoneAttachment3D`): `Head` (глаза; в позе `prone` взгляд
  горизонтально вперёд, −Z), `HandL`, `HandR` (точки хвата), `CockpitCamera` (кабинная камера лёжа).
- Анимации (24 кадр/с; `walk`, `run` зациклены в `pilot.glb.import`):

| Анимация | Длина | Что |
|---|---|---|
| `stand` | поза | стоит на старте, крыло на плечах, корпус вперёд ~30°, руки на стойках на уровне плеч |
| `walk` | 1,0 с, цикл | ходьба с крылом, руки на стойках |
| `run` | 0,67 с, цикл | разбег: корпус вперёд ~40°, ноги бегут, руки на стойках |
| `run_air` | 1,5 с | после отрыва ноги ещё «бегут в воздухе», шаги затихают |
| `climb_in` | 1,5 с | заползание в кокон: корпус ложится, ноги уходят в кокон, руки по очереди со стоек на базовую штангу |
| `prone` | поза | полёт лёжа, руки на базовой штанге, глаза = `pilot_eye` |
| `climb_out` | 1,5 с | выход из кокона перед посадкой: ноги вниз, корпус вертикально, руки на стойки |
| `flare` | поза | выравнивание/посадка: вертикально, руки высоко на стойках, ноги выпущены вперёд |

  Все позы — при `HangPoint` в начале координат; на земле (`stand`, `walk`, `run`) нижняя подошва на
  2,0 м ниже карабина (= `flight.json → visual.hang_height_m`), т. е. крыло на земле держится на
  «плечах» без поворота модели пилота. Руки стоя тянутся к стойкам средней трапеции (ширина штанги
  1,42 м), лёжа — к штанге (±0,33 м).
- **Порядок фаз (переключает код, переходы — `AnimationPlayer.play(name, blend)` или AnimationTree):**
  `stand` ⇄ `walk` → `run` (разбег) → *отрыв* → `run_air` (~1,5 с) → `climb_in` (~1,5 с) →
  `prone` (весь полёт; крен/тангаж — сдвиг ноды пилота, как сейчас) → у земли (например, ниже 15–20 м
  или по команде) `climb_out` (~1,5 с) → `flare` → касание → `stand`/`walk`. Смешивание 0,2–0,3 с
  между соседними фазами; `run_air`, `climb_in`, `climb_out` проигрываются один раз.
- ⚠ Без проигрывания анимации модель стоит в позе покоя (стоя, руки вниз). Обёртка должна
  запустить `prone`/`stand` сразу после загрузки и больше не поворачивать модель на 90° для позы стоя
  (сейчас так делает `GliderVisual`); сдвиг по крену/тангажу в полёте — как раньше.
- Вид от первого лица на старте: камера в `Head`, `Helmet` скрыт, взгляд вниз на 60–80° — видны
  грудь и подвеска, ноги и ботинки между стойками, базовая штанга с планшетом (`pilot/pov_down.png`).
- Проверка по фото: [стоя с крылом на плечах](https://commons.wikimedia.org/wiki/File:Deltaplane_au_d%C3%A9part.JPG),
  [разбег сбоку](https://commons.wikimedia.org/wiki/File:Hang_glider_start_hill_aug2004.jpg),
  [камера на крыле при разбеге](https://commons.wikimedia.org/wiki/File:2025-06-12-elift1-Start-Fuessen-FluegelkameraB.jpg)
  (шлем-POV вниз на ноги в открытых источниках не нашёлся). ✔ наклон корпуса вперёд, руки на стойках у плеч, кокон висит сзади, на
  разбеге ноги в беге. ✘ манекен угловатый, кисти не обхватывают трубу, кокон стоя — «щит» за
  бёдрами (у реальных подвесок мягкий хвост).

**Приборы** `instrument.glb`, `vario_90s.glb`: `Body` (корпус, кнопки, хомут) и `Screen` — экран,
смотрит в −Z, UV 0..1 на весь экран: u слева направо, v сверху вниз (как ViewportTexture).
Планшет: экран 92×123 мм, 3:4 портрет (под SubViewport 480×640), начало — ось базовой штанги, хомут
вдоль X. Вариометр: круглый циферблат Ø66 мм (`Screen` — круг, UV по описанному квадрату), начало — ось
стойки.

⚠ Расхождение: в docs/flight.md сказано «+Z маркера `InstrumentMount` — нормаль экрана». В моделях
принято −Z (как `look_at` в Godot), см. questions.md → «Модели». Обёртке нужно просто прикрепить .glb
к маркеру без поворота.

**Деревья** `trees/tree_<вид>.glb`: меши `LOD0`, `LOD1`, `LOD2` в одной точке (основание ствола),
реальная высота (`tree_params.json → height_m`: 18–25 м). Материалы: `Bark_<вид>` (кора 256×512),
`Leaf_<вид>` (карточки хвои/листвы 512², альфа-отсечение, glTF alphaMode MASK), `Impostor_<вид>`.
Картинки-импосторы: `trees/tree_<вид>_impostor.png` (256×512 RGBA, вид сбоку, ортокамера, низ = земля)
и атлас `trees/trees_impostor_atlas.png` (1024², ячейки 256×512: верхний ряд pine, cedar, larch, birch;
нижний — spruce).

## Шейдер паруса

Файлы: `assets/shaders/sail/sail.gdshader`, `sail_material.gd` (`SailMaterial`), `configs/sail.json`
(значения по умолчанию, с `_doc`), карты `glider_<id>_normal.png` (латы, швы, кромка майлара, подгиб
задней кромки, X-сетка ламината) и `glider_<id>_trans.png` (сколько света проходит: кромка, латы,
швы, двойная обшивка темнее). Карты пишет `tools/blender/sail_maps.py` вместе с крыльями.

- **Просвечивание**: `BACKLIGHT` = раскраска × карта просвечивания × `translucency` — снизу против
  солнца парус светится, латы и швы видны тёмными линиями. Двусторонний (`cull_disabled`).
  Парус по умолчанию **не отбрасывает тень** (`cast_shadows: false`): иначе тень верхней обшивки гасит
  свечение нижней; цена — парус отбрасывает тень (в т.ч. на пилота и землю) через cast_shadows в configs/sail.json, но сам тени не принимает (render_mode shadows_disabled) — в тени рельефа не темнеет паруса.
- **Анимация вершин** (смещение по +Y модели, м) по маске
  (вторая UV меша `Sail`, в Godot `UV2`: `UV2.x` — вес пролёта между латами, 0 на лате; `UV2.y` — доля
  хорды, у нижней обшивки +2; цвет вершин не используется — по glTF он умножается на цвет материала):
  колыхание между латами ниже `firm_speed_ms` (полное ниже `soft_speed_ms`), трепет при
  сваливании (`stall_amount`), волны от турбулентности (`turbulence`), трепет задней кромки выше
  `flutter_start_ms` с частотой `flutter_hz_per_ms · V` (VR-19). Передняя кромка и латы неподвижны.

**Подключение (GliderVisual, делает flight/интегратор):**
```gdscript
# после загрузки модели крыла (model = "glider_sport" и т. п.)
_sail_mat = SailMaterial.apply(wing_node.find_child("Sail", true, false) as MeshInstance3D, model)
# каждый кадр (или шаг физики)
SailMaterial.set_flight(_sail_mat, t.airspeed_ms, stall_amount_0_1, turbulence_0_1)
```
`stall_amount` — например доля от α_крит до срыва / флаг срыва со сглаживанием; `turbulence` —
|dV_верт/dt| воздуха, нормированная (0..1). Нет шейдера/карт — `apply` вернёт `null`, остаётся
исходный материал .glb.

**Стенд**: `scenes/models_preview/sail_preview.tscn` — слайдеры скорости/сваливания/турбулентности;
со снимками: `-- --wing=sport --view=below|keel|te|cockpit|side --airspeed=25 --stall=0 --turb=0
--shot=/путь.png [--frames=8 --dt=0.03]` (серия кадров с фиксированным временем шейдера).

**Сравнение с фото снизу против солнца** — [Sport 2 снизу у киля](https://www.willswing.com/hang-gliders/sport-2/),
[T3 спереди в полёте](https://www.willswing.com/hang-gliders/t3/),
[Falcon 4 снизу](https://commons.wikimedia.org/wiki/File:Wills_Wing_Falcon_4_hang_glider.jpg):
✔ парус светится, латы и швы тёмными линиями, передняя кромка (майлар+труба) темнее, у ламината
видна X-сетка, двойная обшивка темнее одинарной задней части. ✘ цвета насыщеннее (у прототипов много
серого прозрачного майлара), нет светового пятна солнца и мягкой тени лат на ткани; в
gl_compatibility нет теней сквозь ткань.

## Кабинная камера (главный кадр) — рекомендация

Проверено рендером и в Godot (`models_preview.tscn -- --view=cockpit`): из самих глаз (`Head`) лёжа
стойки уходят в стороны на ~70°, а парус почти над головой — в обычный FOV попадают только тросы и
планшет. Поэтому рекомендуемая камера — пустышка **`CockpitCamera` в pilot.glb**: на 0,25 м позади и
0,08 м выше `Head`, взгляд вперёд с наклоном **+10° вверх**, **вертикальный FOV 90–100°** (Godot
`Camera3D.fov`, keep height), `near` 0,02 м, меш **`Helmet` скрыть** (камера окажется над шеей, внутри
шлема). В кадре: обе стойки, базовая штанга, руки на ней, планшет в центре штанги (экран к глазам,
читается), вариометр на левой стойке, передние тросы и нос паруса с нижней поверхностью вверху.
Больше паруса — наклон +15…18° (штанга уходит к нижнему краю). Так выглядят `cockpit.png`.

## Как подключить деревья вместо конусов (делает интегратор)

Сейчас `scripts/terrain/terrain_trees.gd` строит «токарную» крону и всё двигает шейдер
`trees.gdshader` (VERTEX.y = t 0..1, VERTEX.xz — направление). Предложение:
1. В `configs/world.json → trees` добавить пути: `"models": {"conifer": ["res://assets/models/trees/tree_cedar.glb", "…spruce", "…pine", "…larch"], "birch": ["…tree_birch.glb"]}`,
   `"impostor_atlas": "res://assets/models/trees/trees_impostor_atlas.png"`, дистанции LOD
   (например 0–120 м LOD0, 120–350 м LOD1, дальше LOD2 / текстура леса).
2. На каждый вид и LOD — свой `MultiMeshInstance3D` с мешем из .glb (`find_child("LOD0").mesh`) и
   `visibility_range_begin/end` для LOD; шейдер оставляет расчёт положения по `INSTANCE_ID`, но
   вместо деформации кроны масштабирует меш: `VERTEX = VERTEX * (hh / height_m) + base`, вид выбирается
   хешем клетки (как сейчас `con`), `sink_fraction` — как было.
3. Альтернатива для дали — только атлас: один квад-билборд на экземпляр, UV = ячейка вида.
Нет файла — остаются конусы (запасной вариант по ARCHITECTURE.md).

## Скриншоты

`docs/models/screenshots/<модель>/` — `bottom.png`, `front.png`, `side.png`, `iso45.png` (1280×720,
одинаковый светлый фон и свет, Blender Eevee; у крыльев без пилота) и у крыльев `cockpit.png` — из `CockpitCamera`
(крыло + pilot.glb без Helmet + instrument.glb + vario_90s.glb, вертикальный FOV 95°). Модели: `glider_training`, `glider_kingpost`, `glider_sport`, `pilot`, `instrument`,
`vario_90s`, `trees/` (`<вид>.png` — LOD0 | LOD1 | LOD2, `trees_iso45.png` — все виды сверху под 45°).
Проверка в Godot: `scenes/models_preview/models_preview.tscn` (три крыла с пилотом и приборами),
снимок: `xvfb-run -a godot --path . --rendering-method gl_compatibility res://scenes/models_preview/models_preview.tscn -- --view=iso|below|side|cockpit --shot=/путь.png`.

## Приёмка: сравнение с фото

Для каждой модели 3 фото реального прототипа (в репозиторий не кладём) → рендер модели в близком
ракурсе → коллаж «фото | модель» (вне репозитория). Вердикт — по чек-листу: силуэт в плане,
стреловидность/размах, кингпост есть/нет, трапеция, пилот, прибор.

**glider_training** — фото: [Falcon 4 снизу](https://commons.wikimedia.org/wiki/File:Wills_Wing_Falcon_4_hang_glider.jpg),
[Falcon 4 снизу 3/4](https://www.willswing.com/hang-gliders/falcon-4/),
[Aeros Target сбоку](https://commons.wikimedia.org/wiki/File:Aeros_target_single_surface_hangglider.jpg).
✔ план (угол носа ~122°, широкая хорда, скруглённые концы), цветная полоса передней кромки, латы
линиями, видимая снизу поперечина, кингпост с верхними тросами, трапеция с колёсами, пилот под крылом.
✘ нет «пузыря» паруса между латами и прозрачности; колёса крупноваты.

**glider_kingpost** — фото: [Sport 2 снизу, сбоку в полёте, спереди на земле](https://www.willswing.com/hang-gliders/sport-2/).
✔ двухцветная нижняя обшивка до ~60 % хорды, белая задняя часть, кингпост и тросы, поперечина скрыта,
лёгкий отрицательный V. ✘ на фото ламинат с X-сеткой прозрачнее; передняя кромка у прототипа толще.

**glider_sport** — фото: [Aeros Combat снизу](https://commons.wikimedia.org/wiki/File:Combat-aeros-aile-delta-competition.jpg),
[T3 спереди и сбоку в полёте](https://www.willswing.com/hang-gliders/t3/).
✔ узкий удлинённый план (угол носа 132°, размах 10,4 м), нет кингпоста и верхних тросов, «чайка»
(−4,5°) спереди, серая майларовая кромка, обтекатели стоек, спидбар, сдвоенные боковые тросы.
✔ в профиль трапеция — одна наклонная линия (обе стойки совпадают), как на фото T3 сбоку: наклон
≈ 24° вперёд от перпендикуляра к килю, высота 1,55 м. ✘ спереди парус тоньше, чем на широкоугольном фото.

**pilot** — фото: [пилот в коконе сбоку](https://commons.wikimedia.org/wiki/File:Hg_rheinebene_aug2000.jpg),
[T3 крупно](https://www.willswing.com/hang-gliders/t3/),
[вид с киля сзади](https://commons.wikimedia.org/wiki/File:Hang_glider_Pilotenview_oct2005.jpg).
✔ лежит, голова в шлеме чуть позади и выше штанги, руки к штанге, кокон с хвостом, фал к подвесу.
✘ манекен без пальцев/складок, руки почти прямые (на фото локти согнуты), кокон уже реального.

**instrument** — фото: [Kobo с XCSoar — экран и с датчиком](https://dukeofted.wordpress.com/2016/06/21/lk8000-and-xcsoar-on-an-unmodified-kobo-mini/),
[смартфон и вариометр в обтекателе на штангу](https://delta-goodies.com/product/altair-hang-gliding-dual-pod-power-ii). ✔ чёрный чехол с большим экраном, кнопка, кронштейн-хомут
на штангу, экран наклонён к лицу (на cockpit.png читаем). ✘ портрет 3:4, а Kobo на фото — альбомный.

**vario_90s** — фото: [Flytec 4005](https://commons.wikimedia.org/wiki/File:Gleitschirmvario.jpg),
[Flytec 3005 SI и VA 2002 со стрелкой](https://naviter.com/brauniger-flytec-naviter/). ✔ «коробочка» со шкалой сверху и блоком круглых кнопок снизу,
хомут на стойку. ✘ у 4005 шкала-столбик ЖК, у нас круглый циферблат (сознательно: обобщённый «старый
стрелочный вариометр», шкала рисуется в SubViewport).

**Деревья** — по 3 фото Wikimedia Commons на вид (часть — Алтай): сосна
[Семей](https://commons.wikimedia.org/wiki/File:Pinus_sylvestris_solitary_tree_in_Semey_Ormany.jpg),
[одиночная](https://commons.wikimedia.org/wiki/File:Pinus-sylvestris-01-fws.jpg),
[Урал](https://commons.wikimedia.org/wiki/File:Pinus_sylvestris_Urals.jpg);
кедр [Чемал](https://commons.wikimedia.org/wiki/File:Chemalsky_District,_Altai_Republic,_Russia_-_panoramio_(23).jpg),
[группа](https://commons.wikimedia.org/wiki/File:Pinus_sibirica_trees_(01).jpg),
[Семинский перевал](https://commons.wikimedia.org/wiki/File:SeminskyPass_013_1582.jpg);
лиственница [Горный Алтай](https://commons.wikimedia.org/wiki/File:%D0%93%D0%BE%D1%80%D0%BD%D1%8B%D0%B9_%D0%90%D0%BB%D1%82%D0%B0%D0%B9_-_panoramio_-_Tanya_Dedyukhina_(12).jpg),
[Юстыд](https://commons.wikimedia.org/wiki/File:Larch_in_the_valley_of_the_river_yustid_02.jpg),
[раскидистая](https://commons.wikimedia.org/wiki/File:%D0%9A%D1%80%D0%B0%D1%81%D0%BD%D0%BE%D1%8F%D1%80%D1%81%D0%BA._%D0%A2%D0%BE%D1%80%D0%B3%D0%B0%D1%88%D0%B8%D0%BD%D1%81%D0%BA%D0%B8%D0%B9_%D1%85%D1%80%D0%B5%D0%B1%D0%B5%D1%82_-_panoramio.jpg);
берёза [Осло](https://commons.wikimedia.org/wiki/File:Silver_Birch_(Betula_pendula)_-_Oslo,_Norway_2020-08-04.jpg),
[одиночная](https://commons.wikimedia.org/wiki/File:Haltern_am_See,_Westruper_Heide,_Solit%C3%A4rbaum_--_2025_--_8748.jpg),
[опушка](https://commons.wikimedia.org/wiki/File:Haltern_am_See,_Westruper_Heide_--_2025_--_8721.jpg);
ель [Эстония](https://commons.wikimedia.org/wiki/File:Kuusk_Keila-Paldiski_rdt_%C3%A4%C3%A4res.jpg),
[Бескиды](https://commons.wikimedia.org/wiki/File:Picea_abies_Beskid_%C5%BBywiecki.JPG),
[ель сибирская](https://commons.wikimedia.org/wiki/File:Picea_obovata_Shekuria_River.jpg).
- `pine` — ✔ высокий голый рыжий ствол, плоская клочковатая крона наверху. ✘ крона симметричнее, чем у старых сосен.
- `cedar` — ✔ густая тёмная широкая крона от ~1/4 высоты, толстый ствол. ✘ нет многовершинности.
- `larch` — ✔ прямой ствол, узкий конус, светлая мягкая хвоя, горизонтальные ветви. ✘ ярусы регулярнее.
- `birch` — ✔ белый ствол с чёрными отметинами и тёмным комлем, овальная светлая крона, свисающие пучки. ✘ крона прозрачнее реальной летней.
- `spruce` — ✔ плотный тёмный узкий конус почти от земли, острая вершина. ✘ нижние ветви не касаются земли.

## Что улучшить на этапе хорошей графики

- Парус: цвета ближе к прототипам (прозрачный серый майлар), пятно солнца сквозь ткань, тень от лат,
  пересчёт нормалей при анимации, частичная тень паруса на пилоте.
- Пилот: риг и анимация (руки на стойках/штанге, поворот головы), складки кокона, перчатки с пальцами;
  при желании — готовая CC0-фигура.
- Приборы: кнопки/надписи текстурой, стекло с бликом; карабины, наконечники, шарниры на трапеции.
- Деревья: больше вариаций (2–3 сида на вид), импосторы с 8 ракурсов, ветер в шейдере, осенняя лиственница.

## Источники референсов (в репозиторий не кладутся)

- Wills Wing Falcon 4, Sport 2, T3: https://www.willswing.com/hang-gliders/falcon-4/, …/sport-2/, …/t3/
- Wikimedia Commons: [Falcon 4](https://commons.wikimedia.org/wiki/File:Wills_Wing_Falcon_4_hang_glider.jpg),
  [Aeros Target](https://commons.wikimedia.org/wiki/File:Aeros_target_single_surface_hangglider.jpg),
  [U2C](https://commons.wikimedia.org/wiki/File:Wills_Wing_U2C_160.jpg),
  [Aeros Combat](https://commons.wikimedia.org/wiki/File:Combat-aeros-aile-delta-competition.jpg),
  [T2C](https://commons.wikimedia.org/wiki/File:Wills_Wing_T2C_144.jpg),
  [вид пилота](https://commons.wikimedia.org/wiki/File:Hang_glider,_fly_-_panoramio.jpg),
  [пилоты в коконе](https://commons.wikimedia.org/wiki/File:Hg_rheinebene_aug2000.jpg),
  [ещё](https://commons.wikimedia.org/wiki/File:Hg_Donnersberg_Wald_1993.jpg),
  [зима](https://commons.wikimedia.org/wiki/File:Hg_winter_2006.jpg),
  [с киля](https://commons.wikimedia.org/wiki/File:Hang_glider_Pilotenview_oct2005.jpg)
- Aeros Combat, Moyes Litespeed S4, обтекатели и кронштейны Altair: https://delta-goodies.com/
- Flytec 6030: https://naviter.com/flytec-6030/; XC Tracer: https://www.xctracer.com/en/
- Деревья: Wikimedia Commons (Pinus sylvestris, Pinus sibirica, Larix sibirica, Betula pendula,
  Picea abies / Picea obovata).
Полный список с прямыми ссылками на картинки — в рабочем `refs/SOURCES.txt` агента (76 строк);
при необходимости его можно положить сюда.
