---
type: "contract"
status: "closed"
module: "air-model"
area: "air"
updated: "2026-10-15"
summary: "Модель воздуха, стыки C1–C3: эталон AM-01 → GPU, вход места AirPlace/AirCase, выход решателя в WindField."
related: ["docs/contracts/air-model.md"]
contracts: [{"id": "C1", "version": 2}, {"id": "C2", "version": 9}, {"id": "C3", "version": 2}]
---

# Модель воздуха: C1–C3: эталон → GPU, вход места, выход решателя

Стыки C1–C3. Вход (правила изменения, общие соглашения, список стыков и частей) — [air-model.md](../air-model.md).

## C1 v2 — эталон AM-01 → GPU AM-03
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
- **v2 (А1, план `docs/archive/plan/air-model-a1.md`):** уравнение тепла — два переносимых скаляра: θ′_d
  (диабатическая часть: L θ′_d = Q − θ′_d/τ) и полное θ′ (L θ′ = Q − w·dθ̄/dz − θ′_d/τ; τ — явный источник,
  не в диагонали); K_θ = K/Pr_t (один множитель 1/Pr_t на все три оси); `cplz`: s_th = Δτ_θ; порядок
  итерации: шаблон θ′_d → прогонки → шаблон θ′ → прогонки; критерий остановки — по max невязок θ′ и θ′_d;
  выхолаживание в балансе тепла — Σ θ′_d/τ. Полное θ′ — основное поле (плавучесть, N² в kloc, ореол,
  канал `theta`). Фикстуры `ref/` — новые массивы `in_thd`, `heat_thd`, `sol_thd`, `bh_d` (N) и шаблон
  `Ch_d` (7·N), `params.pr_t` в JSON; `heated_slope` — с pr_t ≠ 1; `picard/`, `window/` — пересчёт.
- **Границы А2 (сходимость, 01.10.2026, К2):** без смены версии — значения численных параметров
  (`k_relax`, `heat_sweeps`, `mom_sweeps`, `dtau_*`, …) одновременно в `air.py → Params` и `AirCase.p`
  (инвариант C2 ниже), пересчёт фикстур `picard/`, `window/`, `ref/` тем же генератором с `params` в JSON;
  пропуск второго прохода тепла в решении без нагрева (там θ′_d ≡ 0 — результат тот же). **Через
  координатора, версия +1:** граничное условие θ′ на выходной грани или иная правка схемы — C1 v3
  (сначала reference.md); потолок окна (`TOP_ABOVE`, «верх — h_max + 2000 м») или зона релаксации — C7 v3.
  Параметры модели игры λ/h, α, z0, max_profile А2 не меняет (волна Б, п. 2).
- **Тесты:** `test_c1_ref_fixture_format`, `test_c1_ref_mask_rule`, `test_c1_ref_solution_div_free`
  (v2: новые массивы — в списках `REF_N`/`REF_STENCIL` теста вместе с пересчётом фикстур).

## C2 v9 — вход места `AirPlace` / `AirCase` (AM-03) ← рельеф, поверхность, погода, солнце
**Владелец:** AM-03. **Потребители:** AM-06Б (загрузка/пересчёт, C9), AM-04.

| Вход | Откуда в игре | Формат |
|---|---|---|
| рельеф `hc` | `HeightLayer` detail (узлы 25 м), `AirPlace.block_mean` — блочное среднее по клетке | (ny, nx) float64, м над морем, j — север |
| поверхность (v8) | снимок `AirPlace.surface_of(terrain, detail, water)` → `place.surface`: класс и влажность узлов 25 м; `AirPlace.cell_surface` — доли классов и влажность клетки | (ny, nx, CLASS_COUNT) доли узлов, (ny, nx) m |
| вода | доля узлов клетки: вода карты/маски 10 м (озёра OSM) **или** маска рек слоя (`detail_water.png`) | класс WATER в долях; H — по T воды (SH3) |
| погода на час | `WeatherModel.diurnal_state`, `reference_context`, типовой t_max (`typical_max_c`), `sky` | → `z_i` (м над морем, NAN — нет конвекции), `gam` (NZ = nz + 2, К/м, в центрах с ореолом) |
| солнце и H (v8) | `AirPlace.surface_flux` = `SurfaceHeat.mix_flux` по клетке (SH2/SH3, `docs/contracts/surface-heat.md`) | `heat` (ny, nx) Вт/м² на горизонтальную площадь; пусто — без нагрева |
| ветер прогноза | игра (`--wind`, `--from`, погода) | `u10` (м/с на 10 м), `wdir` (откуда, °) |
| место | `configs/locations/<место>.json` | `center_lat, center_lon, utc_offset_h, id` |

