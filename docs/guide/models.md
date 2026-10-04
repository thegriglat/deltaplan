---
type: "guide"
status: "active"
module: "wings"
updated: "2026-10-03"
summary: "Модели (крылья, пилот, приборы, деревья) — Все модели генерируются скриптами Blender 4.3 (воспроизводимо, параметры в JSON рядом со скриптами), исходники .blend и текстуры — в assets/source/ (там .gdignore), готовые .glb — в assets/models/."
related: []
---
# Модели (крылья, пилот, приборы, деревья)

Все модели генерируются скриптами Blender 4.3 (воспроизводимо, параметры в JSON рядом со скриптами),
исходники `.blend` и текстуры — в `assets/source/` (там `.gdignore`), готовые `.glb` — в `assets/models/`.
Сторонних ассетов нет, всё «сгенерировано» (ASSETS.md → «Модели и текстуры»); исключение — тело пилота:
базовый меш MakeHuman из MPFB 2 (CC0), собирается скриптом.

| Файл | Что | Треугольников |
|---|---|---|
| `assets/models/glider_training.glb` | учебное однообшивочное крыло с кингпостом (в духе Wills Wing Falcon / Aeros Target) | 13 112 |
| `assets/models/glider_sport.glb` | спортивное безмачтовое (topless) крыло, обтекатели стоек, спидбар (в духе T3 / Combat / Litespeed) | 12 980 |
| `assets/models/glider_slavutich_ut.glb` | советское учебное 1979 г. (в духе Славутич-УТ): однообшивочное, угол носа 118°, 7 лат, килевой карман 0,15 м, радиальные полотнища белый/красный/синий, серебристые трубы, рубленые законцовки | 12 144 |
| `assets/models/glider_apogee.glb` | советское 1980-х (в духе «Апогея» Мысенко): мачтовое, двухобшивочное 80 %, 122°, 9 лат + промежуточные, высокий килевой карман 0,3 м, белый матовый лавсан | 12 880 |
| `assets/models/glider_atlas.glb` | советский «Атлас» (копия La Mouette Atlas): однообшивочное, 120°, 8 лат, карман 0,2 м, радужные полотнища | 13 032 |
| `assets/models/glider_target.glb` | учебное однообшивочное с колёсами (в духе Aeros Target 16), 120°, белый/синий/красный | 13 112 |
| `assets/models/glider_magic.glb` | соревновательное мачтовое конца 1980-х (в духе Airwave Magic IV 166): двухобшивочное 60 %, 124°, 11 лат, карман 0,1 м, шеврон маджента/бирюза/жёлтый | 12 576 |
| `assets/models/glider_laminar.glb` | мачтовое двухобшивочное 80 % (в духе Icaro Laminar Easy 14), 127°, 13 лат, круглые стойки, узор `laminar` | 11 696 |
| `assets/models/glider_combat.glb` | безмачтовое (в духе Aeros Combat GT 13.2): 95 %, 130°, 16 лат, обтекатели, спидбар, тёмная кромка и жёлтый центр | 13 844 |
| `assets/models/glider_icaro_piuma.glb` | N1, в духе Icaro Piuma: учебное мачтовое однообшивочное (нижняя обшивка 30 %), 120°, 7 лат, профилированные стойки, колёса, шеврон | 12 728 |
| `assets/models/glider_ww_t2c.glb` | N24, в духе Wills Wing T2C: безмачтовое двухобшивочное 92 %, 129,5°, 11 лат, обтекатели, спидбар, узор `sport` | 13 268 |
| `assets/models/glider_moyes_malibu2.glb` | N2, в духе Moyes Malibu 2 166: учебное мачтовое однообшивочное (20 %), 120,5°, 7 лат, круглые стойки, колёса | 12 248 |
| `assets/models/glider_air_f2.glb` | N3, в духе Airborne F2 190: учебное мачтовое (нижняя обшивка 30 %), 118°, 7 лат, круглые стойки, колёса, шеврон | 12 248 |
| `assets/models/glider_aeros_fox.glb` | N4, в духе Aeros Fox: учебное мачтовое (25 %), 120°, 7 лат, профилированные стойки (Finsterwalder), колёса | 12 728 |
| `assets/models/glider_ww_sport3.glb` | N10, в духе Wills Wing Sport 3 155: мачтовое двухобшивочное 85 %, 127°, 7 лат, шеврон | 12 128 |
| `assets/models/glider_ww_u2.glb` | N11, в духе Wills Wing U2 145: мачтовое двухобшивочное 84 %, 126,5°, 8 лат, профилированные стойки | 13 472 |
| `assets/models/glider_aeros_discus.glb` | N12, в духе Aeros Discus 14: мачтовое двухобшивочное 85 %, 125°, 9 лат, узор `laminar` | 12 560 |
| `assets/models/glider_air_sting3.glb` | N13, в духе Airborne Sting 3 154 (Sport): мачтовое двухобшивочное 75 %, 121°, 8 лат, профилированные стойки, шеврон | 13 472 |
| `assets/models/glider_icaro_alto.glb` | N14, в духе Icaro Alto M: мачтовое двухобшивочное 85 %, 127,5°, 8 лат | 12 992 |
| `assets/models/glider_icaro_mastr.glb` | N15, в духе Icaro MastR L: двухобшивочное 94 %, 131°, 11 лат, небольшая мачта 0,6 м (оценка) без верхних тросов — только две luff-линии (`top_wires: false`), обтекатели, тёмная кромка | 13 424 |
| `assets/models/glider_moyes_gecko.glb` | мачтовое двухобшивочное 85 % (по паспорту Moyes Gecko 155), 124°, 8 лат на сторону | 12 992 |
| `assets/models/glider_ww_t3.glb` | безмачтовое (по паспорту Wills Wing T3 144), 127°, как база sport | 13 268 |
| `assets/models/glider_moyes_litespeed_rx.glb` | безмачтовое (по паспорту Moyes Litespeed RX), 127,5°, как база sport | 13 268 |
| `assets/models/glider_moyes_litesport.glb` | мачтовое двухобшивочное (по паспорту Moyes Litesport), 127°, как база laminar | 11 696 |
| `assets/models/glider_aeros_combat_c.glb` | безмачтовое (по паспорту Aeros Combat C), 130°, как база combat | 13 844 |
| `assets/models/glider_icaro_laminar_z9.glb` | безмачтовое (по паспорту Icaro Laminar Z9), 132°, короткие латы у задней кромки | 13 844 |
| `assets/models/glider_bautek_fizz.glb` | мачтовое без шнуров-люфов (по паспорту Bautek Fizz), 130°, как база laminar | 12 944 |
| `assets/models/glider_condor_crex3.glb` | N5  Delta Flugschule Condor Crex 3 (по паспорту): мачтовое  двухобшивочное 60 %  122°  7 лат на сторону; форма — подобие базы  размах/площадь по конфигу | 12 248 |
| `assets/models/glider_condor_flex.glb` | N6  Condor FLEX / Lifter (по паспорту): мачтовое  однообшивочное  122°  5 лат на сторону; форма — подобие базы  размах/площадь по конфигу | 12 680 |
| `assets/models/glider_fs_funky.glb` | N7  Flugsport Skypoint Funky (по паспорту): мачтовое  однообшивочное  122°  7 лат на сторону; форма — подобие базы  размах/площадь по конфигу | 12 248 |
| `assets/models/glider_fs_space.glb` | N8  Flugsport Skypoint Space (по паспорту): мачтовое  двухобшивочное 72 %  122°  7 лат на сторону; форма — подобие базы  размах/площадь по конфигу | 12 248 |
| `assets/models/glider_ww_eagle.glb` | N9  Wills Wing Eagle (по паспорту): мачтовое  двухобшивочное 60 %  124°  11 лат на сторону; форма — подобие базы  размах/площадь по конфигу | 12 576 |
| `assets/models/glider_bautek_kite.glb` | N16  Bautek Kite (по паспорту): мачтовое  двухобшивочное 85 %  128°  10 лат на сторону; форма — подобие базы  размах/площадь по конфигу | 11 840 |
| `assets/models/glider_bautek_astir.glb` | N17  Bautek Astir (по паспорту): мачтовое  двухобшивочное 85 %  130°  9 лат на сторону; форма — подобие базы  размах/площадь по конфигу | 12 560 |
| `assets/models/glider_fs_crossover.glb` | N18  Flugsport Skypoint Crossover (по паспорту): мачтовое  двухобшивочное 82 %  127°  9 лат на сторону; форма — подобие базы  размах/площадь по конфигу | 12 560 |
| `assets/models/glider_seed_spyder.glb` | N19  Seedwings Spyder (по паспорту): безмачтовое  двухобшивочное 82 %  128°  8 лат на сторону; форма — подобие базы  размах/площадь по конфигу | 13 844 |
| `assets/models/glider_ww_super_sport.glb` | мачтовое среднее (в духе Wills Wing Super Sport 153): магик-база, двухобшивочное 60 %, 124°, 11 лат | 12 576 |
| `assets/models/glider_ww_ultra_sport.glb` | мачтовое среднее (в духе Wills Wing Ultra Sport 147): база magic, 124°, 11 лат | 12 576 |
| `assets/models/glider_ww_spectrum.glb` | начальное мачтовое (в духе Wills Wing Spectrum 165): база training, 121° | 13 112 |
| `assets/models/glider_moyes_litespeed_s.glb` | спортивное безмачтовое (в духе Moyes Litespeed S 4): база sport, 130° | 13 268 |
| `assets/models/glider_aeros_combat_l.glb` | соревновательное безмачтовое (в духе Aeros Combat L): база combat, 130° | 13 844 |
| `assets/models/glider_air_c4.glb` | соревновательное безмачтовое (в духе Airborne C4 13.5): база combat, 130°, 12 лат | 13 844 |
| `assets/models/glider_air_rev.glb` | соревновательное безмачтовое (в духе Airborne REV): база combat, 130°, профильные стойки | 13 844 |
| `assets/models/glider_dp_she1.glb` | соревновательное безмачтовое (в духе DesignProducts SHE 1): база combat, 130° | 12 548 |
| `assets/models/glider_seed_skyrunner_xr.glb` | среднее мачтовое (в духе Seedwings Skyrunner XR): база laminar, 127° | 11 840 |
| `assets/models/glider_ww_fusion.glb` | безмачтовое продвинутое (в духе Wills Wing Fusion 150): база sport, 128° | 13 268 |
| `assets/models/glider_ww_talon.glb` | безмачтовое продвинутое (в духе Wills Wing Talon): база sport, 128° | 13 268 |
| `assets/models/glider_ww_cross_country.glb` | мачтовое продвинутое (в духе Wills Wing Cross Country 155): база magic, 124° | 12 576 |
| `assets/models/pilot.glb` | пилот со скелетом и 8 анимациями (стоя, ходьба, разбег, бег в воздухе, заползание в кокон, лёжа, выход, выравнивание): тело человека MakeHuman (MPFB 2) с плавной привязкой к костям, кулаки в перчатках обхватывают трубу | 5 433 |
| `assets/models/instrument.glb` | планшет-полётный компьютер (e-reader/телефон в чехле) на кронштейне в центре базовой штанги | 742 |
| `assets/models/vario_90s.glb` | обобщённый вариометр 1990-х (коробочка со стрелочной шкалой и кнопками) на хомуте базовой штанги слева от планшета | 1 078 |
| `assets/models/trees/tree_<вид>.glb` | деревья Алтая: `pine`, `cedar`, `larch`, `birch`, `spruce`, по 3 LOD | LOD0 ≤ 2k, LOD1 ≤ 200, LOD2 = 4 |

