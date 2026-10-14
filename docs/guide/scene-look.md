---
type: "guide"
status: "active"
module: "scene-look"
area: "world"
updated: "2026-10-15"
summary: "Модуль scene-look («картинка сочнее»): принцип, шейдерный include sl_*, конфиг и выключатели; пункты SL-2…SL-23 разнесены по частям."
related: ["docs/guide/scene-look/light-atmosphere.md", "docs/guide/scene-look/ground.md", "docs/guide/scene-look/forest-cost.md", "docs/guide/scene-look-keys.md", "docs/plan/scene-look.md", "docs/contracts/scene-look.md", "docs/guide/terrain.md", "docs/guide/vegetation.md", "docs/guide/atmosphere.md"]
---
# scene-look — картинка сочнее

Модуль делает вид с высоты правдоподобнее там, где раньше был плоский или чужой по физике цвет: лес вдали, тени гор, дымка против солнца, дороги, тропы на склонах, камень, времена года. Принцип — физика прежде «нравится»: каждый пункт опирается на простую модель с цифрами из конфига. Контракты стыков — `docs/contracts/scene-look.md` (SL-К1 — файлы и конфиг, SL-К2 — широта, дата, сезон, SL-К3 — бюджет и замер GPU, SL-К4 и SL-К5 — смена формы дерева и дерево в клетке). Таблицы всех ключей — [scene-look-keys.md](scene-look-keys.md); план и журнал — `docs/plan/scene-look.md`. Контракты SL-К6 (варианты шейдера рельефа) и SL-К7 (упаковка карт рельефа, одна текстура просек) — там же.


## Пункты по частям

| Часть | Пункты |
|---|---|
| [scene-look/light-atmosphere.md](scene-look/light-atmosphere.md) | SL-2 свет неба и земли, дальняя тень рельефа, полог леса вдали; SL-3 дымка с ореолом; SL-4 дороги вдали; SL-7 просвет паруса и листвы |
| [scene-look/ground.md](scene-look/ground.md) | SL-8 скотные тропы; SL-9 скалы и осыпи; SL-6 сезон по дате, широте и высоте; SL-14 альбедо деревьев; SL-15 волны ветра по траве; SL-5 пятна тона, зелень у воды, граница леса; SL-10 свежий снег и ледники |
| [scene-look/forest-cost.md](scene-look/forest-cost.md) | SL-17…SL-20 лес вдали (дерево в клетке, кресты, плавные стыки); SL-11 и SL-23 цена GPU и варианты шейдера по пресетам; границы модели |

## Как устроено

- **Include.** Весь новый шейдерный код — `scripts/terrain/scene_look.gdshaderinc`: функции `sl_*` и uniform-ы `sl_*`. Подключён в `terrain_main.gdshaderinc` (тело шейдера рельефа, после `terrain_common`; `terrain.gdshader` и `variants/terrain_*.gdshader` — его варианты), `forest_impostors.gdshader`, `grass.gdshader`, `tree_model.gdshader`, `tree_cross.gdshader`. Дымка, дороги и парус — в своих файлах (`haze.*`, `roads.look.*`, `configs/sail.json`), у них свои ключи.
- **Строки `// SL`.** В `terrain_main.gdshaderinc` — только `#include` и короткие строки вызовов с меткой `// SL` в конце. Результат старых функций (`meadow_color*`, `field_plot_color`, `canopy`…) правится после вызова; сами функции и код mountain-look (вершинный шейдер, `relief_*`, снег `gully_*`/`snow_*`, `rock_*`, `scree_*`) не меняются. Найти все вставки: поиск `// SL` в шейдере.
- **Конфиг.** `configs/world.json → scene_look`: ключ `<k>` попадает в uniform `sl_<k>` материала рельефа (`TerrainRenderer.apply_scene_look_params`), вложенных объектов нет — числа, массивы чисел (→ vec2/3/4, без перевода из sRGB: цвета линейные) и bool. У каждого ключа есть `<k>_doc`.
- **Выключатели.** `light_enabled`, `tree_albedo_enabled`, `patch_enabled`, `riparian_enabled`, `treeline_enabled`, `season_enabled`, `trails_enabled`, `rock_enabled`, `grass_wind_sheen_enabled`, `snow_enabled`, `glacier_enabled` (все `true`). Выключено — картинка как до пункта: в include каждая функция при `false` сразу возвращает вход. Пресеты качества (`configs/game.json → graphics_presets`) ключи `scene_look` не меняют, но выбирают вариант шейдера рельефа (`world.json → terrain.variant`, SL-К6): в `low` и `far` части SL вырезаны при компиляции — [scene-look/forest-cost.md](scene-look/forest-cost.md).
- **Рантайм-uniform-ы** (не ключи конфига; ставит `Terrain`): `sl_lat_deg` (широта центра места), `sl_doy` (день года из даты полёта, по умолчанию 196 = 15 июля), `sl_sun_dir` (на солнце), `sl_sky_up` и `sl_ground_low` (линейные RGB неба сверху и серой «земли» Godot снизу, CPU-оценка `TerrainRenderer.scene_look_sky`), `sl_season_pre` (vec4). Правило: после смены `sl_doy` или `sl_lat_deg` вызывать `SeasonLook.apply_pre`, иначе сезон останется на 15 июля.
- **Охрана `SL_NO_GROUND`.** Блоки include, которым нужен `terrain_common` (поля, луг, тропы, скалы, пятна), стоят под `#ifndef SL_NO_GROUND`: у `tree_model.gdshader` этого файла нет, он задаёт `#define SL_NO_GROUND`. Новый код с зависимостью от `terrain_common` обязан быть под охраной, иначе шейдер деревьев не соберётся (ловит `--filter=season`).
- **Тесты.** Контрактный — `tests/contracts/test_scene_look_contracts.gd`; сезон — `SeasonLook` против шейдера на GPU (`tools/gpu_tests.sh --filter=season`).
