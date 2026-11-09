---
type: "research"
status: "active"
module: "picard-terrain"
area: "air"
updated: "2026-11-09"
summary: "picard-terrain, этап 2: карта пути срезанных клеток в поле игры (dp-air) и разбиение встраивания PT-9…PT-12."
related: ["docs/plan/picard-terrain.md", "docs/contracts/picard-terrain.md", "docs/research/picard_terrain.md", "docs/research/rust-wind-field-path.md"]
conclusion: "Типы клеток игры задаёт один узел — столбцовый kf в AirCaseRs::prepare (case_prepare.rs:452); PT2 входит через hc_type и доли, фон/AGL остаются на настоящем hc. Читатели земли (Field::k1, фазы, поток окон) берут hc как границу воздуха и сводятся к типам. dp-air на ветке не собирается (case_build.rs:454)."
data: "tools/research/picard_terrain/out/PT-7/{levels,work,types_shift}.json (+скрипты)"
applied_in: ""
---
# picard-terrain, этап 2: путь срезанных клеток в поле игры

Разведка PT-7, код и Godot не запускались. Решения 2026-11-09: в игру — только срезанные клетки PT2, по умолчанию, без флага; старый путь маски убрать; побитность прежнего поля не нужна; замыкание, калибровку, `vf_min` = 0,05, 17 точек на ребро и `AF_FLOOR` = 1e-3 не менять. Пути от корня, строки — ветка `feature/picard-terrain` (`85cbaf6af`). «Расчёт» — формулы кода на растрах мест `tests/fixtures/wind/places` (скрипты `tools/research/picard_terrain/out/PT-7/`); «оценка» — не замер.

PT2 в решателе: `rust/picard_rs/src/cut.rs:1-30`; рецепт случая — `tools/research/picard_terrain/cut.py:1-34`, `build` (:122-205): доли `vf`, `af_u/v/w` из растра; типы по `hc_type` = низ первой клетки с `vf ≥ vf_min` (`type_height`, :99-108); вход, зависящий от типов (`cell, tu, tv, tw, Kx, Ky, Kz, b_u, b_v, fixed_*`), — подготовкой на `hc_type`; фон `ubg/vbg` — от **настоящего** `hc` (:136-141); затем полная клетка (`vf ≥ 1−1e-6`, :150-156) и пол грани (:158-163); `cut_cells = true`. Остальное (`hc, nu_bg, Q, gam, sp_*, lam`) — из случая PT1 без изменений (:171-178). Построитель в Rust — PT-8 (PT6 v1, `docs/contracts/picard-terrain.md:99-115`), считается готовым API.

## 1. Путь поля и уровни

Проход `solve_pass` (`rust/dp-air/src/field/runtime.rs:1060`): `domain_for` (:414) → `build_level` ×2 — 1200 и 400 м через `rayon::join` (:847, :1075-1078) → `phases_of` (:889, случай с нагревом) → `coarse_start` (:1040; mech+heat на 1200 м, `prolong_to`) → `solve_one` mech (:1184) и heat (:1187) → `build_field` (:1320) → `windows_of` (:1261) → `solve_windows` (`clipmap.rs:422`).

Уровень (`build_level`, `runtime.rs:847-873`): `weather_for` → `build_domain_input` (`place_input.rs:213`) → `build_case` (`case_prepare.rs:144`) → `without_heat` (:378) → `prepare()` ×2 (:424) → `build_solver_case` ×2 (`case_build.rs:202`). mech и heat обязаны иметь **одни** типы и доли.

| уровень | где строится | рельеф | сетка (внутр.) |
|---|---|---|---|
| 1200 м (старт) | `build_level(coarse_dom)` (`runtime.rs:1075`), `coarse_domain` (:447), `picard_coarse_factor = 3` (`configs/atmosphere.json:295`) | `block_mean` (`weather_core.rs:753`), 48×48 узлов 25 м на клетку | 32×32×nz |
| 400 м (область) | `build_level(fine_dom)`, `DX = 400` (`runtime.rs:83`), `domain_for` (:414-444) | 16×16 узлов | 96×96 при `domain_l_m = 38400` (`configs/atmosphere.json:288`), меньше, если место меньше |
| окно 100 м | `window_case` (`clipmap.rs:383`) → `build_window_input` (`window.rs:180`) | 4×4 узла | 64×64 (`N_WINDOW`, `window.rs:66`), `dz = dx/2 = 50 м` (:102), `window_levels_m = [100, 50]` (`configs/atmosphere.json:338`) |
| окно 50 м | то же, родитель — окно 100 м | 2×2 узла | 64×64, `dz = 25 м` |

