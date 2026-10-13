---
type: contract
status: active
module: mountain-look
updated: 2026-10-13
summary: "Контракты mountain-look: высоты места со сглаживанием только в лесу и застройке (MLK-К1), дальнее заострение рельефа — функция мира и дальности с нулём у камеры (MLK-К2), формат зонда силуэта гор (MLK-К3)."
related: ["docs/plan/mountain-look.md", "docs/guide/terrain.md", "docs/contracts/osm-any.md", "docs/contracts/no-osm.md"]
contracts: [{"id": "MLK-К1", "version": 1}, {"id": "MLK-К2", "version": 2}, {"id": "MLK-К3", "version": 2}]
---
# Контракты mountain-look

Контрактный тест — `tests/contracts/test_mountain_look_contracts.gd` (К1 пишет MLK-2, К2 — MLK-3, К3 — MLK-1; каждый — свои функции
`test_k1_*`, `test_k2_*`, `test_k3_*`). Правка интерфейса — только через координатора: версия +1, этот файл и тест — в том же шаге.

## MLK-К1 v1 — высоты места: сглаживание только под кронами и крышами
- Владелец: MLK-2 (`DemStage`/стадия сборки места). Потребители: `Terrain.height_at/normal_at` (полёт, столкновения, старты, посадки),
  поле воздуха и термики (вход решателя — высоты слоёв), `TerrainRenderer` (текстура высот), `RiverStage`, `OsmStage`, `TerrainRelief`,
  зонды `cliff_look_probe.gd`, `mountain_look_probe.gd` (К3).
- Детальный слой (Copernicus, 25 м): `h = r + w·(G_σ(r) − r)`, `r` — сырая выборка Copernicus в узлах (как сейчас до сглаживания),
  `G_σ` — тот же разделимый гаусс, `σ = smooth_sigma_cells` (0,8 клетки), `w ∈ [0, 1]` — вес «кроны/крыши» в узле.
- `w`: доля леса в окрестности узла (маска 10 м, канал L `detail10`) и застройки (WorldCover класс 7 / `built10`), максимум из двух,
  затем мягко размыта гауссом `smooth_mask_sigma_m` (≈ 50 м, не меньше 2 клеток) и ограничена [0, 1]. Классы — ключ
  `smooth_mask_classes` (по умолчанию [1, 7]). На скалах, снегу, голом грунте, лугах, кустарнике дальше ~3·`smooth_mask_sigma_m`
  от леса и застройки `w = 0` → `h = r` (до кванта 1/32 м).
- Нет данных покрова (офлайн, процедурный классификатор): `w = 1` везде — поведение как до модуля (ступеньки леса не вылезают).
- Фоновый слой (Terrarium, σ = 0) не сглаживается; в зоне детального берёт его итоговые высоты (`_patch_from_finer`) → на стыке нет ступеньки.
- Ключи слоя (`configs/world.json → location_builder.template.dem.layers[]`, `configs/locations/<id>.json → dem.layers[]`):
  `smooth_sigma_cells` (float, клетки), `smooth_mask_sigma_m` (float, м), `smooth_mask_classes` (int[]); пишутся в `meta.json` слоя.
- Формат места: `Locations.FORMAT_VERSION` = 4 (было 3) — старые кеши `user://locations` пересобираются.
- Инварианты для теста: (1) `FORMAT_VERSION == 4`; (2) на синтетическом рельефе (гребень + лес в половине области) узлы с `w = 0`
  равны сырым до 1/32 м, узлы глубоко в лесу равны `G_σ(r)` до 1/32 м; (3) `w` гладкая: соседние узлы отличаются ≤ 0,5;
  (4) `height_at` в узлах = записанный слой (как раньше); (5) без маски — `h = G_σ(r)` везде.

## MLK-К2 v2 — дальнее заострение и силуэт вершин (только картинка)
Изменено в v2 (MLK-3, 13.10): подъём выпуклых вершин вдали по пирамиде максимумов высот (пики не теряются между вершинами LOD);
сила заострения от перепада высот (высокие горы — сильнее, холмы — как v1), предел — подсеточный гребень; юбка висит от высоты узла без подъёма;
зеркало получает карту классов, 3D-камеру и пороги LOD.
- Владелец: MLK-3. Потребители: вершинный шейдер `terrain.gdshader` (оба слоя, все LOD, проход теней), `TerrainRenderer` (текстура
  `height_max_tex` — `HeightLayer.make_max_texture`, RF, уровни ≥ 1 — максимум, не среднее), CPU-зеркало для зонда К3.
