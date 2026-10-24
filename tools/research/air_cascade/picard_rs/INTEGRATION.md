---
type: "research"
status: "active"
module: "picard-rs"
updated: "2026-10-24"
summary: "picard_rs для интегратора: API, вход R1 и выход, тёплый старт, потоки, сборка, пример"
conclusion: "Крейт встраивается по этому описанию без чтения src; не проверено: Windows/macOS, 200 м, окна 100/50 м, rayon в gdext"
data: "examples/integrate.rs"
applied_in: ""
related: ["tools/research/air_cascade/picard_rs/README.md", "docs/contracts/picard-rs.md", "docs/contracts/air-cascade.md", "docs/plan/picard-rs.md", "docs/plan/rust-ext.md", "tools/research/rust_ext/gdext_probe/README.md"]
---

# picard_rs — описание для интегратора

Для того, кто встраивает крейт в игру (gdext) и крейт не видел. Читать `src/` не нужно: всё, что вызывается снаружи, описано здесь.
Источник каждого утверждения — код крейта (`src/api.rs`, `src/state.rs`, `src/case.rs`, `src/solver.rs`), контракты R1/R2/R4/R6
(`docs/contracts/`) и README крейта; что не проверено запуском — помечено «не проверено». Встраивание в игру (gdext) — отдельный модуль,
здесь его нет.

Что делает крейт: решает установившееся среднее поле ветра и θ′ (Пикар AM-01, как `AirPicardJob` на GPU) на **одной** сетке за **один** вызов.
Вход — готовый случай (подготовка рельефа, K, губок, нагрева — в игре, не в крейте), выход — поля `u, v, w, θ′, θ′_d, p`.

## API

Библиотека `picard_rs` (`src/lib.rs`): `api`, `case`, `state`, `solver`, `report`, `util`, `kernels`, `lines`, `mg`, `blocks`. Для встраивания нужны
`api`, `case`, `state` и два типа из `solver` (`StopReason`, `Residuals`/`Check`). Остальное — внутреннее (ядра, прогонки, V-цикл, сверка блоков).

### Функции

| Функция | Что |
|---|---|
| `api::solve(&Case, &SolveOpts) -> anyhow::Result<Solved>` | вся работа: подготовка (холодная или тёплая), итерации, `finalize`, сверка с эталоном случая. **Блокирует** вызывающий поток до конца |
| `case::Case::load(&Path) -> Result<Case>` | читает `<случай>.json` и `.bin` рядом (R1) |
| `state::State::read(&Path)` / `State::write_atomic(&self, &Path)` | снимок R4 v2 с диска / на диск (`.json` + `.bin`, запись через временные файлы и переименование) |
| `state::State::check_dims(&Consts)` | ошибка, если сетка снимка не равна сетке случая |
| `api::resolve_threads(n)`, `api::pool(n)` | число потоков (`0` → все логические) и свой `rayon::ThreadPool`; нужны только при работе с `Solved.picard` напрямую |

### SolveOpts (`Default` в скобках)

| Поле | Тип | Смысл |
|---|---|---|
| `threads` | `usize` (0) | потоков в **своём** `rayon::ThreadPool` на этот вызов; `0` = `std::thread::available_parallelism()` (при ошибке 1; на Linux std учитывает квоту cgroup — по документации std, не проверялось). Глобальный пул rayon не создаётся и не используется. Результат побитно не зависит от числа потоков (тест `tests/api.rs`) |
| `max_iters` | `usize` (2000) | остановка точно после этой итерации |
| `tol_scale` | `f64` (1.0) | множитель к трём допускам критерия случая (`tol_mom_rms`, `tol_th_rms`, `tol_div_rms`); 1.0 = как у эталона. Должен быть конечным и > 0, иначе ошибка. **Принято 5** для холодного и тёплого старта (решение пользователя 2026-10-24, PR-8) |
| `time_budget` | `Option<Duration>` (None) | реальное время итераций, считается от начала итераций (подготовка не входит); проверяется после каждой итерации — когда исчерпан, остановка после неё и выдача текущего поля. Предел точный до одной итерации (≈ 60–90 мс на 8 потоках, 400 м), но подготовка и `finalize` идут сверх бюджета |
| `init` | `Option<State>` (None) | тёплый старт от этого снимка; `None` — холодный (фон + 30 V-циклов) |
| `snapshot_at` | `Vec<usize>` (пусто) | строго возрастающие номера итераций, после которых брать `finalize`-снимок в `Solved.snapshots` (номера больше сделанных итераций не берутся). Не строго возрастающий список — ошибка. Для игры не нужно |

