---
type: "contract"
status: "active"
module: "air-cascade"
area: "air"
updated: "2026-10-24"
summary: "Стыки шага 0 air-cascade (Пикар на Rust): вход — случаи формата ref/ (R1), выход решателя — JSON замера (R2), крейт и сборка (R3)."
related: ["docs/plan/air-cascade.md", "docs/guide/air-model-gpu/picard.md", "tools/research/air3d/reference.md"]
contracts: [{"id": "R1", "version": 1}, {"id": "R2", "version": 1}, {"id": "R3", "version": 1}]
---

# Контракты модуля air-cascade

Владелец — координатор модуля. Менять интерфейс — только координатор: версия +1, потребителям — `task note`.
Контрактный тест — `tools/research/air_cascade/picard_rs/contract/check_contract.py` (только stdlib
Python): `python3 <путь> --ref <case.json>…` (R1), `--results <dir>` (R2), `--crate` (R3); код 0 — соблюдено.

Шаг 0 (план → «Вариант: библиотека на Rust», «Шаг 0»): прототип решателя Пикара 400 м на Rust, сверка с
эталоном AM-01 (`tools/research/air3d/air.py`, float64) и с GPU игры по допускам GPU-теста. Код игры не
меняется.

## R1 v1 — случай Пикара: подготовленный вход + эталон (формат `ref/` AM-01)
Владелец формата — AM-01 (`tools/research/air3d/fixtures.py`, есть); производитель случаев Онгудая — AC-R2;
потребители — AC-R1, AC-R3.
- Пара файлов `<случай>.json` + `<случай>.bin`. `.bin` — float32 little-endian подряд; `.json` →
  `arrays: {имя: [смещение, длина]}` в числах float32. Целочисленные массивы (типы, индексы) — тоже float32.
- Раскладка 3D: (NZ, NY, NX) **с ореолом** (`halo` = 1), индекс `(k·NY + j)·NX + i`, `dims` = [NX, NY, NZ]
  с ореолом; `nx, ny, nz` — без ореола. Шаблоны `C*` — (7, NZ, NY, NX): 0 центр, 1 −x, 2 +x, 3 −y, 4 +y,
  5 −z, 6 +z. Массивы по внутренним клеткам (`div_*`, `proj_rhs`, `vcycle_phi_raw`) — nx·ny·nz.
- Обязательные ключи JSON: `case, dims, halo, dx, dz, z_bot, x0, y0, nx, ny, nz, params, case_params,
  mg_levels_xyz, criterion, solution, history, arrays`.
  `params` — все параметры эталона `Params` (решатель берёт их отсюда, а не из своих умолчаний);
  `criterion` = {`tol_mom_rms`, `tol_th_rms`, `tol_div_rms`, `check_every`}; `solution` = {`status`,
  `iters`, `final_residuals`, `max_speed`, …}; `history` — список {`it`, `mom_rms`, `th_rms`, `thd_rms`,
  `div_rms`} по проверкам (раз в `check_every`).
- Обязательные массивы — постоянный вход (после подготовки, `Air` setup): `hc, cell, tu, tv, tw, nu_bg,
  Q, gam, cplz, sp_u, sp_w, spc, ubg, vbg, lam, Kx, Ky, Kz, fixed_u, fixed_v, b_u, b_v`; решение
  эталона до критерия + finalize: `sol_u, sol_v, sol_w, sol_th, sol_thd, sol_p`.
- Необязательные — промежуточные блоки одной итерации от снимка `in_*` (есть у 4 случаев `ref/`, порядок —
  `notes` в JSON и `reference.md` → «Итерация Пикара»): `in_*, nu_in, nuh_in, bc_*, kloc_*, Cm_*/bm_*,
  sweep1_u, mom_*, div_star, proj_rhs, vcycle_phi_raw, proj_phi, proj_*, div_after, Ch_d/bh_d,
  heat_thd, Ch/bh, heat_th`.
- Случаи `ref/` (есть, в git, не менять): `tests/atmosphere/fixtures/air_model/ref/{flat_wind,agnesi,
  heated_slope,saddle}`.
- Случаи Онгудая (AC-R2, вне git — крупные): `tools/research/air_cascade/picard_rs/data/ongudai/
  ongudai_d400_u<U10>_<heat|mech>.{json,bin}` — без блоков, плюс ключи `format: "ref-case"`,
  `version: 1`, `source` = {`fixture`: путь к `tests/atmosphere/fixtures/air_model/picard/ongudai_d400_h12`,
  `U10`, `heat`, `dtype: "float64"`, `git`}, `crop` (как в фикстуре Онгудая) и `t_ref_s` (время
  эталона CuPy f64 на RTX 4070 SUPER, справочно). `solution.iters` — проверка, на которой сработал
  критерий (как `runs[].iters` фикстуры).
- Нет обязательного ключа/массива или смещение за концом `.bin` — ошибка чтения, не умолчание.

