---
type: "contract"
status: "closed"
module: "air-model"
area: "air"
updated: "2026-10-15"
summary: "Модель воздуха, стыки C4–C8: WindField/AirFieldSet → атмосфера, термики, сеть, часы старта, клипмапы, пересчёт."
related: ["docs/contracts/air-model.md"]
contracts: [{"id": "C4", "version": 4}, {"id": "C5", "version": 1}, {"id": "C6", "version": 1}, {"id": "C7", "version": 4}, {"id": "C8", "version": 2}]
---

# Модель воздуха: C4–C8: WindField и его потребители

Стыки C4–C8. Вход (правила изменения, общие соглашения, список стыков и частей) — [air-model.md](../air-model.md).

## C4 v4 — `WindField` / `AirFieldSet` → атмосфера, термики, возмущения, визуал
**Владелец:** AM-05 (`air_field_set.gd`, ветка поля в `atmosphere.gd`). **Потребители:** AM-07,
AM-08, AM-10, физика крыла/боты/птицы (через атмосферу).

**`WindField` (один уровень):**
| Функция | Возврат |
|---|---|
| `sample(pos, ground_h = NAN) -> Vector3` | мир (u, w_mech, −v), м/с; вне поля — ближайший край |
| `sample_theta(pos, ground_h) -> float` | θ′, К (у земли — первая воздушная клетка) |
| `sample_w_conv(pos, ground_h) -> float` | м/с, **пилоту напрямую не отдаётся** |
| `contains(pos) -> bool`, `edge_weight(pos) -> float` | 1 внутри, smoothstep к 0 в полосе `edge_cells` у боков и под верхом, 0 снаружи |
| `ground_height(x, z)`, `center_xz()`, `size_x()` | рельеф сетки, мир |
| поля `dx, dz, x0, y0, z_bot, nx, ny, nz, z0, edge_cells, meta, limits` | только чтение для потребителей |
| `raw_vel()`, `raw_w_conv()`, `raw_theta()` | сырые массивы клеток (раскладка без ореола; `raw_vel` — u, v, w_mech подряд по 3), только чтение |
| `raw_hc()`, `raw_k1()` | рельеф сетки по столбцам (м), первая воздушная клетка столбца (nz — в земле) |
| `heat_flux()`, `z_i()`, `gam()`, `u10()` | вход решения из `meta` (C3): H ny·nx Вт/м² (или массив `heat` файла; пусто — нет), z_i м над морем (NAN — нет), dθ̄/dz nz К/м, U10 м/с |
| `turb_at(pos, ground_h = NAN) -> PackedFloat32Array` (C4 v3, AM-08) | `T_SIZE` = 8 чисел, индексы `T_*`: `T_SHEAR` \|∂U_h/∂z\| в точке, 1/с (ниже центра 1-й клетки — производная лог-профиля); `T_N2` = g/θ0·(dθ̄/dz + ∂θ′/∂z), 1/с² (NAN — нет `meta.gam`); по столбцам (билинейно): `T_USTAR` u* = κ\|U_r\|/ln(a_r/z0) (r — 1-я воздушная клетка с центром ≥ dz/2 над hc), `T_UOUT` наибольшая \|U_h\| в слое `A_OUT` = 600 м над hc и `T_AOUT` — её высота над hc, `T_DESC` = max(0, −min w_mech)/U_out в том же слое, `T_WSTAR` w* (H сглажен квадратом 1500 м), `T_HMIX` = max(z_i − hc, 300) м (0 — нет heat/z_i) |
| `static deardorff_wstar(H, z_i, hc) -> float` | w* = (g/θ0·H/(ρc_p)·max(z_i − hc, 300))^(1/3), м/с — **одна формула** для термиков (AM-07) и болтанки (AM-08) |

Выборка у земли: столбец c читается на высоте `y + (hc_c − h)·exp(−agl/dx)` (h — настоящая
земля, `ground_h`); ниже центра первой воздушной клетки — лог-профиль к 0 на z0.

