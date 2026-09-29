# Модель воздуха: контракты систем

Интерфейсы на стыках задач плана `docs/plan/air_model.md` (AM-00…AM-12). Зафиксировано **то, что
есть в коде** на 29.09.2026 (ветка `feature/air-model`); то, чего ещё нет, помечено «проект».
Контрактные тесты — `tests/contracts/test_air_contracts.gd` (headless, без GPU):
`godot --headless --path . res://tests/run_tests.tscn -- --filter=test_air_contracts`.

## Правило изменения контракта
- Исполнитель работает **в рамках контракта**. Нужен другой интерфейс — только через К0:
  1. правка раздела контракта: версия +1, строка в «Журнале версий» (что изменилось, дата, кто);
  2. уведомление всех задач-потребителей из таблицы раздела;
  3. их правка — в том же шаге или сразу после (до следующей задачи в очереди);
  4. контрактные тесты (`tests/contracts/`) меняются **в том же коммите**, что контракт.
- Версия раздела — в заголовке (`## C3 v1 — …`); тест `test_contract_versions` сверяет их с
  константой в тесте — правка контракта без правки теста (или наоборот) ломает прогон.
- Исправление внутри реализации, не меняющее интерфейс (числа, скорость, внутренняя раскладка
  буферов GPU), контракт не трогает.

## Общие соглашения (действуют во всех разделах)
| Что | Соглашение |
|---|---|
| Мир игры | x — восток, y — вверх (м над морем), z — **юг** (−Z — север); `net.proto` — то же |
| Сетка решателя | i — восток, j — **север** (y_решателя = −Z мира), k — вверх; x0, y0 — западный и южный края внутренней области, z_bot — низ внутренней области (м над морем) |
| Скорость мир ↔ сетка | мир (x, y, z) = (u, w, −v) |
| Раскладка без ореола | (nz, ny, nx), индекс `(k·ny + j)·nx + i`; центр `x0 + (i + ½)dx`, `y0 + (j + ½)dx`, `z_bot + (k + ½)dz` |
| Раскладка с ореолом | (NZ, NY, NX) = (nz + 2, ny + 2, nx + 2), индекс `(k·NY + j)·NX + i`; центр `x0 + (i − ½)dx`, `z_bot + (k − ½)dz` (та же точка, что без ореола при i_без = i − 1) |
| Грани MAC (с ореолом) | `u[k,j,i]` — западная грань клетки i (между i − 1 и i), `v` — южная, `w` — нижняя |
| Столбцы | hc и 2D-массивы — (ny, nx), индекс `j·nx + i` |
| `dims` в JSON | всегда [x, y, z]-размеры (`[NX, NY, NZ]`), хотя индекс идёт k, j, i |
| Маска земли | клетка — земля, если z её центра < hc столбца (ореол: весь слой k = 0 — земля) |
| Ветер «откуда» | `wdir` / `wind_from_deg`, ° от севера по часовой; направление «куда» в сетке (ex, ey) = (−sin, −cos), в мире `WindModel.dir` = (−sin, 0, cos) |
| Единицы | м, с, м/с; θ′ и θ̄ — К; dθ̄/dz (`gam`) — К/м; поток тепла H — Вт/м² на горизонтальную площадь; z_i — м **над морем** |
| Числа на стыке | float32 LE (файлы, буферы GPU); CPU-вход решателя (`AirCase`) — float64 |
| Нечисловые | на входе `WindField` NaN/∞ → 0 |

---

## C1 v1 — эталон AM-01 → GPU AM-03
**Владелец:** AM-01. **Потребители:** AM-02 (блоки), AM-03 (Пикар), AM-09.

- **Дискретизация** — `tools/research/air3d/reference.md` → «Дискретизация (спецификация для
  GPU)» (при расхождении текста с `air.py` прав текст); выбор сетки — там же, «Решение: σ-сетка
  или маска». Изменение схемы = новая версия C1 (пример: cf64b7b, Δτ_u = 0,3 с/м·Δx — см. Р1).
