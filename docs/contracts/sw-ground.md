---
type: "contract"
status: "active"
module: "sw-ground"
area: "air"
updated: "2026-11-08"
summary: "Стыки sw-ground: приземные точки SWG1, таблица у земли SWG2, ротор на рельефе SWG3, время поля на окнах игры SWG4."
related: ["docs/plan/sw-ground.md", "docs/contracts/sw-charges-3d.md", "docs/research/sw_charges_3d.md"]
contracts: [{"id": "SWG1", "version": 1}, {"id": "SWG2", "version": 1}, {"id": "SWG3", "version": 1}, {"id": "SWG4", "version": 2}]
---
# Контракты модуля sw-ground

Общее для всех стыков.
- Код и данные — `tools/research/sw_ground/`; интерпретатор — `tools/research/sw_ground/py` (venv sw_charges_3d;
  PYTHONPATH — `sw_ground`, `sw_charges_3d`, `sw_charges`). Пакеты `tools/research/sw_charges_3d/*` (SWD1–SWD9,
  `docs/contracts/sw-charges-3d.md`) — только импортировать, не менять; нужна правка — копия в `sw_ground/` с новым именем.
- Эталоны — SWD1 v2: `tools/research/sw_charges_3d/out/refs/<case>.h5` (рельеф, Пикар nom/adv1 на 11 уровнях) и
  `out/refs/points.json` (мачты, нормировочные точки `norm`, разрезы, роторы Menke/Пикара). Случаи `ASK_TU03B`,
  `PERD_NE`, `PERD_SW`; типы точек `upstream`, `windward`, `crest`, `lee`, `valley` — классификатор SWD1
  (`refs/points.py: classify`), не менять.
- `s` — s_norm SWD1: скорость (горизонтальная, м/с) / скорость в точке `norm` того же источника.
- Допуск к Пикару — `|s_pan − s_ref| ≤ 0,15·|s_ref|`. Строки Пикара ниже 50 м — `ref_use` = "справочно" (SWD5, 2D №7).
- Все JSON: `format`, `version`, `git` (короткий хеш), `created` (ISO). Запись — во временный файл и переименование.
- Контрактный тест: `tools/research/sw_ground/py tools/research/sw_ground/contract/check_contract.py <файлы>`
  (формат по полю `format`); `--selftest` — проверка самого теста.

## SWG1 v1 — приземные точки (плотный набор)
Владелец — SWG-1; потребители — SWG-1, задачи исправления слоя у земли, итог.
Зачем: в SWD5 на тип точки Perdigão по 2 положения — доли «в ±15 %» по ним не значат ничего.
- Путь — `tools/research/sw_ground/out/points/ground_points.json`; `format` = "swg-points", `version` = 1,
  `rule` (строка: как выбраны точки — сетка, шаг прореживания, область), `rows` — {`case`, `id` (`G_<case>_<n>`),
  `type`, `x`, `y` (м, система случая SWD1), `z_ground` (м), `z_agl` (м), `s_nom`, `s_adv1` (s Пикара nom/adv1 в
  точке; нет — null), `speed_nom` (м/с)}.
- Выбор: центры клеток Пикара nom внутри `refs/points.py: box(case)`, тип — `classify(case, x, y)`; прореживание —
  равномерное по сетке (шаг одинаков для всех типов случая), без отбора по значению ошибки.
- Высоты: обязательно 10, 50, 300 м; допускаются другие из `z_agl` SWD1.
- Инварианты: PERD_NE и PERD_SW — у типов `lee`, `valley`, `crest`, `windward` на 10 и 50 м n ≥ 30;
  ASK_TU03B — `lee` на 10 и 50 м n ≥ 30, остальные типы — сколько есть (≥ 1, где тип есть в области);
  `id` уникален; `type` из пяти.

