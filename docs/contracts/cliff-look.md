---
type: contract
status: "closed"
module: cliff-look
area: world
updated: "2026-10-23"
summary: "Стыки cliff-look: стенд ракурсов крутых склонов (CL-К1); границы правки вида скал в шейдере рельефа (CL-К2)."
related: ["docs/plan/cliff-look.md", "docs/contracts/mountain-look.md", "docs/guide/terrain/surface.md"]
contracts: [{"id": "CL-К1", "version": 3}, {"id": "CL-К2", "version": 3}]
---
# Контракты cliff-look

## CL-К1 v3 — стенд ракурсов
Изменено в v3 (CL-1): `cam_agl_m` — высота над землёй ПОД КАМЕРОЙ (как в `osm_place_shot.gd`); формат файла не менялся.
Изменено в v2 (2026-10-23, решение пользователя): замер цены кадра на GPU убран — не делать.
- Владелец: CL-1. Потребители: CL-2 и следующие задачи модуля (кадры «после» — тем же стендом, без правок ракурсов).
- Ракурсы — `tools/shots/cliff_look_views.json` (UTF-8 JSON):
  `{"version": 1, "date": "ГГГГ-ММ-ДД", "hour": <местный час, float>, "sun_min_deg": 35,
    "places": [{"tag": "<латиница>", "name": "<по-русски>", "lat": f, "lon": f,
                "views": [{"name": "<латиница>", "lat": f, "lon": f, "dist_m": f, "cam_agl_m": f, "az_deg": f, "wait_s": f}]}]}`
  Смысл полей `views` — как у `tools/shots/osm_place_shot.gd` (вид `pt`): цель (lat, lon), камера на `dist_m` от цели со стороны
  `az_deg` (° от севера), на `cam_agl_m` над землёй под камерой. Мест ≥ 3 (Шымбулак обязательно), ракурсов ≥ 2 на место.
  Высота солнца на всех местах в `date`/`hour` > `sun_min_deg` (кадры не зависят от правки заката HH-15).
- Запуск: `tools/shots/cliff_look_shots.sh <before|after|<метка>> [--views=<путь>]` — все ракурсы, кадры
  `/home/greg/deltaplan/build/screenshots/cliff-look/<метка>_<tag>_<view>.jpg` (JPEG q88, 1920×1080), профиль Godot — временный
  или общий кеш мест (не профиль копии), `project.godot` после запуска возвращается.
- Контрактный тест `tests/contracts/test_cliff_look_contracts.gd`: формат `cliff_look_views.json` (поля, типы, ≥ 3 мест, Шымбулак есть,
  ≥ 2 ракурса), версия 1 (формат файла ракурсов не менялся); ломается, если формат поменяли без правки контракта.

## CL-К2 v3 — вид крутых склонов: границы правки
Изменено в v3 (решение пользователя 2026-10-23 12:13): рисунок скал (блоки CL-2) отменён, смещение вершин (CL-К3) не делается;
только убрать полосы (`ledge_*`, `strata_strength`) и сопутствующую рябь, без нового рисунка.
- Владельцы: скалы — CL-2/CL-6, рельеф снега — CL-3. Потребители: шейдер рельефа (`terrain.gdshader` → `terrain_main.gdshaderinc`,
  `terrain_common.gdshaderinc`), CPU-зеркало `tools/bench/cliff_look_probe.gd` (если формулы веса скал/снега меняются).
- Неизменно: физика — `height_at`, `surface_at`, классы карты поверхности, поле воздуха; вершинный шейдер и MLK-К2 v2 (у камеры `dh = 0`);
  `rock_scatter`; посадку не учитывать (решение 2026-10-23).
- Скалы (CL-6): уступы `ledge_*` и цветные `strata_*` — нет (сделано в CL-2); блоки породы CL-2 (`cliff_block_m`, `cliff_tone`, `cliff_tilt`,
  `cliff_bulge`, `cliff_jitter`, `cliff_crack_*`, `cliff_ao*`, `cliff_fade_px`) — убрать из шейдера и конфига; ослабление мелкой ряби на крутом
  (`cliff_slope_deg`, `cliff_fine_keep` — вес `sl_rock` < 2 м и Rock030) — оставить (не рисунок). `strata_m` в конфиге остаётся (RockScatter).
- Снег (CL-3): 1–2 простых крупных элемента рельефа снега (напр. желоба/рёбра вдоль линии падения на крутом снегу, крупная волнистость)
  в нормали и тоне снега; ключи `terrain_look.snow_relief_*`; классы снега и доля снега (MLK-4) не меняются.
- Стык файлов: в `terrain_main.gdshaderinc` CL-2 правит блок скал и уступов, CL-3 — блок снега; свои uniform-ы — рядом со своими
  блоками (скалы — на месте `strata_*`/`ledge_*`, снег — рядом с `snow_*`), не в конец файла; в `world.json` — рядом с родственными ключами.
- Ключи HH-15 (`time.light`, `sun_glare`, экспозиция в `rendering`) не трогать; `sky.gdshader` — не трогать.
- Геометрия у камеры: меши и смещение вершин — нет (решения 2026-10-23).

