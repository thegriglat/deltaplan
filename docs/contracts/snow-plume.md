---
type: "contract"
status: "active"
module: "snow-plume"
area: "world"
updated: "2026-10-23"
summary: "Стыки snow-plume: порог срыва снега (К1), снег на CPU (К2), модель → список источников → отрисовка (К3), конфиг и бюджет кадра (К4)."
related: ["docs/plan/snow-plume.md"]
contracts: []
---
# Контракты модуля snow-plume

Мировые оси игры: X — восток, −Z — север, Y — метры над уровнем моря; начало X/Z — центр места. Скорости — м/с в мировых осях. Файлы модуля — `scripts/world/snow_plume/`, настройки — `configs/snow_plume.json` (`Config.get_config("snow_plume")`).

## SNW-К1 v1. Порог срыва снега и сила шлейфа
Владелец чисел — SNW-1 (`docs/research/snow_plume.md`, источник у каждого числа); код — SNW-2; числа в конфиг — SNW-4.
- `static func SnowPlumeModel.threshold_u10(t_c: float, cfg: Dictionary) -> float` — порог скорости ветра на 10 м над снегом, м/с, при температуре воздуха `t_c` °C. Форма: `a + b·t_c + c·t_c²` для сухого снега (`t_c ≤ wet_t_c`); при `t_c > wet_t_c` — `wet_u10_ms`. Ключи `cfg.threshold.{a, b, c, wet_t_c, wet_u10_ms}`.
- `static func SnowPlumeModel.intensity(u10: float, u_t: float, cfg: Dictionary) -> float` = `clamp((u10 − u_t) / cfg.span_ms, 0, 1)`; 0 при `u10 ≤ u_t`.
- От SNW-1 также: `render.settle_ms` (скорость оседания частиц в шлейфе, м/с), `render.spread_ms` (скорость роста поперечника шлейфа, м/с), `model.path_points × model.path_dt_s` (время жизни видимого шлейфа, с; с v3 — короткие струйки, К4 v3), `model.lee_slope_deg` и `model.fetch_m` (геометрия гребня, где поток отрывается и снег набирается) — с источниками или пометкой «оценка» и обоснованием.
- Если литература даёт другую форму порога — SNW-1 сообщает `contract:`, координатор меняет версию.

## SNW-К2 v2. Снег на CPU
Владелец — SNW-2; потребитель — SNW-4 (как `snow_fn` модели).
- `class_name SnowCover` (`scripts/world/snow_plume/snow_cover.gd`), `static func snow_fraction(terrain: Terrain, x: float, z: float) -> float` — доля снега 0..1 в точке, CPU-зеркало шейдера рельефа без шума:
  - A: `terrain.surface_at(x, z) == SurfaceLayer.SNOW`, или `== BARE` и `terrain.height_at(x, z) > terrain._look.gully_snow_line_m` (при `terrain._look.snow_bare_merge > 0`); множитель крутизны `1 − smoothstep(snow_slope_deg.x, snow_slope_deg.y, slope)` (уклон из `terrain.normal_at`). Сдувание с гребня (`snow_ridge_blow`) не учитывать: это следствие переноса, источник — снег наветренного склона.
  - C: свежий снег `SeasonLook`: `f = smoothstep(line, line + snow_fresh_band_m, h)`, `line = SeasonLook.snow_line(terrain.flight_doy, terrain.center_lat, terrain.scene_look_params())`, множитель `1 − smoothstep(snow_fresh_slope.x, .y, slope)`; при `scene_look.snow_enabled == false` C = 0.
  - Итог `max(A, C)`. Снег в ложбинах (gully) не источник.
- Только чтение, без побочных эффектов; вне рельефа (точка вне `terrain.detail_bounds()`) — 0; кэш производных величин (линия снега и т. п.) сбрасывается при смене даты, широты, `scene_look.snow_enabled` или `_look` (v2).

## SNW-К3 v3. Модель → список источников → отрисовка
Владелец — SNW-2 (модель); потребители — SNW-3 (отрисовка), SNW-4. Контрактные тесты — `tests/contracts/test_snow_plume_k3_model.gd` (SNW-2), `tests/contracts/test_snow_plume_k3_render.gd` (SNW-3).