- `AirPlace.domain_case(detail, water, loc, dx, hour, u10, wdir, t_max = NAN, sky = "clear",
  heat = true, inflow_k = 1.0, surface = null) -> AirCase` (v8: хвостовой `surface`) — квадрат `DOMAIN_L` = 38 400 м вокруг центра мира (x0 = y0 = −19 200),
  dz = 105 м (dx ≥ 200) или dx/2, верх — 3000 м над максимумом рельефа, nz чётное; null — область
  вне слоя.
- `AirCase`: `set_grid(dx, nx, ny, dz, z_bot, nz, x0, y0)`, `hc, gam, z_i, heat, u10, wdir, taper,
  p` (Params эталона; `p.dtau_u = NAN` → `dtau_per_m·dx` — рабочее дерево AM-03, Р1), `prepare()`,
  `zc(k) = z_bot + (k − ½)dz` (с ореолом), `dims() = (nx+2, ny+2, nz+2)`, `without_heat()`,
  `meta()` (→ C3).
- `hour` — местное солнечное время игры (часы, как `SunClock`); часы старта — из
  `SunClock.start_hours()` (C6).
- **v3 (А1):** `AirCase.p.pr_t` — турбулентное число Прандтля (K_θ = K/Pr_t; 0,85 — решение
  пользователя 30.09.2026); τ (`tau_cool`) — время релаксации только диабатической θ′_d. `closure`, `nu_const`, `adv2`,
  `limiter` — исследовательские параметры `Params` air.py, в `AirCase.p` их нет (GPU: hb, 1-й порядок).
  Тёплый старт `AirPicardJob.warm` и `state()` — `{u, v, w, th, thd, p}` (нет `thd` — нули). `meta()` без изменений.
- **Инвариант (01.10.2026, К2):** `AirCase.p` = `Params()` эталона `air.py` по всем общим ключам (числа и
  флаги; `dtau_u` None ↔ NAN не сверяется); α и max_profile решателя = `configs/atmosphere.json → wind.shear_exponent`,
  `wind.max_profile_factor` (одно α у решателя и `WindModel`). Менять параметр — во всех трёх местах одним коммитом.
  Устройство α «из местного z0 и устойчивости» (решение К1, волна Б) — это новая версия C2 через координатора.
- **v4 (01.10.2026, К2, волна Б п. 2 — решение по α):** профиль притока решателя и аналитический профиль
  `WindModel` — **одна функция** (один GDScript-класс, напр. `WindProfile`, static): 
  - `alpha(u10, sun_elev_deg, cover) -> float` — показатель по устойчивости: класс Паскуилла–Тернера по скорости
    на 10 м и инсоляции (высота солнца, облачность; ночь — по облачности), α = α_N · r(класс), r — отношения
    показателей Irwin (1979, «сельская местность») к классу D; α_N = `wind.shear_exponent_neutral` = **0,24**
    (совместная калибровка Б1: Askervein α_A 0,242 ± 0,004; Perdigão упирается в край сетки ≥ 0,29 — лес);
  - `max_profile(alpha, u10, z0, f_cor) -> float` = (z_sat/10)^α, z_sat = `wind.z_sat_frac` (0,3) · 0,3 u*/f,
    u* = κ u10/ln(10/z0) — то же правило, что `tools/research/cases/rules.py` (C10 v3); u10 → 0 — нижний предел
    u10 (без деления на ноль; в штиль профиль притока решателю не нужен);
  - `AirPlace.domain_case` / `AirWindowCase` ставят `p.alpha`, `p.max_profile` случая по этой функции (час, солнце,
    облачность, ветер случая); `WindModel` берёт α и max_profile из неё же при смене ветра/погоды/часа
    (`Atmosphere`), а не из констант конфига. `wind.shear_exponent` и `wind.max_profile_factor` удаляются из
    конфига (совместимость не нужна).
  - Решатель: **λ = max(lam, lam_frac·h)** с `lam` 40 м, `lam_frac` 0,0158 (Б1, перевод (б): все cbl-случаи
    матрицы А2 сходятся); z0 игры 0,1 м — без изменений.
  - Инвариант (заменяет v3): `Params()` air.py = `AirCase.p` по общим ключам, кроме `alpha`/`max_profile` — они
    у случая из функции; `Params().alpha` = α_N; GDScript-функция и `rules.py` на контрольных входах дают одно
    z_sat/max_profile (тест сверяет с числами, записанными в тесте из rules.py).