Крыло + пилот ≈ 17–18,5k треугольников (бюджет 30k; из них трапеция с узлами, наконечниками и подвеской ≈ 3–4k, мелкие детали в дали упрощает авто-LOD импорта Godot), приборы < 1,1k (бюджет 3k).
Никаких логотипов и названий брендов на моделях нет; фото конкретных моделей — только референсы стиля.

## Как перегенерировать

```bash
blender --background --python tools/blender/build_gliders.py      # все крылья (или -- sport apogee …)
tools/blender/setup_mpfb.sh                                         # один раз: MPFB 2 для пилота
BLENDER_USER_RESOURCES=~/.cache/deltaplan/blender_user blender --background --python tools/blender/build_pilot.py
blender --background --python tools/blender/build_instrument.py   # планшет
blender --background --python tools/blender/build_vario90s.py
xvfb-run -a blender --background --python tools/blender/build_trees.py   # Eevee печёт импосторы
tools/blender/render_all.sh                                        # скриншоты → docs/models/screenshots/
xvfb-run -a blender --background --python tools/blender/render_trees.py
godot --headless --path . --import
godot --headless --path . --script res://scenes/models_preview/check_models.gd   # контракт имён
```

Файлы: `bl_util.py` (MeshBuilder, материалы, экспорт), `frame_parts.py` (детали трапеции: пластины,
болты, наконечники тросов, профильная труба, стропы, карабин), `glider_params.json` (форма крыльев, трапеция,
глаза пилота), `sail_texture.py` (раскраска паруса), `tree_params.json`, `tree_textures.py`,
`render_views.py` (приёмочные рендеры из готовых .glb), `render_trees.py`, `compress_png.py`.

