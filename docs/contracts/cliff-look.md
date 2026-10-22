---
type: contract
status: active
module: cliff-look
area: world
updated: 2026-10-23
summary: "Стыки cliff-look: стенд ракурсов крутых склонов (CL-К1); границы правки вида скал в шейдере рельефа (CL-К2)."
related: ["docs/plan/cliff-look.md", "docs/contracts/mountain-look.md", "docs/guide/terrain/surface.md"]
contracts: [{"id": "CL-К1", "version": 2}, {"id": "CL-К2", "version": 1}]
---
# Контракты cliff-look

## CL-К1 v2 — стенд ракурсов
Изменено в v2 (2026-10-23, решение пользователя): замер цены кадра на GPU убран — не делать.
- Владелец: CL-1. Потребители: CL-2 и следующие задачи модуля (кадры «после» — тем же стендом, без правок ракурсов).
- Ракурсы — `tools/shots/cliff_look_views.json` (UTF-8 JSON):
  `{"version": 1, "date": "ГГГГ-ММ-ДД", "hour": <местный час, float>, "sun_min_deg": 35,
    "places": [{"tag": "<латиница>", "name": "<по-русски>", "lat": f, "lon": f,
                "views": [{"name": "<латиница>", "lat": f, "lon": f, "dist_m": f, "cam_agl_m": f, "az_deg": f, "wait_s": f}]}]}`
  Смысл полей `views` — как у `tools/shots/osm_place_shot.gd` (вид `pt`): цель (lat, lon), камера на `dist_m` от цели со стороны
  `az_deg` (° от севера), на `cam_agl_m` над землёй в цели. Мест ≥ 3 (Шымбулак обязательно), ракурсов ≥ 2 на место.
  Высота солнца на всех местах в `date`/`hour` > `sun_min_deg` (кадры не зависят от правки заката HH-15).
- Запуск: `tools/shots/cliff_look_shots.sh <before|after|<метка>> [--views=<путь>]` — все ракурсы, кадры
  `/home/greg/deltaplan/build/screenshots/cliff-look/<метка>_<tag>_<view>.jpg` (JPEG q88, 1920×1080), профиль Godot — временный
  или общий кеш мест (не профиль копии), `project.godot` после запуска возвращается.
- Контрактный тест `tests/contracts/test_cliff_look_contracts.gd`: формат `cliff_look_views.json` (поля, типы, ≥ 3 мест, Шымбулак есть,
  ≥ 2 ракурса), версия 1 (формат файла ракурсов не менялся); ломается, если формат поменяли без правки контракта.

## CL-К2 v1 — вид крутых склонов: границы правки
- Владелец: CL-2 (по диагнозу CL-1). Потребители: шейдер рельефа (`terrain.gdshader` → `terrain_main.gdshaderinc`,
  `terrain_common.gdshaderinc`, `scene_look.gdshaderinc`), `rock_scatter`, CPU-зеркала (`tools/bench/cliff_look_probe.gd`, `ReliefLook`).
- Неизменно: физика — `height_at`, `surface_at`, классы карты поверхности, поле воздуха; посадку не учитывать (решение 2026-10-23).
- MLK-К2 v2 действует (у камеры `dh = 0`, без швов по LOD и слоям). Нужна геометрия у камеры на скалах — только через шлюз (вопрос главной),
  с новой версией этого контракта.
- Ключи вида скал — `configs/world.json → terrain_look.*` (каждый — uniform); ключи HH-15 (`time.light`, `sun_glare`, экспозиция
  в `rendering`) не трогать; `scripts/terrain/` и `sky.gdshader` HH-15 не трогает.
- Уточняется в v2 после CL-1: какие члены раскраски убираются/заменяются, масштабы крупных форм (м).