- **Фикстуры** `tests/atmosphere/fixtures/air_model/ref/<случай>.{json,bin}` (случаи `agnesi`,
  `flat_wind`, `heated_slope`, `saddle`), генератор `tools/research/air3d/fixtures.py`:
  - `.bin` — float32 LE, массивы подряд; `.json → arrays: {имя: [смещение, длина]}` в числах
    float32, без дыр, Σ длин · 4 = размер `.bin`. Целые (типы, индексы) — тоже float32.
  - `.json`: `case, dims = [nx+2, ny+2, nz+2], halo = 1, dx, dz, z_bot, x0, y0, nx, ny, nz,
    params` (все `Params`, **включая `dtau_u` — брать из JSON**), `case_params` (U10, wdir, z_i,
    U_aloft), `cd, closure, criterion, solution, history, notes`.
  - Длины массивов: `hc` — nx·ny; поля клеток/граней (`cell`, `tu/tv/tw`, `in_*`, `sol_*`, `mom_*`,
    `proj_*`, `bm_*`, `bh`, …) — N = NX·NY·NZ; шаблоны `Cm_u/v/w`, `Ch` — 7·N (0 центр, 1 −x, 2 +x,
    3 −y, 4 +y, 5 −z, 6 +z); без ореола (`div_star`, `proj_rhs`, `vcycle_phi_raw`, `div_after`) —
    nx·ny·nz; `gam`, `cplz` — NZ.
  - `cell`: 0 земля, 1 воздух, 2 ореол. Порядок блоков одной итерации — `notes` и reference.md →
    «Итерация Пикара»; вход блока — выход предыдущего.
- **Инварианты:** все числа конечны; маска = правило «центр < hc»; `sol_*` — после finalize:
  max|∇·u|·dx/U ≤ 10⁻⁵ (фактически ≤ 3·10⁻⁷).
- **Допуски GPU против эталона:** блоки AM-02 ≤ 10⁻⁵ отн.; решение AM-03 ≤ 10⁻³·|u₀| и
  ≤ 0,05 К (план, AM-03 «Приёмка»); критерий остановки — reference.md → «Критерий остановки».
- Прочие фикстуры: `blocks/` (AM-02, `gpu_block_refs.py`), `picard/` (AM-03, вход Онгудая 400/200 м:
  `hc, H, gam`, пробы и обрезка поля) — формат файлов тот же, наборы массивов — свои у задачи.
- **Тесты:** `test_c1_ref_fixture_format`, `test_c1_ref_mask_rule`, `test_c1_ref_solution_div_free`.

## C2 v2 — вход места `AirPlace` / `AirCase` (AM-03) ← рельеф, погода, солнце
**Владелец:** AM-03. **Потребители:** AM-06Б (загрузка/пересчёт), AM-06б (библиотека), AM-04.

| Вход | Откуда в игре | Формат |
|---|---|---|
| рельеф `hc` | `HeightLayer` detail (узлы 25 м), `AirPlace.block_mean` — блочное среднее по клетке | (ny, nx) float64, м над морем, j — север |
| вода | маска слоя (светлое — вода), `AirPlace.water_fraction` → H = 0 над водой | (ny, nx) доля |
| погода на час | `WeatherModel.diurnal_state`, `reference_context`, типовой t_max (`typical_max_c`), `sky` | → `z_i` (м над морем, NAN — нет конвекции), `gam` (NZ = nz + 2, К/м, в центрах с ореолом) |
| солнце | `SunClock` / `AirPlace.solar_flux` (запаздывание прогрева, косинус к склону, рассеянная 0,10, выхолаживание) | `heat` (ny, nx) Вт/м²; пусто — без нагрева |
| ветер прогноза | игра (`--wind`, `--from`, погода) | `u10` (м/с на 10 м), `wdir` (откуда, °) |
| место | `configs/locations/<место>.json` | `center_lat, center_lon, utc_offset_h, id` |

