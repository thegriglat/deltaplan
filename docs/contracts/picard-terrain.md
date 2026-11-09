---
type: "contract"
status: "active"
module: "picard-terrain"
area: "air"
updated: "2026-11-09"
summary: "Стыки picard-terrain: случаи опыта PT1, срезанные клетки PT2, 2-й порядок PT3, строки замеров PT4, выборка в точках PT5."
related: ["docs/plan/picard-terrain.md", "docs/contracts/picard-rs.md", "docs/contracts/air-cascade.md", "docs/contracts/sw-charges-3d.md", "tools/research/air3d/reference.md"]
contracts: [{"id": "PT1", "version": 1}, {"id": "PT2", "version": 1}, {"id": "PT3", "version": 1}, {"id": "PT4", "version": 1}, {"id": "PT5", "version": 1}]
---

# Контракты модуля picard-terrain

Владелец — координатор модуля. Менять интерфейс — только координатор: версия +1, потребителям — `task note`.
Контрактный тест — `tools/research/picard_terrain/contract/check_contract.py` (только stdlib Python):
`selftest` | `cases <case.json>…` (PT1, PT2) | `rows <rows.jsonl>…` (PT4). Код 0 — соблюдено.
Побитно прежнее поведение `picard_rs` без флагов — `tools/research/picard_terrain/contract/check_default.sh`
(последняя строка `identical=4/4`).
Пути: `P = rust/picard_rs`, `T = tools/research/picard_terrain`, `D = $PICARD_TERRAIN_DATA`
(по умолчанию `~/data/picard_terrain`, вне git, общий для всех копий).

## PT1 v1 — случай опыта (R1 + ключ `pt`)
Владелец — PT-1 (производитель `T/make_cases.py`); потребители — PT-2…PT-5, итог.
- Пара `D/cases/<case>.json` + `.bin` в формате R1 v1 (`docs/contracts/air-cascade.md`) с допущением R6 v3
  (эталона `sol_*`/`solution`/`history` может не быть). `format: "ref-case"`, `version: 1`.
- Имя `<case>` = `<site>_d<dx>` (dx — целое, м; 12,5 → `12p5`); `site` ∈ `askervein`, `kayancha`,
  `perdigao_ne`, `perdigao_sw`. Случай со срезанными клетками — `<site>_d<dx>_cut` (PT2).
- `params` — все поля `Params` air3d (`tools/research/air3d/air.py`) как есть, включая `adv2` (bool) и
  `limiter` (int); ключ `cut_cells` (bool) — PT2.
- Ключ `pt` (обязателен): `version: 1`, `site`, `dx`, `dz` (м), `domain_m` [Lx, Ly], `top_m` (верх области, м
  над уровнем моря), `U10` (м/с, где задан), `wdir_deg` (откуда дует, ° от севера), `z0` (м), `heat: false`,
  `source` = {`script`, `args`, `git`}, `terrain` = {`path` (относительно `D`), `dataset`, `x0`, `y0`, `dx`},
  `probes` — список {`name`, `x`, `y`, `z_agl`, `role` ("target" | "norm" | "mast"), `pair` (имя точки нормы для
  "target" или `null`)}.
- Оси и единицы: x — восток, y — север, м, та же система, что `x0, y0` сетки случая; высоты — м над уровнем моря.
- Один `site` — одна постановка на всех dx и вариантах: та же область, верх, приток, `z0`, `U10`, `wdir_deg`,
  губки; меняются только `dx`, `dz = dx/2`, маска и (PT2) доли. Нейтрально, ветер ≥ 5 м/с.
- Рельеф подсетки — HDF5 `D/terrain/<site>.h5`, датасет `h` float32 (ny, nx), м над уровнем моря; атрибуты
  `x0, y0` (координаты узла [0, 0]), `dx` = 30 (узлы `x0 + i·dx`, `y0 + j·dx`); поверхность между узлами —
  билинейная. Askervein — исходный растр блочным средним до 30 м; Каянча, Perdigão — GLO-30.
- Точки: Askervein — `HT_<z>` (target, `pair` = `RS_<z>`) и `RS_<z>` (norm), z_agl 10, 30, 60, 100 м;
  Каянча — `START_<z>` (target, `pair` = null), z_agl 20, 30, 50, 100 м (старт `kayancha_south`,
  `air3d/real.py`); Perdigão — мачты SWD1 (`tools/research/sw_charges_3d/out/refs/points.json`, role "mast").
- Нет обязательного ключа или массива — ошибка чтения, не умолчание.

## PT2 v1 — срезанные клетки (дополнение к R1)
Владелец — PT-2 (производитель долей и решатель); потребители — PT-5, PT-4.
- Массивы в `.bin` (раскладка R1, (NZ, NY, NX) с ореолом, float32): `vf` — доля объёма клетки над рельефом
  подсетки, [0, 1]; `af_u`, `af_v`, `af_w` — доля открытой (над рельефом) площади грани MAC с тем же индексом,
  что `u`, `v`, `w`, [0, 1]. Ореол: копия соседней внутренней клетки/грани по нормали к границе.