### Solved (результат)

| Поле | Тип | Смысл |
|---|---|---|
| `iters` | `usize` | сделано итераций |
| `stop` | `StopReason` | причина остановки (ниже) |
| `residuals` | `Residuals` | достигнутые невязки **выданного** поля на итерации `iters` (до `finalize`) |
| `history` | `Vec<Check>` | проверки невязки `{it, res, t_s}`; последняя всегда на `iters` (если остановка не на плановой проверке, делается лишняя). `t_s` — секунды от начала итераций |
| `state` | `State` | выданное поле **после** `finalize` (как `AirPicardJob.state()` после фазы final); годится как `init` следующего вызова |
| `snapshots` | `Vec<State>` | снимки по `snapshot_at` |
| `timing` | `Timing` | `total_s`, `setup_s`, `iter_s`, `iters_run`, `check_s`, `n_checks`, `pool_threads`, `cpu_s` (только Linux, иначе 0), `phase_s: Option<[f64;5]>` — секунды по фазам `[mom, heat, proj, kupd, other]` |
| `dev` | `Option<Dev>` | отклонение от `sol_*` случая (`u_rel`, `th_abs`, `p_rel`, `div_rms`, …); **`None` для случая без эталона** (игровой вход; R6 v3), `Some` — если у случая есть `solution` и все `sol_u…sol_p` (см. «Вход и выход») |
| `out` | `SolveOut` | то же, что выше, + `status`, `phase_s`, сырые снимки |
| `picard`, `pool` | `Picard`, `rayon::ThreadPool` | решатель с полями (`picard.f`) и пул вызова. Держат память; в игре отбросить после копирования `state` |

`StopReason` (`solver.rs`): `Converged` — критерий выполнен (все три невязки `rms` меньше допуска × `tol_scale`); `MaxIters`; `TimeBudget`;
`Diverged` — невязки не конечны или `mom_max > 50`. При совпадении на одной итерации приоритет: Diverged, Converged, MaxIters, TimeBudget.
`.as_str()` → `"converged" | "max_iters" | "time_budget" | "diverged"`.

`Residuals` (все `f64`): `mom_max`, `mom_rms`, `th_max`, `th_rms`, `thd_rms`, `div_rms`. Критерий — `mom_rms`, `th_rms`, `div_rms`.
Первая проверка — после `check_every` (10) итераций (у холодного случая Онгудая плюс 1 предварительный шаг: `it` = 11, 21, …; у тёплого — 10, 20, …).

### State (поля и единицы)

Все массивы `Vec<f32>` длины `dims[0]·dims[1]·dims[2]` (с ореолом 1), раскладка и индекс — в «Вход и выход». Это те же шесть полей, что у GPU-решателя игры (`AirPicardJob.state()`: `u, v, w, th, thd, p`); единицы СИ.

| Поле | Единицы | Смысл |
|---|---|---|
| `u`, `v`, `w` | м/с | составляющие ветра по осям x, y, z сетки случая (привязка осей к сторонам света — как у случая R1, здесь не перепроверялась) |
| `th` | К | θ′, отклонение потенциальной температуры |
| `thd` | К | θ′_d (нагрев); при `Q ≡ 0` везде 0 |
| `p` | реш. ед. | давление-подобная поправка проекции (для тёплого старта нужна, наружу не нужна) |
| `nu`, `nuh` | реш. ед. | турбулентные вязкости; `Option`; пишутся для анализа, при старте **не читаются** |
| `case`, `input` | — | имя случая и путь его `.json` |
| `it` | — | итераций до снимка (0 — начальное поле) |
| `dims` / `n` / `halo` | — | размеры с ореолом `[nxh,nyh,nzh]` / без `[nx,ny,nz]` / ширина ореола (всегда 1) |
| `residuals` | — | JSON-запись проверки, если снимок на проверке |

