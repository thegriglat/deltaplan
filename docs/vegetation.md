# Растительность вблизи камеры

Группа «Растительность» (V01: рекомендации 1, 3, 4 из docs/plan/README.md, группа 5). Пока — только
травинки вокруг камеры (`GrassField`); деревья остаются файлами и конфигом группы «Рельеф»
(`configs/world.json → trees`) до переноса файлов из `scripts/terrain/` (карточка V02, после terrain2).

## Файлы

| Файл | Что делает |
|---|---|
| `scripts/terrain/grass_field.gd` (`GrassField`, MultiMeshInstance3D) | сетка пучков травы вокруг камеры, приминание у ног пилота, посадки-прямоугольники, тестируемые статические формулы (`far_density`, `press_factor`, `in_landing_rect`, …) |
| `scripts/terrain/grass.gdshader` | где трава (по карте поверхности), высота, прореживание/расширение вдали, ветер (`terrain_wind.gdshaderinc`), приминание, цвет (`terrain_common.gdshaderinc → meadow_color`), скошенные площадки |
| `configs/vegetation.json` | параметры травы (`grass`): свой файл, не делится с `configs/world.json` (владение группы «Рельеф») |
| `tests/vegetation/test_grass_field.gd` | прореживание вдали, приминание по высоте ног, прямоугольник посадки |

## API

- `Terrain.get_grass_palette()` — общая с рельефом палитра (цвет, сухость), читает `GrassField`.
- `Terrain.set_pilot(node)` — трава приминается у ног ноды `node`.
- `GrassField.set_landing_sites(sites: Array[Dictionary])` — посадки прямоугольником, не кругом:
  `sites` — как `WorldObjects.get_landing_sites()`:
  `[{position: Vector3, axis_deg, length_m, width_m, mowed_height_k?}]`. Подключает группа
  «Сцена игры» (`WorldObjects.get_landing_sites()` → `terrain.grass.set_landing_sites(...)`). До
  вызова действует круговое скашивание вокруг `Terrain.get_landing_sites()` радиусом
  `grass.landing_mow_radius_m`.

## Параметры (`configs/vegetation.json → grass`)

- `radius_m`, `clump_spacing_m`, `blades_per_clump`, `segments`, `blade_width_m` — форма и число пучков.
- `blade_height_m`, `crop_height_m`, `shrub_density` — высота по классу поверхности (луг/поле/кустарник).
- `far_density_min`, `thin_start_k`, `thin_end_k` — прореживание вдали (рекомендация 1): доля видимых
  пучков падает от 1.0 у камеры до `far_density_min` на доле `thin_end_k` от `radius_m` (начиная с
  `thin_start_k`); пучок виден, если `hash(cell) < density`. По умолчанию даёт в 0–10 м от камеры
  вершин в ≈ 6–7 раз больше на единицу площади, чем в кольце 20–30 м.
- `far_width_k` — во столько раз шире дальние пучки (компенсирует прореживание визуально).
- `press_radius_m`, `press_agl_full_m`, `press_agl_zero_m` — приминание у ног пилота (рекомендация 3):
  полное при высоте ног над землёй ≤ `press_agl_full_m` (0,4 м), ноль при ≥ `press_agl_zero_m` (1,2 м);
  нормаль травинки не переворачивается на изнанке (`cull_disabled` + явный `NORMAL`, изнанка светится
  `BACKLIGHT`, а не темнеет).
- `mowed_height_k`, `landing_mow_radius_m` — круговое скашивание по умолчанию (см. API выше).
- `dryness_add_by_location` — сухость травинок сверх палитры локации, только для травы (Онгудай +0,35,
  Аскарово +0,25); не трогает `configs/locations/*.json` (владение группы «Рельеф»).
- `sway_hz`, `sway_amp`, `bend_amp`, `color_variation`, `max_agl_m` — качание, разброс цвета, высота
  отключения.

## Замеры (V01, критерий приёмки)

- Перенос `grass` из `configs/world.json` в `configs/vegetation.json` не меняет кадр (PSNR ≥ 45 дБ,
  тот же `--autopilot --screenshot --time --camera`, пока стенд T01 не готов).
- Прореживание: вершин в кольце 20–30 м от камеры в 5–8 раз меньше на единицу площади, чем в 0–10 м
  (`test_far_thinning_ratio`, ratio ≈ 6,5).
- Приминание: пилот на земле — полное (`press_factor` ≈ 1); в 1,5 м над землёй — 0
  (`test_press_full_at_low_agl`, `test_press_zero_above_1_2m`).
- Посадка прямоугольником: точка в 1 м от края внутри площадки — скошено, в 1 м за краем — нет
  (`test_landing_rect_inside_and_outside`).
- Против солнца (`--look`/камера сзади, yaw +180°): изнанка травинок не темнее лица > 15 % —
  `BACKLIGHT` в `grass.gdshader`.
- GPU травы (кадр с травой минус `--no-grass` в `terrain_preview.gd`) ≤ 0,3 мс на `radius_m` 30 м,
  `clump_spacing_m` 0,3 м.