- `pt.cut` = {`version: 1`, `vf_min`, `samples_per_edge`, `terrain_dx`: 30}. Типы согласованы с долями:
  внутренняя клетка `cell` = 1 ⇔ `vf ≥ vf_min`; грань типа 1 ⇒ доля > 0; клетка воздуха с `vf = 1` ⇒ все 6 её
  граней с долей 1 (допуск 1e-6). `Kx, Ky, Kz` и прочий вход — как даёт подготовка air3d для этих типов, **без**
  умножения на доли (доли применяет решатель).
- `params.cut_cells` = true — решатель обязан найти `vf, af_*` (нет — ошибка); false или нет ключа — доли не
  читаются, путь решения побитно R1.
- Масса: при `cut_cells` невязка неразрывности клетки — `Σ ±af·u/h` по шести граням (на единицу полного объёма
  клетки); `div_rms` R2 и критерий — по ней. Площадь и нормаль стенки в клетке — из долей (замкнутость:
  вектор площади стенки = −Σ af·A·n по граням).

## PT3 v1 — ограниченный 2-й порядок переноса
Владелец — PT-3; потребители — PT-5, PT-4.
- Как air3d: `params.adv2` (bool) включает отложенную поправку переноса (`air.py` → `adv2_mom`, `adv2_heat`,
  `reference.md` → «Перенос»), `params.limiter`: 0 — линейная, 1 — ван Лир, 2 — ван Альбада (как air3d),
  3 — minmod (новое: φ(r) = max(0, min(1, r))). `adv2` = false — путь решения побитно R1.
- CLI `picard solve … --adv2 <off|linear|vanleer|vanalbada|minmod>` перекрывает `params.adv2`/`limiter`;
  `--cut-cells` (PT2) — `params.cut_cells = true`. Без флагов — значения из `params`.
- R2 (picard-rs R2 v3) + ключ `variant` = {`cut_cells` (bool), `adv2` (bool), `limiter` (int | null при
  `adv2` = false)}; остальные поля R2 без изменений.

## PT4 v1 — строка замера (jsonl)
Владелец — координатор; производители — PT-1…PT-5; потребитель — итог (`docs/research/picard_terrain.md`).
- Файл `T/out/<ID>/rows.jsonl` (в git), строка — один прогон одного случая одним вариантом. Поля (все
  обязательны, нет значения — `null`): `format: "pt-row"`, `version: 1`, `task`, `case`, `site`, `dx`,
  `solver` ("picard_rs" | "air3d"), `dtype` ("f32" | "f64"), `cut_cells` (bool), `adv2` (bool), `limiter`
  (int | null), `status` ("ok" | "max" | "diverged" | "stalled"), `iters`, `max_iters`, `final` = {`mom_rms`,
  `th_rms`, `div_rms`}, `time` = {`total_s`, `ms_per_iter`, `threads`, `locked` (bool, под замком cpu)},
  `r2` (путь к R2 или null), `state` (путь к R4 в `D` или null), `probes` — список {`name`, `z_agl`, `S`
  (м/с, |u| по горизонтали), `dS` (S/S_pair − 1 при `pair`, иначе null)}, `rotor` (PT-4: список
  {`transect`, `present`, `L_m`, `depth_m`} по критерию SWD5 v7, иначе null), `masts_rmse` (PT-4: RMSE s_norm
  по мачтам SWD1 или null), `note`.
- "stalled" — критерий не достигнут, невязка не убывает (меньше чем в 2 раза за последние 50 % итераций).
- Время сравнимо только при `locked` = true и одном `threads` (8).

## PT5 v1 — выборка в точках
Владелец — PT-1 (`T/sample.py`: `probe_values(case_json, state_json) -> list[dict]`); потребители — PT-2…PT-5.
- Поле — R4 v2 (`format: "picard-rs-state"`); поля air3d переводятся PT-1 в тот же формат (dtype "f32").
- Скорость в центре клетки — среднее двух граней по каждой оси (грань земли — 0). Колонна (i, j) — клетки
  воздуха (`cell` = 1) с центром не ниже рельефа подсетки h(x_i, y_j) (растр PT1, билинейно); z_agl = z_k −
  h(x_i, y_j). Значение колонны на z_agl — линейно по z_agl, ниже центра нижней такой клетки — её значение.
  В точке — билинейно по 4 колоннам на заданном z_agl. Одно правило для базы и всех вариантов.
- Ротор Perdigão — критерий и разрезы SWD5 v7 / SWD1 (`tools/research/sw_charges_3d`), u∥ по тому же правилу.