**Центровка** — офлайн, в рантайме ничего не считается: `python3 tools/blender/aframe_cg.py [--pick-tilt]`
(грубая оценка по трубам: киль, передние кромки, поперечина, кингпост, стойки, штанга; погонные массы —
`control_frame.mass_model` (оценка), ткань — резерв `sail_mass_kg`, `null` — не учитывается) пишет в
`wings.<id>`: `cg_from_nose_m` и `nose_forward_m` = `cg_from_nose_m − hang_cg_offset_m`; `--pick-tilt` —
ещё и наклон стоек. Входы: `tools/blender/aframe_trim.json` (тангаж киля на трим-скорости и плечи
пилота в полёте; обновляется `godot --headless --path . res://tools/flight/aframe_trim.tscn -- --out=tools/blender/aframe_trim.json`).
После пересчёта пересобрать модели (`blender --background --python tools/blender/build_gliders.py`) и
`godot --headless --import`. `crossbar_from_nose_m` — центр поперечины от носа (вход, прежнее
`nose_forward_m − 0,08`); `wings.<id>` руками `cg_from_nose_m`/`nose_forward_m` не править.

**Параметры крыла** (`glider_params.json → wings.<id>`; размах и площадь берутся из `configs/wings/<id>.json`,
а если конфига крыла ещё нет — из `span_m`/`area_m2` самой записи; `area_m2` справочная, площадь подгоняют
`root_chord_m`/`tip_chord_m`):
`nose_angle_deg` (угол носа, 122/126/132°), `root_chord_m`/`tip_chord_m`, `nose_forward_m` (нос впереди
подвеса), `dihedral_deg` (поперечное V **в полёте**, кромки уже выгнуты нагрузкой; передняя кромка — прямая, без прежнего «провиса» концов −0,05·a³: советские +2…+2,5°, учебные +1,5°, мачтовые двухобшивочные 0…−1°, безмачтовые −2°; обоснование — docs/archive/plan/wings-lineup.md §9), `washout_deg` (крутка), `camber`
(серп профиля у корня/в середине/на конце), `double_surface`/`lower_cover` (доля хорды под нижней
обшивкой), `battens_per_side`, `kingpost_m` (0 — безмачтовое), `crossbar_u`, `luff_lines`,
`basebar_width_m`, `faired_uprights`, `wheels`, цвета труб и `design` (раскраска паруса).
Необязательные (по умолчанию — прежний вид): `keel_pocket_m` (0 — нет; высокий килевой карман —
«плавник» паруса под килем, часть меша `Sail`, вырез у узла трапеции, глубже всего у хвоста; UV2 — вес 0,
не колышется), `short_battens` (промежуточные короткие латы от 0,6 хорды к задней кромке: линии на
раскраске и швы в карте нормалей), `tip_round` (true; false — «рубленая» законцовка 1980-х),
`sail_rough` (0,75; матовый лавсан — 0,92), `wire_r_m` (радиус тросов, 0,0045; у старых — толще),
`bar_grips` (true — резиновые накладки на штанге под руками; false у советских — голая труба),
`upright_bend` (нет; `{t0, fwd_m, out_m}` — изгиб нижней части стоек: от доли длины t0 от верха
вперёд/наружу до fwd_m/out_m, у `sport`/`combat` 0,5 и 0,03 м — выше t0 стойка прямая, хват стоя не
меняется), `strap_color` (цвет основной стропы подвески), `top_wires` (true; false — мачта без верхних тросов к носу, хвосту и поперечине, от неё только `luff_lines`: Icaro MastR). `antidive_tube` (нет; только «Апогей»): антипикирующая трубка у законцовки, по одной на полукрыло — `{a0, a1, t1, r_m}`: от передней кромки на станции a0 (доля полуразмаха) назад-внутрь под ≈45° к точке t1 (доля хорды) на станции a1, пересекает последнюю полную лату; идёт под парусом (под нижней обшивкой, дальше — под верхней), материал труб, часть меша `Frame`, r_m — радиус (0,01 — труба Ø20 мм).
Узоры `design.pattern`: `center_v`, `chevron`, `sport`, а также `panels` (радиальные полотнища от носа:
`design.panels` — цвета от киля к законцовке по кругу, `panel_count` — полотнищ на полукрыло, `seam` —
цвет строчки; `design.bottom: "panels"` — те же полотнища на нижней обшивке), `laminar` (светлая кромка,
крупные цветные поля сзади), `combat` (тёмная кромка, контрастный центр). `design.le_band` — ширина полосы
кромки (доля хорды; по умолчанию 0,28 у `sport`, иначе 0,16). Надписей и логотипов нет.
**Трапеция** (`control_frame`, контракты A1/A2 — docs/contracts/aframe-geometry.md): у каждого крыла
свои `upright_tilt_deg` (наклон стоек к нормали киля в плоскости симметрии, низом вперёд, 4…13°; подбирает
`aframe_cg.py --pick-tilt` так, чтобы в полёте на балансировке середина базовой штанги была под серединой
плеч пилота), `upright_len_m` (длина стойки по оси от болта под килем до оси штанги в углу, 1,6…1,75 м,
как у прежней трапеции), `hang_from_apex_m` (подвеска вдоль киля относительно оси стоек, + — впереди;
умолчание `{single: −0,10, double: 0,0}`) и `hang_cg_offset_m` (подвеска впереди центра масс на 0,015 м);
`vario_bar_offset_m` (0,2) — вариометр на базовой штанге на столько левее центра.
`upright_top_x_m`/`upright_top_z_m` (±0,055; −0,02) — ось стоек в узле под килем. В игре геометрию стоек
дают **маркеры** модели (`UprightTopL/R`, `UprightBottomL/R`), PilotArmIK ставит руки по ним; в конфиге
`flight.json` координат стоек нет. `upright_r_m` (0,016),
`basebar_r_m` (0,015) — радиусы труб, накладки +2,5 мм (`bar_grip_x_m`: |x| 0,22–0,43), кулак
перчатки — внутренний радиус 20,5 мм; `fairing_chord_m`/`fairing_thick_m` (0,08/0,029) — обтекатель;
`speedbar_dip_m` (0,05) и `speedbar_flat_half_m` (0,42) — спидбар безмачтовых: ровная середина
(хват ±0,33, планшет, вариометр) ниже концов, изгибы к углам. Детали трапеции — `frame_parts.py`.
Референсы и приоритеты — docs/research/control_frame_refs.md. `pilot_eye` — глаза пилота
(общие для пилота, маркеров приборов и кабинного рендера).