- `AirPlace.domain_case(detail, water, loc, dx, hour, u10, wdir, t_max = NAN, sky = "clear",
  heat = true) -> AirCase` — квадрат `DOMAIN_L` = 38 400 м вокруг центра мира (x0 = y0 = −19 200),
  dz = 105 м (dx ≥ 200) или dx/2, верх — 3000 м над максимумом рельефа, nz чётное; null — область
  вне слоя.
- `AirCase`: `set_grid(dx, nx, ny, dz, z_bot, nz, x0, y0)`, `hc, gam, z_i, heat, u10, wdir, taper,
  p` (Params эталона; `p.dtau_u = NAN` → `dtau_per_m·dx` — рабочее дерево AM-03, Р1), `prepare()`,
  `zc(k) = z_bot + (k − ½)dz` (с ореолом), `dims() = (nx+2, ny+2, nz+2)`, `without_heat()`,
  `meta()` (→ C3).
- `hour` — местное солнечное время игры (часы, как `SunClock`); часы старта — из
  `SunClock.start_hours()` (C6).
- **Тесты:** `test_c2_air_case_grid` (сетка, zc, dims, `without_heat`); ключи `meta()` — после коммита AM-03 (Р4).

## C3 v1 — выход решателя → `WindField` (AM-05)
**Владелец:** AM-05 (`scripts/atmosphere/air_model/wind_field.gd`). **Поставщики:** AM-03
(`AirPicardJob.field()`), AM-06б (библиотека), `to_game_field.py` (прикидка).
**Потребители:** C4, C5, AM-10.

- Каналы (в центрах клеток, раскладка без ореола, float32):
  `u, v` (восток, север, м/с) — решение **с нагревом**; `w_mech` (м/с) — w решения **того же
  случая без нагрева** (H = 0); `w_conv = w − w_mech` (м/с); `theta` = θ′ решения с нагревом (К);
  `hc` (ny·nx, м над морем) — рельеф сетки.
- Построение:
  - `WindField.from_arrays(meta, u, v, w_mech, w_conv, theta, hc, max_speed = 40, max_w = 10)`;
  - `WindField.from_mac(meta, u, v, w, w_mech_faces, theta, cell, hc)` — грани с ореолом (как
    C1), в центры — среднее двух граней, клетки `cell == 0` → 0;
  - `WindField.load_file(путь)` — `<путь>.json` + `<путь>.bin`, формат C6-файл ниже;
  - null — размеры не сходятся (`push_error`).
- `meta` (Dictionary): **обязательно** `dx, dz, x0, y0, z_bot, nx, ny, nz`; `z0` (0,1 м);
  **для термиков (C4)** — `heat` (ny·nx, Вт/м², как в решении, с гашением у края), `z_i` (м над
  морем; нет — без ключа), `gam` (nz, К/м, без ореола), `u10` (м/с); прочее — `label, wdir, cond,
  source, probes, path` (load_file кладёт `path` без расширения).
- `AirPicardJob` (AM-03): `case`, `mech = true` (сначала то же без нагрева → w_mech), `warm =
  {u, v, w, th, p}` (N с ореолом, та же сетка), `start()`, `poll()`, `finished/failed`,
  `field(max_speed, max_w) -> WindField`, `state()`, `results[]` `{label, status ok|max, iters,
  hist, div_rms, div_max, heated}`, `release()`; локальный RD — только главный поток, порциями.
- **Инварианты:** ∇·u на гранях решателя ≤ округления (finalize); в центрах поле не обязано быть
  бездивергентным. Под землёй — 0. Ограничители: |u_h| ≤ `max_speed_ms` (40), |w_mech|, |w_conv|
  ≤ `max_w_ms` (10); NaN/∞ → 0. Поле для игры — **только** с `mech = true` (Р6).
- **Тесты:** `test_c3_from_arrays_axes_units`, `test_c3_mask_log_profile`,
  `test_c3_sanitize_and_limits`, `test_c3_from_mac_ref`, `test_c3_game_field_files`.

