---
type: "guide"
status: "active"
module: "terrain"
area: "world"
updated: "2026-10-15"
summary: "Выбор точки на карте и загрузка места (LoadProgress, ошибки), добавление локации, превью-сцена, четыре места, стенд кадров."
related: ["docs/guide/terrain.md"]
---
# Загрузка места, добавление локации, превью и стенд

Вход — [terrain.md](../terrain.md). Стадии сборки, форматы и кеш — [location-data.md](../location-data.md).

## Точка на карте: сборка места и кеш (osm-any)
Точка (`pick_lat/lon`: карта, «Популярные», «Недавние») грузится как встроенное место (`Game._load_terrain`): точка
внутри встроенного места (≥ 10 км до края детального квадрата) — `load_location` встроенного со стартом в точке; иначе
`Terrain.load_point(lat, lon)` → `LocationBuilder.build` берёт готовое место из `user://locations/<ключ>/` или собирает
его стадиями, затем обычный `load_location(ключ)`; объекты мира, включая OSM-слой из тайлов, строит `WorldObjects` одинаково
для встроенных мест и точек. Встроенное место без файлов в паке собирается при первом выборе (`Terrain.load_builtin(id)` →
`load_point(…, id)`). Стадии, источники, ключ и состав кеша, отказ слоёв, догрузка и повтор без сети — [location-data.md](../location-data.md).
Чтения конфига места — через `Locations` (`config`, `data_dir`, `is_builtin`, `builtin_at`). Ручная сборка без игры:
`godot --headless --path . -s res://tools/terrain/build_location.gd -- --lat 47.05 --lon 11.0 [--offline]`
(встроенное место — `-- --id <id>`, `--local` берёт сырые блоки из `~/.cache/deltaplan_terrain` и `~/.cache/deltaplan_parity`; печатает ключ, missing, время стадий, `net_requests`, размер папки). Сеть: сторож
`stall_timeout_s` не срабатывает, пока стадии присылают прогресс.

## Рантайм-загрузка с карты: ход, фризы, ошибки
`load_point` не останавливает главный поток надолго (окно отвечает, экран загрузки живой):
- тайлы и блоки COG стадий — `HTTPRequest` с `use_threads` (TLS и чтение — не в главном потоке), все запросы — через `HttpLog.fetch`;
- распаковка тайлов COG и выборка классов WorldCover, стадии сглаживания и рек, разбор тайлов OSM — в `WorkerThreadPool`;
- сборка сцены (`setup_async`): меш, деревья, трава — в разных кадрах; пока идёт — `Terrain` не
  обрабатывается (`process_mode`), чтобы дети не видели полусборку. `setup()` (встроенные локации,
  тесты) — как раньше, синхронно.

Ход — `terrain.progress` (`LoadProgress`, `scripts/core/load_progress.gd`): этап (`stage(key, текст)`; для стадий сборки
`dem`, `landcover` — стадия `surface`, `osm` — стадия `osm_tiles`) и доля 0..1 по весам `configs/ui.json → loading.stage_weights`
(dem 45, landcover 25, osm 10, classify 3, mesh 5, trees 4, grass 3, weather 5, …), внутри скачивания — по запросам. Счётчик
запросов «Рельеф/Покров/OSM: N/M» — `LoadProgress.counter`. Экран загрузки (`LoadingScreen`) слушает `progress.changed`.

Ошибки → `load_failed(текст для пилота)`, игра возвращается в меню:
- нет связи / таймаут → «Нет связи с сервером рельефа…» (`err_network`); тайла нет (403/404) → «Для этого места нет данных рельефа.»;
- море (`Terrain.is_sea`): высота точки ниже `sea_depth_m` или ≤ 0 (над океаном тайлы дают 0) без карты
  покрова / с водой в ней → «Здесь море — выберите точку на суше.»;
- доля хода не менялась `stall_timeout_s` → отмена (`cancel_load`) и «Сервер рельефа не отвечает…».

Замер: `tools/loading/load_probe.tscn -- --latlon=<lat>,<lon> [--cache=<пустая папка>] [--url=<шаблон>] [--location=<id>]` —
этапы с длительностью, самый длинный интервал между кадрами, итог (полёт / меню с сообщением).

## Как добавить локацию
Данные места собирает игровой сборщик (одинаково для встроенных мест и точек); подробно — [location-data.md](../location-data.md). В репозитории данных места нет.
1. Скопировать `configs/locations/altai.json` в `configs/locations/<id>.json`, поменять `name`, `center_lat/lon`,
   `utc_offset_h`, при желании размеры слоёв (`dem`, `render`: сторона/шаг должны давать целое число `chunk_cells`).
2. `godot --headless --path . -s res://tools/terrain/build_location.gd -- --id <id>` (нужна сеть) — рельеф Copernicus/
   Terrarium, маски рек, карта поверхности WorldCover, лес и вода 10 м, сглаживание, тайлы OSM (список `osm_tiles.json`), `build.json`
   в `user://locations/<id>` (кеш блоков — `user://terrain_cache`; профиль для проверок — `XDG_DATA_HOME=$(mktemp -d)`).