## Контракт имён и осей

Оси в Godot: вперёд (нос) **−Z**, вверх **+Y**, вправо +X, 1 ед. = 1 м (glTF «+Y up»; в Blender вперёд
+Y, вверх +Z). Проверка — `scenes/models_preview/check_models.gd` (печатает найденные/отсутствующие ноды,
ориентацию и бюджеты; сейчас **ИТОГ: OK**).

**Крыло** `glider_<id>.glb` (начало координат = точка подвеса):
- `Sail` — меш паруса, один материал `Sail_<id>` (двусторонний, текстура 1024²: низ картинки — верхняя
  обшивка, верх — нижняя; под будущий шейдер просвечивания);
- `Frame` — передние кромки, киль, поперечина, кингпост и верхние тросы;
- `ControlFrame` — трапеция: стойки (круглые Ø32 мм или каплевидный обтекатель 80×29 мм),
  базовая штанга (Ø30 мм; у безмачтовых — спидбар), узел стоек под килем (щёки, болты, наконечники
  стоек), углы (пластины, три болта), наконечники тросов (ушко, коуш, обжимная втулка), нижние тросы,
  подвеска (стропа вокруг киля, карабин с центром перекладины над `HangPoint`, страховочная петля).
  Материалы: `Tube_<id>`, `Fitting` (тёмные пластины, наконечники), `Steel` (болты, карабин,
  наконечники тросов), `Grip` (накладки на штанге), `Webbing`/`WebbingBackup` (стропы), **`Wire` — только
  сами тросы** (по нему ленточка-telltale ищет угол трапеции и боковой трос, docs/guide/telltale.md);
  её дети-пустышки:
  - `BaseBar` — центр базовой штанги;
  - `UprightTopL/R` — ось стойки у болта под килем, `UprightBottomL/R` — ось стойки у оси штанги в углу
    (единственный источник геометрии стоек для игры; нет маркера — `push_error`, без запасного числа);
  - `InstrumentMount` — на выносе (кронштейне) 0,6 м вперёд и 0,12 м вверх от центра базовой штанги, **−Z смотрит на глаза пилота** — сюда
    крепится `instrument.glb` без смещения;
  - `VarioMount` — на таком же выносе, в 0,2 м левее центра (между планшетом и левой рукой), −Z смотрит
    на глаза пилота, горизонталь циферблата — вдоль штанги — сюда `vario_90s.glb`. При взгляде вниз
    (0°, −60°) в кадр попадает только штанга между кулаками (±0,35 м): на стойке (даже у угла
    трапеции) вариометр был бы в ~55–75° влево, вне кадра (карточка plan/models/01);