Числа, которых коду недостаточно, помечены «реш. ед.»: единицы `p`, `nu`, `nuh` в крейте не определены, игре они вне `finalize` не нужны.

## Вход и выход

### Вход — случай R1 v1

Формат — `docs/contracts/air-cascade.md` → «R1 v1». Кратко: пара `<случай>.json` + `<случай>.bin`; `.bin` — `float32` little-endian подряд, `arrays` в JSON —
`{имя: [смещение, длина]}` в числах `float32`; целые массивы (типы клеток, индексы) тоже `float32`. Раскладка 3D — **(NZ, NY, NX) с ореолом**,
индекс `(k·NY + j)·NX + i`; `dims = [NX, NY, NZ]` с ореолом, `nx, ny, nz` без (должно быть `dims = n + 2`, иначе ошибка).

| Что в JSON | Используется |
|---|---|
| `case, dims, dx, dz, z_bot, nx, ny, nz` | сетка (в метрах); `x0, y0, halo, mg_levels_xyz` читать не обязательно (сеткой V-цикла управляет крейт) |
| `params` | **все** параметры модели (`tau_cool, z0, pr_t, dtau_u/dtau_per_m, dtau_th, couple, mom_sweeps, heat_sweeps, vcycles, local_k, k_relax, cs_h`) — решатель берёт их из случая, не из умолчаний |
| `case_params` | `U10`, `U_aloft` |
| `criterion` | `tol_mom_rms, tol_th_rms, tol_div_rms, check_every`; `solution` и `history` **необязательны** (эталон; без `history` `pre_steps` берётся из `criterion.pre_steps`, по умолчанию 0) |
| `crop` | необязательно: окно у старта (для `dev.crop`) |

Массивы (все длины `NX·NY·NZ` с ореолом): `cell, tu, tv, tw` (типы клеток и граней), `nu_bg, Q, gam, cplz, sp_u, sp_w, spc, ubg, vbg, lam, Kx, Ky, Kz,
fixed_u, fixed_v, b_u, b_v`; рельеф `hc` — `nx·ny` без ореола. Недостающий ключ или массив, смещение за концом `.bin` — ошибка, не умолчание.
**Случай без эталона (R6 v3, вход игры).** `sol_u, sol_v, sol_w, sol_th, sol_thd, sol_p` (массивы), `solution` и `history` (ключи JSON) необязательны — и в файле, и в `Case`,
собранном в памяти (`Case.solution = None`, `Case.history_ref = None`, массивы `sol_*` не вставлять; `Case::has_reference()` — есть ли эталон целиком).
Без эталона `api::solve` решает как обычно, `Solved.dev = None`, остальные поля `Solved` от эталона не зависят; поле `state` побитно такое же, как у
того же случая с эталоном (тест `no_reference_case_solves_like_with_reference`). Файл R2 такого прогона: `dev` с `null`-полями, `dev_crop`, `iters_ref`,
`history_ref` — `null`; CLI `--diag` без эталона — ошибка. С эталоном всё как раньше (сверка `dev`, путь решения тот же).

`Case::load(path)` — единственный читатель. Структура `Case` (`case.rs`) состоит из публичных полей, `arrays: HashMap<String, Vec<f32>>` в том числе, поэтому
случай можно собрать **в памяти** без файлов; такой путь в крейте не тестировался (не проверено), а `pre_steps` в `criterion` тогда задаётся самим
(`Case::load` выводит его из `history[0].it`, без `history` оставляет значение из файла/0; для игрового случая без эталона — 0).