## C4 v2 — `WindField` / `AirFieldSet` → атмосфера, термики, возмущения, визуал
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

Выборка у земли: столбец c читается на высоте `y + (hc_c − h)·exp(−agl/dx)` (h — настоящая
земля, `ground_h`); ниже центра первой воздушной клетки — лог-профиль к 0 на z0.

**`AirFieldSet`:** `levels: Array[WindField]` **от мелкого к грубому**; `sample(pos, ground_h) ->
Vector4` (xyz — Σ вклад уровней в мире, w — доля поля 0..1; итог = xyz + (1 − w)·аналитика);
`sample_theta`, `sample_w_conv -> Vector2(вклад, доля)`; `contains`, `is_active`,
`blend_fraction`, `advance(dt)`, `set_field` (C8). Нет уровней — `Vector4.ZERO`.

**`Atmosphere`:** `set_air_field(поле | [уровни] | null, blend_s = −1)`, `set_air_mode("auto" |
"on" | "off")`, `is_air_field_on()`, `air_field: AirFieldSet` (есть после `configure`).
Правило стыка 1↔2 (`docs/air_model.md` → «Стык с атмосферой»):
- `air_velocity_at`: горизонталь = поле + (1 − w)·аналитика; `w_mech` **вместо** `w_ridge`
  (край — доля); w_conv — только через термики (AM-07: пузыри + «между» в `ThermalField.sample`);
  подветренная эвристика, болтанка, грозы, волны, облака — как в аналитике.
- `mean_wind_at`: горизонталь поля + w_mech, без эвристики и шума; без поля — (dir·s, **0**).
- Поле выключено / нет поля / вне поля — **побитно** аналитика; `AtmoFingerprint` — поле `off`.

**Термики AM-07** (`ThermalField.air = AirFieldSet` при `is_air_field_on`, `AirThermals.build(f,
cfg, forced)`): берут **грубейший** уровень `levels[-1]`; вход — `meta.heat | heat_array` или
массив `heat` в `.bin`, `meta.z_i`, `meta.gam` (nz), `meta.u10` — через геттеры выше
(`AirThermals.has_inputs`: heat, z_i и gam длиной nz); нет — источников нет (термики — аналитика).
Каналы — через `raw_*()` (C4 v2, Р5 закрыт).

**Возмущения AM-08 — проект:** понадобятся u* (из сдвига поля у земли: |u_h| первой воздушной
клетки и её высота над hc + z0 → κ|u|/ln(a/z0)), сдвиг |∂u_h/∂z| по столбцу, признак отрыва/зоны
тени (опускание w_mech < 0 и сдвиг за бровкой), w* и z_i (из AM-07: `AirThermals.wstar`, meta.z_i).
**Нет в API:** u*, сдвиг, признак отрыва — AM-08 добавляет функции в `WindField` (C4 v2 через К0),
не вычисляя их по приватным массивам.

**Трава/вода/F3 AM-10:** `TerrainWind` берёт `field_src.air_field.sample(Vector3(x, g + 10, z), g)`
(duck typing, `is_air_field_on`) → текстура RGF: **R = мир x (u), G = мир z (−v)**, `field_wind_origin`
— мир (x, z) угла, `field_wind_size_m`, 0 — без поля; порывистость — `air_velocity_at − mean_wind_at`.
F3 (`wind_field_debug.gd`) и `dump_slices.gd` — `air_velocity_at` / `WindField.load_file`.

**Конфиг** `configs/atmosphere.json → air_model`: `enabled` (auto/on/off), `edge_blend_cells` (5),
`blend_s` (60), `recompute_game_min` (15), `max_speed_ms` (40), `max_w_ms` (10), у каждого `_doc`.
- **Тесты:** `test_c4_field_set_vector4`, `test_c4_atmosphere_api_and_analytic`,
  `test_c4_atmosphere_field_rule`, `test_c4_config_keys`.

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
- **Тесты:** `test_c6_start_hours` (часы), формат файла — `test_c3_game_field_files`.

