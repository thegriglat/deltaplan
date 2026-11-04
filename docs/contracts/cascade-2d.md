---
type: "contract"
status: "closed"
module: "cascade-2d"
area: "air"
updated: "2026-11-04"
summary: "Стыки cascade-2d: случаи и сетки (F0), поле разреза json+f32 (F1), запись прогона (F2), метрики сравнения (M1)."
related: ["docs/plan/cascade-2d.md", "docs/contracts/air-cascade.md", "docs/contracts/rust-wind/solver.md"]
contracts: [{"id": "F0", "version": 1}, {"id": "F1", "version": 1}, {"id": "F2", "version": 1}, {"id": "M1", "version": 2}]
---
# Контракты модуля cascade-2d

Менять — только координатор (версия +1, потребителям — `task note`). Проверка —
`tools/research/cascade_2d/py tools/research/cascade_2d/contract/check_contract.py <файлы|каталоги>`
(CSD-0): ломается, если формат поменяли без правки контракта. Каталог данных `$CASCADE2D_DATA`, по
умолчанию `~/data/cascade_2d`.

## F0 v1 — случаи и сетки
Владелец — CSD-1; потребители — CSD-2, CSD-3, CSD-4.
- Уровни k = 0…4: dx_k = 400/2^k м (400, 200, 100, 50, 25), dz_k = 100/2^k м. Область общая для всех
  уровней: x ∈ [−6400, 6400] м (nx_k = 32·2^k), низ z0 = −dz_k (как `air3d/synth.py: grid2d`), верх ≥ 2400 м;
  грани уровня k — подмножество граней уровня k+1 (вложенность). Гребень по центру x_c = 0.
- y: решатель трёхмерный, рельеф и вход постоянны по y; ny — наименьшее, при котором `picard_rs` решает
  (≥ 4); итог — средний ряд j = ny/2. Однородность по y — в F2.
- Случаи (имя — `C<n>`):
  | имя | рельеф | U10, м/с | устойчивость | нагрев |
  |---|---|---|---|---|
  | C0 | плоско | 5 | нейтрально | нет |
  | C1 | Agnesi H = 200, L = 500 | 5 | нейтрально | нет |
  | C2 | Agnesi H = 250, L = 300 | 8 | N = 0,01 с⁻¹ | нет |
  | C3 | как C1 | 1 | слой перемешивания z_i = 1500 | солнце (как `heated_slope`) |
  | C4 | разрез Аскарово через `biyagoda_west` по ветру 270° | 5 | нейтрально | нет — по возможности |
- Для метрик M1: C0, C1, C3 — x_c = 0, L = 500 м; C2 — x_c = 0, L = 300 м; C4 — `case_params.x_c`, `case_params.L` (полуширина склона по уровню H/2) в JSON случая.
- Направление ветра — вдоль +x (C4 — вдоль линии разреза). Параметры физики (`params`) — как у случая
  игры `~/data/air_cascade/ongudai/ongudai_d400_u3_mech_h1200.json`, одинаковые на всех уровнях; отличия
  (если решатель требует) — в F2 `notes` и README CSD-1.
- Случаи R1 — `$CASCADE2D_DATA/cases/<C>_d<dx>.{json,bin}` (dx — целое: 400, 200, 100, 50, 25), формат R1
  (`docs/contracts/air-cascade.md`); `sol_*` можно нулями (эталона кроме самого Пикара нет).

## F1 v1 — поле разреза
Владельцы — CSD-1 (эталон), CSD-3 (каскад), CSD-2 (базовые линии — по желанию, для картинок); потребители — CSD-2, CSD-4.
- Пара `<имя>.json` + `<имя>.bin`, `.bin` — float32 little-endian подряд. Запись — во временные файлы и
  переименование (json последним). Путь — `$CASCADE2D_DATA/fields/<C>/<source>_<variant>_d<dx>[_from<dx>].json`.
- JSON (все ключи обязательны, нет значения — `null`): `format: "cascade2d-field"`, `version: 1`,
  `case` (C0…C4), `source` (`"picard"` | `"cascade"` | `"baseline"`), `variant` (`null` у picard,
  `"V0"…"V3"`, `"V3h"` у cascade, `"B400"`…`"B50"` у baseline), `dx`, `dz`, `nx`, `nz`, `x0` (x левой
  грани, м), `z0` (z нижней грани, м), `parent_dx` (с какого уровня спуск; `null` у picard), `seed`
  (int у V3h, иначе `null`), `arrays` {имя: [смещение, длина] в float32}, `git`, `created` (ISO).