- **v5 (01.10.2026, К2, по отчёту Б2):** насыщение профиля — по толщине слоя **с учётом устойчивости**, как
  `air.py._bl_depth`: z_sat = `wind.z_sat_frac` · h, h = min(0,3 u*/f, 0,4 √(u*·L/f)) для устойчивых классов (E, F),
  h = 0,3 u*/f для D и неустойчивых; L по классу — Golder (1972): 1/L = a + b·lg z0 (A −0,096/0,029, B −0,037/0,029,
  C −0,002/0,018, D 0/0, E 0,004/−0,018, F 0,035/−0,036; Myrup & Ranzieri 1976, Seinfeld & Pandis). Сигнатура:
  `max_profile(alpha, u10, z0, f_cor, cls)` (класс — из `stability_class`); в нейтрали совпадает с `rules.py` (C10 v3).
  Причина: при v4 класс F давал на 300 м 14·U10. Прочее v4 — без изменений.
- **v6 (01.10.2026, модуль air-start, решение пользователя «подстроить поле под старт»):** ветер меню задан
  **на 10 м над стартом**, приток решателя на краю области — подстроенный. Сигнатуры с хвостовым аргументом
  `inflow_k := 1.0` (множитель притока): `AirPlace.domain_case(…, heat = true, inflow_k = 1.0)`,
  `AirWindowCase.window_case(…, ctx, n = 64, inflow_k = 1.0)`, `window_at(…, ctx, n, inflow_k = 1.0)`.
  Аргумент `u10` — ветер меню; α, класс устойчивости и `max_profile` (z_sat) случая — **по `u10` меню**
  (`WindProfile.apply_to_case` от ветра меню); `AirCase.u10 = inflow_k·u10` — ветер притока на 10 м (амплитуда
  профиля u_a = `AirCase.u10`·max_profile, u* замыкания и `meta.u10` — от него же: весь профиль притока
  умножен на k). Новые поля `AirCase.u10_menu` (= `u10` аргумента), `AirCase.inflow_k`; `meta()` + ключи
  `u10_menu`, `inflow_k`; `without_heat()` их сохраняет. `inflow_k = 1` — побитно прежний случай (тесты,
  эталоны, калибровка Б1 не меняются). Решатель, `Params`, калибровка — без изменений.
