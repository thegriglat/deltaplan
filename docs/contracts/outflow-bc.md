---
type: "contract"
status: "active"
module: "outflow-bc"
area: "air"
updated: "2026-11-09"
summary: "Стыки outflow-bc: мягкий выход picard_rs (OB1), записи корпуса (OB2), рез полей (OB3), старты и снимки этапа 2 (OB4)."
related: ["docs/plan/outflow-bc.md", "docs/contracts/rust-wind/solver.md", "tools/research/air3d/reference.md", "rust/picard_rs/README.md"]
contracts: [{"id": "OB1", "version": 1}, {"id": "OB2", "version": 1}, {"id": "OB3", "version": 1}, {"id": "OB4", "version": 1}]
---

# Контракты модуля outflow-bc

Владелец — координатор модуля. Менять интерфейс — только координатор: версия +1, потребителям — `task note`.
Модуль — исследование: игра (`dp-air` src, `dp-gd`, GDScript) не меняется; всё новое — за флагом, по умолчанию побитно прежнее.

## OB1 v1 — мягкий выход в `picard_rs`
Владелец — OBC-1; потребители — OBC-2 (стенд корпуса), игра (только умолчание `Hard`).

**Интерфейс** (`rust/picard_rs/src/api.rs`, реэкспорт из `lib.rs`):
```rust
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Outflow { #[default] Hard, Soft }
pub struct SolveOpts { …, pub outflow: Outflow }          // Default — Hard
pub struct OutflowDiag {
    pub faces_out: usize,        // число граней выхода (u и v вместе)
    pub flux_in: f64,            // Σ|s·u| по граням притока, м/с (сумма по граням; площадь грани dx·dz у всех одна)
    pub flux_net_max_rel: f64,   // max по внешним итерациям |Σ_все грани типа 2 s·u| / flux_in после поправки
    pub backflow_faces: usize,   // грани выхода с s·u < 0 в выданном поле (обратное течение через выход)
}
pub struct Solved { …, pub outflow: Option<OutflowDiag> } // None при Hard
```
CLI: `picard solve <случай> … [--outflow hard|soft]` (по умолчанию hard). В R2 json ключ `"outflow": {faces_out, flux_in,
flux_net_max_rel, backflow_faces}` пишется **только** при soft (при hard файл R2 прежний).

**Поведение `Hard`** — побитно как до правки (поля `Solved.state`, итерации, невязки, R2) при любом числе потоков.

**Поведение `Soft`** (только область: случай без `nest`; с `nest` — ошибка `bail!`; при штиле `u10_positive == false` — как Hard):
- Грани выхода — грани типа 2 компонент u, v (списки `b_u`, `b_v`) на боковой границе с внешней нормалью s (запад/юг −1,
  восток/север +1 по оси массива), у которых s·ubg > 0 (у Hard на них `fixed = ubg·c`). Грани притока (s·ubg < 0) и с
  s·ubg = 0 — как Hard (`fixed_u/v`).
- Нормальная компонента на грани выхода — нулевой градиент: значение соседней внутренней грани той же компоненты по нормали
  (на одну грань внутрь), если она воздушная (тип 1); иначе — `fixed` (Hard) на этой грани.
- Поправка потока: S = Σ s·u по **всем** граням типа 2 (u и v) в f64, детерминированно (не зависит от числа потоков; сделано последовательной суммой по списку граней), затем на каждой
  грани выхода u ← u − s·S/N_out (N_out = `faces_out`). После поправки |S|/flux_in ≤ 1e-6.
- Касательные компоненты в ореоле у грани выхода (v и w в столбцах ореола за x-гранью выхода, u и w — за y-гранью; грани
  типа 3 и не-свободные грани w ореола) — нулевой градиент: значение соседнего внутреннего узла той же компоненты. Угловые
  столбцы ореола — по оси, по которой выход (если выход по обеим — среднее двух). θ′, θ′_d ореола — 0, как Hard.
- Когда: в каждой внешней итерации после шага импульса и до проекции (проекция видит сбалансированную границу; грани
  выхода в проекции фиксированы — условие Неймана для p, как у жёстких), а также при холодном старте до 30 V-циклов
  `init_background` и в `apply_bc_all`. Строки импульса граней выхода — тождество, как у жёстких.