Растр места 25 м, `heights()` — строки `j` к югу (`place_input.rs:16-17`); области решателя — `j` на север (:13-14). PT6 `Raster` ждёт `j` на север, значит PT-9 разворачивает строки (`y = −z`). Область и углы окон кратны 25 м (`window.rs:88-97`), поэтому при 17 точках на ребро шаг точек (расчёт) — **25 м (400 м)**, 75 м (1200 м), 6,25 м (100 м), 3,125 м (50 м): на 400 и 1200 м точки = узлы растра; на окнах — билинейность внутри ячейки 25 м, как у `ground_height` (`runtime.rs:394`). Подсетка игры — 25 м (в опыте 30 м, `docs/contracts/picard-terrain.md:41-43`): меньше 25 м срез ничем не разрешается.

Размеры (расчёт, `levels.py`; `dz = 105 м` при `dx ≥ 200`, `place_input.rs:222-227`; блочное среднее по узлам 25 м, `nz` ±1):

| место | рельеф, м | 400 м: nx·ny·nz (клеток с ореолом) | 1200 м | столбцов 400 м с перепадом > `dz` в клетке |
|---|---|---|---|---|
| ongudai (1601², 25 м) | 507…2511 | 96·96·50 (499 408) | 32·32·48 (57 800) | 6970 из 9216, макс. 383 м |
| synthetic (801²) | 360…1404 | 36·36·40 (60 648) | 12·12·40 | 9 из 1296, макс. 110 м |
| training_island | 0…504 | 96·96·36 (364 952) | 32·32·34 | 78 из 9216, макс. 277 м |
| volcano_island | −0,5…508 | 96·96·36 (364 952) | 32·32·34 | 104 из 9216, макс. 299 м |

Окно: `66·66·(⌈(R+2000)/dz⌉+3)` (`window.rs:68,101-109`, `R` — перепад окна; формула). Предел R1 2^24 клеток (`case_build.rs:72,216`) не задет (макс. ≈ 3 %).

## 2. Где строятся типы клеток

Тип клетки задаёт одна столбцовая величина `kf` (первая воздушная клетка), остальное выводится.

| шаг | файл:строки | что делает | что заменить |
|---|---|---|---|
| 1. `hc` | `place_input.rs:220` (окна `window.rs:188`) | `block_mean` → `DomainInput.hc` (:66) | `hc` остаётся (AGL, фон, `z_i`, `w*`); добавить `hc_type` и доли `vf/af_*` (`type_height`, `fractions`, `finish`) |
| 2. сетка по высоте | `place_input.rs:222-227`, `window.rs:101-109` | `dz`, `z_bot = ⌊min(hc)/dz⌋·dz − dz`, `nz` | не менять; доли строить на ту же `CutGrid`; подсетка ниже `z_bot` — клетка k=1 полна (`clip`) |
| 3. случай | `case_prepare.rs:144-200`, `AirCaseRs` (:114-135), `without_heat` (:378) | `hc` копируется | добавить `hc_type`, доли (общие для mech/heat через `Arc`: без него 4 массива f32 копируются дважды) |
| 4. `kf` | `case_prepare.rs:444-463` | наименьшее `k ≥ 1`: `zc(k) ≥ h` | считать от `hc_type`: низ клетки `k` = `z_bot + (k−1)dz`, формула :454 даёт ровно `k` (расчёт); брать `round((hc_type − z_bot)/dz)`, не `ceil` по равенству `f64` |
| 5. плоскости | `case_prepare.rs:203-240`; `col` 0 = `hp`, 1 = `kf` (:644-645) | `hp` — настоящий рельеф | `hp` не менять (`case_build` читает для фона и `nu_bg`), `kf` от `hc_type`, добавить 4 массива долей |
| 6. типы клеток/граней | `case_prepare.rs:260-282`, `case_build.rs:129-153,234-258`, `window.rs:328-374` `tcode` | из `kf` | не менять (`cell = 1 ⇔ vf ≥ vf_min`, контракт :54-55) |
| 7. неизвестные | `case_prepare.rs:464`, `count_unknowns` (:803-840) | по `kf` | автоматически |
| 8. фон, баланс | `case_prepare.rs:299-350`, :710-742 `fixed_scale`; `case_build.rs:276-309,398-416` | профиль по `hp`, грани по `kf` | как `cut.py:136-141`; баланс по полным площадям остаётся, решатель пересчитывает по открытым (`case.rs:426-428`, `cut.rs:225`) |
| 9. `K_b`, `Q` | `case_build.rs:330-370`, `case_prepare.rs:655-707` | по `hp`, `kf` | в опыте не менялись, `Q` = 0 (`heat: false`); для игры — раздел 6, пп. 1-2 |
| 10. `Case` | `case_build.rs:427-497` | массивы R1 | добавить `vf, af_u, af_v, af_w` (:427-452), `cut_cells = true`; литерал `Params` (:454-468) **не собирается** (раздел 5, PT-9 шаг 0) |
| 11. окно | `window.rs:627-667` | `build_solver_case`, затем `fixed_u/v` и `Case.nest` от родителя | доли идут из `pl` окна; поток границы — раздел 3, п. 8 |

