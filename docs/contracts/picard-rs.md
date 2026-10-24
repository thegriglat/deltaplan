---
type: "contract"
status: "active"
module: "picard-rs"
area: "air"
updated: "2026-10-24"
summary: "Стыки picard-rs: случаи R1, результат R2 v2 (фазы, t_s), крейт R3 v4 (без asm/интринсиков), снимок поля R4, случаи T+15 R5, API потоков R6."
related: ["docs/plan/picard-rs.md", "docs/contracts/air-cascade.md", "tools/research/air_cascade/picard_rs/README.md"]
contracts: [{"id": "R1", "version": 1}, {"id": "R2", "version": 2}, {"id": "R3", "version": 4}, {"id": "R4", "version": 2}, {"id": "R5", "version": 1}, {"id": "R6", "version": 1}]
---

# Контракты модуля picard-rs

Владелец — координатор модуля. Менять интерфейс — только координатор: версия +1, потребителям — `task note`.
Контрактный тест — `tools/research/air_cascade/picard_rs/contract/check_contract.py` (только stdlib Python):
`--ref <case.json>…` (R1), `--results <dir>` (R2), `--crate` (R3), `--state <state.json>…` (R4, вводит
PR-s); R5 — `tools/research/air_cascade/export/check_r5.py <case.json>…` (вводит PR-3); R6 — `cargo test` крейта (`tests/api.rs`, вводит PR-2). Код 0 — соблюдено. Допуски —
`contract/tolerance.py <R2.json>… [--iters-tol N]` → последняя строка `worst=<x>`, проходит при x ≤ 1.
Пути: `P = tools/research/air_cascade/picard_rs`, `D = $AIR_CASCADE_DATA` (по умолчанию `~/data/air_cascade`).

## R1 v1 — случай Пикара (без изменений)
Как `docs/contracts/air-cascade.md` → «R1 v1». Случаи Онгудая — `D/ongudai/ongudai_d400_{u3_heat,u3_mech,
u0_heat,u6_heat}.{json,bin}` (12:00, 150°, эталон f64: 191/231/201/131 итераций).

## R2 v2 — результат прогона (JSON)
Владелец — PR-1; потребители — PR-4, PR-o, PR-n, PR-w, README, шлюзы. R2 v1 (air-cascade) + поля:
- `version: 2`.
- `time.phase_ms` = {`mom`, `heat`, `proj`, `kupd`, `other`} — среднее время фазы на итерацию (без
  проверок), мс; `mom` — сборка шаблонов + прогонки импульса, `heat` — сборка + прогонки θ′_d и θ′,
  `proj` — проекция (дивергенция, V-цикл, поправка), `kupd` — обновление K, `other` — остальное в
  `outer_step`. Сумма = `ms_per_iter` ± 2 %.
- `history[].t_s` — стена, с, от начала итераций (после подготовки) до конца этой проверки (вкл. проверки).
- Файлы — `P/out/<подкаталог задачи>/<случай>_release_t<threads>.json`; `check_contract.py --results`
  принимает v1 и v2 (v1 — старые файлы air-cascade).

## R3 v4 — крейт и сборка
R3 v3 (air-cascade) + (решения пользователя 2026-10-24):
- Без inline asm (`asm!`, `global_asm!`) и ручных интринсиков (`std::arch`, `core::arch`); SIMD — только
  автовекторизацией (данные и циклы) и `multiversion` (цели x86-64-v3 + база, выбор во время работы) — он
  остаётся. База x86-64 (без AVX2) — только для сборки и тестов, не оптимизируется и не меряется.
- Release: `opt-level = 3, lto = "fat", codegen-units = 1, panic = "abort"`; тесты — dev (-O0).
- f32 в расчёте, f64 в редукциях (невязки, суммы); смена — только с замером точности и времени.
- `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings` — чисто.