- `HangPoint` — точка подвеса (= начало координат), сюда крепится `pilot.glb`;
- `WingCG` — центр масс крыла на киле (на `hang_cg_offset_m` позади `HangPoint`);
- `WingTipL`, `WingTipR` — концы передних кромок.

Ноды `Pilot`/`PilotHead` в крыле нет — пилот отдельной моделью.

**Пилот** `pilot.glb` — человек со скелетом (≈ 5,4k треугольников: тело 2,7k, кисти 0,9k, подвеска/кокон/
краги/воротник 1k, голова 0,4k, шлем с визором 0,4k). Начало координат = карабин (крепится в `HangPoint`
крыла без смещения во всех позах), вперёд −Z. В Godot:
`pilot` → `Pilot` → `Skeleton3D` (меши `PilotBody` и `Helmet`, `BoneAttachment3D` с пустышками) и
`AnimationPlayer`.
- Меши: `PilotBody` (тело, подвеска, руки, ноги, ботинки, перчатки, кокон, фал; горловина закрыта
  крышкой и воротником — из глаз внутрь тела не заглянуть) и `Helmet` (голова, шея, шлем и визор —
  прятать в виде от первого лица).
- Тело — базовый меш MakeHuman из MPFB 2.0.17 (`tools/blender/pilot_mpfb.py`): мужчина ~30 лет,
  атлетичный, рост 1,78 м (макро-параметры `MACRO`), лицом вперёд, прорежен по частям (тело / кисти /
  голова — своё число треугольников, швы закрыты крагами и воротником). Привязка плавная: веса рига
  MPFB `game_engine` слиты в наши 17 костей (таз → `Hips`, spine_01 → `Spine`, spine_02/03 и ключицы →
  `Chest`, шея — пополам `Head`/`Chest`, кисть и все пальцы → `Hand`, стопа и носок → `Foot`, ≤ 4
  влияния). Длины звеньев, плечи, тазобедренные суставы, разведение ног, глаза — с суставов меша
  (`fit_dims`, печатается `DIMS`). Одежда — материалами по областям: куртка (`Jacket`) — грудь и руки,
  подвеска (`Pod`) — от пояса до колен (ровный край под поясом-лямкой), брюки (`Trousers`), лицо
  (`Skin`). Ботинки процедурные: голенище до 15 см по контурам стопы MPFB на высотах (закрытый
  носок, пятка; брюки заправлены, стопы MPFB внутри удалены; тёмная кожа `Boot`) и резиновая подошва
  `Sole` 2 см по контуру стопы, на 5 мм шире верха (≈ 200 треугольников на ботинок; низ голенища на
  `Foot`, верх — `Shin`/`Foot`). Подвеска (лямки, пояс, спинка
  с креплением фала), кокон, фал, воротник, краги, шлем и визор — процедурные, по размерам меша; шлем
  открытый, визор — изогнутый щиток по сфере шлема (от края шлема до кончика носа, к бокам сужается
  к кнопкам-шарнирам), тонированное зеркальное стекло (`Visor`: metallic 0,85, roughness 0,07 —
  отражает небо) закрывает глазницы (глаз у меша нет).