- **v7 (05.10.2026, модуль air-square, AQ-1) — геометрия квадрата: клетка ровно dx на земле.** Было (v1–v6):
  `block_mean` брал f = round(dx/s) узлов слоя рантайма (s ≈ 18–38 м, Terrarium) → клетка f·s = 385–414 м при
  переданном решателю dx = 400, область 36,9–39,7 км со сдвигом центра до 0,5 км, а в 5 из 367 мест (широты
  50,7–51,0°, −33,7°) область 40 км не влезала в слой — пустой случай «вне слоя». Стало:
  - **Решётка 25 м мира.** Высота клетки = блочное среднее значений слоя, взятых **билинейно** (как
    `HeightLayer.sample`) в узлах решётки мира с шагом 25 м: x = x0 + 25·m, y = y0 + 25·m′, m, m′ = 0 … f − 1,
    f = dx/25 (dx кратно 25 м, x0, y0 кратны 25 м — иначе ошибка), y — на север (z игры = −y). Т. е. ровно
    функция П6 air-nn (`terrain_cut.grid_h` → `block_mean_400`) и `air3d/terrain.block_mean` эталона: при dx = 400,
    x0 = y0 = −19 200 клетка i покрывает узлы x = −19 200 + 400·i + 25·m (средний узел — x0 + 400·i + 187,5 м:
    унаследованный от эталона сдвиг на полузла 12,5 м против центра клетки решателя x0 + (i + ½)·dx — не правим,
    так обучена сеть П2 и считается П6). Значения узлов — float32 (как П6 `grid_h`), сумма — float64.
    Отличие от эталона Python на том же слое ≤ 1e-3 м (порядок сложения, float32).
  - **Решателю, упрощённому пути и сети — одно и то же:** `AirCase.dx` = 400 = фактическая клетка на земле;
    `x0 = y0 = −DOMAIN_L/2` относительно центра мира (точка старта), область ровно 38 400 м, центр — точка старта.
    Вход сети (`AirNNInput`, П2/N1) берёт `case.hc` — те же клетки, что у П6 (на которых обучена П2).
    Окна `AirWindowCase` — та же функция с их dx, x0, y0.
  - **Вода** (`water_fraction`) — по тем же узлам (маска — ближайший пиксель слоя в узле), доля по клетке.
  - **Слой ⊇ область (инвариант):** все узлы клетки лежат внутри слоя (без экстраполяции за край); иначе — как
    раньше null / пустой массив и `push_error` «область вне слоя рельефа». Слой рантайма detail
    (`_plan_layer`, `size_km` 40 → ≥ 40 км, центр — у точки старта с точностью до полупикселя) вмещает область
    38,4 км с запасом ≈ 800 − 1,5·s м на любой широте до `max_abs_lat` (в т. ч. при понижении zoom); встроенные
    слои `data/terrain/*` (25 м, начало −20 000) — тождественно прежнему результату (узлы совпадают с узлами слоя).
  - Сигнатуры `domain_case`, `block_mean`, `water_fraction`, `window_case`, `window_at` — без изменений.
  - Потребители: AM-04 окна (`AirWindowCase`), `AirRuntime` (C9), набор air-synth
    (новые наборы строить по П6, а не «как игра v6»). Решатель, `Params`, калибровка — без изменений.
  - Тест: `test_c2_cell_geometry` (линейное поле на слое с нечётным шагом и сдвигом начала: клетка = среднее по
    узлам решётки 25 м ≤ 1e-3 м; встроенный формат 25 м — как прямое среднее 16 × 16; окно dx = 200;
    вне слоя → пусто).
