---
type: "plan"
status: "active"
module: "start-map"
updated: "2026-10-05"
summary: "Экран выбора точки старта: растровая топокарта (OpenTopoMap/OSM) вместо отмывки высот и высота выбранной точки над уровнем моря рядом с координатами."
related: ["docs/contracts/start-map.md", "docs/plan/on_demand_location.md", "docs/plan/offline_world_data.md"]
---
# start-map — карта выбора точки старта

## Цель
Отзыв пилотов (05.10.2026): на экране «Полёт…» → «Выбрать на карте…» рисуется отмывка высот из тайлов Terrarium —
по ней местность не узнаётся. Нужно:
1. Подложка — обычная растровая карта (топографическая/OSM), по которой узнаются реки, дороги, посёлки, хребты.
2. Для выбранной точки рядом с координатами — высота, м над уровнем моря, из имеющихся данных рельефа.

## Решения пользователя (не обсуждаются)
- Растровая карта вместо карты высот; простейший рабочий вариант (05.10.2026).
- Офлайн-пакет данных (`docs/plan/offline_world_data.md`, `osm_vector_pack.md`) отложен — не начинать; карта — из сети с кешем на диске.
- Лицензии: некоммерческий open source; атрибуция — в `ASSETS.md` и подписью на карте.
- Не шлифовать; визуальные мелочи — максимум 2 попытки.

## Что есть (05.10.2026)
- `scripts/terrain/map_picker.gd` (`MapPicker`) — панорама/масштаб web-mercator, тайлы Terrarium через `TerrariumLoader.fetch_tile`, шейдер отмывки `map_hillshade.gdshader`, поле «широта, долгота», сигнал `point_picked`. Конфиг — `configs/world.json` → `map_picker`.
- `scripts/terrain/terrarium_loader.gd` — тайлы AWS Terrain Tiles (Terrarium, высота = R·256 + G + B/256 − 32768 м, высоты над уровнем моря — SRTM/GMTED/ETOPO, геоид), кеш `user://terrain_cache/`.
- Растровых карт (OSM/топо) в проекте нет; OSM-векторы (`data/osm/*.json`) — только объекты мира в квадрате локации.
- Экран: `scripts/ui/flight_setup_screen.gd` (оверлей карты, `_on_map_ok`, подпись `setup_map_point`); скриншоты — `tools/shots/ui.sh` (кадр `map_*`).

## Выбор подложки (координатор, 05.10.2026)
- **OpenTopoMap** (`https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png`, z ≤ 17, CC-BY-SA; данные © участники OpenStreetMap, SRTM) — по умолчанию: топографическая карта с горизонталями и отмывкой, пилоту привычна.
- **OpenStreetMap standard** (`https://tile.openstreetmap.org/{z}/{x}/{y}.png`, z ≤ 19, «© OpenStreetMap contributors», ODbL) — второй слой переключателем (если OpenTopoMap медлит/недоступен).
- Обе политики допускают редкий интерактивный просмотр с честным User-Agent и кешем; массовой предзагрузки нет. Esri/Google — нет (условия).
- Отмывка высот как слой убирается (совместимость не нужна); Terrarium остаётся источником высоты точки.

## Границы модели
- Высота точки — Terrarium z12 (шаг ≈ 38 м·cos φ), билинейно; ошибка до десятков метров на крутых склонах; не высота детального слоя локации (Copernicus 25 м).
- Нет сети и нет кеша — карта серая, высота «—»; это не ошибка.

## Задачи
### SM-1. Растровая подложка и высота точки
Тип `dp-engineer` (Sonnet). Скоуп: `scripts/terrain/map_picker.gd`, `scripts/terrain/raster_tile_loader.gd` (новый), `scripts/terrain/terrarium_loader.gd` (только добавить функции высоты), `scripts/terrain/map_hillshade.gdshader` (удалить), `scripts/ui/flight_setup_screen.gd` (подпись точки), `configs/world.json` (`map_picker`), `locale/*` (ключи), `ASSETS.md`, `tests/ui/*`, `tools/shots/*` (только если кадру карты нужно дождаться тайлов), `docs/guide/*` (строка о карте).
Контракты: SM-К1 v1, SM-К2 v1.
Приёмка:
- контрактный тест `tests/contracts/test_start_map_contracts.gd` — 0 упало; тесты `menu_setup`, `recent_places`, `language`, `ui` — 0 упало;
- в коде нет `map_hillshade` и Terrarium-слоя в отрисовке карты;
- скриншот оверлея карты (Алтай, точка выбрана, видна высота) — `/home/greg/deltaplan/build/screenshots/SM-1/`, 1920×1080, карта прогружена (сеть есть).
Оценка: 0,5 дня.

## Риски
- Тайловый сервер OpenTopoMap медленный → второй слой OSM; таймаут из конфига.
- Godot HTTPS и PNG — те же, что у Terrarium (уже работает).