Не затрагивается: классы поверхности и `z0` (`place_input.rs:230-231`), погода и профиль притока, поток тепла, `z_i` (`zi_columns`, :187, по `hc + zi_min`), `gam`, губки (`case_prepare.rs:478-532`), замыкание по столбцам (:563-635), `lam`, `Kx/Ky/Kz` (`case_build.rs:372-396`, без умножения на доли, как требует PT2 v1).

Стоимость долей (оценка по числу точек): слой целиком над/под рельефом столбца даёт `vf` 1/0 без перебора (PT6 v1). Смешанных слоёв (расчёт, `work.py`, слои между min и max рельефа столбца) и выборок `×289`: ongudai 400 м — 22 481 слой, 6,5·10⁶ выборок; ongudai 1200 м — 4601, 1,3·10⁶; training_island 400 м — 9388, 2,7·10⁶; volcano_island — 9655, 2,8·10⁶; synthetic — 2017, 0,6·10⁶. Грани — тот же порядок ×2…3. Порядок 0,1…0,2 с на одном потоке при ~10 нс на выборку (оценка), против минут решения; измерить — PT-8/PT-11. Окно: 64²·≈3 слоя·289 ≈ 3,5·10⁶ выборок при каждом сдвиге (`window_shift_frac = 0,25`, `configs/atmosphere.json:340`; оценка).

Сдвиг типов (расчёт `types_shift.py`, моя реплика правил PT6 на растре места, не код PT-8): `kf_new − kf_old` на 400 м — ongudai: −1 в 6691 из 9216 (73 %), −2 в 131, 0 в 2394; `hc_type − hc`: медиана −79 м, −215…+5 м; training_island: 0 в 8932 (97 %); volcano_island: 0 в 8736 (95 %); synthetic: −1 в 722 из 1296. На 1200 м ongudai до −3 клеток (медиана −138 м). Воздушный слой у склона толще на 1–2 клетки.

## 3. Потребители у земли

`hc` в потребителях играет две роли: настоящая земля (AGL, профили, высоты источников) и граница воздушных клеток (индекс первой клетки). PT2 разделяет их: вторую роль берут типы (`kf`/`k1`), первую оставляет `hc`.