## C7 v0 (проект) — клипмапы AM-04 → `WindField` / `AirFieldSet`
**Владелец:** AM-04. **Потребители:** C4.

Заложено AM-05: уровень = отдельный `WindField` со своими dx/dz/x0/y0; `AirFieldSet.levels` —
**от мелкого к грубому**; выборка: мелкий с весом края w₁, остаток (1 − w₁) — следующему, …,
непокрытое — аналитике; ширина края `edge_blend_cells` клеток **своего** уровня (окно 100 м —
500 м, область 400 м — 2 км); сдвиг окна = `set_field([новые уровни], blend_s)`. Термики — по
грубейшему уровню (подпись сетки для сети стабильна при сдвиге окон). Граница окна с грубого,
порядок пересчёта, сдвиг фоном — проект AM-04. **Тест:** `test_c7_levels_fine_to_coarse`.

## C8 v1 — фоновый пересчёт / подмена (AM-06Б) → `set_field`
**Владелец:** AM-05 (подмена); вызывающий — AM-06Б (проект), AM-04 (сдвиг окон).

- `Atmosphere.set_air_field(new, blend_s = −1)` → `AirFieldSet.set_field(new, blend_s)`;
  −1 — `air_model.blend_s` (60 с). `new`: `WindField`, `Array[WindField]`, `null`/`[]` (плавно в
  аналитику).
- Время подмены — **время атмосферы** (`Atmosphere.step(dt)` → `advance(dt)`, только при
  включённом поле); доля нового — smoothstep(t / blend_s), монотонно; `blend_s ≤ 0` — сразу.
- Подмена во время подмены: «старым» становится ближайшее из (старое, новое) по доле — возможен
  скачок (Р7).
- Строить `WindField` — в рабочем потоке (O(n) ≈ 0,2–0,4 с на 64 × 64 × 62), `set_field` — в
  главном. Пересчёт каждые `recompute_game_min` = 15 игровых минут и при смене ветра/погоды — проект
  AM-06Б. **Тест:** `test_c8_blend`.

---

