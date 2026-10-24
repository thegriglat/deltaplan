---
type: "contract"
status: "active"
module: "picard-rs"
area: "air"
updated: "2026-10-24"
summary: "Стыки picard-rs: случаи R1, результат R2, крейт R3 (без asm), снимок R4, пара T+15 R5, API R6, невязка → отклонение R7."
related: ["docs/plan/picard-rs.md", "docs/contracts/air-cascade.md", "tools/research/air_cascade/picard_rs/README.md"]
contracts: [{"id": "R1", "version": 1}, {"id": "R2", "version": 3}, {"id": "R3", "version": 4}, {"id": "R4", "version": 2}, {"id": "R5", "version": 1}, {"id": "R6", "version": 3}, {"id": "R7", "version": 1}]
---

# Контракты модуля picard-rs

Владелец — координатор модуля. Менять интерфейс — только координатор: версия +1, потребителям — `task note`.
Контрактный тест — `tools/research/air_cascade/picard_rs/contract/check_contract.py` (только stdlib Python):
`--ref <case.json>…` (R1), `--results <dir>` (R2), `--crate` (R3), `--state <state.json>…` (R4, вводит
PR-s); R5 — `tools/research/air_cascade/export/check_r5.py <case.json>…` (вводит PR-3); R6 — `cargo test` крейта (`tests/api.rs`, вводит PR-2). Код 0 — соблюдено. Допуски —
Тождественность пути решения и ускорение пачки — `contract/compare_r2.py <до> <после> [--case …] [--threads 8]`
→ `identical=<k>/<n>` (итерации, история невязок, `dev` побитно равны), `ratio_ms_per_iter`, `ratio_phase_*`.
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

## R6 v2 — API решателя: потоки, критерий, бюджет времени, старт и снимки
Владелец — PR-2 (v1), PR-5 (v2, решение пользователя 2026-10-24); потребители — CLI `picard`, PR-o, PR-n, PR-w,
будущая GDExtension.
- `picard_rs::api::SolveOpts`:
  - `threads: usize` — `0` — все доступные ядра (`std::thread::available_parallelism`, учитывает квоту
    cgroup: под замком cpu — 18);
  - `max_iters: usize`;
  - `tol_scale: f64` — множитель к порогам `criterion` случая (`tol_mom_rms`, `tol_th_rms`, `tol_div_rms`);
    `1.0` — как эталон; при `1.0` итерации и поля побитно те же, что в v1;
  - `time_budget: Option<std::time::Duration>` — стена от начала итераций (после подготовки); проверяется
    после каждой итерации: исчерпан — остановка после этой итерации, отдаётся текущее поле (с finalize);
  - `init: Option<State>` — старт от снимка R4 (семантика — R4 «Старт от снимка»); `None` — холодный старт;
  - `snapshot_at: Vec<usize>` — номера итераций, после которых снять снимок (по возрастанию; больше
    фактических итераций — не снимаются).
  `Default`: threads 0, max_iters как CLI, tol_scale 1.0, time_budget None, init None, snapshot_at пусто.
- `picard_rs::api::solve(case: &Case, opts: &SolveOpts) -> anyhow::Result<Solved>`; `Solved`:
  - `iters: usize` — итераций выполнено; `stop: StopReason` = `Converged | MaxIters | TimeBudget | Diverged`;
  - `residuals: Residuals` — невязки отданного поля на итерации `iters` (до finalize; если `iters` не
    попал на проверку — посчитать дополнительно, как проверку); `history: Vec<Check>`;
  - `state: State` — отданное поле (после finalize), пригодное как `init` следующего вызова;
  - `snapshots: Vec<State>` — снимки по `snapshot_at`: поле после N итераций, как если бы решатель
    остановился на N (finalize — на копии, ход решения не меняется);
  - `timing` (`report::Timing`, вкл. фазы R2 v2), `SolveOut` — как v1.
- `picard_rs::state::State` — поля R4 v2 в памяти (`u, v, w, th, thd, p`, опц. `nu, nuh`, `it`, размеры);
  чтение/запись R4 — `State::read(path)`, `State::write_atomic(path)`.
- Каждый вызов строит свой `rayon::ThreadPool` и работает в `pool.install`; `build_global` нигде нет;
  одновременные вызовы с разным числом потоков допустимы и независимы; результат не зависит от числа
  потоков (побитно).