| № | потребитель | файл:строки | меняется? | что сделать |
|---|---|---|---|---|
| 1 | `Field::k1` | `wind_field.rs:335-355`: `k1 = ceil((hc − z_bot)/dz − ½)`, `a1 = max(z(k1) − hc, 2·z0)` (:350) | **да, критично** | `k1` из типов (`kf − 1`): в `from_mac` (:176-241) — первая `cell == 1` столбца; `from_arrays` (:246; тесты, кеш) — по-прежнему от `hc` |
| 2 | выборка | `col_vel`, `col_scalar` (:646-716), `shift` (:556): `z = y + (hcol − h)·e^(−agl/dx)`, ниже центра `k1` — лог-профиль от `hcol` | **да** | центр `k1` теперь часто ниже `hc` (73 % столбцов ongudai): `a1` уходит в зажим, лог-профиль не работает. Выбор «эффективной земли» для выборки: A — оставить `hc`; B — низ открытой части первой клетки по долям. Решение PT-10 по числам (раздел 6, п. 3) |
| 3 | пограничный слой | `wind_field.rs:379-432`: `u*` по клетке с центром ≥ `dz/2` над `hc` (:403), `U_out` в слое `A_OUT` = 600 м над `hc` | да, мало | правило :403 само отбросит клетки ниже `hc + dz/2`; проверить `u*`, `desc` до/после |
| 4 | кеш | `runtime.rs:487-510` (`"format": 1`, :493); `field_cache.rs:78`, `decode` (:176); `solved.rs:18-21` (`VERSION = 1`), :159-181, :260 | **да** | поле старого кода подойдёт по ключу и подменит новое: поднять `format` ключа до 2 (или `"cut": {…}`) — чужой ключ отвергается и удаляется. `k1` хранить в файле поля (необязательный массив, нет — от `hc`), иначе поле из кеша (`from_arrays`) и свежее разойдутся |
| 5 | GDScript-копия `WindField` | `scripts/atmosphere/air_model/wind_field.gd:289` (свой `k1` от `hc`), `air_field_import.gd:53-67` | да (отладочные виды) | экспорт несёт `k1` (контракт W3 v4, вне PT) или вид покажет разницу; PT-12, низкий приоритет — игровую выборку делает Rust (`atmosphere.gd:4,884`) |
| 6 | фазы | `phase/assembly.rs:179-186` `halo_hc`, :293-330 (клетки `z < hc` пропускаются), :334 `air = zc(k) ≥ hh[col]`; `layers.rs:93`; `prepare.rs:88,108,626` | **да, критично** | `warm`/`freeze` строятся только в клетках `zc ≥ hc`, ниже — нули; при `kf_new < kf_old` клетки между ними решатель считает воздухом и замороженные колонны фиксируют в них 0. Условие «воздух» — по `hc_type` (поле в `PhaseCase`, `prepare.rs:62`, литерал `runtime.rs:900` и 5 тестов); `zagl = zmsl − hc` (:217) и сток остаются на настоящем `hc` |
| 7 | родитель → окно | `level.rs:208-300` (`pcen`: земля родителя = 0), :404 `nest` | да, мало | кода нет; меньше нулей у склона; проверить границу окна у земли |
| 8 | поток границы окна | `window.rs:396-438` `boundary_flux` (площадь `dx·dz` у **всех** граней типа 2), :440-472, :475-513 | **да** | решатель при `cut_cells` перебалансирует `fixed_u/v` по открытым площадям (`case.rs:426-428`, `cut.rs:225-263`); `w` верха (`Case.nest.ubw`) — нет. Площади с `af` — `rebalance` станет тождеством (`r ≈ 1`, `cut.rs:252`) |
| 9 | термики | `terms/thermal_air/mod.rs:405-452` (`k1`: начало `W̄`; `hc`: `h0 = z_i − hc`), `pick.rs:68-100`, :838 | да, мало | `W̄` на 1–2 нижние клетки больше; источники по настоящему `hc`; проверить `terms_thermal_air.rs` |
| 10 | без изменений | `ground_height` (`runtime.rs:394`, `terms/{turb,sum,analytic,waves,thermal}`); `w*`, `hmix`, `edge_weight` (`wind_field.rs:436-470,510`); облака (`terms/clouds/sources.rs:222-225`); `shift_warm` (`level.rs:461-620`, по `tc` окна); `prolong` (`level.rs:172`); `ClipMap`/`FieldSet` | нет | `hc` настоящий либо типы согласованы |

Сшивка уровней: у области и окон разные `dz` (105 / 50 / 25 м) и разные типы, поле у земли читается из разных `k1` — как и с маской; при срезанных клетках разница «первой клетки» между уровнями меньше (кроме варианта A п. 2).

## 4. Тесты и эталоны, которые изменятся

Дампы GDScript/GPU сняты со старого пути; пересобрать их нельзя (GDScript срезанных клеток не умеет). Приём: вход `hc_type = hc` и без долей даёт плоскости и буферы побитно как в дампе — тест остаётся регрессией кода переноса; поведение с долями — новые тесты-свойства.

| тест | что сверяет | реакция | решение |
|---|---|---|---|
| `dp-air/tests/case_prepare.rs` (:1-10; `DomainInput` :377, :473) | плоскости `prepare` против `tests/data/case_prepare` | `kf`, `n_unk` другие | режим без долей — регрессия; свойства `kf ↔ hc_type`, `vf ↔ cell` |
| `case_build.rs` (:1-12) | `tcode`, `ubg`, `Kx`… против GPU; решение Онгудая 400 м (`#[ignore]`) | типы и `ubg` другие | без долей — `K_SETUP`; решение Онгудая перемерить с долями, пороги `div_rms` не менять |
| `window.rs` (:1-14; :177), `clipmap.rs` (:759) | окно, граница, сдвиг против GPU (`tests/data/window`, 15 МБ) | типы окна другие | без долей — регрессия; GPU-сверку окон снять; стык — по свойствам |
| `field_input.rs` | `build_domain_input` против дампа | `hc`, сетка те же | старые ассерты остаются, новые поля — отдельно |
| `runtime.rs`, `acceptance.rs` | оркестровка, итерации (`t4a_*`: `coarse < cold`), AP-20 (`#[ignore]`) | итерации другие | свойства сохранить, точные числа AP-20 пересчитать (PT-11). `t1_*` из шапки (:14) в файле **нет** (grep `fn t1_` пуст) |
| `wind_field.rs` (8 вызовов), `terms_*` | `Field` против дампа GDScript | не меняется при `from_arrays` от `hc` | не трогать; новые тесты `from_mac` с `cell` |
| `phase_assembly.rs:126`, `phase_mech.rs:92`, `phase_f_base_wind.rs:39`, `phase_classifier.rs:88`, `freeze_thd_v11.rs:91` | фазы против дампа | не компилируются без поля `PhaseCase` | механически `hc_type = hc` |
| `field_export.rs`, `formula_facade.rs`, `step_cost_same.rs` (RW-15, побитно, плоское место 401²) | выдача поля, шаг | числа поля другие; `step_cost_same` **остаётся прежним** (`vf ≡ 1` = маска) | первый ассерт PT-9 |
| `tests/fixtures/wind/cases/*` + `dp-stand compare` | W8-эталон старого поля игры | `compare` начнёт падать | вопрос координатору (раздел 6, п. 6) |