- Губки (`sp_u`, `sp_w`, `spc`) крейт не трогает — их задаёт случай (вариант без губки выхода — OB2 `soft_ns`, в стенде).
- Критерий остановки, ∇·u, `finalize` — без изменений (те же формулы, что у Hard).
- Заморозка (`freeze`), `fallback`, `init` — совместимы, отдельно не проверяются (вне основного прогона).

**Контрактный тест** `rust/picard_rs/tests/outflow_v1.rs`: (1) Hard и умолчание — побитно равны эталонным хешам состояния,
снятым на коммите до правки, на 4 фикстурах `tests/atmosphere/fixtures/air_model/ref/{flat_wind,agnesi,heated_slope,saddle}.json`
при 1 и 4 потоках (хеши — для x86-64 с AVX2+FMA, ветка multiversion; на другом CPU пересняты); (2) Soft на тех же фикстурах: статус `ok`, `flux_net_max_rel ≤ 1e-6`, `div_rms` выданного поля ≤ критерия;
(3) Soft побитно одинаков при 1 и 4 потоках; (4) у Hard `Solved.outflow == None`.

## OB2 v1 — корпус и записи прогона
Владелец — OBC-2 (стенд); потребители — OBC-3 (прогон, таблицы, вывод).

**Варианты**: `hard` — `Outflow::Hard`, случай как в игре; `soft` — `Outflow::Soft`, губки как в игре; `soft_ns` — `Outflow::Soft`
и боковая губка импульса только у **приточных** граней: `sp_u = max(губка потолка, C_SCS)`, `sp_w = max(губка потолка w, C_SCS)`
(как губка θ, `case_build.rs` «губки»; плоскости `AirCaseRs::col_plane`/`lev_plane`).

**Спецификация корпуса** `tools/research/outflow_bc/corpus.json` (ключи):
`places` — список `{id, kind: "real"|"ideal", file?, shape?, h_m?, sigma_m?, dirs_deg: [..]}`; `u10_ms: [..]`; `heat: [false, true]`;
`max_iters` (по счёту игры, 1000); `late: {from: 500, step: 50, edge_cells: 5}`; `threads`. `case_id` =
`<place>_d<dir>_u<u10·10, 3 цифры>_<m|h>`, напр. `ongudai_d045_u015_h`.

**Записи** — `cases.jsonl` (строка на пару случай×вариант, дописывается построчно; повторный запуск пропускает готовые
пары `case_id`+`variant`). Поля (null — не определено):
- `case_id, place, kind, shape, h_m, dir_deg, u10_in, heat, variant, git` (коммит кода);
- `status` (`ok`|`max`|`diverged`|`cancelled`), `iters` (по счёту игры), `t_solve_s`, `threads`;
- `u10, fr, n_bv, relief_m` — из `PhaseStats` крейта `dp-air` по области (Fr = 1000 при N = 0);
- `late_spread60_p90` (м/с) — при `max`: снимки `snapshot_at` на итерациях from, from+step, …, max_iters; на 60 м над
  рельефом (линейно по высоте центров клеток) RMS по снимкам |Δ(u,v)| от среднего снимков, 90-й процентиль по клеткам
  области без `edge_cells` у края (как `airlite_gen.late_spread60_p90`); при `ok` — 0;
- `faces_out, flux_in, flux_net_max_rel, backflow_faces` — из `OutflowDiag` (null у hard);
- `res_hist` — история невязок `Solved.history`: список `[it, mom_rms, mom_max, th_rms, thd_rms, div_rms]` на каждую
  проверку (раз в 10 итераций; `it` — как в `Check.it`), для п. 9 (г) этапа 2;
- сравнение с `hard` того же случая (у hard — null): `both_ok` (оба `ok`); для h ∈ {10, 50, 300} м над рельефом, по |Δ(u,v)|
  центров клеток (м/с): `d_start_h_max` (по точкам стартов места; у ideal — вершина, середина наветренного и подветренного
  склона), `d_int_h_rms`, `d_int_h_p99`, `d_int_h_max` (область без 5 клеток у края), `d_band_h_max` (полоса 5 клеток у края);
  `d_int_h_max_rel` = `d_int_h_max / u10`;