Как случай получает игра: `scripts/atmosphere/air_model/air_place.gd:domain_case(detail, water, loc, dx, hour, u10, wdir, …) -> AirCase` собирает вход
(`AirCase.dims()` = `nx+2, ny+2, nz+2` — та же раскладка с ореолом, `air_case.gd`); в `air_runtime.gd:_start_picard(c)` он уходит в `AirPicardJob`.
Образец, как вход часа снимается кодом игры: `tools/research/air_cascade/warm/dump_inputs.gd` (PR-3). Как порождены случаи Онгудая (`f64`,
`$AIR_CASCADE_DATA/ongudai/`, вне git) — `tools/research/air_cascade/export/README.md`. Готовые маленькие случаи в git —
`tests/atmosphere/fixtures/air_model/ref/{flat_wind,agnesi,heated_slope,saddle}.json`.

Два решения игры — **два случая**: «mech» (без нагрева, `Q ≡ 0`) и «heat»; `AirPicardJob` решает их подряд (`_job.mech = true`), крейт — двумя вызовами `solve`
с двумя `Case` (на Онгудае есть `…_mech` и `…_heat`).

### Выход

`Solved.state` — `State` (таблица выше): `u, v, w, th, thd, p, nu, nuh` в той же раскладке, что вход, и после `finalize(10)` — как `AirPicardJob.state()` и
вход `field()`/`_build_field` (`air_picard_job.gd`: `u, v, w, th` решения с нагревом; `w_mech` — `w` решения без нагрева; `WindField` собирает игра). Как
соотносятся **единицы и ориентация** с `WindField`: поля те же буферы (`u, v, w, th, thd, p` в `AirPicardJob.state()`), но сборку `WindField` из массивов Rust
проверять предстоит интегратору (не проверено).

`State::write_atomic` пишет R4 v2: `{format: "picard-rs-state", version: 2, case, input, it, dims, halo, nx, ny, nz, dtype: "f32", residuals, host, arrays}` +
`.bin` (массивы `u, v, w, th, thd, p[, nu, nuh]` подряд, `float32` LE). Чтение: обязательны `u, v, w, th, p`; отсутствующий `thd` — нули; другой
`format/version/dtype` или размеры — ошибка.

## Тёплый старт

`SolveOpts.init = Some(State)` — поле прошлого решения **на той же сетке** (как игра в полёте / втором проходе загрузки). Что делает крейт (`Picard::init_warm`,
повторяет `air_picard_job.gd:_program("warm")`):

1. `check_dims`: сетка снимка (`dims`, `n`, `halo`) и длины всех массивов должны точно совпасть с сеткой случая, иначе **ошибка** (подгонки нет; игра тоже
   отказывает: `AirPicardJob` — «тёплый старт другого размера»).
2. Из снимка берутся `u, v, w, th, thd, p`; `nu`/`nuh`, K (местное и фоновое) и весь остальной вход — заново из случая.
3. Граничные условия — по полю (`apply_bc`), затем **4 V-цикла** проекции (вместо 30) без изменения `p`.
4. Проверки считаются с итерации 0 (`pre_steps = 0`): первая — на 10-й итерации.

**Оба решения греются отдельно**, как `air_runtime.gd:_start_picard`: `_job.warm = pair.mech`, `_job.warm_heat = pair.heat` (`pair = _prev_pair()`, пары собираются
`_warm_next.mech = _building.state(true)`). Для Rust: `init` вызова с mech-случаем — прошлый **mech**-`State`, вызова с heat-случаем — прошлый **heat**-`State`;
чужой не подставлять (размеры совпадут, физика — нет). Снимок хранить на стороне игры: `Solved.state` одного вызова — `init` следующего.

Сколько стоит (PR-8, холодный сошедшийся h1200 → h1215, 8 потоков, до итоговой оптимизации): 10 итераций (0,63 с) дают Δw ≈ 0,025 м/с у старта; тёплый сходится за
≈ 20 итераций (`out/residual/PR-8/README.md`). Пара mech h1200/h1215 вырождена (PR-3). Окончательное время тёплого старта и цепочка T→T+15→T+30 — в итогах PR-w
(см. «Числа»). Если снимок уже сошёлся на тех же условиях, тёплый вызов остановится на первой проверке (проверено на `flat_wind`: `iters=10`).

