---
type: "contract"
status: "active"
module: "air-model"
updated: "2026-10-03"
summary: "Модель воздуха: контракты систем — Интерфейсы на стыках задач плана docs/plan/air_model.md (AM-00…AM-12)."
related: []
contracts: [{"id": "C1", "version": 2}, {"id": "C2", "version": 6}, {"id": "C3", "version": 1}, {"id": "C4", "version": 4}, {"id": "C5", "version": 1}, {"id": "C6", "version": 1}, {"id": "C7", "version": 3}, {"id": "C8", "version": 2}, {"id": "C9", "version": 3}, {"id": "C10", "version": 3}]
---
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

## C2 v6 — вход места `AirPlace` / `AirCase` (AM-03) ← рельеф, погода, солнце
**Владелец:** AM-03. **Потребители:** AM-06Б (загрузка/пересчёт, C9), AM-04.

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
- **Тесты:** `test_c2_inflow_scale` (v6: α/max_profile по меню, u10 случая = k·меню, meta);
  `test_c2_air_case_grid` (сетка, zc, dims, `without_heat`); `test_c2_params_match_reference` (инвариант
  выше; в v4 — исполнитель Б2 переписывает по новому инварианту в том же коммите, что функцию).

## C3 v1 — выход решателя → `WindField` (AM-05)
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

## C7 v3 — клипмапы AM-04 → `WindField` / `AirFieldSet`
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

## C9 v3 — жизненный цикл поля в игре `AirRuntime` (AM-06Б, окна — AM-04)
**Владелец:** AM-06Б (`scripts/atmosphere/air_model/air_runtime.gd`). **Потребители:** `game.gd`
(загрузка, полёт), AM-04 (окна 100/50 м — встраивает свои уровни сюда), AM-11 (замеры).

`AirRuntime extends Node` (ребёнок `Game`; опрос решателя — **сам**, в `_process`: RD — только
главный поток). Область 400 м по всему месту (`AirPlace.domain_case`, `DX = 400`) и — при заданном
`set_focus` — окна клипмапа 100/50 м вокруг старта/пилота (`AirClipmap`, C7).

| API | Что |
|---|---|
| `setup(atmo, place, conditions_fn)` | `atmo` — объект с `set_air_field(поле, blend_s)`; `place = {detail: HeightLayer, water: Image\|null, loc: {id, center_lat, center_lon, utc_offset_h}}` (`AirRuntime.place_of(terrain, utc_offset_h)`); `conditions_fn() -> {hour, u10, wdir, t_max, sky}` (`AirRuntime.conditions_of(clock, atmo, settings)`: час `SunClock`, ветер атмосферы на 10 м, прогноз пилота). Новое место — сброс тёплого старта |
| `await load_field() -> bool` | экран загрузки: точное поле для `conditions_fn()`, в атмосферу **без подмены** (`blend_s = 0`); те же место и условия — сразу true (поле уже в атмосфере); доля — сигнал `progress_changed` |
| `recompute_enabled` | пересчёт в полёте: срок — смена номера `floor(hour·60 / recompute_game_min)` (игровое время, ускорение ×N учтено часами), внеочередной — смена ветра (> 0,05 м/с или > 1°) или погоды (`t_max`, `sky`); поле — на **начало срока**; тёплый старт от `state()` текущего поля; подмена `set_air_field(f, −1)` (C8) |
| `set_focus(node: Node3D, start: Vector3)` / `focus_fn: Callable → Vector3` (v2, AM-04) | центр окон: при загрузке — `start`, в полёте — `node` (когда его родитель шагает физику); не задан — только область. Загрузка: область → окна 100 и 50 м с центром на старте (доля: 0,5 — область, 0,5 — окна), в атмосферу один раз `[окно 50, окно 100, область]`; пересчёт — область, затем окна на прежних местах с тёплого старта, подача одним набором; в покое (`busy()` = false) — сдвиг окон за пилотом (`window_shift_frac`), подача `set_air_field(levels, −1)`, счётчик `shift_count`; ошибка окон — только область. `last_info.windows` — замеры окон. Game: `air_runtime.set_focus(glider, _start_pos)` |
| `request_recompute(reason)` | внеочередной пересчёт по текущим условиям (идёт расчёт — не копится) |
| `stop()` | остановить расчёт, освободить буферы задачи (поле в атмосфере остаётся); RD — до `_exit_tree` |
| `busy()`, `current_conditions()`, `unavailable_reason()`, `last_error`, `last_info` | состояние; `last_info` — `{hour, u10, wdir, t_max, sky, reason, wall_s, gpu_s, iters, warm, loading, start_ms, main_max_ms, poll_max_ms, chunk_max_ms}` |
| `needs_recompute(have, want, step_min) -> String`, `slot`, `slot_hour` (static) | правило сроков ("" — не нужен) |
| сигналы | `field_applied(info)` — поле подано; `fallback(reason)` — не удалось; `progress_changed(fraction)` — доля расчёта при загрузке |

