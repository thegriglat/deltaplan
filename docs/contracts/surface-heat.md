---
type: "contract"
status: "active"
module: "surface-heat"
updated: "2026-10-09"
summary: "Контракты surface-heat: SH1 конфиг параметров поверхности, SH2 ядро SurfaceHeat (H по классу и воде), SH3 вход решателя по клеткам (доли классов, влажность, вода), SH4 сила источника термиков из H, SH5 замер до/после"
related: ["docs/plan/surface-heat.md", "docs/research/surface_params.md", "docs/contracts/air-model.md"]
contracts: [{"id": "SH1", "version": 1}, {"id": "SH2", "version": 2}, {"id": "SH3", "version": 1}, {"id": "SH4", "version": 1}, {"id": "SH5", "version": 1}]
---

# Контракты surface-heat

Общие соглашения: H — явный поток тепла с поверхности, Вт/м², **> 0 вверх** (земля греет воздух). Классы — индексы
`SurfaceLayer` (NONE 0, FOREST 1, GRASS 2, CROP 3, SHRUB 4, BARE 5, WATER 6, BUILT 7, SNOW 8), `CLASS_COUNT` = 9.
Температуры — °C, ветер — м/с, высоты — м над морем. Все функции SH2 — чистые (без состояния, без случайности, без потоков).
Контрактные тесты — `tests/contracts/test_surface_heat_contracts.gd` (пишет SH-2, дополняют SH-4/SH-5); версии — словарь в тесте.

## SH1 v1 — конфиг `configs/surface_heat.json`
Владелец: SH-2 (числа — SH-1). Потребители: SH-2 (`SurfaceHeat`), SH-4, SH-5, SH-6 (z0).
```
{
  "_doc": "...",
  "classes": {                       # ровно 9 ключей = SurfaceLayer.CLASS_NAMES
    "<имя>": {"p4_row": "<class_name из surface_params.csv>",
              "albedo": f, "bowen": f, "bowen_min": f, "bowen_max": f, "g_frac": f, "z0_m": f}
  },
  "radiation": {"s0_wm2": f, ...},   # параметры K↓ и L* (SH-1/SH-2; имена — в _doc)
  "moisture":  {"m_dry": f, "m_norm": f, "m_wet": f},          # 0 ≤ m_dry < m_norm < m_wet ≤ 1
  "water":     {"c_h": f, "u_min_ms": f, "lag_days": f, "ice_c": 0.0, ...},
  "thermal":   {"h_ref_wm2": f}
}
```
Соответствие строкам П4: none→grassland, forest→trees, grass→grassland, crop→cropland, shrub→shrubland, bare→bare_rock,
water→water, built→built_up, snow→snow_ice. Инварианты: числа классов **равны** строке `p4_row` в
`docs/research/surface_params.csv` (тест сверки); bowen_min ≤ bowen ≤ bowen_max; 0 < albedo < 1; 0 ≤ g_frac ≤ 1; z0_m > 0.
Каждое число вне П4 — с источником или пометкой EST в `_doc`. Запаздывание прогрева по классам остаётся в
`configs/weather_model.json → heating.lag_h` (`SurfaceHeating`), не дублируется.

