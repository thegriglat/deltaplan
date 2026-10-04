---
type: "contract"
status: "active"
module: "start-map"
updated: "2026-10-05"
summary: "Контракты модуля start-map: растровые подложки карты выбора старта в конфиге (SM-К1), высота точки по Terrarium и интерфейс MapPicker (SM-К2)."
related: ["docs/plan/start-map.md"]
contracts: [{"id": "SM-К1", "version": 2}, {"id": "SM-К2", "version": 1}]
---
# Контракты модуля start-map

План — `docs/plan/start-map.md`. Менять — только через координатора (версия +1, что изменилось, уведомить потребителей). Контрактный тест — `tests/contracts/test_start_map_contracts.gd` (без сети и GPU).

## SM-К1. Растровые подложки карты (v2)
Владелец: SM-1. Потребители: `MapPicker`, `RasterTileLoader`, `ASSETS.md`, контрактный тест.
- `configs/world.json` → `map_picker.basemaps`: непустой массив; первый элемент — слой по умолчанию. Элемент:
  `{"id": String (латиница, [a-z0-9_]+, уникален), "name_key": String (ключ перевода), "url_template": String (содержит {z}, {x}, {y}; необязательно {s}), "subdomains": Array[String] (может быть пустым; если в шаблоне {s} — непустой), "max_zoom": int (1..19), "attribution": String (непустая, показывается на карте), "_doc": String}`.
  v2: `osm` (OpenStreetMap standard, max_zoom 19, «© OpenStreetMap contributors») — **первый, по умолчанию**: подписи населённых пунктов крупные и с малых масштабов; `opentopomap` (OpenTopoMap, max_zoom 17, «Map data © OpenStreetMap contributors, SRTM | Map style © OpenTopoMap (CC-BY-SA)») — второй.
- Инвариант (решение пользователя 05.10.2026): на карте видны названия населённых пунктов; `map_picker.start_zoom` — не меньше 11 (на OSM standard подписи сёл появляются с z≈11–12).
- `map_picker.tile_cache_dir`: String, кеш `<tile_cache_dir>/<id>/<z>/<x>/<y>.png` (по умолчанию `user://map_cache`); `map_picker.user_agent` — честный User-Agent игры (политика OSM).
- Ключи отмывки (`light_*`, `exaggeration`, `*_color`, `*_height_m`) из `map_picker` удаляются; шейдера `map_hillshade.gdshader` нет.
- `RasterTileLoader` (`scripts/terrain/raster_tile_loader.gd`, Node): `fetch_tile(basemap: Dictionary, z: int, x: int, y: int) -> Image` (await; `null` — нет сети/ошибка, без падений), кеш на диске, не больше `map_picker.max_parallel_requests` (по умолчанию 4) запросов одновременно; запрошенный z ≤ `max_zoom` слоя (выше — растягивается тайл max_zoom).
- Инвариант: атрибуция текущего слоя видна на карте всегда; в `ASSETS.md` — строка про оба слоя (источник, лицензия, атрибуция).

## SM-К2. Высота точки и интерфейс MapPicker (v1)
Владелец: SM-1. Потребители: `scripts/ui/flight_setup_screen.gd`, тесты `tests/ui/*`, контрактный тест.
- `TerrariumLoader.decode_height(c: Color) -> float` (static): м над уровнем моря, `R·256 + G + B/256 − 32768` при каналах 0..255.
- `TerrariumLoader.height_in_image(img: Image, px: Vector2) -> float` (static): билинейно по 4 соседним пикселям, `px` — в пикселях тайла (0..256, центр пикселя i — i + 0,5), края — зажим.
- `TerrariumLoader.elevation_at(lat: float, lon: float, z: int = -1) -> float` (await): z по умолчанию — `map_picker.elevation_zoom` (12); тайл через `fetch_tile` (общий кеш); `NAN` — нет данных.
- `MapPicker`: сигнал `point_picked(lat: float, lon: float)` — без изменений; новый сигнал `elevation_ready(lat: float, lon: float, h_m: float)` (`h_m` может быть `NAN`); свойство `picked_elevation_m: float` (`NAN`, пока не известна или для точки не выбрана); ответ для устаревшей точки (выбрали другую раньше прихода высоты) отбрасывается.
- Отображение: рядом с координатами точки на карте и в подписи экрана «Полёт…» (`setup_map_point`) — `«<lat>, <lon> · <h> м»`, h — целое; нет данных — `«—»`. Единицы — метры над уровнем моря.
- Инвариант: высота — подсказка в меню, в физике не участвует (рельеф полёта строится как прежде).

## История
- SM-К1 v2 (05.10.2026): по умолчанию `osm` (был `opentopomap`); `start_zoom` ≥ 11 — названия населённых пунктов обязательны (решение пользователя). Потребители: MapPicker (порядок слоёв из конфига), контрактный тест.
- v1 (05.10.2026) — заведены до первого исполнителя.