- Сборка: `tools/blender/setup_mpfb.sh` один раз ставит MPFB (zip с extensions.blender.org, проверка
  sha256) в отдельный каталог `~/.cache/deltaplan/blender_user`, не в `~/.config/blender`; сборку
  запускать с `BLENDER_USER_RESOURCES=~/.cache/deltaplan/blender_user` (без MPFB скрипт выходит с
  подсказкой). `PILOT_OUT=<каталог>` — записать `pilot.glb`/`.blend` не в assets. MPFB в игру не входит.
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
  1,42 м), лёжа — к штанге (±0,33 м); точки хвата (`HandL`/`HandR`) — на оси трубы, как у
  `PilotArmIK` в игре.
- Перчатки (материалы `Glove` — чёрная полуматовая кожа, `GlovePanel` — серый ремешок на краге;
  ≈ 450 треугольников на кисть + краг): кисти MakeHuman, пальцы согнуты вокруг трубы до запекания
  (каждая фаланга касается окружности «труба + толщина пальца», толщины меряются по мешу; большой
  палец обходит трубу навстречу, ось трубы косо через ладонь), запястье разогнуто ~28°, чтобы ось
  трубы шла поперёк предплечья и пересекала его продолжение (хват в 0,112 м от запястья). Краг-раструб
  ~8 см поверх рукава обнимает меш руки с зазором и закрывает шов кисть/рукав. Кулак жёсткий на кости
  `Hand.L/R` (часть поворота кисти вокруг предплечья берёт предплечье — пронация без перекрута),
  ось трубы в нём — ось X кости через точку хвата, ни одна вершина кулака не ближе 20 мм к оси (штанга
  15 мм, с накладкой 17,5 мм; круглая стойка 16 мм). Чтобы один кулак подошёл и к штанге, и к стойкам, крен кисти вокруг
  предплечья задаётся в анимации по трубе (`Pose.grips`): на штанге хват сверху, большие пальцы
  внутрь; на стойках — большие пальцы вверх; в `climb_in`/`climb_out` кисть поворачивается при
  перехвате. ⚠ Обтекатели стоек (`sport`, `combat`, хорда ~8 см) длиннее кулака: пальцы спереди
  чуть уходят в обтекатель (сзади не видно).