3. Вписать `start_sites` (lat, lon, `heading_deg` — курс разбега вниз по склону, 1–3 старта) и `landing_sites`.
   Проверка: `tests/terrain/test_locations.gd` (добавить id в `LOCATIONS`) — старт на склоне 8–35°, вниз по курсу, не в лесу;
   посадка пологая, не лес и не вода. Размер места — несколько МБ (WebP; четыре встроенных — 24 МБ вместе).
4. `godot --path . res://scenes/terrain/terrain_preview.tscn -- --location=<id> --site=<id старта>` — посмотреть.
5. Внести данные в `ASSETS.md`; фикстуру для тестов копируют из собранной папки в `tests/fixtures/locations/<id>`.

## Локации
| id | Что | Старты |
|---|---|---|
| `ongudai` | Алтай, долина Урсула у Онгудая, хребет с перевалом Каянча (полёты с 1980-х) | южный склон у Онгудайского ретранслятора, 1870 м, 151° |
| `askarovo` | Башкирия, хребет Биягода у Идяш-Кускарово (дельтадром, ЧР-2025) | запад у верхнего лагеря 294°, восток 94°, южная вершина 285° |
| `aushkul` | Башкирия, озеро Аушкуль: гора Ауштау («пупырь») и хребет у Старобайрамгулово | Ауштау восток 119°, Ауштау юг 170°, хребет запад 273° |
| `altai` | Манжерок, Малая Синюха (дополнительная) | 3 старта |
Источники и допущения — `_sources_doc` в конфиге локации и `questions.md → Рельеф 2`.

## Превью и замеры
```
godot --path . res://scenes/terrain/terrain_preview.tscn -- [--location=id] [--site=id] [--landing] [--agl=м] [--yaw=°] [--pitch=°]
      [--pos=x,y,z --look=x,y,z] [--latlon=lat,lon] [--shot=file.png] [--shot-series=N[,с]] [--bench] [--bench-static=N]
      [--no-trees] [--no-shadows] [--no-grass] [--no-haze] [--inversion=м] [--clearings] [--wind=км/ч,откуда°]
      [--thermal=x,z,радиус,м/с] [--gusts[=м/с]]
```
WASD/QE/Shift — полёт камеры, правая кнопка — обзор. `--bench` печатает FPS и GPU-время, `--bench-static=N` — JSON
`{gpu_ms_mean, gpu_ms_p95, n}` для N неподвижных кадров. Цена кадра по пресетам графики (RTX 4070 SUPER, Онгудай, 800 м над
землёй, 1080p: 4,1–5,8 мс GPU) — таблица в [scene-look/forest-cost.md](../scene-look/forest-cost.md). Пресеты (`configs/game.json → graphics_presets`)
меняют вариант шейдера рельефа (`terrain.variant`), `trees.radius_m` (250 / 400 / 500 м), `trees.cross_radius_m`, тени деревьев,
`sun.shadow_max_distance_m` (1200 / 2000 / 3000 м), густоту травы; в Compatibility-рендере рельеф работает.

## Заменяемые ассеты
Модели деревьев — `world.json → trees.models` (нет файла → процедурные кроны). Карта поверхности — `<слой>_surface.webp` (L8), можно
заменить любой другой классификацией с теми же классами (формат — [location-data.md](../location-data.md)).
Текстуры поверхностей — пути в `configs/world.json → terrain_textures` (пусто — процедурно; нет файла — предупреждение
и процедурно). Реки (маски `RiverStage`, `<слой>_water.webp`) дают русла в канал воды маски 10 м и запасной карте; озёра — класс «вода» WorldCover.

## Стенд кадров (T01)
Стенд T01 (`tools/terrain/shots.sh <выход>`): 7 кадров 1920×1080 (S1–S5 Онгудай, A1 Аскарово, U1 Аушкуль) + `bench.json` (GPU «полностью»/«рельеф», среднее и 95-й перцентиль) за ~45–55 с. `tools/terrain/compare_ref.py` сравнивает кадры с 3 реальными фото Wikimedia Commons (`data/terrain/reference/sources.json`) по яркости/контрасту прямоугольников «лес»/«луг», полос близко/средне/далеко и профилю опушки (S3), собирает `metrics.json` и монтажи «кадр|фото».
Кромку леса в метрах по земле (S3) стенд не считает: итоги T02 — проекцией пикселей кадра на рельеф (DSM) и знаковым
расстоянием до кромки маски 10 м: переход 10→90 % по линии профиля 32 → 13 м, в среднем по кадру (до 1,5 км) 25 → 15 м
(без деревьев-моделей 7,5 м); луг в 0–30 м от кромки темнее луга в 100 м: 12,7 % → 7,9 % (без моделей 3,6 %; остаток —
тени и кроны моделей у опушки). GPU «рельеф» (A/B, чередуя): стенд 2,26 → 1,96 мс, S1–S5 — на 0,24–0,38 мс меньше
(лес вдали — без выборок маски, пятна древостоев только на лесе).