Прежними: `picard_rs/**` (`cut_cells = false` — побитно R1, `cut.rs:28-30`), `level.rs`, `weather_*`, `terms_*` кроме `thermal_air`. GDScript: `tests/atmosphere/{test_wind_field,test_air_field_import,test_air_model_atmo,test_start_air_gpu,test_air_status_iters_gpu,test_ridge_starts}.gd`, `tests/contracts/{test_air_field_contracts,test_rust_wind_purity}.gd`; остальные `test_air_*.gd` — одни `.uid` (перенесены в Rust). `air_case.gd` — GDScript-эталон, в `scripts/` от него остались константы (`wind_profile.gd:128-139`).

## 5. Разбиение

Порядок: PT-8 (`cut_build`) → PT-9 → PT-10 (старт от результата PT-9; файлы не пересекаются) → PT-11 (нужны оба) → PT-12.

### PT-9. Встраивание: случай области, грубого старта и окон

**Шаг 0, отдельным коммитом:** `case_build.rs:454` — литерал `Params` без `adv2`, `limiter`, `cut_cells`: `cargo check --offline -p dp-air` на ветке падает `E0063` (проверено 2026-11-09, единственная ошибка). Добавить `adv2: false, limiter: 0, cut_cells: true`.

Делать: (1) `place_input.rs`, `window.rs::build_window_input` — `hc_type` и доли из `picard_rs::cut_build` (`Raster` из `place.heights()` с разворотом строк; `CutGrid { nx, ny, nz, x0, y0, dx, dz, z_bot }`; порядок PT6: `fractions` → `type_height` → типы → `finish`; `cell/tu/tv/tw` для `finish` строить из `kf` общим кодом с `PreparedPlanes::cell_type/face_type`, `case_prepare.rs:260-282`); (2) `case_prepare.rs` — `hc_type`, `kf` от него, `hp` настоящий, доли в `PreparedPlanes` (`Arc`); (3) `case_build.rs` — 4 массива долей и `cut_cells`; ветка без долей (`Option`) только для тестов дампов, в `build_level` и `window_case` всегда `Some`; (4) `runtime.rs` — ключ кеша (:493), `build_level`, `phases_of` (:900); `clipmap.rs::window_case`; (5) `phase/prepare.rs` — поле `hc_type` в `PhaseCase`/`Prepared.cols` (только плумбинг); (6) тесты раздела 4.

scope: `rust/dp-air/src/field/{place_input,case_prepare,case_build,window,runtime,clipmap,mod}.rs`, новый `field/cut_input.rs`, `field/phase/prepare.rs`, `rust/dp-air/tests/{case_prepare,case_build,window,field_input,clipmap,phase_assembly,phase_mech,phase_f_base_wind,phase_classifier,freeze_thd_v11}.rs`. dont_touch: `rust/picard_rs/**`, `field/{wind_field,solved,field_cache,field_set}.rs`, `field/phase/*` кроме `prepare.rs`, `rust/dp-air/src/terms/**`, `rust/dp-stand/**`, `rust/dp-gd/**`, `scripts/**`, `configs/**`, `docs/contracts/**`.

Проверки: `cargo check --offline -p dp-air` и `cargo test --offline -p dp-air --lib` — 0 ошибок. Плоское место: `vf ≡ 1` → плоскости и буферы побитно как без долей, `step_cost_same` прежний. Онгудай 400 м (96·96·50): `cell == 1 ⇔ vf ≥ 0,05` в каждой внутренней клетке; `vf = 1` ⇒ 6 граней = 1 (1e-6); грань типа 1 ⇒ `af ≥ 1e-3`; все доли в [0, 1]. Доли и `kf` у `case_m`/`case_h` совпадают побитно. Загрузка Онгудая (`tol_scale 5`, `cargo test --release -p dp-air --test runtime -- --ignored`): оба решения сошлись (`StopReason`), `div_rms ≤ tol_div_rms·tol_scale`, окна 100/50 м — то же, NaN в `Field` нет. Запись кеша с ключом `format: 1` отвергается.