- **v8 (09.10.2026, модуль surface-heat, SH-4; SH3 `docs/contracts/surface-heat.md`) — H по классам клетки.**
  Было (v1–v7): `AirPlace.solar_flux` — H0 = 330 Вт/м² × косинус к склону + рассеянная 0,10 − 40 Вт/м² выхолаживания,
  одно запаздывание (`heating.lag_h.none`), над водой (маска рек) H = 0. Стало:
  - **Место** (`AirRuntime.place_of`): `{detail, water, surface, loc}`; `surface` — `AirPlace.Surface`, снимок на
    главном потоке `AirPlace.surface_of(terrain, detail, water, domain_dx)`: ждёт поля рельефа (`terrain.wait_relief()`),
    звать после полян у стартов (в игре — так: `_choose_start` до `_load_air_field`). Узлы — решётка 25 м мира внутри
    слоя detail (`origin_x/z`, `width`, `height`, строки на юг); `cls` (PackedByteArray) — класс узла как
    `Terrain._surface_class`: карта поверхности (покрывающая центр слоя), маска 10 м (вода G ≥ 0,5, лес R ≥ 0,5,
    «не лес» маски поверх леса карты — `open_class_near`), луг/поле/кустарник/NONE круче `terrain_look.rock_slope_deg`
    (нормаль по узлам ±25 м, как `normal_at`) → BARE; поверх — WATER по маске рек (ближайший пиксель, как
    `water_fraction`). `moist` (PackedFloat32Array) — `TerrainRelief.moisture` билинейно (поле, покрывающее центр);
    пусто — поля нет. Снимок только читается: рабочие потоки Terrain не зовут; доли клеток сеток области
    (`domain_dx` = DX и DX·coarse) считаются сразу в пуле, остальное — по запросу (кэш для dx ≥ 200, под мьютексом).
    Нет ни карт, ни полей — `surface = null`.
  - **Доли клетки** `AirPlace.cell_surface(surface, water, layer, x0, y0, dx, nx, ny)` → `{fr, m}`: те же f×f узлов,
    что `block_mean`; `fr[(j·nx + i)·CLASS_COUNT + c]` — доля узлов класса c, `m` — среднее `moist` (нет поля → m_norm
    `configs/surface_heat.json`). Без снимка (тесты без Terrain) — класс NONE, вода — маска рек, m = m_norm.
  - **H** `AirPlace.surface_flux(hc, dx, nx, ny, d, ctx, cfg, cells, u10, t_max)` = `SurfaceHeat.mix_flux(fr, q·C,
    (−∂h/∂x, 1, ∂h/∂y), SurfaceHeating.directions(hour), m, {cover, sky_heat}, water, …)`; нормаль — в осях игры
    (x — восток, y — вверх, z — юг = −y решателя), без нормировки (поток на горизонтальную площадь), градиент как
    `np.gradient`; water = `{t_water_c = SurfaceHeat.water_temp_c(дата места, hc), t_air_c = air_temp_c(hour, t_max, hc),
    u_ms = u10 меню, z_m = hc}` (только в клетках с водой). T_воды ≤ ice_c → лёд (SNOW) — в `mix_flux`.
    `solar_flux`, `H0_WM2`, `DIFFUSE`, `H_LW_WM2`, `LW_CLOUD_K` удалены.
  - **Окна** — та же функция на своей сетке: `AirWindowCase.window_case/window_at(…, inflow_k, surface = null)`,
    `AirClipmap.setup(…, inflow_k, surface = null)` (C7 v4). `AirRuntime` передаёт
    `place.surface` в область и окна.
  - **Источник истины для H — `SurfaceHeat` (GDScript).** Эталон Python (`air.py solar_flux`) остаётся старым; фикстуры
    `picard/`, `window/` по H больше не сверяются (сверка hc, γ, z_i, α — как раньше); GPU-тесты Пикара/окон берут H
    из фикстур (решатель — без изменений). Единицы и раскладка `AirCase.heat`, `meta.heat` (C3), `heat_flux()` (C4),
    вход фаз (P10) — **прежние**.
  - Детерминизм: два снимка одного места и две сборки одного случая — побитно одно `heat` (тест).
  - Тесты: `test_air_place.gd` — `test_cell_fractions_synthetic` (доли, вода карты/маски 10 м/рек, влажность, без
    снимка, H = mix_flux), `test_steep_grass_is_bare`, `test_water_ice_january`, `test_surface_determinism_ongudai`
    (снимок = `Terrain.surface_at`/`moisture_at`, побитный детерминизм, вода снимка ⊇ маски рек);
    `test_c2_surface_input` (контракт: ключ `surface`, хвостовой аргумент).
- **Тесты:** `test_c2_inflow_scale` (v6: α/max_profile по меню, u10 случая = k·меню, meta);
  `test_c2_air_case_grid` (сетка, zc, dims, `without_heat`); `test_c2_params_match_reference` (инвариант
  выше; в v4 — исполнитель Б2 переписывает по новому инварианту в том же коммите, что функцию).