- **Кадр:** вход места и `prepare()` обоих решений — рабочий поток; RD и ядра создаются один раз
  при появлении узла (запуск игры); загрузка — `poll_slice(40 мс)`; полёт — `poll()` порциями
  ≤ 25 мс (`chunk_ms`); сборка `WindField` — `field_async` (рабочий поток).
- **Ошибки** (нет RD / headless / `air_model.enabled = off` / область вне рельефа / Пикар
  разошёлся / таймаут `air_model.timeout_s`): при загрузке — аналитика (поле прошлого места
  убирается), строка `air_model: analytic (<причина>)`, `fallback`; в полёте — прежнее поле,
  строка `air_model: пересчёт не удался (<причина>)`, следующая попытка — на следующем сроке.
  Не падение. `--air-field=` — поле из файла, расчёта нет.
- **Очереди нет:** пересчёт, не успевший до следующего срока, по окончании сменяется новым — на
  последний срок.
- **Сеть:** каждый клиент считает поле сам в `Game.start` (этап «Рассчитываем ветер»); час зоны
  после `join_world` — обычный срок пересчёта.
- **AM-04 (v2):** уровни окон — в тот же `set_air_field([окна…, область])`; одно устройство
  (`RuntimeGpu` собирает и ядра окон `AirWindowJob.WINDOW_SHADERS`), задачи области и окон — по
  очереди (сдвиг — только в покое).
- **v3 (01.10.2026, air-start, решение пользователя):** `conditions_fn().u10` — ветер меню **на 10 м над
  стартом**. Загрузка с заданным `set_focus` и u10 > 0: проход 1 — область + окна с `inflow_k` = k₀ (1,0 или k
  прошлой загрузки того же места и направления), замер U₁ — горизонталь среднего поля (без болтанки, как
  `Atmosphere.mean_wind_at`) на 10 м над землёй старта (`focus_start`); k₁ = k₀·(u10/U₁)^(1/p), p по ветру меню 0,57 / 0,75 / 0,90 при 3 / 6 / 10 м/с (линейно, за краями — край; замер
  отклика поля на приток, `tools/research/air_start/out/passes.csv`), k в 0,3…3; проход 2 — с k₁, в
  атмосферу подаётся **только** поле прохода 2 (одним набором, `blend_s = 0`); доля загрузки: проход 1 — 0…0,5,
  проход 2 — 0,5…1. Без focus или в штиль (u10 < 0,5 м/с, `WindProfile.U10_MIN`) — один проход с k = 1; проход 1 упёрся в предел
  итераций (любое решение области или окна) — второго прохода нет, подаётся поле прохода 1 (без подстройки); неудача
  прохода 2 — поле прохода 1; `air_model.timeout_s` — на проход. В полёте пересчёт (срок, смена ветра/погоды) —
  один проход с k последней загрузки (граница модели: k не уточняется в полёте). Новое: свойство `inflow_k`
  (k поданного поля); `last_info` + `inflow_k`, `passes`, `u_start10_first` (U₁, м/с), `u_start10` (U на 10 м над
  стартом у поданного поля, м/с); строка журнала `air_model: поле …` с k и U над стартом. Остальное — v2.
