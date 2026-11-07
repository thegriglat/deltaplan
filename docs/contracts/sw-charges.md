---
type: "contract"
status: "active"
module: "sw-charges"
area: "air"
updated: "2026-11-08"
summary: "Стыки sw-charges: случай слоя мелкой воды (SW1), поле слоя json+f32 (SW2), запись прогона (SW3); модель — Рипа, reduced gravity."
related: ["docs/plan/sw-charges.md", "docs/contracts/cascade-2d.md", "tools/research/sw_charges/README.md"]
contracts: [{"id": "SW1", "version": 1}, {"id": "SW2", "version": 1}, {"id": "SW3", "version": 1}]
---
# Контракты модуля sw-charges

Владелец всех стыков — координатор модуля; меняет только он (версия +1, потребителям — `task note`).
Контрактный тест: `python3 tools/research/sw_charges/contract/check_contract.py --selftest` (только stdlib) и
`check_contract.py <файлы|каталоги>` — проверка реальных файлов SW1–SW3 по полю `format`.

Общее для SW1–SW3:
- Пара `<имя>.json` + `<имя>.bin`; `.bin` — float32 little-endian подряд; в JSON `arrays` = {имя: [смещение, длина]}
  в float32 (не байтах). Запись — во временные файлы и переименование, JSON последним. У SW3 `.bin` нет.
- Сетка — центры клеток: x_i = x0 + (i + ½)·dx, y_j = y0 + (j + ½)·dy; i — на восток (+x), j — на север (+y);
  массив (ny, nx) с индексом `j·nx + i`. Одномерный случай (разрез) — `dim: 1`, `ny = 1`, `dy = null`, `y0 = 0`.
- Единицы СИ: м, с, м/с; b (reduced gravity g′) — м/с²; поток тепла — Вт/м² (+ — нагрев слоя).
- Нет значения — `null`; все перечисленные ключи обязательны; лишние ключи допустимы (читатель их пропускает).

## SW1 v1 — случай слоя
Владелец — координатор (формат), пишут: генератор случаев прототипа (SWC-4) и задачи опытов; читатель — решатель прототипа (SWC-4, `swc run`).

Модель v1 (Рипа, однослойная reduced gravity; над слоем — покоящаяся атмосфера), u = (u, v), η = z_b + h:
```
∂h/∂t     + ∇·(h u)                         = 0
∂(h u)/∂t + ∇·(h u⊗u) + ∇(½ b h²)            = −h b ∇z_b − c_d |u| u + f h k×u + h F
∂(h b)/∂t + ∇·(h b u)                         = −(g/θ0) · Q / (ρ c_p)
```
b = g·(θ_над − θ_слоя)/θ0 > 0 — слой тяжелее воздуха над ним. F — фоновый градиент давления, держит невозмущённый
поток: F = c_d |U0| U0 / h0 (вектор вдоль ветра), если `physics.forcing = "balance"`, иначе 0. Вовлечения в v1 нет.

JSON (`format: "sw-case"`, `version: 1`):
- `name` (строка, совпадает с именем файла без расширения), `dim` (1 | 2);
- `grid` {`nx`, `ny`, `dx`, `dy`, `x0`, `y0`};
- `ref` — невозмущённое состояние набегающего потока {`h0` м, `b0` м/с², `U0` м/с, `V0` м/с};
- `physics` {`cd` (безразм., квадратичное трение), `f_cor` (1/с), `theta0` К, `rho_cp` Дж/(м³·К), `g` м/с²,
  `h_min` м (порог сухой клетки), `b_min` м/с² (нижний предел b; клетки с b < b_min — в `b_clipped` SW3),
  `forcing` ("balance" | "none")};
- `bc` {`west`, `east`, `south`, `north`}: "farfield" (характеристическое условие к состоянию `ref`: входящие
  инварианты Римана — из `ref`, исходящие — изнутри; b и v на входе — из `ref`), "transmissive" (нулевой градиент),
  "wall", "periodic"; у `dim: 1` south/north — `null`;
- `sponge` — `null` или {`width_m`, `tau_s`}: у краёв x (и y при dim 2, кроме periodic) релаксация h, hu, hv, hb
  к `ref` с весом, растущим к краю от 0 до 1/`tau_s`;