**`AirFieldSet`:** `levels: Array[WindField]` **от мелкого к грубому**; `sample(pos, ground_h) ->
Vector4` (xyz — Σ вклад уровней в мире, w — доля поля 0..1; итог = xyz + (1 − w)·аналитика);
`sample_theta`, `sample_w_conv -> Vector2(вклад, доля)`; `contains`, `is_active`,
`blend_fraction`, `advance(dt)`, `set_field` (C8). Нет уровней — `Vector4.ZERO`.
`sample_dx(pos, ground_h) -> float` (C4 v4, AM-08в) — размер клетки уровней в точке, м: среднее `dx`
уровней с теми же весами, что в `sample` (по текущему набору, без снимка подмены), нормированное на
долю; вне поля / нет уровней — 0.

**`Atmosphere`:** `set_air_field(поле | [уровни] | null, blend_s = −1)`, `set_air_mode("auto" |
"on" | "off")`, `is_air_field_on()`, `air_field: AirFieldSet` (есть после `configure`).
Правило стыка 1↔2 (`docs/guide/air-model.md` → «Стык с атмосферой»):
- `air_velocity_at`: горизонталь = поле + (1 − w)·аналитика; `w_mech` **вместо** `w_ridge`
  (край — доля); w_conv — только через термики (AM-07: пузыри + «между» в `ThermalField.sample`);
  грозы, волны, облака — как в аналитике; подветренная эвристика и болтанка — по полю (C4 v3,
  «Возмущения AM-08» ниже).
- `mean_wind_at`: горизонталь поля + w_mech, без эвристики и шума; без поля — (dir·s, **0**).
- Поле выключено / нет поля / вне поля — **побитно** аналитика; `AtmoFingerprint` — поле `off`.

**Термики AM-07** (`ThermalField.air = AirFieldSet` при `is_air_field_on`, `AirThermals.build(f,
cfg, forced)`): берут **грубейший** уровень `levels[-1]`; вход — `meta.heat | heat_array` или
массив `heat` в `.bin`, `meta.z_i`, `meta.gam` (nz), `meta.u10` — через геттеры выше
(`AirThermals.has_inputs`: heat, z_i и gam длиной nz); нет — источников нет (термики — аналитика).
Каналы — через `raw_*()` (C4 v2, Р5 закрыт).

**Возмущения AM-08 (C4 v3):** `AirFieldSet.sample_turb(pos, ground_h) -> PackedFloat32Array`
(`T_SIZE + 1`): величины `turb_at`, усреднённые по уровням с весами края (**не** умножены на долю),
последнее — доля поля 0..1; в подмене — смесь старого и нового по долям. `load_file` кладёт массив
`heat` из `.bin` в `meta.heat` (читает `heat_flux`). Правило стыка в `air_velocity_at` при доле
поля a > 0 (`docs/guide/air-model.md` → «Масштаб 3: возмущения из поля»):
- горизонталь поля — **без** подветренного ослабления, w_mech — **без** множителя (1 − lee) и без
  эвристического опускания за гребнем; линия тени 12° и её опускание/ослабление — только в
  аналитической доле (1 − a);
- зона отрыва — признак из поля lee_f (дефицит скорости против лог-профиля под U_out × опускание
  столба, `lee.field_*`, без изменений). **C4 v4 (AM-08в):** скачок слоя смешения
  ΔU = max(U_H − \|U\|, 0)·lee_f, U_H — \|U_h\| поля в той же вертикали на высоте гребня
  h + max(r, agl) (r — `GroundField.relief_at`, превышение гребня против ветра); в зоне эвристика даёт:
  болтанку слоя смешения σ_u = 0,18·ΔU, σ_w = 0,14·ΔU; рывки вниз `lee.field_burst_per_du`·ΔU·опасность
  **с нулевым средним** и **только при `turbulence_enabled`** (это часть пульсаций: с выключенной
  болтанкой в зоне отрыва w = w поля); обратный поток у земли
  `lee.field_reverse_per_uh`·U_H·lee_f·опасность·e^(−agl/(0,4r))·(1 − res), где
  res = smoothstep(n0, n1, `lee.field_bubble_length_per_relief`·r / `sample_dx`) (n0, n1 —
  `lee.field_resolved_cells`) — эвристика только там, где пузырь решателем не разрешён;
