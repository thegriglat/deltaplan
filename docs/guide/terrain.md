---
type: "guide"
status: "active"
module: "terrain"
area: "world"
updated: "2026-10-15"
summary: "Рельеф и мир (Terrain): файлы, контракт height_at/surface_at/forest_at, пример подключения; детали — в частях terrain/."
related: ["docs/guide/terrain/relief.md", "docs/guide/terrain/surface.md", "docs/guide/terrain/forest-sky.md", "docs/guide/terrain/runtime.md", "docs/guide/location-data.md", "docs/guide/vegetation.md", "docs/guide/scene-look.md", "docs/guide/world-objects.md", "docs/research/terrain_sources.md"]
---
# Рельеф и мир

FR-17…FR-20, VR-3, VR-4, VR-0, NFR-1, NFR-2. Исследование источников — [research/terrain_sources.md](../research/terrain_sources.md).


## Устройство по частям
Нода `Terrain` — рельеф локации и общий контракт мира: высота, нормаль, класс поверхности, доля леса, источники термиков, старты и
посадки. Все слои (высоты, карта поверхности, цвет земли, деревья) берут данные из файлов места, которые собирает один сборщик
для встроенных мест и любой точки ([location-data.md](location-data.md)). Коллизий с землёй нет — полёт считает `height_at`.

| Часть | О чём |
|---|---|
| [terrain/relief.md](terrain/relief.md) | слои высот (WebP, 25 м / 100 м), `height_at`, чанки и LOD, юбки, нормали, промоины, DSM под лесом, форма гор вдали, поля рельефа (влажность, AO, тень гор) |
| [terrain/surface.md](terrain/surface.md) | карта поверхности WorldCover, маска 10 м (лес, вода), пустыри у стартов, источники термиков, раскраска, луг, скалы и снег |
| [terrain/forest-sky.md](terrain/forest-sky.md) | деревья-модели и средний план леса, полог с высоты, небо, дымка и инверсия, ослепление солнцем, ветер на земле |
| [terrain/runtime.md](terrain/runtime.md) | выбор точки, рантайм-загрузка и ошибки, как добавить локацию, четыре места, превью-сцена, стенд кадров |

Смежные гайды: [vegetation.md](vegetation.md) (трава, кусты, расстановка по кромке), [scene-look.md](scene-look.md) (картинка с высоты),
[world-objects.md](world-objects.md) (ветроуказатели, посадки, лагерь, посёлки, OSM-слой), [location-data.md](location-data.md), [osm-tiles.md](osm-tiles.md).

