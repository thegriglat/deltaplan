# dp-stand — стенд ветра без Godot

Бинарный крейт: модель `dp-air` (`AirModel`) по месту, условиям и моменту фикстуры W8
(`docs/contracts/rust-wind/fixtures-tolerances.md`). Раннер T1 для RW-6…12.

```
cargo run -q --manifest-path rust/Cargo.toml -p dp-stand -- <подкоманда> --case tests/fixtures/wind/cases/x.json
```

Общие ключи (допустимы после подкоманды):

| ключ | значение |
|---|---|
| `--case <cases/x.json>` | случай (обязателен): условия, сид, термики, фокусы, моменты, точки |
| `--place <places/p.json>` | место; по умолчанию `../places/<place>.json` от случая |
| `--model calm` | модель; выбор — функция `setup::make_model` (Formula добавит RW-6) |
| `--configs <каталог>` | `*.json` конфигов (по умолчанию `configs/` репозитория); sha1 сверяется с `configs_sha1` случая, расхождение — предупреждение в stderr |
| `--timeout <с>` | ожидание Ready после `start_at` (60) |
| `--time <с>` | один момент вместо всех (`sample`) или вместо первого (остальные) |

Подготовка: `configure(конфиги, seed)` → `load_place` → `set_conditions` → `set_static_thermals`
→ `set_focuses` → на каждый момент `start_at(t)` и опрос `status` до Ready.

## Подкоманды

- `sample [--points "x,y,z;x,y,z"] [--mode full|mean]` — csv в stdout: `t,x,y,z,vx,vy,vz,sigma`;
  точки по умолчанию — точки случая, моменты — все.
- `slice --out <префикс> --step <м> [--mode ..]` — разрез в `<префикс>.json` + `<префикс>.bin`
  (запись во временный файл и переименование).
  - `--kind horizontal` (по умолчанию): `--x x0,x1 --z z0,z1 --y <высота MSL>`;
  - `--kind vertical`: `--from x,z --to x,z --ys y0,y1`.
  - `.bin` — f32 LE `[ny][nx][4]` `(vx, vy, vz, σ)`, индекс `j*nx+i`; у `horizontal` `i` — по x, `j` — по z;
    у `vertical` `i` — вдоль линии, `j` — по высоте. Заголовок: `version, nx, ny, step, geometry, mode, time_s, model, layout, data`.
- `stats --slice <x.json>` или `stats --min x,y,z --max x,y,z --step s [--mode ..]` — json: средние и σ по
  `vx, vy, vz, sigma`, квантили `vy` 5/50/95, `max_abs_vy`, `n`.
- `decompose --point x,y,z` — json W7: `names, vel, sigma, total` и `sum_vel` (Σ vel).
- `compare [--terms] [--noise-replaced] [--max-violations N]` — модель против `.bin`/`.desc.json` случая.
  Таблица по величинам (`n`, `out`, `max|d|`, `max d/tol`), число точек вне допуска, первые нарушения,
  `PASS`/`FAIL`. Выход: 0 — всё в допуске, 1 — есть вне допуска, 2 — ошибка (файлы, формат, таймаут).
  - `--terms` — ещё и слагаемые по `terms` случая (`decompose`); нет слагаемого в разложении — нарушение;
  - `--noise-replaced` — `SAMPLE_FULL` не сравнивается (шум заменён, W8).
- `timing [--threads N]` — только `--model formula`. На каждый момент (все или `--time`) одна json-строка с журналом
  задачи поля (`JobReport`): `t`, `kind` (`load` — первый момент, `recalc` — остальные), `source`, `wall_s`,
  `passes` (все поля `PassReport`: `secs` = подготовка/грубый шаг/решения/сборка, `iters`, `coarse_iters`, `phase_s`,
  `win_s`, окна…), `windows`, `windows_error`, `notes`, `threads`. Кеш полей на диске стенд не включает
  (`set_cache_dir` не вызывается), `source` всегда `Computed` — это время расчёта. `--threads` задаёт пул rayon.
  Пример: `dp-stand timing --case tests/fixtures/wind/cases/synthetic_strong.json --model formula --timeout 600`.

Допуски — одна таблица `compare::tol` (W8 v1): MEAN, FULL и детерминированные слагаемые `|Δv| ≤ 0,05 + 2 %|v_ref|`
по компоненте; слагаемое `field` `0,1 + 3 %`; σ `0,02 + 5 %`; ядра — место `max(25 м, 2 % radius)`,
`w`, `radius` 3 %, `top` 10 м, `stage` 0,05; облака — число, центр 50 м, база/верх 10 м, `growth/decay` 0,05;
база облаков 5 м. Гребни: в таблице W8 допусков нет — сверяется только число. Ядра и облака сопоставляются
по `id`, иначе по ближайшему; число обязано совпасть.

Формат фикстур читает `dp_air::fixtures` (места, случаи, `.bin`, `.desc.json`); описание формата — в его докстринге.