- болтанка: σ по u* и местному сдвигу (Ri — как замыкание решателя), по w* (Lenschow), шум —
  `GustSpectrum` (фон Карман, масштабы MIL-HDBK-1797 от высоты, σ_w/N, высоты гребня);
  конфиг `turbulence.field_*`, `lee.field_*` (с `_doc`);
- без поля / вне поля / `off` — **побитно** прежняя аналитика; `mean_wind_at` не менялся.

**Трава/вода/F3 AM-10:** `TerrainWind` берёт `field_src.air_field.sample(Vector3(x, g + 10, z), g)`
(duck typing, `is_air_field_on`) → текстура RGF: **R = мир x (u), G = мир z (−v)**, `field_wind_origin`
— мир (x, z) угла, `field_wind_size_m`, 0 — без поля; порывистость — `air_velocity_at − mean_wind_at`.
F3 (`wind_field_debug.gd`) и `dump_slices.gd` — `air_velocity_at` / `WindField.load_file`.

**Конфиг** `configs/atmosphere.json → air_model`: `enabled` (auto/on/off), `edge_blend_cells` (5),
`blend_s` (60), `recompute_game_min` (15), `max_speed_ms` (40), `max_w_ms` (10), у каждого `_doc`.
- **Тесты:** `test_c4_field_set_vector4`, `test_c4_atmosphere_api_and_analytic`,
  `test_c4_atmosphere_field_rule`, `test_c4_config_keys`, `test_c4_turb_at`, `test_c4_sample_dx`,
  `test_c4_lee_keys` (v4).
- **Ключи `lee` (v4):** `field_burst_per_du` (0,42 = 3·σ_w/ΔU), `field_reverse_per_uh` (0,22, Menke 2019;
  заменяет `field_reverse_per_wind`), `field_bubble_length_per_relief` (2,8, Menke 2019 L/H),
  `field_resolved_cells` ([4, 8]), у каждого `_doc`. Аналитические ключи `lee` не меняются.

## C5 v1 — источники термиков → сеть (AM-07)
**Владелец:** AM-07. **Потребители:** сеть (`net_zone.gd`, `net_flight.gd`, сервер Go), AM-11.

- `server/proto/deltaplan/v1/net.proto`: `ZoneState.thermal_sources = 3` → `message ThermalSources
  { string grid = 1; bytes mask = 2; }` (аддитивно). GDScript-схема `NetMessages.MESSAGES`:
  `ZoneState.thermalSources = "msg:ThermalSources"`, `ThermalSources = {grid: string, mask:
  string}` (base64), `NULLABLE["ZoneState.thermalSources"]`.
- `grid` = `AirThermals.signature(f)` = `"%.3f,%.3f,%.3f,%d,%d" % [dx, x0, y0, nx, ny]` уровня.
- `mask` — бит на столбец, номер `j·nx + i` (i — восток от x0, j — север от y0), младший бит
  байта — первый, `(nx·ny + 7) >> 3` байт; в JSON — base64. Только **позиции**; сила, потолок,
  снос — каждый клиент по своему полю.
- Шлёт ведущий с каждым `ZoneState` (1 Гц); нет поля — ключа нет (каждый выбирает сам); другая
  сетка (`grid` ≠ своя подпись) — не применять. Не-ведущий: `ThermalField.set_air_forced(sig, mask)`.
- **Тесты:** `test_c5_signature_and_mask`, `test_c5_net_schema`.

## C6 v1 — часы старта и файл поля (библиотеки нет)
**Владелец:** AM-06 (часы — часть А, готово; файл поля — AM-05). **Потребители:** AM-06Б, AM-04, AM-11, инструменты.

- **Часы старта:** `configs/world.json → time.start_hours` = [9, 12, 15, 20];
  `SunClock.start_hours() -> PackedFloat32Array`, `SunClock.nearest_start_hour(h)`.