- **v9 (10.10.2026, surface-heat SH-6) — z0 по покрову, вход по клетке без перестройки схемы.**
  - `AirCase.z0_map` (ny·nx, м; пусто — `p.z0` во всех столбцах), задаётся `set_z0_map(m)`: `p.z0` = лог-среднее
    карты (эффективный z0 области — профиль притока, α/z_sat `WindProfile.apply_to_case`, фазы). Со снимком
    поверхности `domain_case`/`window_at` строят карту `AirPlace.cell_z0(cells)` — z0 клетки = exp(Σ f_c ln z0_c)
    по долям классов клетки (те же доли, что у H, SH3; z0_c — `configs/surface_heat.json → classes.<имя>.z0_m`,
    П4; П4 §5.4 — лог-среднее по площади); без снимка карты нет, `p.z0` = `AirCase.Z0` (0,1 м). Окна — по своей сетке.
  - `AirCase.col` — `NCOL` = 14: плоскости `COL_CD` = 12 — C_d стенки столбца (κ/ln(½dz/z0))², `COL_UST` = 13 —
    u* замыкания столбца = u*_обл·ln(½dz/z0_обл)/ln(½dz/z0) (тот же ветер на ½dz, что у эффективного z0 области;
    u*_обл = κ·u10/ln(10/z0_обл) = `AirCase.ustar`). `air_picard.glsl`: `setup` — K_b по u* столбца, `mom` — C_d
    столбца грани (плоскость col на привязке 13); `prm[P_CD]`, `prm[P_USTAR]` — эффективные области (ядрами не
    читаются). h_мех и L Обухова в `_closure` — по u* столбца. Без карты — побитно прежнее решение.
  - `meta()`: `z0` — карта ny·nx float32 (есть карта) или число `p.z0` (нет); `z0_eff` = `p.z0` (→ C3 v2).
  - Не входит (стоп-условие SH-6): смещение нуля d над лесом, перестройка нижней клетки/стенки (первая клетка
    ½dz = 52,5 м на 400 м), калибровка Б1/AM-09 (по своим z0 случаев, не z0 игры), сеть/протокол, фазы — эффективный
    z0 области без карты. `WindModel` (аналитика) — по-прежнему `AirCase.Z0`.

## C3 v2 — выход решателя → `WindField` (AM-05)
**Владелец:** AM-05 (`scripts/atmosphere/air_model/wind_field.gd`). **Поставщики:** AM-03
(`AirPicardJob.field()`), AM-06б (библиотека), `to_game_field.py` (прикидка).
**Потребители:** C4, C5, AM-10.

- Каналы (в центрах клеток, раскладка без ореола, float32):
  `u, v` (восток, север, м/с) — решение **с нагревом**; `w_mech` (м/с) — w решения **того же
  случая без нагрева** (H = 0); `w_conv = w − w_mech` (м/с); `theta` = θ′ решения с нагревом (К);
  `hc` (ny·nx, м над морем) — рельеф сетки. `theta` — **полное** θ′ = адиабатическая + диабатическая
  части (C1 v2); диабатическая θ′_d в поле не отдаётся.
- Построение:
  - `WindField.from_arrays(meta, u, v, w_mech, w_conv, theta, hc, max_speed = 40, max_w = 10)`;
  - `WindField.from_mac(meta, u, v, w, w_mech_faces, theta, cell, hc)` — грани с ореолом (как
    C1), в центры — среднее двух граней, клетки `cell == 0` → 0;
  - `WindField.load_file(путь)` — `<путь>.json` + `<путь>.bin`, формат C6-файл ниже;
  - null — размеры не сходятся (`push_error`).
- `meta` (Dictionary): **обязательно** `dx, dz, x0, y0, z_bot, nx, ny, nz`; `z0` — **v2:** карта ny·nx (float32,
  j·nx + i, м; от `AirCase.meta()` со снимком поверхности) или число (одно на все столбцы; нет ключа — 0,1 м;
  файлы C6 — число); `z0_eff` — эффективный z0 области (справочно). `WindField.z0` — лог-среднее карты (термики,
  масштаб 3), `WindField.z0_at(pos)` — z0 столбца; лог-профиль ниже первой воздушной клетки и u* столбца (C4
  `T_USTAR`) — по z0 своего столбца; карта не того размера — null;
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