### PT-10. Потребители у земли + время на стенде

Делать: раздел 3, пп. 1, 2, 4, 6, 8 (+ проверка 3, 9). (1) `wind_field.rs` — `k1` от `cell` в `from_mac`, вариант A/B п. 2 по числам; (2) `solved.rs`, `field_cache.rs` — необязательный массив `k1`, `VERSION`; (3) `phase/assembly.rs` (:179-186, 293-334), `layers.rs:93` — «воздух» по `hc_type`; (4) `window.rs` (**только** :396-513) — площади с `af`; (5) `rust/dp-stand` — подкоманда `timing` по `Formula::report()` → `JobReport` (`runtime.rs:665-677`: `wall_s`, `passes[].secs/iters/coarse_iters/phase_s/win_s`), нужна PT-11.

scope: `rust/dp-air/src/field/{wind_field,solved,field_cache}.rs`, `field/phase/{assembly,layers}.rs`, `field/window.rs` (:396-513), `rust/dp-air/tests/{wind_field,field_export,formula_facade,phase_assembly,terms_thermal_air}.rs`, `rust/dp-stand/src/{main,ops,setup}.rs`, `rust/dp-stand/README.md`. dont_touch: `rust/picard_rs/**`, `field/{place_input,case_prepare,case_build,runtime,clipmap}.rs`, `configs/**`, `docs/contracts/**`.

Проверки: `from_mac`: `k1` = первая `cell == 1` ровно в 9216 из 9216 столбцов Онгудая 400 м. Поле → файл → поле: `k1` совпадает побитно, файл старого формата читается. Выборка вдоль 1000 точек `z_agl` 1…200 м над склоном: скачок `|u(z) − u(z − 1 м)| ≤ 1 м/с`, NaN нет. Фазы: воздушных клеток замороженных колонн с нулевыми `u, v, w, θ'` не более 0,1 % (пороговое число уточнить после первого прогона). Окна: `|net|/|area| ≤ 1e-6` по открытым площадям после поправки; `rebalance` меняет `fixed_*` не более чем на 1e-6 отн. `dp-stand timing --case tests/fixtures/wind/cases/ongudai_strong.json --model formula` печатает json с `wall_s`, `passes[].secs`, `iters`.

### PT-11. Время и присутствие на dp-stand (dp-researcher)

Места: `tests/fixtures/wind/places/{ongudai, synthetic, training_island, volcano_island}`; случаи W8 — `tests/fixtures/wind/cases/` (`ongudai_{strong,medium,storm,wave,day_1..3}`, `synthetic_{strong,medium,weak,storm,wave}`). Команды `rust/dp-stand/README.md`: `sample --points "x,y,z;…"`, `slice --kind horizontal|vertical … --out` (`.bin` f32 `[ny][nx][4]` = vx, vy, vz, σ), `stats --slice` (средние, σ, квантили `vy` 5/50/95, `max_abs_vy`), `decompose`, `compare`; `--model formula` (детерминированный, `setup.rs:12-17`). Времени поля **нет**: `Session::go_to` (`setup.rs:121-139`) ждёт `Ready` и не печатает — нужен `timing` из PT-10 (иначе `RW6Q_MEASURE=1 cargo test --release -p dp-air --test acceptance -- --ignored measure_ongudai_load_matrix`, `acceptance.rs:855-860`).

Мерить: (1) время под `lock cpu`: загрузка (cold, с грубым стартом) и пересчёт (warm, слот 15 мин) на 4 местах до/после — стена, `iters`, `coarse_iters`, `secs [prep, coarse, solve, build]`, `phase_s`, `win_s`; «до» = `85cbaf6af` + шаг 0 PT-9, свой `CARGO_TARGET_DIR`; 3 повтора, потоки 2 и 8. (2) Время долей = `secs[0]` до/после против оценки раздела 2. (3) Присутствие (те же случай и точки): (а) разгон — скорость на гребне/бровке на `z_agl` 10, 30, 60, 100 м к наветренной равнине (`sample` вдоль линии ветра), `w` вдоль наветренного склона; (б) ротор за гребнем при сильном ветре — доля точек `u∥ < 0` в вертикальном разрезе через гребень (`u∥` — проекция на ветер), минимум `u∥`, высота и длина зоны. Критерий — «есть и не хуже», не совпадение со старым (память «присутствие важнее чисел»); опыт PT-1…PT-5 вернул 64–87 % пути к Askervein на 30–100 м (`docs/research/picard_terrain.md`), на 400 м ожидается меньше (оценка). (4) NaN/∞ нет, `edge_weight` непрерывен на границах.