- **Тесты:** `test_c9_runtime_shape` (без GPU; v3 — `inflow_k`); GPU — `tests/atmosphere/test_air_runtime_gpu.gd`,
  с окнами — `test_air_window_gpu.gd::test_runtime_with_windows`.

## C10 v3 — случай калибровки (обёртка прогона air.py) → совместная калибровка
**Владелец:** А4 (Perdigão, `tools/research/cases/perdigao.py`); Askervein — адаптер к той же форме
делает волна Б п. 1 (`tools/research/cases/askervein.py` поверх `recal/run_grid.py`, `tune/out/fit_s1.json`).
**Потребители:** волна Б п. 1 (совместная калибровка λ/h, λ, `local_k` — общие; α, z0 — свои у случая),
повтор Морриса (по условию). Уровень — исследовательский Python (CuPy), в игру не идёт.

Модуль `tools/research/cases/<NAME>.py`:
| Что | Интерфейс |
|---|---|
| `NAME: str` | короткое имя случая (`pd`, `ask`); префикс всех наблюдаемых `<NAME>_` |
| `SUBCASES: list[str]` | подслучаи (для Perdigão — `ne`, `sw`) |
| `observations() -> list[dict]` | `{name, grp, data, sig, sig_grid, grid_corr, unit, subcase, src}`: `data` — наблюдаемое (лучше безразмерное: отношение к опорной скорости, длина к H/расстоянию между грядами), `sig` > 0 — полная 1σ измерения и представительности (разброс по окну, по случаям), `sig_grid` ≥ 0 — оценка систематики сетки (0 — не оценена), `grid_corr` — аддитивная поправка к модели (0 — нет), `src` — источник (статья/таблица/файл) |
| `run_one(over: dict, subcase: str, dx: float = <номинал случая>) -> dict` | `over` — переопределения полей `air.Params` (прочее — `Params()` + постоянные случая: сетка, губки, f_cor, профиль притока); строка `{case, subcase, dx, params, status, iters, t, obs}`: `params` — **все** поля Params как применены, `status` ∈ ok/max/diverged/error, `iters` — внешних итераций, `t` — с решателя, `obs` — `{name: float}` ⊇ имена `observations()` этого подслучая (не определено — NaN/null) |

- **Инварианты:** решатель не меняется (`air.py`, `solver.py`, GPU); нужно в решатель (z0 по карте,
  высота смещения d под пологом) — через координатора. Рельеф и входы — детерминированно (файлы в git или
  скрипт + путь вне git в README). Pr_t = 0,85 (`Params()`), не подгоняется. Замок GPU — на один прогон
  (`morris/model.GpuLock`, `/tmp/heat_ca_gpu.lock`), float32, критерий сходимости air.py, `max_outer` ≤ 4000.
- **v2 (01.10.2026, К2, до волны Б) — сопоставимость случаев.** Общая схема — `tools/research/cases/scheme.py`:
  `SCHEME` (перенос 2-го порядка `adv2`, `limiter` 0, hb, `local_k` вкл, cbl, Pr_t 0,85, `k_relax` 0,1, `cs_h`
  0,25, `k_fa` 1), `MAX_OUTER` 4000, критерий air.py по умолчанию, нейтраль (dθ̄/dz = 0, без нагрева);
  `run_one` накладывает `scheme.apply` поверх `over` — калибровочный прогон схему не меняет. Прогоны оценки
  ошибки схемы (1-й порядок игры, мельче/крупнее сетка) — строка с `scheme_ctl: true`, в χ² не входят. Модуль
  обязан иметь **`SETUP`** (`{подслучай: {…}}` или общий словарь) со всеми ключами `scheme.SETUP_KEYS`: H, dx, dz,
  область, потолок, губки, f_cor, ветер и опорная скорость, номинал α и z0, правило насыщения профиля притока
  (`z_sat_rule`, `max_profile`), лес (смещение d), устойчивость. Геометрия (dx/H, область/H, потолок/H, губки) и
  профиль притока задаются **одним правилом для всех случаев**; различия между случаями — только в данных
  (рельеф, лес, широта, ветер, устойчивость) и в подгоняемых у случая α, z0. Таблица сопоставимости
  «настройка → Askervein → Perdigão» — в журнале модуля до пачки. `check_c10.py` проверяет `SETUP` и
  совпадение `params` строк со `SCHEME` (кроме `scheme_ctl`). Правка `scheme.py` — новая версия C10.