- у выходной границы (Q5; у всех вариантов): `edge_out_h_un_mean` — среднее s·u_n в полосе 5 клеток у граней выхода, м/с;
  `edge_out_h_back_frac` — доля клеток этой полосы с s·u_n < 0.

**Сводка** — `tools/research/outflow_bc/out/summary.csv` (OBC-3): строка на (variant, корзина U10, корзина Fr, heat):
`variant,u10_bin,fr_bin,heat,n,conv_frac,iters_med,iters_p90,spread_med,spread_p90`; корзины U10: `<1, 1–1.5, 1.5–2, 2–2.5,
2.5–3, ≥6`; Fr: `<0.15, 0.15–0.3, 0.3–0.5, 0.5–1, >1`; `heat` — `m`|`h`|`all`.

## OB3 v1 — рез полей (для рисунков)
Владелец — OBC-2; потребитель — OBC-3. По ключу `--save-slices` стенд пишет на пару случай×вариант
`<raw>/slices/<case_id>__<variant>.bin` — f32 LE `[3 высоты: 10, 50, 300 м][3 компоненты: u, v, w][ny][nx]`, центры клеток
области без ореола, индекс `j*nx+i`, и `<…>.json`: `{version: 1, nx, ny, dx_m, agl_m: [10, 50, 300], comps: ["u","v","w"],
case_id, variant, status, iters}`. Запись — во временный файл и переименование. Сырьё вне git (`$OBC_RAW`, по умолчанию
`~/data/outflow_bc`); в репозиторий — только выбранные для рисунков, упакованные в HDF5 (float16, сжатие) OBC-3.

## OB4 v1 — этап 2: старты Пикара и снимки (п. 6–9 плана)
Владелец — OBC-6 (стенд этапа 2); потребители — OBC-7 (прогон), OBC-8 (анализ п. 6–9). Пример `dp-air`
`outflow_stage2` (отдельно от `outflow_corpus`; общая сборка случая — та же, что OB2: место → … → `build_solver_case`,
чистый Пикар, `tol_scale` игры). Код игры (`rust/dp-air/src`, `picard_rs`) по логике не меняется.

**Спецификация** `tools/research/outflow_bc/corpus_stage2.json` — ключи OB2 (`places`, `u10_ms`, `heat`, `hour`, `t_max_c`,
`sky`, `k`, `max_iters`, `threads`) плюс `starts: [..]` и `snap: {every: 10, n_eval: [50, 100, 200, 300], late_from: 500,
late_step: 50, edge_cells: 5}`. Полный корпус: ongudai, training_island, volcano_island × `dirs_deg` [0, 225]; hill_h300,
hill_h1000, ridge_h600 × [270] (как OB2); `u10_ms` [0.5, 1, 2, 3, 6]; heat [false, true]; `max_iters` 1000 → 90 случаев.
`case_id` — как OB2. Пилот `corpus_stage2_pilot.json`: 2 случая (ongudai d0 U10 1 heat; hill_h300 d270 U10 6 mech),
`max_iters` 300, `snap.late_from` 150, `n_eval` [50, 100, 200].

**Старты** (`--starts`, по умолчанию все из спецификации); старт задаёт `SolveOpts.init` решения на 400 м:
- `bg` — холодный (фон, как OB2);
- `coarse3` — как игра (`air_model.picard_start = coarse`, `picard_coarse_factor` 3): Пикар на `coarse_domain(fine, 3)`
  (32×32, 1200 м) тем же путём, что `runtime.rs` `coarse_start` (критерии, max_iters, mech/heat — как в игре), `prolong_to`
  на 400 м;
- `chain` — `coarse_domain(fine, 4)` (24×24, 1600 м) → `coarse_domain(fine, 2)` (48×48, 800 м) → 400 м: каждая ступень —
  Пикар с правилами грубой ступени игры, старт ступени — `prolong_to` предыдущей (первая — холодный);