- **Порядок фаз (переключает код, переходы — `AnimationPlayer.play(name, blend)` или AnimationTree):**
  `stand` ⇄ `walk` → `run` (разбег) → *отрыв* → `run_air` (~1,5 с) → `climb_in` (~1,5 с) →
  `prone` (весь полёт; крен/тангаж — сдвиг ноды пилота, как сейчас) → у земли (например, ниже 15–20 м
  или по команде) `climb_out` (~1,5 с) → `flare` → касание → `stand`/`walk`. Смешивание 0,2–0,3 с
  между соседними фазами; `run_air`, `climb_in`, `climb_out` проигрываются один раз.
- ⚠ Без проигрывания анимации модель стоит в позе покоя (стоя, руки вниз). Обёртка должна
  запустить `prone`/`stand` сразу после загрузки; `GliderVisual` на 90° модель больше не поворачивает
  (поворачивает только заглушку без анимаций). На земле (`stand`/`walk`/`run`) — сдвиг по крену и
  наклон модели назад на 15° вокруг хвата рук на стойках (`GROUND_LEAN_BACK_DEG`, ступни на прежней
  высоте): в позе `stand` ступни на 0,3 м позади таза и глаза на 0,7 м впереди ступней, иначе взгляд
  вниз не достаёт до ног. Итог: ступни→глаза 14° от вертикали, корпус вперёд 17°, ноги 4°
  (`tests/flight/test_pilot_pose.gd`). Сдвиг по крену/тангажу в полёте — как раньше.
- Вид от первого лица на старте: камера в `Head`, `Helmet` скрыт, взгляд вниз на 60–80° — видны
  грудь и подвеска, ноги и ботинки между стойками, базовая штанга с планшетом (`pilot/pov_down.png`).
