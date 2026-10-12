---
type: contract
status: active
module: start-pick
updated: 2026-10-12
summary: "Контракты start-pick: точный старт в FlightSettings и его применение в Game (SP-К1); проверка допустимости точки StartSpot (SP-К2); точный старт в сети — Zone и WorldKey v2 (SP-К3); камни и кусты не на разбеге (SP-К4)."
related: ["docs/plan/start-pick.md", "docs/contracts/start-fixes.md", "docs/contracts/popular-places.md", "docs/guide/net-protocol.md"]
contracts: [{"id": "SP-К1", "version": 1}, {"id": "SP-К2", "version": 1}, {"id": "SP-К3", "version": 1}, {"id": "SP-К4", "version": 1}]
---
# Контракты start-pick

Контрактный тест — `tests/contracts/test_start_pick_contracts.gd` (версии здесь; проверки формы дописывают владельцы). Правка интерфейса — только через координатора: версия +1, этот файл и тест — в том же шаге.

Системы координат (как в коде): мир — X восток, Z юг (−Z север), Y — м над уровнем моря, начало — центр места; курс — градусы, 0 = север, по часовой, `[0, 360)`; вектор «вперёд» `(sin h, 0, −cos h)`; широта/долгота — WGS84, градусы.

## SP-К1 v1
Точный старт в настройках полёта и его применение при старте.

- Владелец: SP-1. Потребители: SP-2 (осмотр, панель, строка в «Настройках полёта»), SP-3 (сеть), `Favorites` (через `to_dict`), `UserSettings.save_last_flight`.
- `FlightSettings` (`scripts/game/flight_settings.gd`):
  - `var start_lat: float = NAN`, `var start_lon: float = NAN` — точка старта, WGS84, градусы;
  - `var start_heading_deg: float = NAN` — курс разбега;
  - `func has_exact_start() -> bool` — `is_finite(start_lat) and is_finite(start_lon) and is_finite(start_heading_deg)`;
  - `func set_exact_start(lat: float, lon: float, heading_deg: float) -> void` — курс приводится к `[0, 360)`;
  - `func clear_exact_start() -> void` — все три в `NAN`;
  - `to_dict`/`from_dict` — ключи `start_lat`, `start_lon`, `start_heading_deg` (нет точки — ключей нет или `null`; `from_dict` без ключей → `NAN`); `duplicate`/копирование настроек переносит поля.
- Точка — уточнение текущего места (`location_id/site_id/pick_lat/pick_lon` не меняются). Любой выбор места в `PlacePickRow` (карта, популярные, недавние, встроенное) вызывает `clear_exact_start()`; загрузка из избранного/последнего полёта — берёт точку из словаря.
- `Game._choose_start()`: если `has_exact_start()` и `StartSpot.check(...)` (SP-К2) по `terrain.latlon_to_local(start_lat, start_lon)` даёт `ok` → `_start_pos = Vector3(x, height_at(x, z), z)`, `_start_heading = start_heading_deg`, `terrain.add_start_clearing(x, z, Terrain.start_clearing_radius_m())`. Иначе — прежний автостарт (встроенный старт или точка с карты) и `push_warning`, без сообщения пилоту.
- `_site_heading = _start_heading` (ветер «в старт» дует в выбранный курс). `_align_start_heading()` при `has_exact_start()` курс не меняет (и на `restart()`).
- `Game.get_start()` — как было: `{position, heading_deg}` — отдаёт точный старт; лагерь, боты, термики, пасхалки, сетевая очередь видят его без правок.
- Инварианты: при допустимой точке `get_start().position` по XZ — в пределах 0,5 м от `latlon_to_local(start_lat, start_lon)`, `heading_deg` — `start_heading_deg` (±0,01°) и после `restart()`; `from_dict(to_dict(s))` сохраняет три поля (NAN ↔ NAN).

## SP-К2 v1
Проверка допустимости точки старта — одна функция для осмотра (SP-2) и запуска (SP-1).

- Владелец: SP-1. Потребители: `Game._choose_start`, панель осмотра (SP-2), тесты.
- `StartSpot` (`scripts/game/start_spot.gd`, `class_name StartSpot`, только static):
  - `static func check(terrain: Terrain, x: float, z: float) -> Dictionary` →
    `{ok: bool, reason: String, height_m: float, slope_deg: float, downhill_deg: float}`;
  - `reason` — `""` при `ok`, иначе один из: `"outside"` (вне `terrain.detail_bounds()`, сжатого на `start_pick.edge_margin_m`), `"water"` (`surface_at == SurfaceLayer.WATER`), `"built"` (`surface_at == SurfaceLayer.BUILT`), `"steep"` (`slope_deg > start_pick.max_slope_deg`); проверка в этом порядке, первая сработавшая;
  - `slope_deg`, `downhill_deg` — по `StartPlacement.evaluate` (тот же `probe_m`), `downhill_deg` — курс вниз по склону (по умолчанию для новой точки); на ровном месте — любой конечный;
  - `height_m` — `terrain.height_at(x, z)`;
  - все числа конечны при любом `x, z` (в т. ч. вне рельефа).
- Конфиг `configs/game.json → start_pick`: `max_slope_deg` (40 — круче на ногах не разбежаться), `edge_margin_m` (200 — поляна, лагерь и разбег в пределах детального рельефа), `_doc`.
- Лес, кусты, пологий склон — допустимы (лес вырубает поляна старта; последствия — в полёте). Подсказок пилоту, кроме причины недопустимости, нет.
- Ключи перевода причин — `start_pick_bad_<reason>` (`locale/ui.csv`, ru/en) — заводит SP-2.

## SP-К3 v1
Точный старт в сетевой игре — у всех один.

- Владелец: SP-3. Потребители: `NetZone`/`NetFlight` (клиент и хост), сервер (поля прозрачно хранит и раздаёт), `docs/guide/net-protocol.md`, `tests/net/*`.
- `net.proto`, `message Zone`: `optional double start_lat = 13; optional double start_lon = 14; optional double start_heading_deg = 15;` — все три или ни одного. Зеркало — `scripts/net/net_messages.gd` (те же имена в camelCase по правилам файла). `FlightSettings.to_zone/from_zone` переносят поля.
- `WorldKey` (`scripts/game/world_key.gd`): `VERSION := 2`; ключи `slat`, `slon` (5 знаков), `hdg` (1 знак), только при `has_exact_start()`; `_place()` точку старта не притягивает к встроенному старту. Мир клиента (`NetFlight.world_settings`) получает точку из ключа.
- Инварианты: хост с точным стартом → у клиента `has_exact_start()`, точка ±1e-5°, курс ±0,1°; `NetQueue.spots_for` строит очередь от этой точки и курса; без точки — поведение как было.

## SP-К4 v1
Камни и кусты не на разбеге у любого старта.

- Владелец: SP-4. Потребители: `ShrubScatter`, `RockScatter`, тесты.
- Центры стартов для отступа — `Terrain.get_start_clearings()` (встроенные старты и добавленные `add_start_clearing`: точка с карты и точный старт), а не только `get_start_sites()`.
- Радиус без камней и кустов — `≥ start_search.runway_m` (40 м) от центра старта (конфиг `keep_off_start_m` у камней и кустов — не меньше `runway_m`).
- Поляна, добавленная после сборки (`add_start_clearing`), убирает камни/кусты на разбеге со следующего перестроения (по `surface_revision` или своей ревизии), без перезагрузки места.
- Инвариант: ни одного камня/куста ближе `runway_m` к центру любой поляны старта; за отступом — как было.