## Нити и вызов в фоне

- `solve` **блокирует**. Звать из своего потока Rust (`std::thread::spawn`), не из главного потока Godot и не из `_process`. Внутри вызова работает свой
  `rayon::ThreadPool` из `opts.threads` потоков (создаётся и закрывается на вызов; время создания входит в `timing.setup_s`).
- Игре нужны две политики: старт игры (загрузка) — **все ядра** (`threads: 0`); фон в полёте — часть ядер, оставляя кадр игре (`threads: N`, N — настройка).
  Число потоков меняет только время, не результат (побитно, на одной ветке ISA). Два одновременных `solve` с разными `threads` независимы (тест `tests/api.rs`).
- Передавать в поток Rust **только свои буферы** (`Vec<f32>`, `State`, `Case`): объекты Godot (`Gd<…>`, `PackedFloat32Array` как ссылка) через потоки не ходят.
  Копировать данные из `PackedFloat32Array` в `Vec<f32>` в главном потоке, результат возвращать так же — через канал/общий `Mutex<Option<Result>>`.
- Опрос: образец — `tools/research/rust_ext/gdext_probe` (`rust/src/lib.rs`: `start()` запускает `std::thread`, `is_done()` / `take_result()`; главный поток не
  завис: 148 кадров за 1000 мс, наибольший интервал 7–10 мс; GDScript опрашивает `is_done()` раз в кадр). План и проба gdext — `docs/plan/rust-ext.md`, раздел
  «Проба gdext на Godot 4.7.2» (`.dpcli/dpcli docs section docs/plan/rust-ext.md "Проба gdext"`). Rayon внутри gdext-библиотеки пробой **не проверялся** (не проверено).
- `time_budget` — для фонового пересчёта: поле выдаётся по истечении бюджета (`stop = TimeBudget`), невязки в `residuals`; годность неполностью сошедшегося поля
  решает порог `tol_scale` (ниже) — бюджет отдаёт то, что есть.
- Отменить идущий `solve` нельзя (флага отмены нет): ограничивать `max_iters` / `time_budget`. Паники: `panic = "abort"` в release-профиле — паника убивает процесс
  (профиль применяет корневой крейт сборки, не зависимость; в gdext-проекте он задаётся в его `Cargo.toml`).
- Память: на Онгудае 400 м (98×98×52 ≈ 0,5 млн клеток с ореолом, 2 МБ на массив) `State` ≈ 16 МБ (8 массивов), столько же — рабочие поля `Picard` внутри `Solved`.

## Сборка

- Крейт `picard_rs` 0.1.0, edition 2024 (Rust ≥ 1.85; проверялся rustc 1.97.1, сообщает `PICARD_RUSTC_VERSION` в `build.rs`), `publish = false`.
  Подключение как зависимость: `picard_rs = { path = "…/tools/research/air_cascade/picard_rs" }` (единственная фича `base_only` — для тестов, по умолчанию выключена).
- Профиль release (`Cargo.toml`, только читать): `opt-level = 3`, `lto = "fat"`, `codegen-units = 1`, `panic = "abort"`. Сборка:
  `cargo build --release --manifest-path tools/research/air_cascade/picard_rs/Cargo.toml` (пример — `… --example integrate`).
- **multiversion**: горячие ядра собираются в двух ветках — `x86_64+avx2+fma` (x86-64-v3) и базовая x86-64; ветка выбирается во время работы по процессору
  (без `RUSTFLAGS` и сборки под процессор сборщика). **Процессоры без AVX2 не поддерживаем**: базовая ветка собирается и работает, но не оптимизируется и не
  мерилась. Проверка ветки: `target/release/picard isa` → `isa_branch=x86_64+avx2+fma` (проверено на Xeon E5-2666 v3). На aarch64 (и с фичей `base_only`)
  — один вариант кода без FMA (собирается по коду, не проверялось). Ветки различаются округлением (FMA) — побитное совпадение между ветками не обещается.