- Проверка по фото: [стоя с крылом на плечах](https://commons.wikimedia.org/wiki/File:Deltaplane_au_d%C3%A9part.JPG),
  [разбег сбоку](https://commons.wikimedia.org/wiki/File:Hang_glider_start_hill_aug2004.jpg),
  [камера на крыле при разбеге](https://commons.wikimedia.org/wiki/File:2025-06-12-elift1-Start-Fuessen-FluegelkameraB.jpg)
  (шлем-POV вниз на ноги в открытых источниках не нашёлся). ✔ человеческие пропорции и плавные
  суставы, наклон корпуса вперёд, руки на стойках у плеч, кокон висит сзади, на разбеге ноги в беге,
  кулаки в перчатках с пальцами обхватывают стойки и штангу, краги без шва у запястья, открытый шлем с
  визором. ✘ одежда «облегающая» (без складок, куртка — цветом по телу), лямки подвески местами
  уходят в плечи при поднятых руках, кокон стоя — «щит» за бёдрами (у реальных подвесок мягкий
  хвост), в `climb_out` при перехвате (кадр 12) рука на 8 см не достаёт до промежуточной точки.

**Приборы** `instrument.glb`, `vario_90s.glb`: `Body` (корпус, кнопки, хомут) и `Screen` — экран,
смотрит в −Z, UV 0..1 на весь экран: u слева направо, v сверху вниз (как ViewportTexture).
Планшет: экран 92×123 мм, 3:4 портрет (под SubViewport 480×640), начало — ось базовой штанги, хомут
вдоль X. Вариометр: круглый циферблат Ø66 мм (`Screen` — круг, UV по описанному квадрату), начало — ось
стойки.

⚠ Расхождение: в docs/guide/flight.md сказано «+Z маркера `InstrumentMount` — нормаль экрана». В моделях
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
(крыло + pilot.glb без Helmet + instrument.glb + vario_90s.glb, вертикальный FOV 95°). Модели: `glider_training`, `glider_sport`, `glider_slavutich_ut`, `glider_apogee`, `glider_atlas`, `glider_target`, `glider_magic`, `glider_laminar`, `glider_combat`, `pilot`, `instrument`,
`vario_90s`, `trees/` (`<вид>.png` — LOD0 | LOD1 | LOD2, `trees_iso45.png` — все виды сверху под 45°).
`control_frame/` — трапеция в игре до/после деталировки (`<крыло>_<вид>_before|after.jpg`: L — взгляд влево на стойку, DS — вниз стоя, DF — вниз в полёте) и крупные планы `frame_*.jpg` из
`tools/shots/frame_shot.tscn` (крыло + пилот на пустой сцене: виды из глаз F, DF, U, L, R, UB и снаружи XA — подвес и узел стоек, XC — угол, XS, XF; запуск — в шапке скрипта).
Проверка в Godot: `scenes/models_preview/models_preview.tscn` (три крыла с пилотом и приборами),
снимок: `xvfb-run -a godot --path . --rendering-method gl_compatibility res://scenes/models_preview/models_preview.tscn -- --view=iso|below|side|cockpit --shot=/путь.png`.

**Для сайта.** `docs/models/screenshots/glider_<id>/iso45.jpg` (все 48 крыльев) — JPEG качество 85, 1280×720, крыло обрезано по содержимому и центрировано с полем ~3,5%, заливка фона. Генерация: `tools/blender/render_wings_site.sh` → рендер PNG через `render_views.py` и преобразование `wings_site_jpg.py`.

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

**glider_kingpost** (Wills Wing Sport 2) — убрана из игры 28.09.2026 вместе с крылом.

**glider_sport** — фото: [Aeros Combat снизу](https://commons.wikimedia.org/wiki/File:Combat-aeros-aile-delta-competition.jpg),
[T3 спереди и сбоку в полёте](https://www.willswing.com/hang-gliders/t3/).
✔ узкий удлинённый план (угол носа 132°, размах 10,4 м), нет кингпоста и верхних тросов, «чайка»
(−4,5°) спереди, серая майларовая кромка, обтекатели стоек, спидбар, сдвоенные боковые тросы.
✔ в профиль трапеция — одна наклонная линия (обе стойки совпадают), как на фото T3 сбоку: наклон
≈ 24° вперёд от перпендикуляра к килю, высота 1,55 м. ✘ спереди парус тоньше, чем на широкоугольном фото.

**pilot** — фото: [пилот в коконе сбоку](https://commons.wikimedia.org/wiki/File:Hg_rheinebene_aug2000.jpg),
[T3 крупно](https://www.willswing.com/hang-gliders/t3/),
[вид с киля сзади](https://commons.wikimedia.org/wiki/File:Hang_glider_Pilotenview_oct2005.jpg).
✔ лежит, голова в шлеме чуть позади и выше штанги, руки к штанге, кокон с хвостом, фал к подвесу,
тело человека MakeHuman, кулаки на штанге большими пальцами внутрь.
✘ одежда без складок, руки почти прямые (на фото локти согнуты), кокон уже реального.

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
- Пилот: поворот головы, складки кокона и одежды, мягкий хвост кокона стоя.
- Приборы: кнопки/надписи текстурой, стекло с бликом.
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

**Подвеска (A1 v3)** — `wings.<id>.hang_source`: `passport` (положение подвески на киле от носа из паспорта/руководства
производителя: `hang_from_nose_m`, `hang_ref`; данные и цитаты — `tools/research/data/wing_passports/hang_passports.json`;
сейчас 8 крыльев: air_f2, air_sting3, ww_t2c, aeros_combat_l, moyes_litespeed_rx/s, moyes_litesport, moyes_malibu2) или `cg`
(центр масс труб + 1,5 см вперёд). Паспорт добавляется в `hang_passports.json`, затем `aframe_cg.py --pick-tilt`.

**Высота пилота в полёте (A3.5)** — длина подвески `configs/pilot.json → visual.hang_length_m` (карабин — низ
торса) выводится из модели пилота: низ торса над осью базовой штанги 0,37 ±0,03 м (A3.5 v5). Регулируется
`pilot_eye[2]` в `glider_params.json` (глаза в позе prone; выше значение — пилот выше); после смены пересобрать
`build_pilot.py`, обновить `aframe_trim.json`, `aframe_cg.py --pick-tilt`, `build_gliders.py`, `--import`;
`body_below_hang_m` — центр тела для маятника (визуал; физика его не читает).