**Модель** `class_name SnowPlumeModel extends RefCounted` (`scripts/world/snow_plume/snow_plume_model.gd`):
- `func _init(cfg: Dictionary, height_fn: Callable, snow_fn: Callable, wind_fn: Callable, temp_fn: Callable)`; `cfg` — раздел `model` конфига (недостающие ключи — значения по умолчанию К4).
  - `height_fn(x: float, z: float) -> float` — высота рельефа, м; `snow_fn(x: float, z: float) -> float` — К2; `wind_fn(pos: Vector3) -> Vector3` — средний ветер (`Atmosphere.mean_wind_at`); `temp_fn(z_m: float) -> float` — температура воздуха на высоте, °C.
- `func update(cam: Vector3, dt: float) -> Array` — вызывать каждый кадр в главном потоке; список обновляется не чаще `update_s`, между обновлениями возвращается тот же список. Поиск гребней — в рассрочку (≤ `scan_points_per_frame` вызовов `height_fn`/`snow_fn` за кадр) или в рабочем потоке (там — только `height_fn`/`snow_fn`, если они чистые; `wind_fn`/`temp_fn` — только в главном потоке).
- `func wind_calls_last() -> int` — вызовов `wind_fn` в последнем обновлении списка.
- Гребень для направления ветра `d` (горизонтальный единичный): подъём наветренного склона и спад подветренного на `fetch_m` по `d`, спад не круче/положе `lee_slope_deg` по К1; точки гребня не ближе `spacing_m` друг к другу. Снег гребня — среднее `snow_fn` по наветренному отрезку `fetch_m`; источник — только при `snow ≥ snow_min`.
- Ветер гребня — `wind_fn(pos + (0, 10, 0))`, `u10` — его горизонтальная длина; порог `threshold_u10(temp_fn(pos.y), cfg)` (К1). Источник отбрасывается, если местный ветер повёрнут от направления скана больше чем на `dir_tolerance_k · rescan_dir_deg` (v2).
- Линия тока: `path[0] = pos + (0, start_agl_m, 0)`, `path[i+1] = path[i] + vel[i]·path_dt_s` (или точнее, RK2), `vel[i] = wind_fn(path[i])`; после шага y поднимается до `height_fn + min_agl_m`, если ниже.

**Источник** — `Dictionary` с ключами (типы точно такие):
`id: int` (одинаков для той же клетки гребня между обновлениями), `pos: Vector3` (точка гребня, y = `height_fn`), `dir: Vector3` (горизонтальный единичный по ветру), `u10: float`, `u_t: float`, `intensity: float` (0..1), `snow: float` (0..1), `width_m: float` (= `spacing_m`), `path: PackedVector3Array` (`path_points` точек), `vel: PackedVector3Array` (столько же), `path_dt: float` (с), `surf: PackedVector3Array` (v3: 2…8 точек рельефа, где рождаются струйки — вдоль гребня в пределах ±`width_m`/2 и на наветренном склоне до `surf_upwind_m` от гребня; y = `height_fn`).

**Инварианты списка:** размер ≤ `max_emitters`; по возрастанию горизонтального расстояния до камеры; все в пределах `radius_m`; у каждого `intensity > 0`, `u10 > u_t`, `snow ≥ snow_min`; `path[i].y ≥ height_fn(path[i].x, path[i].z) + min_agl_m − 0.01`; `surf[j].y = height_fn(surf[j].x, surf[j].z)` (±0,01 м), `surf[j]` не дальше `width_m`/2 + `surf_upwind_m` от `pos` по горизонтали; `wind_calls_last() ≤ max_wind_samples`; ветер ниже порога или нет снега — пустой список.