- **v3 (01.10.2026, К2, по этапу 1 Б1):** общие правила постановки — `tools/research/cases/rules.py` (приходит с
  веткой Б1; правка — только через координатора, как `scheme.py`): H — перепад рельефа в области наблюдений
  (опорная точка ↔ вершина/гребни ↔ дно); `H_PER_DX` 5,8 (dx округляется к шагу данных), dz = dx/2; `N_DOM` 200
  клеток; `SPONGE_CELLS` 35; потолок `TOP_PER_H` 7,5 H над высшей точкой рельефа, верхняя губка — от высшей точки
  до потолка; профиль притока — степенной с насыщением z_sat = 0,3·h, h = 0,3 u*/f (u* = κU10/ln(10/z0)),
  max_profile = (z_sat/10)^α — пересчитывается с α и z0 прогона; U10 фона — так, чтобы модель на опорной точке
  совпала с данными у номинала, дальше фиксирован; нижняя граница наблюдений — 1·dz; лес — поверхность + d·доля,
  скалярное z0. Сеточная поправка — одним способом: Δ = y(dx·2/3) − y(dx) у номинала, `grid_corr` = Δ,
  `sig_grid` = |Δ| ⊕ ½|Δ_области|. Наблюдаемые мачт Perdigão — компонента вдоль ветра притока u_∥/S_ref (одно
  правило для NE и SW; поворот вдоль долины — вне нейтрального среднего поля). Отклонение устойчивости данных от
  нейтрали — в σ.
- **Уточнения (01.10.2026, К2, без смены версии — по вопросам А4):** `grp` — группа для χ² по частям и
  для учёта зависимости (наблюдаемые одной группы — одна мачта или одни и те же исходные числа; потребитель
  отчитывается по группам и может задать внутри группы корреляцию); лишние поля строки `run_one`
  (`inputs`, `t_lock_wait`, `tag`, …) допустимы, потребитель их не читает. **Схема переноса**: при калибровке
  физических параметров все случаи считаются одной схемой (`adv2`, `limiter`, dx — в `params`/`dx` строки);
  ошибка 1-го порядка игры — отдельная систематика, не в параметрах (А3, §4).
- **χ² потребителя:** Σ ((obs + grid_corr − data) / √(sig² + sig_grid²))²; строки со `status` ≠ ok в χ²
  не входят (учитываются отдельно).
- **Тест:** `tools/research/cases/check_c10.py <модуль> [runs.jsonl …]` — форма `SETUP`, `observations()` и строк
  прогонов, общая схема (без GPU, venv калибровки). Пробный `perdigao/out/trial_runs.jsonl` (А4, v1: 1-й порядок,
  k_relax 0,5) по v2 не проходит — пересчитывается владельцем в волне Б.

---

