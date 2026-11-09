---
type: "research"
status: "active"
module: "outflow-bc"
area: "air"
updated: "2026-11-09"
summary: "Стенд этапа 2 outflow-bc: пример outflow_stage2, старты Пикара на 400 м, снимки каждые 10 итераций, записи OB4, проверка"
related: ["docs/plan/outflow-bc.md", "docs/contracts/outflow-bc.md", "rust/dp-air/examples/outflow_stage2.rs", "tools/research/outflow_bc/README.md"]
conclusion: ""
data: ""
applied_in: ""
---

# Стенд этапа 2 outflow-bc: старты и снимки

Пп. 6–9 плана («старт и предел итераций в слабый ветер»): для каждого старта Пикара на 400 м — снимки поля каждые 10
итераций, эталон R, ошибки снимков против R, приращения между снимками (для критерия остановки п. 9), история невязки.
Контракт — `docs/contracts/outflow-bc.md`, OB4 v1; сборка случая и метрики — как у стенда корпуса (README.md рядом, OB2).
Решатель — `picard_rs` (CPU, Rust), Godot не нужен.

## Команды

```bash
mkdir -p build/obc
# пилот (2 случая × 5 стартов, hard) под замком cpu; ключ вывода --out по умолчанию <raw>/stage2/stage2.jsonl
.dpcli/dpcli job --lock cpu start OBC-6-pilot 7200 cargo run --release --manifest-path rust/Cargo.toml -p dp-air \
  --example outflow_stage2 -- --spec tools/research/outflow_bc/corpus_stage2_pilot.json --variants hard \
  --out build/obc/OBC-6_pilot.jsonl --raw build/obc/OBC-6_raw --save-slices
python3 tools/research/outflow_bc/check_stage2.py build/obc/OBC-6_pilot.jsonl \
  --spec tools/research/outflow_bc/corpus_stage2_pilot.json --slices build/obc/OBC-6_raw/stage2/slices \
  --full-spec tools/research/outflow_bc/corpus_stage2.json
# полный корпус (OBC-7): два процесса по половине случаев
... --spec tools/research/outflow_bc/corpus_stage2.json --shard 0/2 --out stage2.s0.jsonl --save-slices     # и 1/2
cargo test --release --manifest-path rust/Cargo.toml -p dp-air --example outflow_stage2     # модульные тесты
```

Ключи примера: `--spec`, `--variants` (по умолчанию все три: hard, soft, soft_ns), `--starts` (подмножество
`bg,coarse3,chain,phase,chain_phase`; по умолчанию все из спецификации), `--out` (jsonl, по умолчанию
`<raw>/stage2/stage2.jsonl`, дописывается построчно с flush), `--raw` (по умолчанию `$OBC_RAW` или `~/data/outflow_bc`),
`--save-slices`, `--shard i/n` (случаи по номеру mod n), `--threads`, `--list`. Повтор пропускает готовые тройки
`case_id`+`variant`+`start`. Пиковую память меряют обёрткой (`/usr/bin/time` в системе нет): `python3 -I` скрипт с
`resource.getrusage(RUSAGE_CHILDREN).ru_maxrss` вокруг запуска.

## Старты (путь игры, `rust/dp-air/src/field/runtime.rs`)

| старт | что делает |
|---|---|
| `bg` | холодный старт 400 м (фон), `init = None`; `t_start_s = 0` |
| `coarse3` | `coarse_start` игры: Пикар на `coarse_domain(fine, 3)` (32×32, 1200 м) холодным стартом, `max_iters` и `tol_scale` конфига игры (`RtCfg`), без запасных правил и заморозки; `level_of` + `prolong_to` на 400 м |
| `chain` | то же ступенями 24×24 (1600 м) → 48×48 (800 м) → 400 м; старт ступени — `prolong_to` предыдущей, первая холодная |
| `phase` | тёплый старт `assemble(...)` фаз на 400 м: `warm` (с нагревом) или `warm_mech` (без) — в игре Пикару стартом не служит (там только заморозка и `nonconv`), здесь служит |
| `chain_phase` | `chain`, первая ступень (1600 м) стартует с `warm`/`warm_mech` фаз этой сетки |

Фазы, как в игре (`phases_of`), считаются по случаю с нагревом; для варианта без нагрева его плоскости готовятся
отдельно. Размеры тёплого старта проверяются против случая решателя. Сборка фаз на 1600 м (24×24) строится без правки
логики `src` (тест `phase_warm_and_chain_dims`), поэтому `chain_phase` реализован. Для `soft*` грубые ступени
решаются тем же выходом (`Outflow::Soft`, у `soft_ns` — с той же губкой), чтобы старт был совместим с 400 м; в игре
грубая ступень жёсткая (при `hard` это тождественно игре). Отказ старта (ступень разошлась, фазы отказали, размеры) —
запись `status: "start_failed"` с `start_err`, без метрик.

В `src` изменена только видимость: `runtime::prolong_to` и `runtime::level_of` (`pub`).

## Снимки и метрики

`SolveOpts.snapshot_at = [10, 20, …, предел]` (предел — `max_iters`, округлённый вверх до кратного 10): финализированные
копии, побитно равные итоговому полю при остановке на этой итерации. После остановки раньше снимки = итоговое поле.
Эталон R: `converged` (статус `ok`: итоговое поле) или `late_mean` (среднее снимков `late_from`, `late_from + late_step`,
…, предел). Метрики считаются в Rust (`outflow_stage2/analysis.rs`) на срезах трёх высот 10/50/300 м
(`metrics::slice`, область без `edge_cells` клеток у края — «область»):

- `late_spread_<h>_p90` — как OB2 `late_spread60_p90`, но на высоте h; 0 при `ok`;
- `e<N>_<h>_start_max|int_rms|int_p99|int_max` — |Δ(u,v)| снимка N против R (напр. `e100_50_int_p99`);
- `err_hist` — по снимку `[it, e10_p99, e50_p99, e300_p99, e10_max, e50_max, e300_max, estart_max]`;
- `inc_hist` — со второго снимка `[it, inc3d_rms, inc10_p99, inc50_p99, inc300_p99, inc_int_max]`; `inc3d_rms` — RMS
  |Δ(u,v,w)| по воздушным клеткам области (центры клеток, все уровни воздуха);
- `res_hist` — как OB2 (раз в 10 итераций).

Дополнительно к OB4 (не в контракте, только чтение): `t_setup_s`, `t_iter_s`, `t_check_s`, `t_snap_s` (время снимков =
`t_solve_s − setup − iter − check`) — чтобы оценить цену снимков.

## Файлы

- `rust/dp-air/examples/outflow_stage2.rs` — спецификация, сборка уровней, старты, запись; `outflow_stage2/analysis.rs` —
  эталон R, `eN_*`, `err_hist`, `inc_hist` (тесты на синтетических полях); `ideal.rs`, `metrics.rs` общие с `outflow_corpus`
  (`#[path]`).
- `corpus_stage2.json` — полный корпус (90 случаев × 5 стартов); `corpus_stage2_pilot.json` — пилот (2 случая, `max_iters` 300).
- `check_stage2.py` — проверка записей и резов, `est_full_h`.