## Что где
| Файл | Что делает |
|---|---|
| `scripts/terrain/terrain.gd` (`Terrain`, группа `"terrain"`) | нода рельефа: загрузка локации (`load_location`, `load_point`, `load_builtin`), контракт `height_at / normal_at / get_start_sites / sun_exposure_at`, `surface_at / forest_at / get_forest_mask / thermal_source_strength_at / get_landing_sites`; солнце и дата (`set_sun`, `set_flight_date`, `set_class_sun`), вода для термиков (`set_water_heat`), пустыри у стартов (`add_start_clearing`), поля рельефа (`moisture_at / relief_ao_at / relief_horizon_at`) |
| `scripts/terrain/surface_layer.gd` (`SurfaceLayer`) | карта поверхности (классы земного покрова) на сетке, `class_at`, текстура R8; маска «деталь 10 м» (`forest_at`, `mask_r` — лес, `mask_g` — вода), мягкая подложка застройки |
| `scripts/terrain/surface_classifier.gd` (`SurfaceClassifier`) | запасная процедурная карта (нет сети) по высоте/уклону/экспозиции/шуму |
| `scripts/terrain/cog_reader.gd` (`CogReader`), `worldcover_loader.gd` (`WorldCoverLoader`) | разбор COG GeoTIFF (читают DemStage и SurfaceStage); `WorldCoverLoader` — только имена файлов WorldCover |
| `scripts/terrain/tree_placer.gd` (`TreePlacer`), `terrain_tree_models.gd` (`TerrainTreeModels`), `tree_model.gdshader`, `tree_cell.gd` + `tree_cell.gdshaderinc` (`TreeCell`) | деревья-модели 5 пород × LOD0/1 (MultiMesh), «дерево в клетке» (хеш одинаков на CPU и GPU), расстановка в рабочем потоке, качание от ветра |
| `scripts/terrain/tree_crosses.gd` + `tree_cross.gdshader` (`TreeCrosses`) | LOD2-кресты деревьев в вершинном шейдере (SL-18) |
| `scripts/terrain/forest_impostors.gd` + `.gdshader` (`ForestImpostors`) | дальний план леса за крестами, до `trees.impostors.outer_m` 3,5 км: билборды из атласа импостеров |
| `scripts/terrain/rock_scatter.gd` + `.gdshader` (`RockScatter`) | 3D-камни вокруг камеры: степенной закон размеров (щебень 0,15–0,6 м — слой мелочи только в `small_radius_m` 90 м, `build_small_tile`; глыбы 0,6–3 м, 4 м — только bedrock, — в `radius_m` 300 м, `build_tile`); формы-роли `round/chunk/slab/wedge/tooth/comb` (`tools/blender/build_rocks.py`: плиты, сколы, клин, зуб, гребешок; окатанный — малая доля); неравномерный масштаб, наклон по нормали, плиты плашмя; курумник и выходы породы по логике пятен породы шейдера; **грядки** гребешков 3–8 м вдоль горизонтали (на слоях `terrain_look.strata_m`); **осыпи** — шлейфы щебня по линии падения под обрывом (мелочь ближе к обрыву, крупнее ниже); без коллизий, чисто визуально; детерминированно (хеш клетки); `configs/world.json → rocks`, подключение `RockScatter.attach(terrain, cam)` |
| `scripts/terrain/grass_field.gd` + `grass.gdshader` (`GrassField`), `shrub_scatter.gd` + `.gdshader` (`ShrubScatter`), `meadow_look.gdshaderinc` | травинки, кусты и одиночные деревья на лугу, цвет луга — см. [vegetation.md](vegetation.md) |
| `scripts/terrain/terrain_wind.gd` + `terrain_wind.gdshaderinc` (`TerrainWind`) | ветер и термики атмосферы → шейдеры рельефа, травы, деревьев (VR-17) |
| `scripts/terrain/terrain_relief.gd` (`TerrainRelief`), `relief_look.gd` (`ReliefLook`) | поля рельефа из DEM любой локации: влажность (сток D8 + вогнутость), сглаженная экспозиция, AO по горизонтам, горизонт к солнцу (тень рельефа); CPU-зеркало формы гор вдали |
| `scripts/terrain/height_layer.gd` (`HeightLayer`) | сетка высот, билинейная выборка (RefCounted, тестируется headless) |
| `scripts/terrain/geo.gd` (`TerrainGeo`) | lat/lon ↔ мир, направление солнца, вектор курса |
| `scripts/terrain/terrain_renderer.gd` (`TerrainRenderer`) | чанки + LOD, материалы, текстуры поверхностей |
| `scripts/terrain/terrain_main.gdshaderinc` + `terrain.gdshader` и `variants/terrain_*.gdshader`, `terrain_common.gdshaderinc`, `cloud_shadow.gdshaderinc` | тело шейдера рельефа (высоты в вершинном шейдере, раскраска: трава, лес, поля, скалы, снег, вода) и его варианты по пресетам; общие функции; тени облаков на земле |
| `scripts/terrain/terrain_trees.gd` + `trees.gdshader` (`TerrainTrees`) | запасные процедурные кроны (если нет моделей) |
| `scripts/terrain/terrarium_loader.gd` (`TerrariumLoader`) | тайлы Terrarium для высоты точки на карте выбора (`elevation_at`), кеш `user://terrain_cache` |
| `scripts/terrain/map_picker.gd` + `raster_tile_loader.gd` (`MapPicker`, `RasterTileLoader`) | карта выбора точки: растровая топокарта (OpenTopoMap / OSM, кеш `user://map_cache`), высота точки из Terrarium z12, щелчок / ввод координат → `point_picked(lat, lon)`, `elevation_ready` |
| `scripts/world/sky_environment.gd` (`SkyEnvironment`), `haze.gdshader`, `scenes/world/environment.tscn` | небо, солнце с мягкими тенями, голубая дымка, мутный слой под инверсией (VR-3), glow |
| `scripts/terrain/scene_look.gdshaderinc`, `season_look.gd` (`SeasonLook`), `configs/world.json → scene_look` | модуль scene-look («картинка сочнее»): свет неба и земли, дальний лес, сезон, тропы, скалы, снег, ветер по траве — см. [scene-look.md](scene-look.md) |
| `scenes/terrain/terrain_preview.tscn`, `map_picker_preview.tscn` | отдельный запуск модуля |
| `scripts/terrain/build/` (`DemStage`, `RiverStage`, `SurfaceStage`, `SmoothStage`, `OsmTilesStage`, `LocationBuilder`, `LocationCache`, `Locations`), `scripts/terrain/built_patches.gd` (`BuiltPatches`), `tools/terrain/build_location.gd` | сборка данных места (высоты, реки, карта поверхности, сглаживание, тайлы OSM) — одна для встроенных мест и точек; см. [location-data.md](location-data.md) |
| `configs/locations/<id>.json` | локация: центр, слои DEM, LOD, старты, посадки, реки, карта поверхности, переопределения вида и пород деревьев (`terrain_look`, `trees`) |
| `configs/world.json` | солнце, небо, дымка, эффекты, вид рельефа, деревья, камни, текстуры, рантайм-загрузка, сборщик места, ветер на земле, scene-look, варианты шейдера (`terrain`), карта выбора |
| `configs/vegetation.json` | трава, кусты, одиночные деревья, добавки к кромке леса |

## Использование
```gdscript
var terrain: Terrain = $Terrain          # location_id = "altai" грузится в _ready
atmosphere.set_ground(terrain.height_at, terrain.thermal_source_strength_at)  # VR-4: источники из карты
sky.set_inversion_height_msl(atmosphere.get_cloudbase_msl())                  # VR-3: верх дымки
var site: Dictionary = terrain.get_start_sites()[0]   # {id, name, position, heading_deg, lat, lon}
glider.reset_on_ground(site.position, site.heading_deg)

# произвольная точка (FR-17, OA-К4): кеш user://locations или сборка, затем сигнал loaded
terrain.load_point(43.25, 42.45)
await terrain.loaded

# карта выбора места
var picker := MapPicker.new()
picker.point_picked.connect(func(lat, lon): terrain.load_point(lat, lon))
```