## Расхождения (на 29.09.2026) и предложения
| # | Что | Где | Предложение (кому) |
|---|---|---|---|
| Р1 | Δτ_u: эталон с cf64b7b — 0,3 с/м·Δx; фикстуры `ref/` посчитаны с 600 с (в JSON); закоммиченный `AirCase.p.dtau_u = 600` | AM-01 ↔ AM-03 | AM-03: закоммитить `dtau_u = NAN → dtau_per_m·dx` (есть в рабочем дереве), в сверке с `ref/` брать `params.dtau_u` из JSON. Фикстуры не пересчитывать (C1 v1: Δτ из JSON) |
| Р2 | `field/kayancha_w100_h13_U3_d180` — поле **прикидки** (solver.py, npz), не air.py: нет `z_i/heat/gam/u10`, другие ключи `cond`; `thermals/*` — уже air.py | AM-05 ↔ AM-01/AM-07 | AM-05 (или К0): перегенерировать `field/` из air.py тем же путём, что `thermals/`, пробы `probes` пересчитать; до того — пометка `"model": "prototype"` в JSON. Тест `test_air_model_atmo` сверяет пробы — поменять вместе |
| Р3 | Нет версии модели в данных и константы версии формата в коде: JSON поля — `version: 1` (формат), `WindField` его не проверяет; версии модели (нужна AM-06б) нет | AM-05, AM-06б | AM-05: `const FORMAT_VERSION := 1` в `WindField`, `load_file` отвергает `version` > поддерживаемой; AM-06б: `model_version` (хеш параметров/коммита air.py) в метаданных библиотеки и поля. Тест C3 — дополнить |
| Р4 | Вход термиков в `meta` (`heat, z_i, gam, u10`): закоммиченный `AirCase.meta()` их не отдаёт → поле с GPU без термиков из поля | AM-03 ↔ AM-07 | AM-03: закоммитить новый `meta()` (есть в рабочем дереве: `heat_used`, `gam[1..nz]`, `z_i`, `u10`, `wdir`). **Ошибка в рабочем дереве:** `PackedFloat32Array(heat_used)` из `PackedFloat64Array` — ошибка скрипта (meta() не возвращает, `field()` тоже упадёт); переводить поэлементно. После — вернуть проверку ключей в `test_c2_air_case_grid` |
| Р5 | `AirThermals` читает приватные `_vel, _wconv, _theta, _k1, _hc` `WindField` — раскладка хранения стала интерфейсом | AM-07 ↔ AM-05 | Публичные геттеры только чтения в `WindField` (`column_first_air(c)`, `cell_vel(k, c)`, `cell_w_conv`, `cell_theta`, `column_hc(c)` или отдача массивов) — C4 v2 через К0, AM-07 переходит на них. AM-07 заявил, что добавит — согласовать с владельцем AM-05 |
| Р6 | `AirPicardJob.field()` при `mech = false`: `w_mech = w`, `w_conv = 0` → конвективная вертикаль идёт пилоту напрямую (двойной счёт с пузырями) | AM-03 | Поле для игры — только `mech = true`; при `mech = false` `field()` возвращать null или класть `meta.no_mech = true`, а атмосфера такое поле не берёт. Решает К0 |
| Р7 | Подмена во время подмены (`set_field` при 0 < доля < 1) перезапускает смешение от «ближайшего» — скачок до половины разницы полей; при ускорении времени и пересчёте раз в 15 игровых мин подмены могут перекрываться | AM-05 ↔ AM-06Б, AM-04 | AM-06Б/AM-04: не подавать новое поле, пока `blend_fraction() < 1` (очередь последнего); или AM-05: «старым» делать снимок текущей смеси. Выбор — К0 |
| Р8 | `AirThermals.has_inputs` истинно при любом `meta.arrays` (даже без `heat`) — ложное «есть вход», дальше `build` падает на размере | AM-07 | Проверять `arrays.has("heat")` (тривиально, AM-07) |
| Р9 | Комментарий `TerrainWind._update_field_texture`: «RG = (u, v)», фактически (мир x, мир z) = (u, −v); шейдер читает как мир xz — работает верно | AM-10 | Поправить комментарий (тривиально, AM-10) |
| Р10 | Термики по грубейшему уровню (`levels[-1]`): с клипмапами это область 400 м, а фикстуры и настройка AM-07 — по окну 100 м | AM-04 ↔ AM-07 | Решить до AM-04: источники по области 400 м (подпись сетки стабильна для сети) или по окну (подпись меняется при сдвиге окна → переотправка маски). Записать в C7 v1 |
| Р11 | `dims` в JSON фикстур — [NX, NY, NZ], а раскладка — (NZ, NY, NX); у полей игры `dims` нет | документация | Принято соглашением («Общие соглашения»); не менять |

## Журнал версий
| Контракт | Версия | Дата | Что |
|---|---|---|---|
| C1–C5, C8 | v1 | 29.09.2026 | первая фиксация по коду |
| C6, C7 | v0 | 29.09.2026 | проект (часы старта C6 — готово) |
| C6 | v1 | 29.09.2026 | К0: библиотеки полей нет (решение пользователя); C6 — часы старта и отладочный файл поля |
| C4 | v2 | 29.09.2026 | AM-07: `WindField.raw_vel/raw_w_conv/raw_theta/raw_hc/raw_k1` и `heat_flux/z_i/gam/u10` (только чтение) вместо приватных массивов (Р5); `has_inputs` проверяет heat, z_i и gam |
| C2 | v2 | 29.09.2026 | AM-03 (lint, snake_case): `AirCase.U10` → `u10`, `NX/NY/NZ` → `nx_h/ny_h/nz_h` (размеры с ореолом), `U_a` → `u_a`; аргумент `AirPlace.domain_case(…, u10, …)` — только имя; ключи `meta()` без изменений |
