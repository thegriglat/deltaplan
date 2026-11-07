---
type: "research"
status: "active"
module: "outflow-bc"
area: "air"
updated: "2026-11-08"
summary: "Стенд корпуса outflow-bc: пример dp-air outflow_corpus (hard/soft/soft_ns, область 400 м), записи OB2, резы OB3, оценка времени"
related: ["docs/plan/outflow-bc.md", "docs/contracts/outflow-bc.md", "rust/dp-air/examples/outflow_corpus.rs"]
conclusion: ""
data: ""
applied_in: ""
---

# Стенд корпуса outflow-bc

Исследование: вклад жёсткого выхода области 400 м (`fixed_u/v` на гранях выхода) в слабый ветер — сравнение `hard`, `soft`
(нулевой градиент + поправка Σ=0, OB1) и `soft_ns` (soft без боковой губки импульса у граней выхода). Решатель — `picard_rs`
(CPU, Rust); Godot не нужен. Контракты — `docs/contracts/outflow-bc.md` (OB1, OB2, OB3); план — `docs/plan/outflow-bc.md`.

## Команды

```bash
# пилот (4 случая × 3 варианта) и проверка; cargo — под замком cpu
mkdir -p build/obc
cargo run --release --manifest-path rust/Cargo.toml -p dp-air --example outflow_corpus -- \
  --spec tools/research/outflow_bc/corpus_pilot.json --variants hard,soft,soft_ns \
  --out build/obc/OBC-2_pilot.jsonl --save-slices --raw build/obc/OBC-2_raw
python3 tools/research/outflow_bc/check_records.py build/obc/OBC-2_pilot.jsonl \
  --spec tools/research/outflow_bc/corpus.json --slices build/obc/OBC-2_raw/slices

# полный корпус (OBC-3): два процесса по половине случаев
... --spec tools/research/outflow_bc/corpus.json --shard 0/2 --out cases.jsonl --save-slices   # и 1/2
cargo test --release --manifest-path rust/Cargo.toml -p dp-air --example outflow_corpus       # модульные тесты
```

Ключи примера: `--spec`, `--variants` (по умолчанию все три), `--out` (jsonl, дописывается), `--raw` (сырьё; по умолчанию
`$OBC_RAW` или `~/data/outflow_bc`), `--save-slices`, `--shard i/n` (случаи по номеру mod n), `--threads` (иначе `threads`
спецификации), `--list` (только перечислить случаи), `--start bg` (только холодный старт; под этап 2 плана — OB2 v2).
Повторный запуск пропускает готовые пары `case_id`+`variant`; запись — построчно с flush. Порядок в паре — hard, soft,
soft_ns (поле hard нужно для `d_*`; при отсутствии в запуске берётся из реза `<raw>/slices/<id>__hard.bin`, иначе решается заново без записи).

## Корпус (`corpus.json`)

Места игры `ongudai`, `training_island`, `volcano_island` × направления «откуда» 0, 90, 225, 315° и идеальные формы
`hill_h300`, `hill_h1000` (холм `h·exp(−r²/2σ²)`), `ridge_h600` (хребет поперёк ветра `h·exp(−x'²/2σ²)`, x' — вдоль ветра),
σ = 3 км, ветер 270°, основание 0 м, луг, без воды; сетка 1601×1601 шаг 25 м (как места фикстур). U10 = 0,5; 1; 1,5; 2; 2,5; 3
и контроль 6; 9 м/с; mech и heat (час 13, ясно, дневной максимум 22 °C); предел 1000 итераций; 240 случаев × 3 варианта.
`corpus_pilot.json` — те же места и условия, ключ `cases` — явный список из 4 случаев (`ongudai_d090_u010_m`,
`ongudai_d225_u025_h`, `hill_h1000_d270_u015_m`, `training_island_d000_u060_m`).

## Как собирается случай

Как игра, без Godot (цепочка режима B `rust/dp-air/tests/case_prepare.rs`, `runtime::build_level`): место → `domain_for`
(96×96 клеток по 400 м, dz 105 м) → `field_weather` → `build_domain_input` → `build_case` (`k` = 1, режим `Start`; без нагрева
— `without_heat()`) → `prepare` → `build_solver_case` → `picard_rs::api::solve` (чистый Пикар: без заморозки фаз, запасных
правил, окон и грубого старта; `tol_scale` — `air.tol_scale` конфига, как у игры). `soft_ns`: после сборки
`sp_u = max(lev[3], col[7])`, `sp_w = max(lev[4], col[7])` (плоскости `AirCaseRs`: `C_SCS` = 7, `L_SPZ` = 3, `L_SPZW` = 4);
`Kx/Ky/Kz` проекции не пересчитываются. Fr, N, рельеф — `phase::prepare::prepare` (как `PhaseStats`): `Fr = U_a/(N·max(relief, 1))`,
`Fr = 1000` при N = 0.

## Формат записей и резов

Записи `cases.jsonl` — `docs/contracts/outflow-bc.md`, OB2 v1: ключи как в контракте; метрики по высотам 10/50/300 м
называются `d_start_<h>_max`, `d_int_<h>_rms|p99|max|max_rel`, `d_band_<h>_max`, `edge_out_<h>_un_mean|back_frac`
(`<h>` ∈ 10, 50, 300). Высота над рельефом — линейно между центрами клеток колонны (центр клетки `k`: `z_bot + (k−½)·dz`;
ниже центра первой клетки воздуха — её значение, как `air3d/synth.py::agl`); u, v, w центра клетки — среднее двух граней.
`d_*` сравнивают конечные поля варианта и `hard` (не снимки); `both_ok` — оба `ok`. Точки стартов: `start_sites` места
(`y = −z`), у идеальных форм — вершина, середина высоты наветренного и подветренного склона (r = σ√(2 ln 2)); точка вне области
пропускается, билинейно по четырём центрам клеток. Полоса выхода — 5 клеток у сторон, где фон дует наружу (пара «клетка,
сторона»: угловая клетка при двух сторонах считается дважды). `late_spread60_p90` — `airlite_gen.late_spread60_p90` на 60 м по
снимкам 500, 550, …, 1000 (11 снимков, `status` = `max`; при `ok` — 0, при `diverged` — null).

Резы OB3 — `<raw>/slices/<case_id>__<variant>.bin|json`: f32 LE `[3 высоты][u, v, w][ny][nx]`, JSON с `version`, `nx`, `ny`,
`dx_m`, `agl_m`, `comps`, `case_id`, `variant`, `status`, `iters`. Сырьё вне git.

## Проверка и оценка времени

`check_records.py <jsonl> --spec <corpus.json> --slices <dir>` печатает `OBC2: records=<n> invalid=<k> est_full_h=<x>
pilot_s=<сумма t_solve_s>` и первые 5 нарушений: ключи и типы OB2, формат `case_id`, `flux_net_max_rel ≤ 1e-6` у soft*, рез OB3
(размер bin, json) на каждую запись. `est_full_h` — среднее `t_solve_s` на итерацию (по `heat`) × ожидаемые итерации по корзине
U10 (≤ 2 м/с — 1000, 2,5–3 — 600, ≥ 6 — 200; пилот подправляет, если его итераций больше) × число пар полного корпуса / 3600
для одного процесса на `threads` нитей.