- Массивы, индекс `k·n_i + i` (k — по z снизу, i — по x слева):
  - `u` — нормальная скорость на x-гранях, (nz, nx+1), м/с;
  - `w` — нормальная скорость на z-гранях, (nz+1, nx), м/с;
  - `th` — θ′ в клетках, (nz, nx), К (у каскада — от родителя или по правилу тепла);
  - `cell` — 1 воздух, 0 земля, (nz, nx);
  - `tu`, `tw` — тип грани как в решателе (0 — стенка, ≥ 1 — открыта), (nz, nx+1) и (nz+1, nx);
  - `h` — высота земли по центрам колонн, (nx), м.
- Инварианты: на гранях `tu`/`tw` = 0 скорость ровно 0; дивергенция клетки
  div = (u[k,i+1] − u[k,i])/dx + (w[k+1,i] − w[k,i])/dz — та же дискретизация, что у проекции решателя
  (если решатель не разнесённый, CSD-1 переводит в грани так, чтобы div совпала с его `div_rms`, и пишет как);
  длины массивов — по формулам; нет массива — ошибка чтения.

## F2 v1 — запись прогона
Владельцы — CSD-1, CSD-3; потребители — CSD-4. Один JSON на прогон, рядом с F1:
`$CASCADE2D_DATA/fields/<C>/<…>.run.json` и копия в `tools/research/cascade_2d/out/runs/<C>/` (в git).
- Ключи (все обязательны, нет — `null`): `format: "cascade2d-run"`, `version: 1`, `case`, `source`,
  `variant`, `dx`, `parent_dx`, `seed`, `threads`, `ny` (picard; `1` у каскада), `status`
  (`"ok"` | `"max"` | `"diverged"`), `iters` (picard; `null` у каскада),
  `time` = {`total_s`, `setup_s`, `work_s` (решение или спуск), `per_row_s` (= `work_s`/`ny`)},
  `memory` = {`peak_rss_mb` (VmHWM из `/proc/self/status` в конце), `arrays_mb`},
  `balance` = {`max_rel_div` (max |div|·dx/U_ref по клеткам воздуха), `rms_rel_div`, `levels`
  (список {`dx`, `max_rel_div`}; у picard — один)},
  `y_uniform` (picard: max |f(j) − f(ny/2)| / U_ref по u, w; иначе `null`),
  `query` (каскад: {`n_points`, `us_per_point`, `threads: 1`, `max_abs_diff_vs_full`}; иначе `null`),
  `field` (путь F1), `cmd` (командная строка), `host` {`cpu`, `rustc`}, `git`, `notes`.
- Время — под замком `.dpcli/dpcli lock cpu`, release-сборка, одна машина; U_ref — по M1.

## M1 v2 — метрики сравнения
Владелец — CSD-2; потребитель — CSD-4. Определения — `docs/plan/cascade-2d.md`, «Метрики».
- Всё на сетке 25 м против P25 (`picard`, dx 25) того же случая; поле грубее (baseline) — линейная
  интерполяция `u`, `w` по своим сеткам граней, в земле 0. Скорости клеток — среднее двух граней.
- v2 (2026-11-04): у C3 `w_max` — максимум w по столбу |x − x_c| ≤ 3L на всех высотах до z = 2000 м (не только ROI); `F_up` — через z = 750 м.
- U_ref — |u| P25 в клетке на 100 м над землёй при x = −4800 м (вне губок; иначе ближайшая — в `notes`).
- Выход: `tools/research/cascade_2d/out/metrics/<C>.json` — `format: "cascade2d-metrics"`, `version: 1`,
  `case`, `ref` (путь P25), `U_ref`, `E_ref` {метрики B50 против P25}, `rows` — список
  {`field` (путь F1), `source`, `variant`, `dx`, `parent_dx`, `seed`, `E_u`, `E_w`, `E_u_lee`, `dS`
  ({`25`, `50`, `100`, `mean`}), `r_w`, `L_rec`, `L_rec_ref`, `w_max`, `w_max_ref`, `F_up`, `F_up_ref`,
  `max_rel_div`, `max_speed`, `sigma_u`, `sigma_w` (профили по z_agl, только V3h; иначе `null`)};
  неприменимое (нет возврата, не термик) — `null`. Плюс `<C>.csv` — те же строки без профилей.