## R2 v1 — результат прогона решателя (JSON)
Владелец — AC-R1 (первая версия), потребители — AC-R3, README шага 0, шлюз пользователю.
- Файл `tools/research/air_cascade/picard_rs/out/<случай>_<profile>_t<threads>.json` (в git — малые).
  Запись — во временный файл и переименование.
- Поля (все обязательны; нет значения — `null`, не пропуск ключа):
  `format: "picard-rs-result"`, `version: 1`, `case` (имя), `input` (путь к `.json` случая),
  `profile` (`"dev"` | `"release"`), `threads` (int), `dtype` (`"f32"` | `"f64"`),
  `status` (`"ok"` | `"max"` | `"diverged"`), `iters` (int, номер итерации последней проверки — та же
  мера, что `solution.iters` эталона), `iters_ref` (= `solution.iters` случая),
  `history` — список {`it`, `mom_rms`, `mom_max`, `th_rms`, `thd_rms`, `div_rms`} по проверкам,
  `history_ref` — `history` случая как есть,
  `dev` = {`u0` (м/с, = max(`case_params.U_aloft`, `solution.max_speed`)), `u_rel` (max по u, v, w
  |Δ| / u0 против `sol_*`), `th_abs` (К, max |Δ| по θ′ и θ′_d), `p_rel` (max|Δp| / max|p_ref|,
  справочно), `div_rms`, `div_rms_ref` (СКО ∇·u по клеткам типа 1, float64 от `sol_*`)},
  `time` = {`total_s`, `setup_s`, `ms_per_iter` (среднее по итерациям без проверок), `check_ms`
  (среднее на проверку), `ns_per_cell_iter` (= ms_per_iter·1e6 / `n_cells`), `n_cells` (nx·ny·nz)},
  `host` = {`cpu`, `rustc`, `git`}.
- Единицы: м/с, К, с, мс, нс. `u_rel`, `p_rel` — безразмерные.

## R3 v1 — крейт решателя и сборка
Владелец — AC-R1; потребители — AC-R3 (замеры), шаг 1 плана (2D со временем), возможная GDExtension.
- Место: `tools/research/air_cascade/picard_rs/` — отдельный пакет Cargo (`name = "picard_rs"`, edition
  2024), не член чужого workspace; lib + bin `picard`. Без Godot и без зависимостей от кода игры.
  `.gitignore` пакета: `target/`, `data/`.
- Сборка: `[profile.release] opt-level = 3, lto = "fat", codegen-units = 1, panic = "abort"`.
  Отладка и тесты — dev-профиль (opt-level 0, по умолчанию). Без `target-cpu=native` и без
  `.cargo/config*` с `rustflags`.
- Условия качества: `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`,
  `cargo build --release` — без ошибок и предупреждений.
- Код: комментарии на английском — у каждого модуля (`//!`) и каждой `pub fn`/`pub struct`.
  Функции чистые: вход → выход, меняются только явные выходные буферы (`&mut`); без глобального и
  статического изменяемого состояния, без `RefCell`/`Cell`/`static mut`/`thread_local!`; пул потоков —
  явный (`rayon::ThreadPool` из `--threads`, `pool.install`), не глобальный.
- Данные: плоские массивы с ореолом в раскладке R1 (вход читается без перестановок); хранение и счёт —
  f32, как GPU игры (f64 — по желанию, для отладки).
- CLI (минимум; можно больше):
  `picard blocks <case.json>` — относительные ошибки блоков итерации против блоков R1 (таблица в stdout);
  `picard solve <case.json> --threads N [--max-iters M] [--out <файл>]` — решение до критерия → R2;
  `picard bench <case.json> --threads 1,4,8,16 [--iters K]` — замер времени итерации по потокам → R2 на
  каждое число потоков.
- Зависимости — по необходимости: `rayon`, `serde`/`serde_json`, `anyhow`, `clap`; без сети в рантайме.

## Допуски сверки (по GPU-тесту `tests/atmosphere/test_air_picard_gpu.gd`)
- Блоки одной итерации: ≤ 1e-5 отн. (V-цикл — после вычитания среднего); типы клеток/граней — точно.
- Решение `ref/`: статус ok; |iters − iters_ref| ≤ max(20, iters_ref/10) (цель — как эталон, ±1 проверка);
  `u_rel` ≤ 1e-3; `th_abs` ≤ 0,05 К.
- Онгудай 400 м: |iters − эталон f64| ≤ 20 (цель — ±10, как GPU); поле целиком `u_rel` ≤ 1e-3, `th_abs`
  ≤ 0,05 К; поле у старта (`crop`) — против фикстуры, те же допуски. Эталон f64 сейчас (фикстура,
  `runs`): 3 м/с с нагревом 191, без нагрева 231; в плане «90 ± 1» — число до А1 и C2 v4, не действует.