## SH2 v2 — ядро `SurfaceHeat` (`scripts/atmosphere/surface_heat.gd`, `class_name SurfaceHeat`)
Владелец: SH-2. Потребители: SH-4 (`AirPlace`, `AirWindowCase`), SH-5 (`Terrain`), SH-3/SH-7 (замер).
Обязательные статические функции (имена и порядок аргументов фиксированы; дополнительные — можно):
```
static func config() -> Dictionary                                  # SH1, кэш
static func shortwave(cos_inc: float, sin_el: float, cover: float, sky_heat: float, cfg: Dictionary) -> float
    # K↓ на поверхность, Вт/м²: прямая ∝ max(cos_inc, 0), рассеянная ∝ max(sin_el, 0); sin_el ≤ 0 → 0.
    # cos_inc — скалярное произведение нормали на направление НА солнце; нормаль (−∂h/∂x, −∂h/∂y, 1) без нормировки →
    # поток на горизонтальную площадь (решатель), единичная нормаль → на площадь склона (точка).
static func bowen(cls: int, m: float, cfg: Dictionary) -> float     # β по влажности рельефа m ∈ [0, 1] (план §1.4)
static func land_flux(cls: int, k_down: float, cover: float, m: float, cfg: Dictionary) -> float
    # H = (Rn − G)·β/(1+β), Rn = (1−α)·k_down − L*(cover), G = g_frac·Rn. cls = WATER — ошибка (push_error, вернуть 0).
static func water_temp_c(month: int, day: int, z_m: float, ctx: Dictionary, wcfg: Dictionary) -> float
    # max(0, T̄_air(дата − lag_days, высота z_m)); T̄_air — средняя суточная из WeatherModel (typical_max_c, суточная амплитуда)
static func air_temp_c(hour: float, t_max: float, z_m: float, ctx: Dictionary, wcfg: Dictionary) -> float
    # температура воздуха у поверхности на высоте z_m (WeatherModel.diurnal_state + поправка на высоту)
static func water_flux(t_water_c: float, t_air_c: float, u_ms: float, cfg: Dictionary) -> float
    # ρ·c_p·C_H·max(u, u_min)·(T_w − T_a)
static func mix_flux(fracs: PackedFloat32Array, off: int, normal: Vector3, class_sun: PackedVector3Array,
                     m: float, sky: Dictionary, water: Dictionary, cfg: Dictionary) -> float
    # H клетки/точки: Σ_c f_c·H_c, fracs[off + c], c < CLASS_COUNT (сумма 0 → весь вес NONE; иначе нормируется);
    # class_sun[c] — единичный вектор НА солнце для класса c на hour − lag_h[c] (SurfaceHeating.directions), нулевой — солнце
    # под горизонтом (K↓ = 0); sky = {cover, sky_heat}; water = {t_water_c, t_air_c, u_ms} (пусто → H воды = 0).
    # T_water ≤ ice_c → доля воды считается классом SNOW (лёд, солнце класса SNOW).
```
Оси: мир игры x — восток, z — юг (Godot), y — вверх; `class_sun` в тех же осях, что `SurfaceHeating.directions`.
Вызывающий решатель переводит градиент своей сетки в нормаль в этих осях сам.
v2 (добавочно, SH-9): `water` в `mix_flux` может содержать `z_m` (высота воды, м; нет — 0) → ρ воздуха по высоте в `water_flux(t_water_c, t_air_c, u_ms, cfg, z_m := 0.0)`; `shortwave` — облачность только через `cover` (Stull), `sky_heat` не используется (аргумент оставлен).
Инварианты (юнит-тесты): H не убывает по cos_inc; при Rn − G > 0 H не возрастает по m; bowen(c, m_norm) = bowen,
bowen ∈ [bowen_min, bowen_max], bowen(c, ≤ m_dry) = bowen_max, bowen(c, ≥ m_wet) = bowen_min; солнце под горизонтом → H < 0
для суши (−L*·…); знак water_flux = знак (T_w − T_a); T_w ≥ 0; одинаковые входы → одинаковый результат (побитно).

## SH3 v1 — вход решателя по клеткам (`AirPlace`)
Владелец: SH-4. Потребители: `AirPicardJob`, `AirWindowCase`, `AirPhase` (через `AirCase.heat`/`heat_used`), `WindField`
(`meta.heat`), `AirThermals` (`heat_flux()`), SH-6.
- `AirCase.heat`: PackedFloat64Array ny·nx, j·nx + i (как сейчас), Вт/м² на горизонтальную площадь, = `SurfaceHeat.mix_flux`
  по клетке. Единицы и раскладка `AirCase.heat`, `meta.heat` (C3), `heat_flux()` (C4) **не меняются**.