- Зависимости (README → «Зависимости»): `rayon` 1.12, `serde`/`serde_json` 1, `multiversion` 0.9.2, `anyhow` 1, `clap` 4 (только `picard` CLI); pure-Rust,
  без `-sys`, `cc`, `cmake`; лицензии MIT / Apache-2.0.
- Windows и macOS: не собирались и не запускались (так и считать). `cpu_seconds()` на них вернёт 0.
- Чего крейт **не** делает (README → «Отличия от эталона и допущения»): не готовит случай (рельеф, K_b, губки, нагрев, типы клеток); не знает фаз `AirPhaseJob`,
  заморозки колонн, карты ω, `z_i` по столбцам; не имеет GPU-пути, окон (nest), переноса второго порядка (`adv2`), грубой сетки (`warm_coarse`); не пишет `WindField`.

## Числа

Итоговые замеры PR-12 (итоговый код, Онгудай 400 м, 96×96×50, Xeon E5-2666 v3, AVX2+FMA, под замком `cpu`, один прогон на точку; полно — `out/final/README.md`).
Время `solve` целиком, с (итерации); тёплый — из поля прошлого срока, цепочка h1200 холодный → h1215 → h1230:

| Что | tol_scale | 2 потока | 3 | 6 | 8 |
|---|---|---|---|---|---|
| Загрузка, u3_heat (191 / 111 ит.) | 1 / **5** | 31,3 / **18,7** | 23,5 / **14,4** | 12,7 / **7,6** | 10,3 / **6,2** |
| Загрузка, u3_mech (231 / 141 ит.) | 1 / **5** | 29,5 / **19,2** | 22,3 / **14,4** | 12,2 / **7,6** | 10,0 / **6,2** |
| Загрузка, u6_heat (131 / 81 ит.) | 1 / **5** | 22,0 / **14,8** | 16,5 / **10,4** | 8,8 / **5,7** | 7,2 / **4,6** |
| Загрузка, u0_heat (201 / 61 ит.) | 1 / **5** | 32,4 / **10,5** | 24,8 / **8,2** | 13,3 / **4,4** | 10,7 / **3,5** |
| Тёплый T+15 (h1215) | 1 (20 ит.) / **5** (10 ит.) | 3,78 / **2,03** | 2,78 / **1,56** | 1,62 / **0,91** | 1,28 / **0,75** |
| Тёплый T+30 из тёплого (h1230) | 1 (90 ит.) / **5** (20 ит.) | 15,6 / **3,65** | 11,4 / **2,86** | 6,24 / **1,57** | 5,06 / **1,29** |
| Холодный h1230 (261 / 151 ит.) для сравнения | 1 / **5** | 45,1 / **26,1** | 33,2 / **19,7** | 18,1 / **10,8** | 14,6 / **8,6** |

До оптимизации (PR-1, tol 1, 8 потоков): u3_heat 21,1 с, u3_mech 21,0, u6_heat 15,2, u0_heat 22,2 — итоговый код ×2,0–2,1 быстрее при тех же итерациях и полях.
Срок пересчёта: 15 игровых минут = 900 с при `time.speed` 1, 15 с при ×60 (`configs/atmosphere.json:321`, `configs/world.json:44`); тёплый tol 5 занимает 0,1–4 % срока при ×1/×10 и 5–24 % при ×60.
Конец цепочки (тёплый h1230 tol 5 против холодного сошедшегося): у старта Δw 0,009, Δ(u,v) 0,036; склоны Δw 0,026 (Δwt 0,058); термики Δw 0,015 м/с — в пределах порога.
Точность порога `tol_scale = 5` по холодному старту — `out/residual/PR-8/README.md` (8 потоков, код до итоговой оптимизации; итерации и отклонения те же, время в таблице — до оптимизации):