## R4 v2 — снимок поля (состояние Пикара)
Владелец — PR-s; потребители — PR-n, PR-w. v2 (по PR-3, тёплый старт игры): K не греется, старт — 4 V-цикла.
- Пара `<имя>.json` + `<имя>.bin`, упаковка как R1: `.bin` — float32 LE подряд, `arrays: {имя: [смещение,
  длина]}` в числах float32; раскладка 3D (NZ, NY, NX) с ореолом, как поля `Fields` крейта.
- JSON: `format: "picard-rs-state"`, `version: 2`, `case` (имя случая), `input` (путь к `.json` случая),
  `it` (итераций выполнено; 0 — начальное поле), `dims`, `halo`, `nx`, `ny`, `nz`, `dtype: "f32"`,
  `residuals` (запись `history` R2 на этой итерации или `null`), `host.git`.
- Массивы: обязательны `u, v, w, th, thd, p` (как `AirPicardJob.state()` игры); `nu, nuh` — необязательны
  (пишутся для анализа, при старте не читаются).
- Старт от снимка — как тёплый старт игры (PR-3, `export/README.md` → «Тёплый старт игры»): из снимка
  берутся `u, v, w, th, thd, p`; нет `thd` — нули; `nu, nuh` (K замыкания) и весь вход — от нового случая,
  считаются заново, как при холодном старте; вместо холодного начала (граничные условия + 30 V-циклов
  проекции) — граничные условия без фона + 4 V-цикла (`air_picard_job.gd:_program('warm')`). Размеры
  (`dims`, `halo`) должны совпасть со случаем — иначе ошибка, не подгонка.
- Место: `D/picard_rs/states/` (вне git, ~12–16 МБ на снимок). Запись — во временный файл и переименование.

## R5 v1 — случаи T+15 мин (пара для тёплого старта)
Владелец — PR-3; потребители — PR-w.
- Формат — R1 v1 (`format: "ref-case"`) + в `source`: `hour` (ч, дробное, напр. 12.25), `warm_from` (имя
  случая на T) и `changed` — список входов, которые меняются от T к T+15 так же, как в игре (напр. `Q`,
  `H`, `ubg`, …), с источником в коде игры (файл:функция).
- Имена: `D/ongudai/ongudai_d400_u<U10>_<heat|mech>_h<ЧЧММ>.{json,bin}`; случай на T — существующий
  `…_u3_heat`/`…_u3_mech` (12:00) или новый с тем же генератором, если 12:00 не воспроизводится тем же путём.
  Сделано (PR-3): старые 12:00 тем же путём не воспроизводятся, пара — `…_u3_{heat,mech}_h1200` → `_h1215`
  (холодный эталон f64: heat 281/281, mech 341/341).
- Эталон (`sol_*`, `history`, `solution.iters`) — холодный решатель air.py f64, как AC-R2; сетка, область,
  `params`, `criterion` — те же, что у случая на T.

## R6 v1 — API решателя с числом потоков
Владелец — PR-2; потребители — CLI `picard`, PR-o, PR-n, PR-w, будущая GDExtension.
- `picard_rs::api::SolveOpts { threads: usize, max_iters: usize }` (`threads = 0` — все логические ядра,
  `std::thread::available_parallelism`; `Default`: 0 и предел итераций CLI).
- `picard_rs::api::solve(case: &Case, opts: &SolveOpts) -> anyhow::Result<Solved>` — подготовка, итерации до
  критерия, finalize; `Solved` несёт `SolveOut`, время (`report::Timing`) и итоговые поля. Каждый вызов
  строит свой `rayon::ThreadPool` (`ThreadPoolBuilder::new().num_threads(n).build()`) и работает в
  `pool.install`; `build_global` и глобальный пул rayon не используются нигде в крейте.
- Одновременные вызовы из разных потоков ОС с разным числом потоков — допустимы и независимы; результат
  (итерации, поля) не зависит от числа потоков (как в AC-R3: сверка одинакова на всех потоках).
- CLI `solve`/`bench` — тонкая обёртка над `api::solve`.