- Доли классов клетки — по тем же узлам 25 м, что `block_mean` (f×f узлов на клетку): класс узла — как `Terrain._surface_class`
  (карта поверхности + маска 10 м: вода G ≥ 0,5, лес R ≥ 0,5; круче `rock_slope_deg` → BARE). Доля воды = доля узлов,
  где вода по карте/маске 10 м **или** по маске рек (`detail_water.png`).
- Влажность клетки — среднее `TerrainRelief.moisture` по узлам клетки; поля нет → m_norm. Решение строится только после
  готовности полей рельефа (детерминизм: две сборки одного случая — побитно одинаковое `heat`).
- Вода клетки: t_water_c = `SurfaceHeat.water_temp_c` (дата места, высота клетки hc), t_air_c = `SurfaceHeat.air_temp_c`
  (час случая, высота hc), u_ms = u10 случая.
- Состав `place` (`AirRuntime.place_of`) и сигнатура `AirPlace.domain_case` меняются → **C2 v7 → v8** в
  `docs/contracts/air-model.md` (поля place, источники долей/влажности/воды; убрать «вода → H = 0», «H0 = 330»), правка
  словаря `CONTRACTS` в `tests/contracts/test_air_contracts.gd` — в той же задаче. P10 (фазы) и C3/C4 — без смены версии
  (смысл и формат H прежние).

## SH4 v1 — сила источника термиков масштаба 2 (`Terrain`)
Владелец: SH-5. Потребители: `GroundField.sun_fn` (`Atmosphere.set_ground`), `AtmoDay.source_fn`, `ThermalField._source_at`,
`AirThermals.pick_in_column`.
- Сигнатуры без изменений: `thermal_source_strength_at(x, z) -> float`, `thermal_source_strength_for(x, z, class_sun, to_sun) -> float`, 0..1.
- s = clamp(max(H, 0)/h_ref_wm2 · (1 + edge_boost·близость к границе), 0, 1); H = `SurfaceHeat.mix_flux` для одного класса
  точки (`_surface_class`), единичная нормаль, класс-солнце из `class_sun` (нет — `to_sun`), m = `moisture_at`, sky =
  {cover 0, sky_heat 1} (ясно: облака/тени учитывает `ThermalField`), вода — контекст `Terrain.set_water_heat(t_water_c, t_air_c, u_ms)`
  (не задан — H воды 0 → s = 0).
- Из `configs/world.json → surface.thermal` удаляются `class_strength`, `exposure_gain`, `exposure_power`, `wet_k`, `wet_from`;
  `edge_*` остаются. Порог `thermal.sun_min` и показатели в `atmosphere.json` — по смыслу «доля H_ref», числа не подбирать.
- Инварианты (тесты): на ровном при одном солнце порядок s по классам = порядок H из SH2; к солнцу > ровно > от солнца;
  сырая ложбина < сухой гребень при прочих равных; вода днём (T_w < T_a) → 0; граница классов усиливает.

## SH5 v1 — замер «до/после» (`tools/research/surface_heat/`)
Владелец: SH-3. Потребители: SH-7, SH-8, отчёт главной сессии.
- Запуск: один скрипт, места и часы в аргументах; вывод `tools/research/surface_heat/out/<метка>/<место>_h<час>.json` и сводка
  `tools/research/surface_heat/out/<метка>/summary.csv` (небольшие, коммитятся — «до» переживает удаление копии) (строка на место×час); сравнение двух меток — `compare` → таблица markdown.
- Поля JSON (обязательные): `location, hour, commit, h_wm2{mean,p10,p50,p90}, h_by_class{<имя>:{area_frac,mean}}`,
  `sources{n, density_km2, strength_ms{mean,p10,p90}}` (AirThermals по полю), `ceiling_agl_m{p10,p50,p90}`,
  `slope_lift[{start, w_ms}]` (подъём у стартов, поле), `lee[{site, w_min_ms, sigma_w_ms}]`, `water{area_frac, t_water_c, t_air_c, h_mean_wm2}`.
- Работает и на коде до изменений (ветка модуля до SH-4/SH-5) — отсутствующие поля (вода) пишутся null.
