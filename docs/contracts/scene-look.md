---
type: contract
status: active
module: scene-look
updated: 2026-10-13
summary: "Контракты scene-look: свой include и секция конфига без правок кода mountain-look (SL-К1), широта/дата/сезон для шейдеров с CPU-зеркалом (SL-К2), бюджет и замер GPU (SL-К3)."
related: ["docs/plan/scene-look.md", "docs/contracts/mountain-look.md", "docs/guide/terrain.md"]
contracts: [{"id": "SL-К1", "version": 1}, {"id": "SL-К2", "version": 1}, {"id": "SL-К3", "version": 1}]
---
# Контракты scene-look

Контрактный тест — `tests/contracts/test_scene_look_contracts.gd` (`test_k1_*` и проводка `test_k2_wiring_*` — SL-2, сезон `test_k2_season_*` — SL-6).
Правка интерфейса — только через координатора: версия +1, этот файл и тест — в том же шаге.

## SL-К1 v1 — свой include, своя секция конфига, стык с mountain-look
- Владелец: SL-2. Потребители: SL-4…SL-10, mountain-look (не должен ломаться при слиянии).
- Весь новый шейдерный код — в `scripts/terrain/scene_look.gdshaderinc`: функции `sl_*`, uniform-ы `sl_*`. Подключается в `terrain.gdshader`
  (после `terrain_common`), может подключаться в `grass.gdshader`, `forest_impostors.gdshader`, `tree_model.gdshader`, `road.gdshader`.
- В `terrain.gdshader` — только строка `#include` и короткие строки вызовов, каждая с меткой `// SL` в конце; результат существующих функций
  (`meadow_color*`, `field_plot_color`, `canopy`, …) правится после вызова, сами функции в `terrain_common`/`meadow_look` не меняются.
  До волны 3 не трогать: вершинный шейдер и `relief_*`, снег (`gully_*`, класс 8, `snow_*`), скалы и осыпи (`rock_*`, `scree_*`, `ledge_*`,
  `material_edge_*`, `outcrop_*`) — это mountain-look.
- Конфиг — `configs/world.json → scene_look` (новая секция в конце файла, не внутри `terrain_look`). Каждый ключ `scene_look.<k>` попадает в
  uniform `sl_<k>` материала рельефа тем же механизмом, что `terrain_look` (`TerrainRenderer.apply_look_params`); вложенных объектов нет
  (числа, массивы чисел → vec2/3/4, bool). Выключатель пункта — `scene_look.<пункт>_enabled` (bool), всё выключено = картинка как до модуля
  (кроме SL-3/SL-4/SL-7 — свои файлы и свои ключи `haze.*`, `roads.look.*`, `sail_params`).
- Пресеты качества (`configs/game.json → graphics_presets`) могут выключать пункты через `world.scene_look.*` — только если не влезаем в SL-К3.
- В шейдере рельефа — без циклов с `break` и с числом шагов из uniform (проход теней дорожает).
- Документ — `docs/guide/scene-look.md` (SL-12); в `docs/guide/terrain.md` — только строка в «Что где».
- Инварианты теста: include существует и подключён; каждый ключ `scene_look` есть uniform-ом в шейдере рельефа; в `terrain.gdshader`
  нет uniform-ов `sl_*`, объявленных вне include.

## SL-К2 v1 — широта, дата, сезон
- Владелец проводки — SL-2, владелец сезона — SL-6. Потребители: SL-5, SL-6, SL-10, трава, импостеры, модели деревьев.
- Uniform-ы (во всех шейдерах с include): `sl_lat_deg` (float, градусы, + север; широта центра места), `sl_doy` (float, день года 1…366,
  из даты полёта `FlightSettings.month/day`; по умолчанию 196 = 15 июля). Ставит `Terrain`: при сборке материала и
  `Terrain.set_flight_date(month: int, day: int)` (вызывает игра при старте полёта, там же, где солнце); материалам травы, импостеров и
  деревьев — тем же путём, что `sun_dir`.
- Сезон (SL-6): CPU-зеркало `scripts/terrain/season_look.gd`, `class_name SeasonLook`,
  `static func state(doy: float, lat_deg: float, alt_m: float, look: Dictionary) -> Dictionary` с ключами `green`, `dry`, `autumn`, `bare`
  (все 0…1: свежесть весенней травы, сухость/солома, осенняя окраска листвы, листва опала); в шейдере — `vec4 sl_season(float doy,
  float lat, float alt)` с той же формулой (правятся вместе). `look` — секция `scene_look`.
- Фенология: сдвиг сроков по закону Хопкинса — ≈ 4 дня на 1° широты к полюсу и на ~122 м высоты (весна позже, осень раньше);
  южное полушарие — дата сдвинута на полгода; |широта| < ~23° — `autumn = bare = 0`. Сухость лета складывается с `terrain_look.dryness`
  места (местная база), а не заменяет её.
- Инварианты теста: все значения в [0, 1]; (doy, lat) и (doy+182,5, −lat) дают одно состояние (± 0,02); при фиксированной осенней дате
  `autumn` не убывает с высотой; 15 июля, 51° с. ш., 1000 м → `autumn = bare = 0`; 1 октября, 51°, 1000 м → `autumn ≥ 0,5`;
  тропики (5°) → `autumn = 0` круглый год.
- v2 (SL-10): ключ `snow_fresh` 0…1 — свежий снег выше сезонной линии.

## SL-К3 v1 — бюджет и замер GPU
- Владелец: координатор. Потребители: все задачи.
- Замер: `tools/terrain/shots.sh <каталог>` → `bench.json` (`gpu_ms_mean` «full» и «relief», 1080p, RTX 4070 SUPER) — база (ветка, от которой
  задача) и задача, по 2 прогона вперемежку, медиана; в отчёт — `gpu_full_ms_base`, `gpu_full_ms_after`, `gpu_relief_ms_base`,
  `gpu_relief_ms_after`. Дымка, дороги, парус, которых нет в стенде, — `tools/bench/frame_profile.sh` или число из теста с обоснованием.
- Бюджет на 4070 SUPER (≈ ×2,5 на RX 5600 XT): SL-2 0,12; SL-3 0,03; SL-4 0,03; SL-5 0,08; SL-6 0,06; SL-7 0,02; SL-8 0,03; SL-9 0,05;
  SL-10 0,03 мс; сумма ≤ 0,4 мс. Превышение — шлюз.
- VRAM: новых текстур нет; если без неё никак — через координатора, по экранному размеру, сжатие + мипмапы.