## Расхождения (на 29.09.2026) и предложения
| # | Что | Где | Предложение (кому) |
|---|---|---|---|
| Р1 | Δτ_u: эталон с cf64b7b — 0,3 с/м·Δx; фикстуры `ref/` посчитаны с 600 с (в JSON); закоммиченный `AirCase.p.dtau_u = 600` | AM-01 ↔ AM-03 | AM-03: закоммитить `dtau_u = NAN → dtau_per_m·dx` (есть в рабочем дереве), в сверке с `ref/` брать `params.dtau_u` из JSON. Фикстуры не пересчитывать (C1 v1: Δτ из JSON) |
| Р2 | ~~`field/kayancha_w100_h13_U3_d180` — поле прикидки~~ **закрыто AM-06Б:** в JSON `"model": "prototype"` — фикстура проверяет выборку и стык с атмосферой (пробы), не физику поля; поле решателя игры проверяет GPU-тест `test_air_runtime_gpu` | AM-05 ↔ AM-01/AM-07 | — |
| Р3 | ~~Нет константы версии формата~~ **закрыто AM-06Б:** `WindField.FORMAT_VERSION = 1`, `load_file` отвергает другую версию с ошибкой (`test_c6_field_version`); версия модели не нужна — библиотеки нет | AM-05 | — |
| Р4 | Вход термиков в `meta` (`heat, z_i, gam, u10`): закоммиченный `AirCase.meta()` их не отдаёт → поле с GPU без термиков из поля | AM-03 ↔ AM-07 | AM-03: закоммитить новый `meta()` (есть в рабочем дереве: `heat_used`, `gam[1..nz]`, `z_i`, `u10`, `wdir`). **Ошибка в рабочем дереве:** `PackedFloat32Array(heat_used)` из `PackedFloat64Array` — ошибка скрипта (meta() не возвращает, `field()` тоже упадёт); переводить поэлементно. После — вернуть проверку ключей в `test_c2_air_case_grid` |
| Р5 | `AirThermals` читает приватные `_vel, _wconv, _theta, _k1, _hc` `WindField` — раскладка хранения стала интерфейсом | AM-07 ↔ AM-05 | Публичные геттеры только чтения в `WindField` (`column_first_air(c)`, `cell_vel(k, c)`, `cell_w_conv`, `cell_theta`, `column_hc(c)` или отдача массивов) — C4 v2 через К0, AM-07 переходит на них. AM-07 заявил, что добавит — согласовать с владельцем AM-05 |
| Р6 | `AirPicardJob.field()` при `mech = false`: `w_mech = w`, `w_conv = 0` → конвективная вертикаль идёт пилоту напрямую (двойной счёт с пузырями) | AM-03 | Поле для игры — только `mech = true`; при `mech = false` `field()` возвращать null или класть `meta.no_mech = true`, а атмосфера такое поле не берёт. Решает К0 |
| Р7 | ~~Подмена во время подмены — скачок~~ **закрыто AM-06Б:** «старым» — снимок текущей смеси (C8 v2) | AM-05 ↔ AM-06Б, AM-04 | — |
| Р8 | `AirThermals.has_inputs` истинно при любом `meta.arrays` (даже без `heat`) — ложное «есть вход», дальше `build` падает на размере | AM-07 | Проверять `arrays.has("heat")` (тривиально, AM-07) |
| Р9 | Комментарий `TerrainWind._update_field_texture`: «RG = (u, v)», фактически (мир x, мир z) = (u, −v); шейдер читает как мир xz — работает верно | AM-10 | Поправить комментарий (тривиально, AM-10) |
| Р10 | Термики по грубейшему уровню (`levels[-1]`): с клипмапами это область 400 м, а фикстуры и настройка AM-07 — по окну 100 м | AM-04 ↔ AM-07 | **Решено (К0):** источники — по области 400 м (подпись сетки стабильна при сдвиге окон); записано в C7 v1 |
| Р11 | `dims` в JSON фикстур — [NX, NY, NZ], а раскладка — (NZ, NY, NX); у полей игры `dims` нет | документация | Принято соглашением («Общие соглашения»); не менять |
| Р12 | Каждое новое поле → `ThermalField._update_air` → `AirThermals.build` на главном потоке: **~0,77 с** на области 400 м (замер AM-06Б, 4070 SUPER) — кадр в полёте раз в 15 игровых минут (при ×60 — раз в 15 с) | AM-07 ↔ AM-06Б, AM-11 | AM-11 (или AM-07): сборка источников в рабочем потоке, подача готового списка на главный |
| Р13 | Тёплый старт пары: `AirPicardJob.warm` греет только первое решение (без нагрева — от состояния решения **с** нагревом), решение с нагревом — всегда холодное (`reinit`): итераций 70 + 90 против 100 + 90 (−16 %, а не −56 %) | AM-03 | AM-03: `warm_mech` — отдельное состояние решения без нагрева и тёплый старт второго решения от своего `warm`; `state()` → оба. Тогда `AirRuntime` хранит оба |
| Р14 | `AirPlace.context` берёт дату из `WeatherModel.reference_context`, а не дату полёта (`settings.month/day`) | AM-03 ↔ AM-06Б | AM-03: аргумент даты (или ctx) в `domain_case`; `AirRuntime` передаст дату неба |
| Р15 | `AirRuntime` обходит два места решателя подклассами в своём файле: `PreparedCase` (`prepare()` обоих решений заранее в рабочем потоке — иначе 0,67 с на главном в `AirPicardJob.start`) и `RuntimeGpu` (`release()` освобождает только буферы задачи, RD и ядра живут — иначе 0,2 с на создание RD в каждом пересчёте); `RuntimeGpu` опирается на приватные `_owned/_sets/_scratch` `AirGpu` | AM-03 ↔ AM-06Б | AM-03: публичные `AirCase.is_prepared()` (без повторного `prepare`) + `AirPicardJob.mech_case`, `AirGpu.release_buffers()`; `AirRuntime` переходит на них |