| Случай (холодный) | Итераций при `tol_scale` 5 | Время, с | Старт Δw / Δ(u,v) max, м/с | Склоны Δw / Δwt max, м/с |
|---|---|---|---|---|
| u3_heat | 111 | 6,53 | 0,002 / 0,016 | 0,007 / 0,013 |
| u3_mech | 141 | 6,77 | 0,008 / 0,034 | 0,025 / 0,064 |
| u6_heat | 81 | 4,75 | 0,005 / 0,021 | 0,020 / 0,043 |

Эталон — `tol_scale 1`: 191 / 231 / 131 итерация. Случай u0_heat (штиль) критерием невязки не фиксируется — не разбирать (решение пользователя). Вывод PR-8: на
`tol_scale 5` ускорение холодного старта всего ×1,6–1,7, а у старта отклонение в пределах порога вариометра.

## Ограничения и непроверенное

- Проверено на сетке 400 м (Онгудай, 96×96×50, dz 105 м) и малых случаях `ref/`. Сетки 200 м и окна 100/50 м (клипмап) **не запускались** — размеры и время
  не известны.
- Windows и macOS не проверялись; gdext-пробы — только Linux x86_64 (Godot 4.7.2).
- Rayon внутри gdext-библиотеки, фон при работающем кадре игры, экспорт игры с расширением — не проверялись.
- Сборка `WindField` из массивов Rust, соответствие осей и единиц игре — по именам и коду GDScript, запуском не сверялось.
- Тёплый старт сверен на паре Онгудая h1200→h1215 (PR-8); для остальных пар и для mech (вырождена) — нет.

## Пример вызова

Файл `examples/integrate.rs` (тот же код): читает случай R1 из `argv[1]`, холодный `solve` на 2 потоках с `tol_scale 5`, печатает причину остановки и невязки,
затем тёплый вызов от полученного `state`. Запуск (под замком `cpu`, как cargo в этом репозитории):

```
.dpcli/dpcli lock cpu <ID> --no-tmux -- cargo build --release --manifest-path tools/research/air_cascade/picard_rs/Cargo.toml --example integrate
tools/research/air_cascade/picard_rs/target/release/examples/integrate tests/atmosphere/fixtures/air_model/ref/flat_wind.json
# stop=converged iters=10 mom_rms=9.102e-5 th_rms=8.137e-8 div_rms=3.934e-7 total_s=0.07
```

```rust
use picard_rs::api::{SolveOpts, solve};
use picard_rs::case::Case;
use std::path::Path;

fn main() -> anyhow::Result<()> {
    let path = std::env::args()
        .nth(1)
        .expect("usage: integrate <case.json>");
    // Reads <case>.json and the <case>.bin next to it (R1 format).
    let case = Case::load(Path::new(&path))?;

    // Cold start: private pool of 2 threads, the global rayon pool is not touched.
    let opts = SolveOpts {
        threads: 2,
        tol_scale: 5.0,
        ..Default::default()
    };
    let r = solve(&case, &opts)?;
    println!(
        "stop={} iters={} mom_rms={:.3e} th_rms={:.3e} div_rms={:.3e} total_s={:.2}",
        r.stop.as_str(),
        r.iters,
        r.residuals.mom_rms,
        r.residuals.th_rms,
        r.residuals.div_rms,
        r.timing.total_s
    );

    // Fields with halo, layout (NZ, NY, NX), index (k * NY + j) * NX + i, f32.
    let s = &r.state;
    println!(
        "dims_halo={:?} cells={} u[0]={} w[0]={}",
        s.dims,
        s.n3(),
        s.u[0],
        s.w[0]
    );

    // Warm start of a later call on the same grid: pass the previous state as `init`.
    let warm = SolveOpts {
        threads: 2,
        tol_scale: 5.0,
        init: Some(r.state),
        ..Default::default()
    };
    let r2 = solve(&case, &warm)?;
    println!("warm stop={} iters={}", r2.stop.as_str(), r2.iters);
    Ok(())
}
```

В реальном вызове `solve` стоит в потоке Rust (см. «Нити и вызов в фоне»), а `Solved.state` копируется в буфер игры и сохраняется как `init` следующего пересчёта своего решения.
