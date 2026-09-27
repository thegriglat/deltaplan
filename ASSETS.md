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
| `data/terrain/altai/detail.f32.gz` | высоты 40×40 км вокруг Манжерока, шаг 25 м (float32, gzip; пересэмплировано и сглажено `tools/terrain/fetch_dem.py`) | [Copernicus DEM GLO-30](https://registry.opendata.aws/copernicus-dem/) (ESA/DLR/Airbus, 1″ ≈ 30 м) | Copernicus DEM licence: бесплатно, любое использование и распространение с атрибуцией «produced using Copernicus WorldDEM-30 © DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018 provided under COPERNICUS by the European Union and ESA» | локация «Алтай», зона полётов |
| `data/terrain/altai/far.f32.gz` | высоты 160×160 км, шаг 100 м (фон до горизонта) | [AWS Terrain Tiles](https://registry.opendata.aws/terrain-tiles/) (Terrarium z10: SRTM, GMTED2010, ETOPO1 и др.) | открытые данные; атрибуция источников по [списку Mapzen](https://github.com/tilezen/joerd/blob/master/docs/attribution.md) (SRTM — public domain) | локация «Алтай», дальний рельеф |
| `data/terrain/altai/meta.json` | размеры сеток, атрибуция | сгенерировано `tools/terrain/fetch_dem.py` | — | загрузка локации |
| `data/terrain/altai/*_water.png` | маски рек (Катунь, Майма и др.) | сгенерировано из высот `tools/terrain/rivers.py` (сток priority-flood) | как у высот | вода на рельефе |
| `data/terrain/<локация>/*_surface.png`, `surface.json`, `*_detail10.png` | карта поверхности (классы: лес, луг, пашня, кустарник, скалы/грунт, вода, застройка, снег), 8 бит, шаг 25 м / 100 м; мода 3×3 подвыборок; `*_detail10.png` (T02) — маска доли леса 10 м для резкой кромки, `tools/terrain/fetch_landcover.py` | [ESA WorldCover 2021 v200, 10 м](https://registry.opendata.aws/esa-worldcover-vito/) (AWS, COG) | **CC-BY 4.0**: «© ESA WorldCover project 2021 / Contains modified Copernicus Sentinel data (2021) processed by ESA WorldCover consortium» (атрибуция в титрах) | цвет земли, деревья и источники термиков (VR-4) — все локации |
| `user://terrain_cache/worldcover/…` (не в репо) | тайлы WorldCover, скачанные в игре для выбранной точки | ESA WorldCover (как выше) | CC-BY 4.0 (как выше) | рантайм-карта поверхности (`worldcover_loader.gd`) |
| `data/terrain/ongudai/*` | высоты 40×40 км (Copernicus, 25 м) + 160 км (Terrarium, 100 м), реки, карта поверхности — Онгудай, перевал Каянча | Copernicus DEM GLO-30, AWS Terrain Tiles, ESA WorldCover | как у строк выше (Copernicus DEM licence, открытые данные, CC-BY 4.0) | локация «Алтай — Онгудай» |
| `data/terrain/askarovo/*` | то же — хребет Биягода у Аскарово (Башкортостан) | то же | то же | локация «Башкирия — Аскарово» |
| `data/terrain/aushkul/*` | то же — озеро Аушкуль, гора Ауштау (Башкортостан) | то же | то же | локация «Башкирия — Аушкуль» |
| `user://terrain_cache/terrarium/…` (не в репо) | тайлы высот, скачанные в игре по выбранной точке | [AWS Terrain Tiles](https://registry.opendata.aws/terrain-tiles/) | как выше | рантайм-загрузка рельефа (FR-17) |
| `data/osm/altai.json`, `ongudai.json`, `askarovo.json`, `aushkul.json` | дороги, здания (прямоугольники), ЛЭП и опоры, реки и водоёмы, населённые пункты, поля и заборы — квадрат детального слоя рельефа; упаковано `tools/osm/fetch_osm.py` (Overpass API) | [OpenStreetMap](https://www.openstreetmap.org/) | **ODbL 1.0**: «© OpenStreetMap contributors» (атрибуция в титрах; производная база — под ODbL) | объекты мира: дороги, здания, ЛЭП, заборы у посадок (`scripts/world_objects/`) |

## Модели и текстуры
| Файл | Что | Источник | Лицензия | Где используется |
|---|---|---|---|---|
| `assets/models/glider_training.glb`, `glider_kingpost.glb`, `glider_sport.glb` (исходники `assets/source/glider_*.blend`, текстуры паруса `glider_*_sail.png` 1024²) | три крыла: парус, каркас, трапеция, тросы, маркеры (docs/models.md) | сгенерировано `tools/blender/build_gliders.py` (Blender 4.3) | — | визуал планера (`configs/wings/*.json → visual.visual_model`) |
| `assets/shaders/sail/sail.gdshader`, `glider_*_normal.png`, `glider_*_trans.png` | шейдер паруса (просвечивание, анимация), карты нормалей и просвечивания 1024² | сгенерировано `tools/blender/sail_maps.py`, шейдер написан вручную | — | парус крыльев (`SailMaterial`) |
| `assets/models/pilot.glb` (`assets/source/pilot.blend`) | манекен пилота со скелетом и анимациями (stand, walk, run, run_air, climb_in, prone, climb_out, flare), шлем отдельным мешем | сгенерировано `tools/blender/build_pilot.py` | — | пилот (`configs/pilot.json → visual.visual_model`) |
| `assets/models/instrument.glb` (`assets/source/instrument.blend`) | планшет-полётный компьютер на кронштейне базовой штанги, без логотипов | сгенерировано `tools/blender/build_instrument.py` | — | прибор на `InstrumentMount` |
| `assets/models/vario_90s.glb` (`assets/source/vario_90s.blend`) | обобщённый вариометр 1990-х со стрелочной шкалой, без брендов | сгенерировано `tools/blender/build_vario90s.py` | — | прибор на `VarioMount` (левая стойка) |
| `assets/models/trees/tree_{pine,cedar,larch,birch,spruce}.glb`, `tree_*_impostor.png`, `tree_*_{bark,leaf}.png`, `trees_impostor_atlas.png` (исходники `assets/source/trees/`) | деревья Алтая, LOD0/LOD1/импостор; текстуры хвои, листвы и коры процедурные | сгенерировано `tools/blender/build_trees.py` | — | пока не подключены (замена конусов — docs/models.md) |
| `assets/models/rocks/rocks.glb` (исходник `assets/source/rocks/rocks.blend`) | 6 валунов/глыб (boulder0–5) и 3 мелких камня (stone0–2), по 3 LOD (1280/320/80 и 320/80/20 треугольников); рисунок — трипланарно `data/terrain/textures/rock_ambientcg_rock030.jpg` в `scripts/terrain/rock_scatter.gdshader` | сгенерировано `tools/blender/build_rocks.py` (Blender 4.3) | — | 3D-камни у земли (`scripts/terrain/rock_scatter.gd`, `configs/world.json → rocks`) |
| `assets/models/shrubs/shrubs.glb` (исходник `assets/source/shrubs/shrubs.blend`) | 3 куста — караганник (karagana), шиповник (rosehip), ивняк (willow): лопасти-эллипсоиды с шумом листвы, высота 1 м, по 3 LOD (~2400/370/80 треугольников); цвет листвы и рисунок — `scripts/terrain/shrub_scatter.gdshader` | сгенерировано `tools/blender/build_shrubs.py` (Blender 4.3) | — | кусты на лугах и в кустарнике (`scripts/terrain/shrub_scatter.gd`, `configs/vegetation.json → shrubs`); там же одиночные деревья — модели `assets/models/trees/tree_{larch,birch}.glb` |
| `assets/models/bird.glb` (исходник `assets/source/bird.blend`) | низкополигональная парящая хищная птица, размах 1,6 м (57 вершин) | сгенерировано `tools/blender/bird.py` (Blender 4.3) | — | птицы в сильных термиках (`scripts/atmosphere/bird_flock.gd`, путь — `configs/atmosphere.json → birds.model_path`) |
| `assets/models/world/windsock.glb` (`assets/source/world/windsock.blend`) | ветроуказатель: мачта 4 м, конус 2,4 м с 5 оранжево-белыми полосами (ткань гнёт шейдер), вертлюг | сгенерировано `tools/blender/world_objects/build_world_objects.py` (Blender 4.3) | — | ветроуказатели на стартах и посадках (`configs/world_objects.json → windsock.scene_path`) |
| `assets/models/world/streamer.glb` (`assets/source/world/streamer.blend`) | вешка 1,8 м с красно-белой лентой 1,2 м | то же | — | ленточки на старте (`streamers.scene_path`) |
| `assets/models/world/fence_segment.glb` (`…/fence_segment.blend`) | пролёт забора 3 м (столб + 2 жерди) | то же | — | заборы у посадок (`landing.fence_scene_path`) |
| `assets/models/world/power_tower.glb`, `power_pole.glb` (`…/power_*.blend`) | решётчатая опора ЛЭП 110 кВ 28,5 м; ж/б столб 10 кВ 9 м с изоляторами | то же | — | ЛЭП из OSM (`power.tower_scene_path`, `pole_scene_path`) |
| — | покос посадки, ленты дорог, провода | сгенерировано процедурно: `scripts/world_objects/draped.gdshader`, `wire.gdshader`, `wind_cloth.gdshader` | — | объекты мира |
| `assets/textures/clouds/cloud_shape.png`, `cloud_detail.png` | бесшовный 3D-шум облаков: Perlin-Worley 128³ и Уорли 64³ (атласы срезов, импорт как Texture3D) | сгенерировано `tools/atmosphere/gen_cloud_noise.py` | — | объёмные облака (`configs/atmosphere.json → clouds.noise_*_texture`); без файла — процедурный Уорли в `cloud_layer.gd` |
| — | пятно тени облака на земле | сгенерировано процедурно (`scripts/atmosphere/cloud_layer.gd`) | — | тени облаков (декали) |
| — | перистая пелена, пылевые вихри: 2D-шум | сгенерировано процедурно (`NoiseTexture2D` в `scripts/atmosphere/cirrus_layer.gd`, `dust_devils.gd`) | — | перистые облака, пылевые вихри |
| — | раскраска рельефа по карте поверхности (рисунок полей, крон, застройки, скал), процедурные кроны-заглушки и запасная карта поверхности | сгенерировано процедурно: `scripts/terrain/terrain.gdshader`, `trees.gdshader`, `surface_classifier.gd` | — | рельеф |
| — | дымка слоя перемешивания (VR-3) | сгенерировано процедурно: `scripts/world/haze.gdshader` | — | небо и дымка |
| `assets/ui/menu_background.jpg` | фон главного меню | скриншот из самой игры (сгенерировано) | собственный | главное меню |
| `data/terrain/textures/grass_ambientcg_grass004.jpg` | рисунок травы вблизи (1K, цвет) | [ambientCG Grass004](https://ambientcg.com/view?id=Grass004) | CC0 | рельеф, `configs/world.json → terrain_textures.grass` |
| `data/terrain/textures/grass_ambientcg_grass004_normal_ao.jpg` | нормали травы (NormalGL: R, G) + AO (B), 512², ближняя фактура луга | [ambientCG Grass004](https://ambientcg.com/view?id=Grass004) | CC0 | рельеф, `terrain_textures.grass.normal` |
| `data/terrain/textures/rock_ambientcg_rock030.jpg` | рисунок скал вблизи (1K, цвет) | [ambientCG Rock030](https://ambientcg.com/view?id=Rock030) | CC0 | рельеф, `terrain_textures.rock` |
| `data/terrain/textures/rock_ambientcg_rock030_normal.jpg` | карта нормалей скал (NormalGL, уменьшена до 512²) | [ambientCG Rock030](https://ambientcg.com/view?id=Rock030) | CC0 | рельеф, `terrain_textures.rock.normal` |
| `data/terrain/textures/scree_ambientcg_gravel022.jpg` | щебень осыпей (цвет, 512²) | [ambientCG Gravel022](https://ambientcg.com/view?id=Gravel022) | CC0 | рельеф, `terrain_textures.scree` |
| — | полог леса с высоты, фактура лугов и полей, слои скал, колыхание травы, травинки | сгенерировано процедурно: `terrain.gdshader`, `terrain_wind.gdshaderinc`, `grass.gdshader` | — | рельеф |

## Эталонные фото для сравнения рельефа (data/terrain/reference/, не входят в игру)
| Файл | Что | Источник | Лицензия | Где используется |
|---|---|---|---|---|
| `data/terrain/reference/photos/photo_a_mountains.jpg` | Горы (хребет Пайн-Маунтин, Калифорния): лесистые склоны пятн | [Ken Lund (Flickr: Ken Lund, from Reno, Nevada, USA)](https://commons.wikimedia.org/wiki/File:Pine_Mountain_Ridge,_California_(20961815573).jpg) | CC BY-SA 2.0 | стенд T01, compare_ref.py |
| `data/terrain/reference/photos/photo_b_forest_edge.jpg` | Опушка леса и луг (Врапач, Хорватия), дрон ~250-350 м: пряма | [Pan Domaci](https://commons.wikimedia.org/wiki/File:Aerial_view_of_Vrapa%C4%8D.jpg) | CC0 | стенд T01, compare_ref.py |
| `data/terrain/reference/photos/photo_c_valley_haze.jpg` | Долина с дымкой и хребтами за 20+ км (Бозеполе, Польша, съём | [Andrzej Otrębski](https://commons.wikimedia.org/wiki/File:Bozepole_aerial.jpg) | CC BY-SA 4.0 | стенд T01, compare_ref.py |