scope: `tools/research/picard_terrain/out/PT-11/**`, этот документ (раздел «Замеры»). dont_touch: `rust/**`, `scripts/**`, `configs/**`. Проверки: таблица 4 места × (загрузка, пересчёт) × (до, после); отношение стены после/до для загрузки ≤ 1,2 (условие остановки плана; ориентир опыта ×0,8…1,15); таблица присутствия без NaN.

### PT-12. Godot и документы

Тесты headless под `lock cpu`: `godot --headless --path . res://tests/run_tests.tscn -- --filter=<подстрока>` (`.claude/workflow.md:130`; профиль `XDG_DATA_HOME=~/.cache/dp-xdg/$(basename "$PWD")`, первый запуск `--import`): `wind_field`, `air_field`, `air_model_atmo`, `start_air`, `air_status`, `rust_wind_purity`, `air_field_contracts`. **Автопилотный полёт у склона есть:** `tests/atmosphere/test_ridge_starts.gd` (бот `BotPilot.setup_ridge`, ветер 20 км/ч в склон, термики выключены, набор за 5 мин на 50–100 м AGL; `FLY_MINUTES = 5`, `WEAK_CLIMB_SITES`), запуск `--filter=ridge_starts` (время прогона измерить при первом запуске). Критерий: поле есть, NaN нет, набор не хуже «до» (`85cbaf6af` + шаг 0). Других автопилотов у склона нет (`tests/flight/pendulum`, `test_speed_hold`, `stability/test_matrix` — не по теме). Визуал — тестовая сборка Linux главной сессии (`.claude/workflow.md:132`). Документы: `docs/guide/air-model/{field-cpu,runtime}.md` («MAC с маской»), `docs/research/rust-wind-field-path.md`, `docs/guide/atmosphere.md` («Склон на стартах»), CHANGELOG. scope: `tests/atmosphere/**` (ожидания), `docs/guide/**`, `CHANGELOG.md`; dont_touch: `rust/**`.

## 6. Не решено, риски, границы

Для `uncertain` отчёта; замыкание и калибровка не менялись.

1. **Нагрев.** Опыт PT был без нагрева (`heat: false`, контракт :34). В игре `Q = h0/dz` кладётся в клетку `kf` (`case_prepare.rs:698-700`; CBL равномерно по `[ks, k1]`, :679-696) и остаётся «на единицу объёма» (`kernels.rs:402-404`, `cut.rs:12-13`): для клетки с `vf < 1` приток в столбец ≈ `vf·h0`. Делить ли на `vf` — вопрос замыкания; проверить баланс тепла (`Σ Q·vf·dz` против `heat_used`) в PT-11.
2. **`nu_bg` у земли.** `z = max(zc − hp, 0)` (`case_build.rs:344,356-358`): центр первой клетки ниже `hp` (73 % столбцов ongudai) даёт `K_b = k_fa`. Как в опыте (`cut.py:171`), но при клетке 400 м не проверено.
3. **Эффективная земля выборки** (п. 2 раздела 3): вариант B не проверен ни на Askervein, ни на Perdigão (там читалась подсеточная земля точки, PT5 v1, контракт :90-97).
4. **Срезанные клетки + окна + заморозка.** `Case.nest` (`case.rs:395-411`), заморозка (`Spec.freeze`) и `rebalance` вместе с `cut_cells` в опыте не бывали (область без `nest`, без фаз). Покрыть проверками PT-10/PT-11.
5. **Подсетка 25 м.** Опыт на 30 м; в окне 50 м клетка = 2×2 ячейки растра, срез почти плоскость: эффект на окнах ожидается меньше, чем на 400 и 100 м (оценка).
6. **Фикстуры W8.** `tests/fixtures/wind/cases/*.bin` — старое поле; `dp-stand compare` (допуск 0,05 м/с + 2 %) начнёт падать. Пересъём после PT-9 или явное снятие до PT-12 — решение координатора.
7. **Не проверено.** `cargo test` и Godot не запускались (только `cargo check -p dp-air` — `E0063`); время долей — оценка; `hc_type`/`kf` — скрипт, не код PT-8.

## 7. Замеры (PT-11)

Стенд `dp-stand --model formula`, до = `f44c66b4a`, после = ветка PT-11 (с PT-10). Скрипты, сырьё, воспроизведение — `tools/research/picard_terrain/out/PT-11/` (`README.md`, `summary.json`).

