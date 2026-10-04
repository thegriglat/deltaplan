# Ассеты

Все сторонние и сгенерированные ассеты проекта: что это, откуда, лицензия, где используется.
Правила:
- проект пока **некоммерческий**: допустимы бесплатные ассеты под любыми открытыми лицензиями, включая некоммерческие (CC-BY-NC, AudioLDM2/AudioGen, BBC Sound Effects и т. п.);
- **записываем ВСЕ использованные материалы** — ассеты, данные, шрифты, модели генерации (какая модель, её лицензия, промпт/параметры);
- ассеты с некоммерческой или ограниченной лицензией помечаем **⚠ NC** в колонке «Лицензия». Перед продажей делается отдельный прогон на соответствие лицензиям: всё с ⚠ NC заменяется;
- «только для личного использования» и лицензии, запрещающие распространение в составе игры, не берём;
- сначала ищем готовое для Godot: [Godot Asset Library](https://godotengine.org/asset-library), Kenney, Quaternius, Poly Haven, ambientCG;
- если подходящего нет, генерируем сами (процедурно или на GPU) и отмечаем «сгенерировано».

Добавляя ассет, допиши строку в нужную таблицу. Подробные атрибуции для звуков лежат в [assets/sounds/LICENSES.md](assets/sounds/LICENSES.md).

## Шрифты
| Файл | Что | Источник | Лицензия | Где используется |
|---|---|---|---|---|
| `assets/fonts/DSEG7Classic-Bold.ttf` | семисегментные цифры | [DSEG](https://github.com/keshikan/DSEG) | OFL 1.1 | цифры на LCD-экране прибора |
| `assets/fonts/NotoSansMono-CondensedBold.ttf` | моноширинный шрифт с кириллицей | [Noto](https://fonts.google.com/noto) | OFL 1.1 | подписи на экране прибора |
| `assets/fonts/NotoSans-CondensedBold.ttf` | шрифт с кириллицей (не моно) | [Noto](https://fonts.google.com/noto) | OFL 1.1 | цифры на экране прибора (`instruments.json → digits_font`) |

## Звуки
| Файл | Что | Источник | Лицензия | Где используется |
|---|---|---|---|---|
| — | звук вариометра | сгенерировано процедурно, `scripts/audio/vario_synth.gd` | — | вариометр |
| `assets/sounds/airflow/wind_rush_loop.ogg, wind_rumble_loop.ogg, wires_whistle_loop.ogg` | поток воздуха: шум обтекания, бафтинг у ушей, свист тросов (лупы, pitch ∝ скорости) | сгенерировано процедурно, `tools/sounds/synth_wind.py` | — | звук полёта (поток воздуха) |
| `assets/sounds/airflow/wind_ears_loop.ogg` | ветер в ушах на малой скорости (луп) | [freesound 611197](https://freesound.org/s/611197/) klankbeeld | CC0 | поток воздуха 20–50 км/ч |
| `assets/sounds/airflow/air_rush_fast_loop.ogg` | рёв потока на большой скорости (луп) | [freesound 20108](https://freesound.org/s/20108/) cognito perceptu | CC0 | поток воздуха 55–90 км/ч |
| `assets/sounds/sail/wing_under_wind_loop.ogg` | шелест ткани крыла под нагрузкой (луп) | [freesound 836086](https://freesound.org/s/836086/) bruno.auzet | CC0 | парус |
| `assets/sounds/sail/sail_luff_loop.ogg` | трепетание паруса (луп) | [freesound 154794](https://freesound.org/s/154794/) felix.blume | CC0 | малая скорость, сваливание |
| `assets/sounds/sail/sail_snap_01…06.ogg` | одиночные хлопки паруса | [freesound 57280](https://freesound.org/s/57280/) _earthbound_ | CC0 | сваливание, болтанка |
| `assets/sounds/sail/sail_flutter_synth_loop.ogg` | синтетическое трепетание (запасной вариант) | сгенерировано, `tools/sounds/synth_wind.py` | — | парус (альтернатива) |
| `assets/sounds/run/step_grass_01…08.ogg` | шаги бега по траве | [freesound 556042](https://freesound.org/s/556042/) Nox_Sound | CC0 | разбег, пробежка после посадки |
| `assets/sounds/run/step_gravel_01…08.ogg` | шаги бега по щебню и камням | [freesound 556002](https://freesound.org/s/556002/) Nox_Sound | CC0 | разбег |
| `assets/sounds/run/breath_run_loop.ogg, breath_pant_after.ogg` | дыхание на бегу (луп), одышка | [freesound 609482](https://freesound.org/s/609482/) Lashim | CC0 | разбег, после посадки |
| `assets/sounds/landing/land_soft_grass.ogg` | мягкое касание травы | [freesound 73583](https://freesound.org/s/73583/) J.Zazvurek | **CC-BY 4.0** (атрибуция в титрах) | мягкая посадка |
| `assets/sounds/landing/land_hard_dirt.ogg` | тяжёлое падение на грунт | [freesound 504626](https://freesound.org/s/504626/) leonelmail | CC0 | жёсткая посадка |
| `assets/sounds/landing/frame_hit_alu.ogg` | удар по алюминиевой трубе | [freesound 352775](https://freesound.org/s/352775/) spoonbender | **CC-BY 4.0** (атрибуция в титрах) | удар каркаса |
| `assets/sounds/landing/kenney_impact*.ogg` | лёгкие металлические и мягкие удары | [Kenney Impact Sounds](https://kenney.nl/assets/impact-sounds) | CC0 | касание трапецией, посадка |
| `assets/sounds/frame/creak_01…06.ogg` | скрип подвески и стропы под нагрузкой | [freesound 862995](https://freesound.org/s/862995/) Valerie-Vivegnis | CC0 | перегрузки, разбег |
| `assets/sounds/frame/carabiner_clip.ogg` | щелчок карабина | [freesound 399926](https://freesound.org/s/399926/) Kinoton | CC0 | пристёгивание перед стартом |
| `assets/sounds/ambient/launch_meadow_loop.ogg` | горный луг: птицы, насекомые, далёкие колокольчики | [freesound 454841](https://freesound.org/s/454841/) Tonmeister88 | CC0 | окружение на старте, затухает с высотой |
| `assets/sounds/ambient/birds_alpine_loop.ogg` | птицы на альпийском пастбище | [freesound 855955](https://freesound.org/s/855955/) Nordliecht | CC0 | окружение у земли |
| `assets/sounds/ambient/cowbells_distant_loop.ogg` | далёкие коровьи колокольчики | [freesound 437147](https://freesound.org/s/437147/) neilraouf | CC0 | окружение у земли |
| `assets/sounds/ambient/wind_launch_gusts_loop.ogg` | порывистый ветер на хребте | [freesound 454092](https://freesound.org/s/454092/) kyles | CC0 | ветер на старте (громкость ∝ ветру) |
| `assets/sounds/ambient/grass_wind_loop.ogg` | шелест травы на ветру | [freesound 146436](https://freesound.org/s/146436/) felix.blume | CC0 | ветер на старте |

## Рельеф и карты
| Файл | Что | Источник | Лицензия | Где используется |
|---|---|---|---|---|
| `data/terrain/altai/detail.f32.br` | высоты 40×40 км вокруг Манжерока, шаг 25 м (float32, brotli; пересэмплировано и сглажено `tools/terrain/fetch_dem.py`) | [Copernicus DEM GLO-30](https://registry.opendata.aws/copernicus-dem/) (ESA/DLR/Airbus, 1″ ≈ 30 м) | Copernicus DEM licence: бесплатно, любое использование и распространение с атрибуцией «produced using Copernicus WorldDEM-30 © DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018 provided under COPERNICUS by the European Union and ESA» | локация «Алтай», зона полётов |
| `data/terrain/altai/far.f32.br` | высоты 160×160 км, шаг 100 м (фон до горизонта) | [AWS Terrain Tiles](https://registry.opendata.aws/terrain-tiles/) (Terrarium z10: SRTM, GMTED2010, ETOPO1 и др.) | открытые данные; атрибуция источников по [списку Mapzen](https://github.com/tilezen/joerd/blob/master/docs/attribution.md) (SRTM — public domain) | локация «Алтай», дальний рельеф |
| `data/terrain/altai/meta.json` | размеры сеток, атрибуция | сгенерировано `tools/terrain/fetch_dem.py` | — | загрузка локации |
| `data/terrain/altai/*_water.png` | маски рек (Катунь, Майма и др.) | сгенерировано из высот `tools/terrain/rivers.py` (сток priority-flood) | как у высот | вода на рельефе |
| `data/terrain/<локация>/*_surface.png`, `surface.json`, `*_detail10.png` | карта поверхности (классы: лес, луг, пашня, кустарник, скалы/грунт, вода, застройка, снег), 8 бит, шаг 25 м / 100 м; мода 3×3 подвыборок; `*_detail10.png` (T02) — маска доли леса 10 м для резкой кромки, `tools/terrain/fetch_landcover.py` | [ESA WorldCover 2021 v200, 10 м](https://registry.opendata.aws/esa-worldcover-vito/) (AWS, COG) | **CC-BY 4.0**: «© ESA WorldCover project 2021 / Contains modified Copernicus Sentinel data (2021) processed by ESA WorldCover consortium» (атрибуция в титрах) | цвет земли, деревья и источники термиков (VR-4) — все локации |
| `user://terrain_cache/worldcover/…` (не в репо) | тайлы WorldCover, скачанные в игре для выбранной точки | ESA WorldCover (как выше) | CC-BY 4.0 (как выше) | рантайм-карта поверхности (`worldcover_loader.gd`) |
| `data/terrain/ongudai/*` | высоты 40×40 км (Copernicus, 25 м) + 160 км (Terrarium, 100 м), реки, карта поверхности — Онгудай, перевал Каянча | Copernicus DEM GLO-30, AWS Terrain Tiles, ESA WorldCover | как у строк выше (Copernicus DEM licence, открытые данные, CC-BY 4.0) | локация «Алтай — Онгудай» |
| `data/terrain/askarovo/*` | то же — хребет Биягода у Аскарово (Башкортостан) | то же | то же | локация «Башкирия — Аскарово» |
| `data/terrain/aushkul/*` | то же — озеро Аушкуль, гора Ауштау (Башкортостан) | то же | то же | локация «Башкирия — Аушкуль» |
| `user://terrain_cache/terrarium/…` (не в репо) | тайлы высот, скачанные в игре по выбранной точке | [AWS Terrain Tiles](https://registry.opendata.aws/terrain-tiles/) | как выше | рантайм-загрузка рельефа (FR-17) |
| `$AIR_NN_DATA/pilot/raw/terrarium/…`, `pilot/tiles/v1/cut/*.npz` (не в репо) | тайлы высот z5/z8/z12 и вырезки 38,4 км по горам суши для пилота air-nn П-2 (NN-P4, `tools/research/air_nn_pilot/terrain_cut.py`) | [AWS Terrain Tiles](https://registry.opendata.aws/terrain-tiles/) | как выше | обучение и проверка сети поля ветра (исследование) |
| `data/osm/altai.json`, `ongudai.json`, `askarovo.json`, `aushkul.json` | дороги, здания (прямоугольники), ЛЭП и опоры, реки и водоёмы, населённые пункты, поля и заборы — квадрат детального слоя рельефа; упаковано `tools/osm/fetch_osm.py` (Overpass API) | [OpenStreetMap](https://www.openstreetmap.org/) | **ODbL 1.0**: «© OpenStreetMap contributors» (атрибуция в титрах; производная база — под ODbL) | объекты мира: дороги, здания, ЛЭП, заборы у посадок (`scripts/world_objects/`) |

## Модели и текстуры
| Файл | Что | Источник | Лицензия | Где используется |
|---|---|---|---|---|
| `assets/models/glider_training.glb`, `glider_sport.glb`, `glider_slavutich_ut.glb`, `glider_apogee.glb`, `glider_atlas.glb`, `glider_target.glb`, `glider_magic.glb`, `glider_laminar.glb`, `glider_combat.glb` (исходники `assets/source/glider_*.blend`, текстуры паруса `glider_*_sail.png` 1024²) | девять крыльев (без логотипов и надписей): парус, каркас, трапеция, тросы, маркеры (docs/guide/models.md) | сгенерировано `tools/blender/build_gliders.py` (Blender 4.3) | — | визуал планера (`configs/wings/*.json → visual.visual_model`) |
| `assets/shaders/sail/sail.gdshader`, `glider_*_normal.png`, `glider_*_trans.png` | шейдер паруса (просвечивание, анимация), карты нормалей и просвечивания 1024² | сгенерировано `tools/blender/sail_maps.py`, шейдер написан вручную | — | парус крыльев (`SailMaterial`) |
| `assets/models/pilot.glb` (`assets/source/pilot.blend`) | пилот со скелетом и анимациями (stand, walk, run, run_air, climb_in, prone, climb_out, flare): тело человека (мужчина ~30 лет, 1,78 м) с плавной привязкой к костям, кулаки в перчатках из кистей MakeHuman, шлем отдельным мешем; подвеска, кокон, фал, краги, шлем и визор — процедурные | сгенерировано `tools/blender/build_pilot.py` (Blender 4.3); тело — базовый меш MakeHuman, макро-морфы и веса рига `game_engine` из [MPFB 2.0.17](https://github.com/makehumancommunity/mpfb2) (прорежено, пальцы согнуты вокруг трубы). Сам MPFB (код, GPL-3.0) — только инструмент сборки (`tools/blender/setup_mpfb.sh`), в игру не входит | ассеты MPFB/MakeHuman (базовый меш, морфы, риги, веса) — CC0 1.0 ([LICENSE.md MPFB](https://github.com/makehumancommunity/mpfb2/blob/master/LICENSE.md), [LICENSE.ASSETS.md](https://github.com/makehumancommunity/mpfb2/blob/master/LICENSE.ASSETS.md)); остальное — сгенерировано | пилот (`configs/pilot.json → visual.visual_model`) |
| `assets/models/instrument.glb` (`assets/source/instrument.blend`) | планшет-полётный компьютер на кронштейне базовой штанги, без логотипов | сгенерировано `tools/blender/build_instrument.py` | — | прибор на `InstrumentMount` |
| `assets/models/vario_90s.glb` (`assets/source/vario_90s.blend`) | обобщённый вариометр 1990-х со стрелочной шкалой, без брендов | сгенерировано `tools/blender/build_vario90s.py` | — | прибор на `VarioMount` (левая стойка) |
| `assets/models/trees/tree_{pine,cedar,larch,birch,spruce}.glb`, `tree_*_impostor.png`, `tree_*_{bark,leaf}.png`, `trees_impostor_atlas.png` (исходники `assets/source/trees/`) | деревья Алтая, LOD0 (≤ ~2k треугольников)/LOD1/импостор; текстуры хвои, листвы и коры процедурные: у сосны и кедра — кисти хвои на концах побегов, у ели — лапа ёлочкой, у лиственницы — розетки на провисающих побегах, у берёзы — плакучие пряди мелких листьев (прежние «перья»-веера вблизи читались как пальмы); нормали карточек — от центра кроны, импостор запекается без блика при нейтральном свете | сгенерировано `tools/blender/build_trees.py` | — | пока не подключены (замена конусов — docs/guide/models.md) |
| `assets/models/rocks/rocks.glb` (исходник `assets/source/rocks/rocks.blend`) | 6 валунов/глыб (boulder0–5) и 3 мелких камня (stone0–2), по 3 LOD (1280/320/80 и 320/80/20 треугольников); рисунок — трипланарно `data/terrain/textures/rock_ambientcg_rock030.jpg` в `scripts/terrain/rock_scatter.gdshader` | сгенерировано `tools/blender/build_rocks.py` (Blender 4.3) | — | 3D-камни у земли (`scripts/terrain/rock_scatter.gd`, `configs/world.json → rocks`) |
| `assets/models/shrubs/shrubs.glb` (исходник `assets/source/shrubs/shrubs.blend`) | 3 куста — караганник (karagana), шиповник (rosehip), ивняк (willow): лопасти-эллипсоиды с шумом листвы, высота 1 м, по 3 LOD (~2400/370/80 треугольников); цвет листвы и рисунок — `scripts/terrain/shrub_scatter.gdshader` | сгенерировано `tools/blender/build_shrubs.py` (Blender 4.3) | — | кусты на лугах и в кустарнике (`scripts/terrain/shrub_scatter.gd`, `configs/vegetation.json → shrubs`); там же одиночные деревья — модели `assets/models/trees/tree_{larch,birch}.glb` |
| `assets/models/world/tents.glb` (исходник `assets/source/world/tents.blend`) | Туристические палатки лагеря у старта: купольная 2-местная (dome2), туннельная 3-местная (tunnel3), тент-навес (tarp) — дуги/стойки, растяжки, колышки, полог входа; по 2 LOD (~1500/1800/500 и 80/48/36 треугольников); цвет ткани задаёт игра (материалы `Fabric`/`Door`), без логотипов | сгенерировано `tools/blender/build_tents.py` (Blender 4.3) | — | лагерь у старта (`scripts/world_objects/tent_camp.gd`, `configs/world_objects.json → tents`) |
| `assets/models/bird.glb` (исходник `assets/source/bird.blend`) | низкополигональная парящая хищная птица, размах 1,6 м (57 вершин) | сгенерировано `tools/blender/bird.py` (Blender 4.3) | — | птицы в сильных термиках (`scripts/atmosphere/bird_flock.gd`, путь — `configs/atmosphere.json → birds.model_path`) |
| `assets/models/world/windsock.glb` (`assets/source/world/windsock.blend`) | ветроуказатель: мачта 4 м, конус 2,4 м с 5 оранжево-белыми полосами (ткань гнёт шейдер), вертлюг | сгенерировано `tools/blender/world_objects/build_world_objects.py` (Blender 4.3) | — | ветроуказатели на стартах и посадках (`configs/world_objects.json → windsock.scene_path`) |
| `assets/models/world/streamer.glb` (`assets/source/world/streamer.blend`) | вешка 1,8 м с красно-белой лентой 1,2 м | то же | — | ленточки на старте (`streamers.scene_path`) |
| `assets/models/world/fence_segment.glb` (`…/fence_segment.blend`) | пролёт забора 3 м (столб + 2 жерди) | то же | — | заборы у посадок (`landing.fence_scene_path`) |
| `assets/models/world/power_tower.glb`, `power_pole.glb` (`…/power_*.blend`) | решётчатая опора ЛЭП 110 кВ 28,5 м; ж/б столб 10 кВ 9 м с изоляторами | то же | — | ЛЭП из OSM (`power.tower_scene_path`, `pole_scene_path`) |
| — | покос посадки, ленты дорог, провода | сгенерировано процедурно: `scripts/world_objects/draped.gdshader`, `wire.gdshader`, `wind_cloth.gdshader` | — | объекты мира |
| — | костёр: кольцо камней, поленья, угли, язычки пламени, клубы дыма | сгенерировано процедурно: `scripts/world_objects/campfire.gd` (меш из примитивов), `flame_puff.gdshader`, `smoke_puff.gdshader`, `smoke_particles.gdshader` (без текстур) | — | лагерь пилотов у старта |
| `assets/textures/clouds/cloud_shape.png`, `cloud_detail.png` | бесшовный 3D-шум облаков: Perlin-Worley 128³ и Уорли 64³ (атласы срезов, импорт как Texture3D) | сгенерировано `tools/atmosphere/gen_cloud_noise.py` | — | объёмные облака (`configs/atmosphere.json → clouds.noise_*_texture`); без файла — процедурный Уорли в `cloud_layer.gd` |
| — | пятно тени облака на земле | сгенерировано процедурно (`scripts/atmosphere/cloud_layer.gd`) | — | тени облаков (декали) |
| — | перистая пелена, пылевые вихри: 2D-шум | сгенерировано процедурно (`NoiseTexture2D` в `scripts/atmosphere/cirrus_layer.gd`, `dust_devils.gd`) | — | перистые облака, пылевые вихри |
| — | раскраска рельефа по карте поверхности (рисунок полей, крон, застройки, скал), процедурные кроны-заглушки и запасная карта поверхности | сгенерировано процедурно: `scripts/terrain/terrain.gdshader`, `trees.gdshader`, `surface_classifier.gd` | — | рельеф |
| — | дымка слоя перемешивания (VR-3) | сгенерировано процедурно: `scripts/world/haze.gdshader` | — | небо и дымка |
| `assets/ui/menu_background.jpg` | фон главного меню: вечер 20:15 над Онгудаем (южный старт), учебное крыло, кучевые; 3840×2160, JPEG q92 | скриншот из самой игры (пресет «Высокое», масштаб рендера 100 %), пересъёмка одной командой `tools/shots/menu_background.sh` по параметрам `tools/shots/menu_background.json` | собственный | главное меню (ui.json → menu_background) |
| `assets/ui/boot_splash.png` | заставка при запуске: фон меню + лого, 1920×1080 | `magick menu_background.jpg -resize 1920x1080` + `assets/logo.png` шириной 912 px по центру, центр лого на y=220 (в небе) | собственный | заставка (project.godot → boot_splash/image) |
| `assets/logo.png` | лого «DELTAPLAN» (дельтаплан вписан в букву «А») | от автора проекта | собственный | главное меню (ui.json → menu_logo) |
| `assets/icon.png`, `assets/icon.ico` | иконка игры: дельтаплан из лого на светлом скруглённом квадрате (16–256 px, мелкие размеры утолщены) | вырезано из `assets/logo.png` (ImageMagick) | собственный | иконка окна и exe Windows (config/icon, export_presets → application/icon) |
| `data/terrain/textures/grass_ambientcg_grass004.jpg` | рисунок травы вблизи (1K, цвет) | [ambientCG Grass004](https://ambientcg.com/view?id=Grass004) | CC0 | рельеф, `configs/world.json → terrain_textures.grass` |
| `data/terrain/textures/grass_ambientcg_grass004_normal_ao.jpg` | нормали травы (NormalGL: R, G) + AO (B), 512², ближняя фактура луга | [ambientCG Grass004](https://ambientcg.com/view?id=Grass004) | CC0 | рельеф, `terrain_textures.grass.normal` |
| `data/terrain/textures/rock_ambientcg_rock030.jpg` | рисунок скал вблизи (1K, цвет) | [ambientCG Rock030](https://ambientcg.com/view?id=Rock030) | CC0 | рельеф, `terrain_textures.rock` |
| `data/terrain/textures/rock_ambientcg_rock030_normal.jpg` | карта нормалей скал (NormalGL, уменьшена до 512²) | [ambientCG Rock030](https://ambientcg.com/view?id=Rock030) | CC0 | рельеф, `terrain_textures.rock.normal` |
| `data/terrain/textures/scree_ambientcg_gravel022.jpg` | щебень осыпей (цвет, 512²) | [ambientCG Gravel022](https://ambientcg.com/view?id=Gravel022) | CC0 | рельеф, `terrain_textures.scree` |
| — | полог леса с высоты, фактура лугов и полей, слои скал, колыхание травы, травинки | сгенерировано процедурно: `terrain.gdshader`, `terrain_wind.gdshaderinc`, `grass.gdshader` | — | рельеф |

## Аддоны Godot (addons/)
| Файл | Что | Источник | Лицензия | Где используется |
|---|---|---|---|---|
| `addons/debug_draw_3d/` | Debug Draw 3D 1.7.3 (Dmitriy Salnikov), GDExtension: отладочные стрелки и линии в 3D. Из релизного архива `debug-draw-3d_1.7.3.zip` взяты только библиотеки Linux x86_64, Windows x86_64 и macOS universal (редактор/debug, release-заглушка и release `.enabled` для `forced_dd3d`) | [DmitriySalnikov/godot_debug_draw_3d](https://github.com/DmitriySalnikov/godot_debug_draw_3d/releases/tag/1.7.3) | MIT (`addons/debug_draw_3d/LICENSE`) | отладочный слой F5 — ветер (`scripts/game/debug_overlays.gd`) |
| `addons/debug_menu/` | Debug Menu (Hugo Locurcio / Calinou), коммит `ff124615a7da981722b3927343b9965a6a156718` (main на 19.11.2025): меню FPS и времени кадра с графиками | [godot-extended-libraries/godot-debug-menu](https://github.com/godot-extended-libraries/godot-debug-menu) | MIT (`addons/debug_menu/LICENSE.md`) | отладочная клавиша F2 (создаётся по нажатию; своя F3 аддона отключена) |

## Эталонные фото для сравнения рельефа (data/terrain/reference/, не входят в игру)
| Файл | Что | Источник | Лицензия | Где используется |
|---|---|---|---|---|
| `data/terrain/reference/photos/photo_a_mountains.jpg` | Горы (хребет Пайн-Маунтин, Калифорния): лесистые склоны пятн | [Ken Lund (Flickr: Ken Lund, from Reno, Nevada, USA)](https://commons.wikimedia.org/wiki/File:Pine_Mountain_Ridge,_California_(20961815573).jpg) | CC BY-SA 2.0 | стенд T01, compare_ref.py |
| `data/terrain/reference/photos/photo_b_forest_edge.jpg` | Опушка леса и луг (Врапач, Хорватия), дрон ~250-350 м: пряма | [Pan Domaci](https://commons.wikimedia.org/wiki/File:Aerial_view_of_Vrapa%C4%8D.jpg) | CC0 | стенд T01, compare_ref.py |
| `data/terrain/reference/photos/photo_c_valley_haze.jpg` | Долина с дымкой и хребтами за 20+ км (Бозеполе, Польша, съём | [Andrzej Otrębski](https://commons.wikimedia.org/wiki/File:Bozepole_aerial.jpg) | CC BY-SA 4.0 | стенд T01, compare_ref.py |

## Сайт проекта (site/, не входит в игру)
| Файл | Что | Источник | Лицензия | Где используется |
|---|---|---|---|---|
| `site/themes/hugo-book/` | тема Hugo Book (копия без exampleSite и .git), коммит `40749065b170062e1821ebc9199656c9acd6870d` (ветка main на 24.09.2026) | [alex-shpak/hugo-book](https://github.com/alex-shpak/hugo-book) | MIT (`site/themes/hugo-book/LICENSE`) | сайт на GitHub Pages (`site/hugo.toml`) |
| KaTeX (стили, шрифты), MiniSearch, Mermaid в `site/themes/hugo-book/static/` | входят в тему | через Hugo Book: [KaTeX](https://github.com/KaTeX/KaTeX), [MiniSearch](https://github.com/lucaong/minisearch), [Mermaid](https://github.com/mermaid-js/mermaid) | MIT | формулы, поиск, диаграммы на сайте |

## Данные исследований (tools/research/, не входят в игру)
| Файл | Что | Источник | Лицензия | Где используется |
|---|---|---|---|---|
| `tools/research/osm_pack/results/*.jpg`, `*.json` | растры 10×10 км из векторного пакета OSM Словении и замеры размеров (рельеф, покров, OSM) | [Geofabrik](https://download.geofabrik.de/europe/slovenia.html) выгрузка 28.09.2026 (© OpenStreetMap contributors); [Copernicus DEM GLO-30](https://registry.opendata.aws/copernicus-dem/); [ESA WorldCover 2021](https://esa-worldcover.org/) | ODbL (OSM), лицензия Copernicus DEM с атрибуцией, CC BY 4.0 (WorldCover) | `docs/plan/osm_vector_pack.md` |
| `tools/research/cases/perdigao/out/terrain10.npz`, `masts.csv`, `terrain_check.md` | рельеф 6×6 км (DSM, шаг 10 м) и доля леса вокруг долины Perdigão, высоты мачт; случай калибровки А4 (`tools/research/cases/perdigao.py`) | [Copernicus DEM GLO-30](https://registry.opendata.aws/copernicus-dem/); [ESA WorldCover 2021](https://esa-worldcover.org/); положения мачт — Palma et al. 2018 (NEWA), NCAR/EOL ISFS | Copernicus DEM licence с атрибуцией, CC BY 4.0 (WorldCover); данные Perdigão — цитирование NCAR/EOL и Menke et al. 2019 (CC BY 4.0) | `docs/archive/plan/air-model-a4.md` |
| `tools/research/data/wing_passports/out/haiku/*.json`, `out/haiku_dhv/*.json`, сводка `wings_merged.json` (источники — `sources.md`) | паспортные характеристики дельтапланов (площадь, размах, массы, скорости, Vmin/Vmax при VG), каждое число со ссылкой и цитатой | страницы и руководства производителей (Wills Wing, Moyes, Icaro, Airborne, Bautek, Aeros), [DHV Geräteportal](https://service.dhv.de/db1/technicsearchpage.php?lang=DE), собрано 30.09.2026 | © производителей / DHV; лицензия на данные не заявлена. В git — только числа-факты со ссылкой и короткими цитатами; сами страницы и PDF не хранятся (PDF удалены, ссылки — в `sources.md`, `fetch_pdfs.py` скачивает заново). Для регулярного скрейпинга DHV вежливее спросить разрешение | исследование (сравнение с `configs/wings`) |
| `tools/research/air_synth/hg_sites/*.csv`, `sites.json`, `takeoffs_game.json`, `summary.*` | каталог стартов дельтаплана мира (теги `free_flying:*`), места (кластеры < 10 км), перепад рельефа квадрата 40 × 40 км (SY-9, контракт S6) | [OpenStreetMap](https://www.openstreetmap.org/) через Overpass API, дата выгрузки — `summary.json`; высоты для перепада — [Terrain Tiles](https://github.com/tilezen/joerd/blob/master/docs/attribution.md) (Mapzen/AWS, не в git) | **ODbL 1.0**: «© OpenStreetMap contributors»; производная база — под ODbL | обучение сети ветра под места, где летают (air-synth); возможный предвыбор мест в игре |
