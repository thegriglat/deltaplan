---
type: "contract"
status: "active"
module: "outflow-bc"
area: "air"
updated: "2026-11-08"
summary: "Стыки outflow-bc: мягкий выход в picard_rs (OB1, флаг SolveOpts.outflow), корпус и записи прогона (OB2), рез полей (OB3)."
related: ["docs/plan/outflow-bc.md", "docs/contracts/rust-wind/solver.md", "tools/research/air3d/reference.md", "rust/picard_rs/README.md"]
contracts: [{"id": "OB1", "version": 1}, {"id": "OB2", "version": 1}, {"id": "OB3", "version": 1}]
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
- Поправка потока: S = Σ s·u по **всем** граням типа 2 (u и v) в f64 детерминированной редукцией (`util`), затем на каждой
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
при 1 и 4 потоках; (2) Soft на тех же фикстурах: статус `ok`, `flux_net_max_rel ≤ 1e-6`, `div_rms` выданного поля ≤ критерия;
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