**Время (потоки 8, медиана 3, с).** Стена до / после; отношение после/до. Загрузка (t=0): Онгудай 163/187 (**1,15**), synthetic 105/114 (1,08), training_island 84/83 (0,99), volcano_island 96/91 (0,95). Пересчёт 900 с: 64/60, 82/99, 38/35, 34/29 (0,95; 1,21; 0,92; 0,84); 3600 с: 0,91; 0,97; 0,82; 0,97. `load_ratio_max` = 1,15 ≤ 1,3, условие остановки (≤ 1,2) не сработало. Итерации те же или меньше (Онгудай загрузка: 130/140, грубых 110/130). Разброс повторов ±30…40 % (в машине шла чужая нагрузка, load average 15…50 на 20 ядрах при замке cpu), поэтому различия в пределах ±15 % — шум. Потоки 2 (1 повтор, оценка): загрузка Онгудая 108/239 (2,2), остальные 0,78…1,6; ориентир только по порядку.
Доли: `secs[0]` (подготовка) выросла с 0,32 до 0,70 с (Онгудай, загрузка, потоки 8), 0,03→0,08 (synthetic), 0,27→0,59, 0,22→0,60 (острова): в 2…3 раза, абсолютно ≤ 0,8 с против 7…80 с решений; оценка раздела 2 (0,1…0,2 с на потоке) занижена в 3…4 раза, на результат не влияет.

**Тепло (риск 1).** Онгудай 400 м, 5184 столбца вдали от края: Σ Q·dz = h0 (1,000000), Σ Q·vf·dz = **0,964·h0** (по столбцам 0,925…1,000, p50 0,966). Т. е. в клетке `kf` Q остаётся «на единицу объёма», и срезанная клетка отдаёт столбцу на 3,6 % меньше тепла (в среднем); делить на vf — решение замыкания, не принято (`heat_balance.json`, крейт `probe`, `Case.arrays["Q"]`, `vf` из `level_cases`).

**Термики (ongudai_day_1..3, 4 момента, `AirModel::cores`).** Ядер после/до 0,95…1,03 (минимум **0,946**), NaN нет; в t=3600 с день 1 встречается ядро с w=0. Таблица — `thermals.csv`. Ядра зависят от поля слабо; проверка в основном на отсутствие потерь.

**Присутствие.** Ветер определён по `far`-точкам случая (Онгудай 144° откуда, synthetic 300°); гребни — по высотам места: 2 набора (массивы: подъём 700…970 м, и умеренные гряды 80…400 м, 4 шт.), по 3 и 4 линии на случай, `ongudai_strong` и `synth_strong`, 3 момента (`presence.csv`, 168 строк). `ongudai_storm` исключён из критериев (по `far` точкам ветер бури не однонаправлен, ротор «везде»).
Разгон S(z) = |U| на гребне / |U| на наветренной равнине (минимум рельефа в 1,5…4 км вверх по ветру) на z_agl 10/30/60/100 м. Медиана S: до 2,64/2,35/2,22/1,94, после 1,81/1,80/1,72/1,60. Отношение (S_после−1)/(S_до−1) (167 из 168, S_до>1,05): минимум **0,16**, медиана 0,69; по z_agl минимум 0,16/0,34/0,41/0,52, лучшая половина `synth_strong` на 60…100 м ≈ 0,7…1,0, на умеренных грядах до 1,15…8 (редкие гребни, где до было почти 1). Порог ≥ 0,9 не выполнен. `w` на наветренном склоне (z_agl 30 м, среднее): до 0,58, после 1,03 м/с в медиане — подъём у склона после заметно сильнее и ближе к ожидаемому.
Ротор (доля u∥<0 за гребнем до 3 км, ≤ 300 м AGL; есть при > 0,01): до есть у 2 гребней (по 2 момента = 4 случая): доли 0,011…0,015, min u∥ −0,5…−0,6 м/с, длина 400…700 м, высота ≤ 30 м; после: 0,006 (ниже порога; min −0,29) и 0,0 (min +7 м/с). `rotor_lost` = **4** (случай-момент), по сути 2 гребня; ротор «до» на самом пороге и мелкий, в `ongudai_storm` крупный (до 290 м) сохранён.
NaN/∞: во всех выборках, ядрах, json timing и балансе тепла после — 0, до — 0.

**Границы.** Гребни и равнина — автоматический отбор по рельефу, не по опыту; зона «плоская равнина» может быть другой высоты (долина против массива) — отношение зависит от неё одинаково в обоих вариантах, но не есть доля Askervein. «До» на 10…30 м AGL может быть завышено ступенчатым рельефом (точка внутри грунтовой клетки), поэтому минимум отношения на 10 м — не показатель потери. Эталона ветра в горах нет; пропавший разгон не означает ошибки — требует решения, чей S ближе к опыту (Пикар врёт 10…15 %). Вертикальный разрез заменён сеткой точек `sample` (тот же `ops::sample_slice`), шаг по длине 100 м. Один сид, режим `mean`.