## Журнал версий
| Контракт | Версия | Дата | Что |
|---|---|---|---|
| C1–C5, C8 | v1 | 29.09.2026 | первая фиксация по коду |
| C6, C7 | v0 | 29.09.2026 | проект (часы старта C6 — готово) |
| C6 | v1 | 29.09.2026 | К0: библиотеки полей нет (решение пользователя); C6 — часы старта и отладочный файл поля |
| C4 | v4 | 01.10.2026 | К2 до AM-08в (решение пользователя по шлюзу, В2 + Р1): `AirFieldSet.sample_dx`; в зоне отрыва ΔU от ветра на уровне гребня U_H (не U_out), рывки `field_burst_per_du`·ΔU только при болтанке, обратный поток `field_reverse_per_uh`·U_H × (1 − разрешённость пузыря); ключи `lee.field_*`; аналитика без изменений. Потребители: атмосфера (AM-08в), F3/выгрузки через `air_velocity_at` (без болтанки рывков больше нет) |
| C4 | v3 | 29.09.2026 | AM-08: `WindField.turb_at` (T_*), `deardorff_wstar`, `AirFieldSet.sample_turb`; `load_file` → `meta.heat`; стык в `air_velocity_at`: с полем подветренное опускание и ослабление ветра только из поля, эвристика — рывки с нулевым средним, ротор и болтанка по ΔU; болтанка по u*, w*, Ri, спектр фон Кармана; конфиг `turbulence.field_*`, `lee.field_*` |
| C4 | v2 | 29.09.2026 | AM-07: `WindField.raw_vel/raw_w_conv/raw_theta/raw_hc/raw_k1` и `heat_flux/z_i/gam/u10` (только чтение) вместо приватных массивов (Р5); `has_inputs` проверяет heat, z_i и gam |
| C2 | v2 | 29.09.2026 | AM-03 (lint, snake_case): `AirCase.U10` → `u10`, `NX/NY/NZ` → `nx_h/ny_h/nz_h` (размеры с ореолом), `U_a` → `u_a`; аргумент `AirPlace.domain_case(…, u10, …)` — только имя; ключи `meta()` без изменений |
| C8 | v2 | 29.09.2026 | AM-06Б (Р7): подмена во время подмены — от снимка текущей смеси (`AirFieldSet._old`), без скачка |
| C9 | v1 | 29.09.2026 | AM-06Б: `AirRuntime` — поле при загрузке и пересчёт в полёте |
| C6 | v1 | 29.09.2026 | AM-06Б (Р3, без смены версии): `WindField.FORMAT_VERSION`, `load_file` отвергает другую версию |
| C7 | v1 | 29.09.2026 | AM-04: клипмапы — уровни [окно 50, окно 100, область], сетка окна, граница от родителя, `AirWindowJob`/`AirWindowCase`/`AirClipmap`, `AirPicardJob.parent_data/state(mech)/grid`, сдвиг одним `levels_changed`, конфиг `window_levels_m`, `window_shift_frac`; Р10 закрыт (термики — по области) |
| C1 | v2 | 30.09.2026 | К1 по плану А1: θ′_d (диабатическая часть) вторым скаляром, τ только для неё; K_θ = K/Pr_t; s_th = Δτ_θ; порядок итерации и критерий; новые массивы фикстур `ref/`, пересчёт `picard/`, `window/` |
| C2 | v3 | 30.09.2026 | К1 по плану А1: `AirCase.p.pr_t`; смысл τ; исследовательские Params не в `AirCase.p`; `warm`/`state()` с `thd` |
| C3 | v1 | 30.09.2026 | К1 (без смены версии): `theta` — полное θ′ (записано явно) |
| C7 | v2 | 30.09.2026 | К1 по плану А1: `parent_data`/`window_state` с `thd`; θ′_d ореола окна из родителя; сдвиг переносит `thd` |
| C9 | v2 | 29.09.2026 | AM-04: окна клипмапа в `AirRuntime` — `set_focus`/`focus_fn`, `shift_count`, `last_info.windows`; загрузка и пересчёт — область + окна одним набором, сдвиг за пилотом в покое (предложено К0) |
| C2 | v3 | 01.10.2026 | К2 (без смены версии): инвариант `AirCase.p` = `Params()` air.py, α/max_profile = `wind.*` игры; тест `test_c2_params_match_reference`. C1 — границы А2 (что без версии, что через К2) |
| C10 | v1 | 01.10.2026 | К2 до А4: модуль случая калибровки (`NAME`, `SUBCASES`, `observations()`, `run_one`) для совместной калибровки волны Б; тест `tools/research/cases/check_c10.py` |
| C10 | v2 | 01.10.2026 | К2 до волны Б: общая схема `cases/scheme.py` (2-й порядок, hb, local_k, cbl, Pr_t 0,85, k_relax 0,1, нейтраль), `SETUP` случая (геометрия и профиль притока — одним правилом), `scheme_ctl` для контрольных прогонов схемы; `check_c10.py` проверяет |
| C10 | v3 | 01.10.2026 | К2 по этапу 1 Б1: общие правила постановки `cases/rules.py` (H/dx 5,8, область 200 клеток, губка 35, потолок 7,5 H, z_sat = 0,3·h, U10 по опорной точке, нижняя граница 1·dz), сеточная поправка одним способом (dx·2/3), мачты Perdigão — u_∥ |
| C2 | v4 | 01.10.2026 | К2, волна Б п. 2: α по устойчивости (Паскуилл–Тёрнер, отношения Irwin 1979 к D) с α_N 0,24 (Б1), max_profile — правило z_sat = 0,3·0,3u*/f (как rules.py) — одна функция для решателя и WindModel; λ: lam 40, lam_frac 0,0158 (Б1); конфиг `wind.shear_exponent_neutral`, `wind.z_sat_frac` вместо `shear_exponent`/`max_profile_factor` |
| C2 | v6 | 01.10.2026 | air-start (решение пользователя): ветер меню — на 10 м над стартом; `inflow_k` в `domain_case`/`window_case`/`window_at`; α, класс, z_sat — по меню, приток `AirCase.u10` = k·меню; `u10_menu`, `inflow_k` в `AirCase` и `meta()`. Потребители: AirRuntime (C9), клипмап (C7), термики (`meta.u10` — приток) |
| C7 | v3 | 01.10.2026 | air-start: `AirClipmap.setup/set_conditions(…, inflow_k)` — окна с тем же множителем притока |
| C9 | v3 | 01.10.2026 | air-start: загрузка в два прохода (k₁ = k₀·(U_меню/U₁)^(1/p), p по ветру; упор в предел итераций или штиль — один проход; неудача прохода 2 — поле прохода 1; timeout_s на проход), `inflow_k`, `last_info.inflow_k/passes/u_start10_first/u_start10`; в полёте — k загрузки |
| C2 | v5 | 01.10.2026 | К2 по Б2: z_sat по толщине слоя с устойчивостью (h_s = 0,4√(u*L/f), L по Golder 1972 по классу и z0) — `max_profile(…, cls)`; класс F больше не даёт 14·U10 на 300 м |