**Отрисовка** `class_name SnowPlumeRender extends Node3D` (`scripts/world/snow_plume/snow_plume_render.gd`):
- `func _init(cfg: Dictionary = {})` — раздел `render` конфига (недостающие — по умолчанию К4); `func set_emitters(list: Array) -> void` — источники К3; `func active_count() -> int` — видимых излучателей.
- Пул из `max_emitters` излучателей создаётся один раз; лишние источники отбрасываются; излучатель переназначается по `id` без перезапуска, если `id` остался. Пустой список — `active_count() == 0`.
- **Вид (v3, решение пользователя 2026-10-23): короткие полупрозрачные струйки мелкой снежной пыли, не облачные клубы.** Частица — вытянутый вдоль местной скорости полупрозрачный штрих длиной `streak_len_m` (3–4 м) и шириной `streak_w_m`; рождается в случайной точке `surf` (± разброс между точками) на высоте 0…`layer_h_m` над рельефом (позёмка — ниже 2 м, ВМО), живёт `life_s`, движется со скоростью `vel` (интерполяция по `path`, т. е. у гребня — местный ветер, за гребнем — вниз/вверх по линии тока) с оседанием `settle_ms` и разлётом `spread_ms`; плавное появление и исчезание. Число частиц и прозрачность ∝ `intensity`; издалека струйки почти не видны — это нормально (`visibility_m`).

## SNW-К4 v3. Конфиг и бюджет
Владелец — SNW-2 (`model`), SNW-3 (`render`, читает с умолчаниями), SNW-4 (файл `configs/snow_plume.json` целиком, числа SNW-1). У каждого ключа — `<ключ>_doc` (смысл, единицы, источник).
- `enabled` (bool, true).
- `model` (v3 — струйки видны вблизи): `radius_m` 1500, `max_emitters` 32, `update_s` 0.5, `max_wind_samples` 140, `scan_step_m` 50, `scan_points_per_frame` 1000, `dir_tolerance_k` 2, `rescan_m` 1000, `rescan_dir_deg` 10, `fetch_m` (К1), `lee_slope_deg` (К1), `spacing_m` 40, `surf_upwind_m` 30, `snow_min` 0.5, `start_agl_m` 1, `min_agl_m` 1 (`start_agl_m ≥ min_agl_m`), `path_points` 3 (≤ 8), `path_dt_s` 1, `span_ms` (К1), `threshold` {`a`,`b`,`c`,`wet_t_c`,`wet_u10_ms`} (К1).
- `render` (v3): `max_emitters` = `model.max_emitters`, `particles_per_emitter` 48, `streak_len_m` 3.5 (решение пользователя 2026-10-23: 3–4 м), `streak_w_m` 0.25 (оценка), `layer_h_m` 2 (ВМО: позёмка — снег, поднятый ниже 2 м), `life_s` 2 (оценка), `settle_ms` (К1), `spread_ms` (К1), `alpha` 0.25 (оценка), `visibility_m` 1500. Ключа `size_m` нет. «Оценка» — подбор по кадрам, не больше 2 попыток.
- Числа без источника до SNW-1 — только в тестах и как умолчания в коде; в конфиг (SNW-4) — числа SNW-1.
- **Бюджет кадра** (замер SNW-5, Эверест, сильный ветер, пресет high, против `enabled: false`): GPU — прирост среднего ≤ 0,5 мс; CPU кадра — прирост среднего ≤ 0,3 мс; худший 1 % — прирост ≤ 2 мс.
- Headless узел не создаётся; сеть не нужна (визуал локальный, одинаково в одиночной и сетевой игре).

## История версий
- v3 (2026-10-23, решение пользователя по кадрам SNW-5: «похоже на горизонтальные облака»): К3 — новый ключ источника `surf`, вид отрисовки — короткие полупрозрачные струйки 3–4 м у поверхности и над гребнем по ветру; К4 — модель ближе и гуще (`radius_m` 1500, `spacing_m` 40, `max_emitters` 32, `path_points` 3 × `path_dt_s` 1, `start/min_agl_m` 1, `surf_upwind_m`), render — ключи струек вместо `size_m`. Владельцы — SNW-7 (модель и отрисовка), потребитель — SNW-8.
- v2 (2026-10-23, ревью SNW-2): К2 — «вне рельефа» = вне `detail_bounds()`, сброс кэша; К3 — отсечка `dir_tolerance_k`; К4 — `scan_points_per_frame` 1000 (кадр скана ≤ 2,5 мс в отладке против 19,6 мс при 4000), `max_wind_samples` 200 (24 источника × 7 вызовов + проверки), `start_agl_m` = `min_agl_m` = 3, ключ `dir_tolerance_k`. Потребитель — SNW-4.
- v1 (2026-10-23): первая версия.