- `VERTEX.y = h + dh − юбка·(skirt_depth + max(dh, 0))`; `dh = dh_peak + (заострение + промоины)·маски`; физика (`height_at`) смещения не видит.
- `dh_peak`: выпуклая вершина вдали поднимается к максимуму окна вокруг узла; уровень окна — по 3D-дальности через пороги LOD слоя
  (`lod_dist_m`) + `relief_peak_level`, не по шагу LOD чанка; вес — выпуклость × «окно содержит вершину»; гаснет ближе `relief_peak_near_m`;
  0 … `relief_peak_max_m`.
- Заострение: доля `relief_sharpen` → `relief_sharpen_high` по перепаду высот (`relief_high_m`, `relief_scale_m`); предел
  `relief_sharpen_max_m` → `clamp(relief_subgrid_k·шаг·tg(уклон), …, relief_sharpen_cap_m)`; общий предел — `ReliefLook.dh_limit_m(look)`.
- Инварианты (тест `test_k2_*`): `dh = 0` при горизонтальной дальности ≤ `relief_near_m.x`; `dh = 0` на лесе, воде, застройке; `dh` не зависит
  от шага LOD чанка; по дальности без ступенек (≤ 2 м на 10 м); подъём в 0 … `relief_peak_max_m`; все ключи `terrain_look.relief_*` — uniform-ы шейдера.
- CPU-зеркало: `ReliefLook.dh(layer: HeightLayer, surface: SurfaceLayer, x: float, z: float, cam: Vector3, look: Dictionary,
  lod_m: PackedFloat32Array) -> float` (`scripts/terrain/relief_look.gd`); шейдер и зеркало правятся вместе; зеркало без шума границ классов.

## MLK-К3 v2 — зонд силуэта гор
Изменено в v2 (MLK-3): поля добавлены, смысл прежних не менялся — раздел `mesh` (dh в долинах, открытые щели LOD, скачки на краю детального слоя), `probe_version` 2, аргументы `--dh=v1|v2`, `--quick=1`, `--look=<json>` (переопределение `terrain_look`); `h_render` считается через `ReliefLook.dh` (К2 v2).
- Владелец: MLK-1 (`tools/bench/mountain_look_probe.gd` + `.tscn`). Потребители: MLK-3, MLK-5, отчёт координатора.
- Запуск: `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . res://tools/bench/mountain_look_probe.tscn -- --latlon=LAT,LON
  [--location=<id>] --tag=<имя> --out=<путь.json> [--agl=300] [--az_step=0.1]`; кеш сырых данных — `--cache=<каталог>` (повторный прогон без сети).
- Вывод stdout: строки `MLOOK <tag> <раздел> ключ=значение …`, последняя `mountain_look_probe: OK`.
- JSON (`--out`, один объект на место): `{"probe_version": 1, "tag", "lat", "lon", "format_version", "layers": [{"id", "spacing_m", "size_km"}],
  "peaks": [{"lat", "lon", "dist_km", "layer", "h_raw", "h_game", "h_render"}],
  "crests": [{"layer", "band_km": [a, b], "zone": "above_forest"|"forest"|"all", "n", "curv_ratio", "drop_m_p50", "drop_m_p90"}],
  "horizon": {"az_step_deg", "rough_raw_deg", "rough_render_deg", "rough_ratio", "deficit_deg_p50", "deficit_deg_max", "far_layer_share"},
  "memory": {…}}` (memory — только у MLK-1, по желанию).
  - `h_raw` — Copernicus 30 м без сглаживания (эталон), `h_game` — `height_at`, `h_render` — высота, как её рисует меш: LOD-выборка вершин
    на расстоянии от точки старта + `dh` К2 (через `ReliefLook.dh`, а до появления зеркала — копия формулы v1 в зонде).
  - `curv_ratio` — медиана кривизны гребней игра/сырое (гребни — сырой лапласиан < −0,15 м/м, как в `cliff_look_probe`).
  - горизонт: точка старта + `--agl`, угол горизонта по азимуту; `rough_*` — СКО высокочастотной части (вычесть сглаживание по 2°)
    угла горизонта; `deficit_*` — недобор угла отрисовки против сырого; `far_layer_share` — доля азимутов, где горизонт даёт фоновый слой.
- Единицы: м, км, градусы. Добавлять поля можно (версия зонда +1), менять смысл — через координатора.