## SWG2 v1 — таблица «у земли» (до/после, разложение, сканы)
Владелец — каждая задача слоя у земли (SWG-1 — «до» и диагностика, исправления — «после»); потребители — приёмка,
итог.
- Путь — `tools/research/sw_ground/out/<task>/ground.json` (`<task>` — ID задачи строчными, напр. `swg-1`);
  `format` = "swg-ground", `version` = 1, `task`;
  - `variants` — {имя: строка-описание с параметрами (σ, ds_min, правило z0, фон, что включено)}; базовые имена
    "potential", "potential_jh" — SWD2 v5 при основном наборе SWD5 (σ 40 м, ds_min 25 м, z0 — медиана растра);
    новые имена — свободные, но описанные здесь;
  - `rows` — по точке × варианту: {`case`, `variant`, `id` (SWG1 `id` или имя мачты), `type`, `z_agl`,
    `ref_kind` ("picard_nom" | "picard_adv1" | "mast"), `ref_use` ("эталон" | "справочно"), `s_ref`, `s_pan`,
    `rel_err` (= (s_pan − s_ref)/s_ref), `within_tol` (|rel_err| ≤ 0,15)};
  - `summary` — {`case`, `variant`, `type`, `z_agl`, `ref_kind`, `n`, `frac_tol`, `mean_rel`, `median_rel`}:
    обязательно для `lee`, `valley`, `crest`, `windward` × 10, 50, 300 м × `picard_nom` по каждому варианту;
  - `masts` — {`case`, `variant`, `type` (тип или "all"), `n`, `rmse_s`, `frac_tol`} — мачты SWD1 (`ref_kind` "mast");
  - `decomp` — {`case`, `type`, `z_agl`, `term`, `value`, `unit`, `note`}: разложение скорости варианта на слагаемые
    (напр. "bg", "panels", "jh", "head", "z0", "sigma"; имена — в `note`), `value` — средний вклад в s или в rel_err
    (`unit` = "s" | "rel" | "m/s");
  - `scan` — {`case`, `variant`, `param`, `value`, `metric`, `result`} — сканы параметров (σ, z0, …), метрики —
    "frac_tol_<type>_<z>", "mean_rel_<type>_<z>", "rmse_s_mast".
- Инварианты: каждый `rows.id` с `ref_kind` Пикара — из SWG1; `summary.n` = число строк `rows` с тем же ключом;
  `within_tol` согласован с `rel_err`.

## SWG3 v1 — нить ротора на реальном рельефе
Владелец — SWG-2; потребители — итог.
- Путь — `tools/research/sw_ground/out/<task>/rotor.json`; `format` = "swg-rotor", `version` = 1, `task`;
  - `params` — один набор на все случаи (SWD7 v2: `closure` = "reattach", `R_rule` 0,25, `gate` "slope",
    `slope_min` 0,27; σ, ds_min — основной набор SWD5) и `criterion` (строка; ротор — u∥ < −0,5 м/с на 15 м на
    отрезке > 50 м вдоль разреза SWD1, как SWD5);
  - `rows` — по разрезу: {`case`, `transect`, `variant` ("rotor_jh"), `present`, `L_m`, `depth_m`,
    `u_min_over_U` (min u∥ на 15 м / U опорной точки | null), `L_menke`, `L_picard_nom`, `L_picard_adv1`
    (из SWD1 `rotor`; нет — null)};
  - `ridges` — по хребту, где проверялся порог: {`case`, `ridge`, `slope_max`, `gate_pass`, `placed`, `converged`,
    `Gamma`, `R`, `x_c`, `x_r` (м вдоль ветра), `reverse_15m` (bool), `picard_reverse` (bool | null),
    `false_rotor` (bool: обратный u∥ есть, а у Пикара, Menke и мачт ротора нет)};
  - `timing` — {`case`, `t_s`, `n_solves`}.
- Инварианты: `params` одинаковы для всех случаев (без подгонки по месту); строки `rows` — по каждому разрезу SWD1
  с `source` Menke или вдоль ветра для всех трёх случаев.

## SWG4 v2 — время поля на сетках окон игры
v2 (2026-11-08, решение о SWG-6): `version` 2; в `rows` — ещё `variant` (строка: "fp64" — опрос как SWG-3; иначе имя
рычага, напр. "fp32", "above_ground", "far_cluster", сочетания через "+") и `err` ({`ref` (строка: с чем сравнивали),
`n`, `rms_rel`, `max_rel`, `max_abs_ms`} по горизонтальной скорости надземных точек | null — эталон или Пикар);
для `variant` ≠ "fp64" у панелей `err` обязателен; `n_points` — фактически опрошенные (у "above_ground" < nx·ny·nz,
равенство nx·ny·nz требуется только у "fp64"). Файлы v1 (SWG-3) остаются валидными как v1.
Владелец — SWG-3; потребители — итог.
- Путь — `tools/research/sw_ground/out/<task>/timing.json`; `format` = "swg-timing", `version` = 1, `task`;
  - `machine` — {`cpu`, `gpu`, `threads` (доступно)};
  - `rows` — {`method` ("panels" | "panels_rotor" | "picard"), `place`, `window_dx` (100 | 50), `nx`, `ny`, `nz`,
    `n_points` (запрошено точек), `stage` ("cold" | "wind_change"), `t_total_s`, `parts` ({имя: с}),
    `backend` ("cupy" | "numpy" | "rust"), `threads` (CPU-потоков | null), `tol_scale` (Пикар | null), `note`}.
- Сетка окна — как в игре (`docs/research/rust-wind-field-path.md`, «Окна 100/50 м»): 64×64, шаг 100 и 50 м,
  `dz = dx/2`, потолок 2000 м над максимумом рельефа окна; у панелей `n_points` = nx·ny·nz (все уровни).
- Инварианты: для каждого `window_dx` и `stage` есть строки "panels" и "picard"; `t_total_s` > 0.