- CLI — тонкая обёртка: `picard solve <case> [--threads N] [--max-iters M] [--tol-scale X] [--time-budget S]
  [--init <state.json>] [--snap-at 30,50,…] [--snap-dir <dir>] [--save-state <state.json>] [--out <R2>]`.

## R2 v3 — дополнения к результату (PR-5)
R2 v2 + `version: 3`, `stop` (`"converged" | "max_iters" | "time_budget" | "diverged"`), `tol_scale`,
`time_budget_s` (`null` — нет), `init` (`null` | путь R4), `snapshots` (список путей R4, может быть пуст),
`residuals` (невязки отданного поля, ключи как `history`). `status` — как раньше. `check_contract.py
--results` принимает v1, v2, v3.

## R7 v1 — невязка → отклонение поля (сводка PR-n)
Владелец — PR-n (задача 4, решение пользователя 2026-10-24); потребители — PR-w, PR-o, шлюз 2.
Файл `P/out/residual/<ID>/summary.json` (JSON, числа — float, м/с; `null` нельзя, кроме `tol_scale` у точек по N):
- `version: 1`, `host.git`, `threads: 8`.
- `regions` = {имя: определение одной-двумя фразами — какие клетки, по какому полю, откуда порог}; обязательны
  `domain` (вся жидкая область), `launch` (окно `crop` случая R1), `agl_10_50`, `agl_50_100`, `agl_100_200`,
  `agl_200_400` (высота центра клетки над рельефом, м), `thermals`, `slopes`.
- `series` — список: {`case`, `start`: `cold`|`warm`, `warm_from` (случай-источник или `null`),
  `ref` = {`iters`, `t_s`, `residuals`} — сошедшееся решение (`tol_scale` 1.0) того же случая с холодного старта,
  `points`: список {`by`: `iter`|`tol_scale`, `N` (итерация снимка или остановки), `tol_scale` (`null` у `iter`),
  `t_s` (время до точки, с), `residuals` = {`mom_rms`, `div_rms`, `th_rms`}, `dev` = {регион: {`du_max`, `du_rms`,
  `dw_max`, `dw_rms`}} по всем регионам, `flows` = {`thermal_w_peak_err`, `thermal_w_mean_err`, `slope_w_mean_err`}
  (ошибка скорости потока против `ref`, м/с, со знаком)}}.
  `du` — модуль разности горизонтального ветра |Δ(u,v)|, `dw` — |Δw|, против поля `ref`.
- Холодные серии: 4 случая R1 Онгудая; у каждой точки `by: iter` с N = 30, 50, 100, 150 (если сошлось раньше —
  N > iters не нужен) и `by: tol_scale` с 3, 10, 30. Тёплые серии: `…u3_heat_h1215` (с `warm_from`
  `…u3_heat_h1200`), `ref` — холодный сошедшийся `…_h1215`; точки по N 10, 20, 30, 50 и `tol_scale` 3, 10, 30.
- `threshold` = {`text` (предложение порога и обоснование), `launch_dw_max`, `launch_du_max`, `slopes_dw_max`,
  `residual` = {`mom_rms`, `div_rms`, `th_rms`} или `tol_scale` (что пороговать в решателе), `sources`: ≥ 2 строки
  «путь[:строка] — что взято» (вариометр, шум термиков/болтанка в игре)}.
Проверка — `P/contract/check_residual.py <summary.json>` → код 0 и `ok series=<n> points=<m>`.

## R6 v3 — случай без эталона (вход игры)
Владелец — координатор (PR-11: `api::solve` требует `sol_*` — игровой случай без эталона даёт ошибку);
потребители — интегратор (будущий модуль gdext), PR-12. R6 v2 + :
- `Case` без эталона — допустим: `sol_u…sol_p`, `solution`, `history` случая могут отсутствовать (в json+bin и в
  `Case`, собранном в памяти). Обязательно для решения — сетка, поля входа, `params`, `criterion`.
- `Solved.dev: Option<…>` — `None` без эталона; сверка с эталоном — только если он есть. Остальные поля `Solved`
  (iters, stop, residuals, history, state, snapshots, timing) — как v2, от наличия эталона не зависят.
- R2 при прогоне без эталона: `dev: null`, `iters_ref: null`, `history_ref: null`; с эталоном — как v3, побитно
  тот же путь решения (`compare_r2.py` → identical).
- Тест: случай с удалёнными `sol_*`/`solution`/`history` решается; поле `state` побитно равно прогону того же
  случая с эталоном; `dev` = `None`.