- `phase` — тёплый старт сборки фаз, как игра (`phase::assembly`: `warm` для heat, `warm_mech` для mech);
- `chain_phase` — `chain`, у которого первая ступень (1600 м) стартует с поля сборки фаз на этой сетке; если сборка фаз
  на 1600 м не строится без правки логики `src` — старт не реализуется (стенд отвергает его с сообщением), в отчёте.
Отказ старта (ступень разошлась, сборка фаз отказала) — запись со `status: "start_failed"` и `start_err`.

**Записи** — `<raw>/stage2/stage2.jsonl` (строка на тройку случай × вариант × старт; `--variants` как OB2; повторный запуск
пропускает готовые `case_id`+`variant`+`start`; построчно с flush). Поля (null — не определено):
- `case_id, place, kind, shape, h_m, dir_deg, u10_in, heat, variant, start, git, threads`;
- `status` (`ok`|`max`|`diverged`|`cancelled`|`start_failed`), `start_err`, `iters`, `t_solve_s` (только решение 400 м),
  `t_start_s` (всё до него: грубые ступени, продолжение, сборка фаз; у `bg` — 0), `start_iters` (итерации ступеней от грубой;
  у `bg`, `phase` — []);
- `u10, fr, n_bv, relief_m` — как OB2; `wstar` — `wstar_max` `case_prepare` по области (м/с; без нагрева — 0); `scale` = max(u10, wstar);
- `res_hist` — как OB2;
- снимки `snapshot_at` = every, 2·every, …, max_iters (финализированные, как у игры при остановке); при остановке раньше —
  снимки после остановки равны итоговому полю. Слои h ∈ {10, 50, 300} м над рельефом, |Δ(u,v)| центров клеток (линейно по
  высоте, как OB2), «область» — без `edge_cells` у края, точки стартов — как OB2 `d_start`;
- эталон R: `ref_kind` = `converged` (статус `ok` — итоговое поле) | `late_mean` (иначе — среднее снимков late_from,
  late_from+late_step, …, max_iters); `late_spread_h_p90` (h ∈ 10/50/300) — как OB2 `late_spread60_p90` на высоте h (0 при `ok`);
- для N ∈ n_eval: `eN_h_start_max`, `eN_h_int_rms`, `eN_h_int_p99`, `eN_h_int_max` — снимок N против R, м/с
  (напр. `e100_50_int_p99`);
- `err_hist` — на каждый снимок `[it, e10_p99, e50_p99, e300_p99, e10_max, e50_max, e300_max, estart_max]` (против R; `estart_max` —
  max по точкам стартов и трём высотам);
- `inc_hist` — на каждый снимок со второго `[it, inc3d_rms, inc10_p99, inc50_p99, inc300_p99, inc_int_max]`: приращение
  против предыдущего снимка (it − every); `inc3d_rms` — RMS |Δ(u,v,w)| по воздушным клеткам области (3D, без полосы у края),
  `inc_h_p99` — 99-й процентиль |Δ(u,v)| слоя h по области, `inc_int_max` — max по трём слоям.

**Рез** (`--save-slices`): `<raw>/stage2/slices/<case_id>__<variant>__<start>.bin` — f32 LE `[поля: ref, n<N>… по n_eval][3 высоты]
[u, v, w][ny][nx]`, раскладка OB3, и `.json` `{version: 1, nx, ny, dx_m, agl_m, comps, fields: ["ref", "n50", …], case_id,
variant, start, status, iters, ref_kind}`; временный файл и переименование. Сырьё — `$OBC_RAW` (по умолчанию `~/data/outflow_bc`).

**Проверка** `tools/research/outflow_bc/check_stage2.py <jsonl> --spec <json> [--slices <dir>]` → строка
`OB4: records=<n> invalid=<k> est_full_h=<x>`: ключи и типы, длины `err_hist`/`inc_hist` (= iters_max/every и на 1 меньше),
согласие `eN_*` с `err_hist`, `e*` = 0 и `late_spread*` = 0 при `ok` для снимков после остановки, рез (размер, json);
`est_full_h` — оценка полного корпуса (один процесс, `threads` нитей) по пилоту: (t_start_s + t_solve_s)/итерацию по
старту и `heat` × ожидаемые итерации по U10 (≤ 2 — 1000, 3 — 700, 6 — 200) × случаи / 3600.