- `run` {`t_end` с, `cfl` (≤ 0,9), `steady_tol`, `avg_from` с (с какого времени копить среднее; `null` — без среднего),
  `out_every` с (`null` — только итог)};
- `source` — откуда случай: {`kind` ("ideal" | "cascade2d" | "location"), `shape` ("flat" | "hill" | "ridge" |
  "step_up" | "step_down" | null), `s` (макс. крутизна, тангенс), `H` м (высота формы), `a` м (масштаб формы),
  `ref_case` (путь к исходному случаю или `null`)};
- `mapping` — `null` или {`U10`, `N`, `z_i`, `dtheta`, `rule`}: из каких условий модели игры получены `ref` и
  по какому правилу (`rule` — строка-ссылка на раздел документа); числовые поля — `null`, если не применимо;
- `arrays`: `zb` (ny, nx) м — высота земли в центрах; `q_heat` (ny, nx) Вт/м² — может отсутствовать (тогда 0);
  `h_init`, `hu_init`, `hv_init`, `b_init` (ny, nx) — могут отсутствовать (тогда старт h = max(0, h0 + z_ref − z_b)
  с z_ref = min z_b по западному краю, скорость из `ref` в мокрых клетках, b = b0).

Идеальные формы (как air-phase, `tools/research/air_synth/solver/reliefs.py`), центр x = 0:
hill/ridge — z = H·exp(−x²/a²) (·exp(−y²/a²) у hill при dim 2; ridge при dim 2 — постоянен по y),
a = H·√2·e^(−½)/s; step_up — z = H·(1 + tanh(x/a))/2, step_down — H·(1 − tanh(x/a))/2, a = H/(2s).

Инварианты: длины массивов = nx·ny; `h0 > 0`, `b0 > 0`, `dx > 0`; у `dim: 1` — `ny = 1`, `dy = null`.

## SW2 v1 — поле слоя
Владелец — решатель (SWC-4); потребители — задачи опытов и сравнения.
- Путь — `<out>/<case>.field.json` (+ `.bin`), промежуточные — `<out>/<case>.t<секунды, целое>.field.json`.
- JSON (`format: "sw-field"`, `version: 1`): `case` (имя SW1), `t` с, `steps`, `grid` (копия SW1), `ref` (копия SW1),
  `mean` {`t_from`, `t_to`, `n`} или `null`, `git`, `created` (ISO), `arrays`.
- Массивы (ny, nx): `zb`, `h` м, `hu`, `hv` м²/с, `hb` м³/с², `wet` (1 — мокрая, 0 — сухая клетка h < h_min);
  при `mean ≠ null` ещё `h_mean`, `u_mean`, `v_mean` (= ⟨hu⟩/⟨h⟩, ⟨hv⟩/⟨h⟩; в сухих — 0), `b_mean` (= ⟨hb⟩/⟨h⟩).
- Инварианты: в сухих клетках hu = hv = 0 и h < h_min; h ≥ 0 везде; у `dim: 1` hv = 0 и v_mean = 0.

## SW3 v1 — запись прогона
Владелец — решатель (SWC-4); потребители — задачи опытов, отчёты.
- Путь — `<out>/<case>.run.json` (без `.bin`).
- JSON (`format: "sw-run"`, `version: 1`): `case`, `field` (путь SW2 итога), `status` ("steady" | "averaged" |
  "max_time" | "diverged"), `t` с, `steps`, `wall_s`, `threads`, `dt_min`, `dt_mean`, `cfl`,
  `mass_rel_err` (|Σh − Σh_старт − Σ(поток через края)·dt| / Σh_старт), `steady_residual`, `dry_cells`,
  `b_clipped` (число клеток, где b упиралось в `b_min`), `notes` (строка), `git`, `created`.
- Критерий `steady`: T_c = (nx·dx)/(|U0| + √(b0·h0)), проверка через τ = 0,05·T_c;
  r = max по мокрым |hu(t) − hu(t − τ)| (и hv) / (h0·(|U0| + √(b0·h0))) — это `steady_residual`;
  `steady` — r < `steady_tol` на двух проверках подряд (счёт останавливается). Не достигнуто к `t_end`:
  `averaged`, если копилось среднее, иначе `max_time`. NaN/Inf или h < 0 — `diverged` (поле — последнее конечное).