- **Файл поля** (`WindField.load_file`, отладка `--air-field=`, фикстуры `field/`, `thermals/`): `.json` —
  `format = "deltaplan-air-field"`, `version = 1`, `dx, dz, x0, y0, z_bot, nx, ny, nz, z0,
  layout, source, cond, arrays` (+ для термиков `z_i, gam (nz), u10, wdir`, массивы `heat`,
  `h_bl`); `.bin` — float32 LE; каналы `u, v, w_mech, w_conv, theta` (nx·ny·nz) и `hc` (nx·ny).
  Файл — только для отладки и тестов; в игре поле считается при загрузке (C3).
- **Библиотеки полей нет** (решение пользователя на шлюзе AM-01): `data/air/`, `user://air/`
  не создаются; AM-06б снята.
- **Тесты:** `test_c6_start_hours` (часы), формат файла — `test_c3_game_field_files`,
  версия — `test_c6_field_version`.

## C7 v4 — клипмапы AM-04 → `WindField` / `AirFieldSet`
**Владелец:** AM-04 (`air_clipmap.gd`, `air_window_job.gd`, `air_window_case.gd`, `air_window.glsl`).
**Потребители:** C4 (выборка), AM-06Б (`AirRuntime`: загрузка, пересчёт, сдвиг), AM-07 (термики).

**Уровни.** `AirFieldSet.levels` = `[окно 50 м, окно 100 м, область 400 м]` — **от мелкого к
грубому**, каждый — свой `WindField` (C3) со своими dx/dz/x0/y0; у окон `meta.level = "window"`.
Выборка (C4): мелкий с весом края w₁, остаток (1 − w₁) — следующему, …, непокрытое — аналитике;
край — `edge_blend_cells` клеток **своего** уровня (окно 50 м — 250 м, 100 м — 500 м, область —
2 км). `sample_turb` (C4 v3) усредняет уровни с теми же весами. **Термики (Р10, решение К0)** —
по грубейшему уровню `levels[-1]` = область: подпись сетки (C5) при сдвиге окон не меняется.

**Сетка окна** (как `real.grid_window` эталона): 64 × 64 столбца, dx из
`air_model.window_levels_m` (100, 50), dz = dx/2; угол x0, y0 кратен 25 м (сдвиг — кратно dx);
z_bot = ⌊h_min/dz⌋·dz − dz, верх — h_max + 2000 м, nz чётное. Вход погоды и солнца — как у области
(C2). Граница — от родителя (область для окна 100 м, окно 100 м для окна 50 м): поле родителя в
центрах клеток трилинейно во все граничные грани и θ′ ореола, поправка потока Σ = 0, зона
релаксации 4 клетки у боков и 1000 м у потолка (reference.md → «Граничные условия области»);
решение без нагрева (w_mech) — от решения родителя **без нагрева**.

**API.**
- `AirPicardJob.parent_data() -> {grid, tc, heat: {u, v, w, th, thd}, mech: {…}}` (грани с ореолом; v2: `thd` —
  θ′_d, у решения без нагрева нули; нет ключа — нули),
  `state(mech := false)`, `grid()`; решения с нагревом и без хранятся оба (пара).
- `AirWindowCase.window_case(detail, water, loc, dx, cx, cy, hour, u10, wdir, t_max, sky, heat,
  ctx, n = 64)` (центр в осях решателя), `window_at(…, x0, y0, …)`; `prepare_pair()` — оба
  случая (можно в рабочем потоке); `P_NEST` = 19 в `prm`.
- `AirWindowJob` (наследник `AirPicardJob`): `case: AirWindowCase`, `parent` (parent_data),
  `prev` (`window_state()` прошлого окна той же клетки — тёплый старт, сдвиг на целое число
  клеток), `shared_gpu` (общий `AirGpu`: `release()` освобождает только свои буферы),
  `window_state() -> {grid, heat, mech}` (v2: с `thd`; сдвиг переносит `thd` как `th`), `nest_corr()`;
  остальное — как C3. Ореол и цель зоны релаксации окна — θ′ **и** θ′_d трилинейно из родителя (v2).
- `AirClipmap`: `setup(detail, water, loc, hour, u10, wdir, t_max, sky)`, `set_conditions(…)`,
  `set_domain(domain_job, domain_field)` (задача области ещё не освобождена; окна, если есть, —
  пересчёт от новой области с тёплого старта), `start(center_xy)`, `update(pilot_pos)` (мир),
  `poll()` (кадр) / `poll_slice(ms)` (экран загрузки), `levels() -> Array[WindField]`,
  `is_ready()`, `is_busy()`, `window_center(q)`, `release()`, `history` (замеры по окнам);
  сигналы `levels_changed(levels: Array[WindField])`, `failed(message)`.

**Порядок и сдвиг.** При загрузке: область (вызывающий) → `set_domain` → `start(старт)` → окна
по очереди 100 → 50 м (входы окон — сразу в рабочих потоках, GPU — одно устройство, порциями).
В полёте: пилот ушёл от центра окна дальше `air_model.window_shift_frac` (0,25) стороны окна по x
или y → это окно и все мельче пересчитываются фоном с новым центром у пилота (угол сдвигается
на целое число клеток), тёплый старт — старое окно (перекрытие) + родитель. До готовности
выборка — старые уровни; **новый набор отдаётся одним `levels_changed`**, когда пересчитаны все
уровни очереди; вызывающий — `Atmosphere.set_air_field(levels, blend_s)` (C8; Р7: не подавать
новый набор во время подмены — держать последний). Ошибка окна — `failed`, уровни прежние,
повтор сдвига не раньше чем через 10 с.

**v3 (01.10.2026, air-start):** `AirClipmap.setup(…, sky, inflow_k = 1.0)`, `set_conditions(…, sky,
inflow_k = 1.0)` — окна строятся с тем же множителем притока, что область (C2 v6); граница окна — от родителя,
как прежде.

**v4 (09.10.2026, surface-heat SH-4, вместе с C2 v8):** хвостовой аргумент `surface` (снимок поверхности места
`AirPlace.Surface`, `place.surface`; null — без карты) у `AirClipmap.setup(…, inflow_k = 1.0, surface = null)`,
`AirWindowCase.window_case(…, ctx, n = 64, inflow_k = 1.0, surface = null)`, `window_at(…, ctx, n, inflow_k, surface = null)`;
H окна — `AirPlace.surface_flux` (SurfaceHeat по долям классов клетки окна), как у области. `AirRuntime` передаёт
`place.surface`. Сетка, уровни, граница, сдвиг — без изменений.

**Конфиг** `air_model`: `window_levels_m` ([100, 50]), `window_shift_frac` (0,25), у каждого `_doc`.
- **Тесты:** `test_c7_levels_fine_to_coarse`, `test_c7_window_grid_and_api` (без GPU);
  GPU — `test_air_window_gpu.gd` (сверка с эталоном, побитно, загрузка и сдвиг клипмапа).

## C8 v2 — фоновый пересчёт / подмена (AM-06Б) → `set_field`
**Владелец:** AM-05 (подмена); вызывающий — AM-06Б (`AirRuntime`, C9), AM-04 (сдвиг окон).

- `Atmosphere.set_air_field(new, blend_s = −1)` → `AirFieldSet.set_field(new, blend_s)`;
  −1 — `air_model.blend_s` (60 с). `new`: `WindField`, `Array[WindField]`, `null`/`[]` (плавно в
  аналитику).
- Время подмены — **время атмосферы** (`Atmosphere.step(dt)` → `advance(dt)`, только при
  включённом поле); доля нового — smoothstep(t / blend_s), монотонно; `blend_s ≤ 0` — сразу.
- **Подмена во время подмены** (v2, Р7): «старым» становится **снимок текущей смеси** —
  взвешенная сумма наборов уровней (старое × (1 − s) + текущее × s на момент вызова), выборка не
  скачет. Наборов в снимке ≤ 3 (`MAX_OLD`), доли < 10⁻³ отбрасываются (остаток перенормируется).
  То же для `sample_theta`, `sample_w_conv`, `sample_turb`.
- Строить `WindField` — в рабочем потоке (O(n) ≈ 0,2–0,4 с на 64 × 64 × 62), `set_field` — в
  главном. Пересчёт каждые `recompute_game_min` = 15 игровых минут и при смене ветра/погоды —
  `AirRuntime` (C9). **Тесты:** `test_c8_blend`, `test_c8_blend_during_blend`.
