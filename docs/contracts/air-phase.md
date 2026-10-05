---
type: "contract"
status: "active"
module: "air-phase"
updated: "2026-10-06"
summary: "Контракты air-phase: P1 идеальные рельефы (reliefs.py + корпус S1 ideal_v1), P2 план опытов (protobuf), P3 результаты замеров (HDF5 + jsonl), P4 пакетный решатель с опциями, P5 интерфейс скрипта прогона run_phase.py"
related: ["docs/plan/air-phase.md", "docs/contracts/air-synth.md", "docs/research/air_phase.md"]
contracts: [{"id": "P1", "version": 1}, {"id": "P2", "version": 1}, {"id": "P3", "version": 1}, {"id": "P4", "version": 1}, {"id": "P5", "version": 1}]
---

# Контракты модуля air-phase

Общее: каталог данных `$AIR_SYNTH_DATA` (по умолчанию `~/air_synth_data`); код — `tools/research/air_phase/`
(кроме P1 — `tools/research/air_synth/solver/reliefs.py`); оси полей — как S5/П1 `d400_*`: `[случай, канал, высота AGL,
j, i]`, j — север, i — восток, u — на восток, v — на север; x0 = y0 = −19 200 м (центр области — (0, 0)). Файлы HDF5
пишутся один раз (временное имя → `os.replace`), `*.tmp` читатель игнорирует. Менять интерфейс — только через
координатора: версия +1, запись «что изменилось» здесь, правка потребителей в том же шаге.
Контрактный тест: `tools/research/air_phase/tests/test_contract_phase.py` (запуск — venv air_nn_pilot,
`python -m pytest -q tools/research/air_phase/tests`).

## P1. Идеальные рельефы (версия 1)
**Владелец:** AP-2. **Потребители:** AP-3 (P5), разбор.

- `reliefs.py`: `ideal_relief(shape: str, s: float, h_m: float = 500.0, length_m: float = 20000.0, base_m: float = 1000.0)
  -> (g100: float64 (384, 384), g400: float64 (96, 96))`; `load_ideal(specs) -> [(имя, g100, g400, scale_m)]` — тот же
  вид, что `load_proto`/`load_corpus`. g400 = блочное среднее 4 × 4 g100 (как S1). Узлы h100 — центры клеток:
  x_i = −19 200 + 50 + 100·i, y_j аналогично (i — восток, j — север).
- Формы (z над базой; ветер по умолчанию с запада, к +x):
  - `hill`: z = h·exp(−(x² + y²)/a²), a = h·√2·e^{−1/2}/s;
  - `ridge`: z = h·exp(−x²/a²)·T(y), T(y) = exp(−max(0, |y| − (L/2 − a))²/a²), a как у `hill`, L = `length_m`;
  - `step_up`: z = h·(1 + tanh(x/a))/2, a = h/(2s) (подъём по ветру; плато до восточного края);
  - `step_down`: z = h·(1 − tanh(x/a))/2 (спуск по ветру — подветренная бровка).
  s = max|∇z| (тангенс) по формуле — тест: численный max|∇z| на h100 совпадает с s в пределах 3 %
  (на g400 — записывается, но не проверяется: при s = 0,5 форма недоразрешена).
- Корпус: S1 (`docs/contracts/air-synth.md`; запись — `corpus_io.py`, атрибут `contract` как он пишет, сейчас "S1 v3") в `$AIR_SYNTH_DATA/corpus/ideal_v1/`, `generator_version = "ideal-v1"`,
  `relief_id` = `Relief.relief_id` плана P2, имя `place.name` = `<shape>_s<s:.2f>` (+ `_L<км>` для ridge, если не 20).
  Рельефы ERODED не копируются: P2 ссылается на `fs1_10k` по id.

## P2. План опытов — манифест protobuf (версия 1)
**Владелец:** AP-2 (`.proto` — координатор, `tools/research/air_phase/proto/phase_plan.proto`). **Потребители:** AP-3, разбор.

- Файлы: `$AIR_SYNTH_DATA/phase/<plan>/plan.pb` (сериализованный `Plan`) + `plan.json` (тот же план в JSON для людей,
  генерируется из pb) + `reliefs` — ссылка на корпус P1. `Plan.contract = "P2 v1"`.
- Линия — набор точек Fr при прочих равных; случай = (line_id, k), `case_id = first_case_id + k`, номера сквозные
  и плотные по плану. Порядок точек в линии = порядок счёта (`fr_f64`, little-endian float64 в `bytes`).
- `start = WARM_PREV`: случай k стартует с полного состояния (float32) случая k − 1 той же линии; k = 0 — холодный.
  `COLD` — фон (`init_background`). `direction` — UP/DOWN для SWEEP (порядок Fr уже в `fr_f64`), иначе DIR_NONE.
- `ref_line_id` — линия GRID той же конфигурации (для SWEEP/RELAX/SEPARATION-400 м), −1 — нет.
- Значения по умолчанию (поле 0 в proto3) не используются как «не задано»: построитель заполняет все поля `Numerics`
  явно; `n_bv_s`, `h_over_zi`, `heat_flux_wm2` — всегда заданы (override), `wdir_from_deg` — всегда задан.
- Серии и состав — план модуля §3; построитель печатает число линий и случаев по сериям.

## P3. Результаты замеров — HDF5 + jsonl (версия 1)
**Владелец:** AP-3. **Потребители:** разбор (следующий этап), отчёт на шлюзе.

- Каталог: `$AIR_SYNTH_DATA/phase/<plan>__<solver_version>/`: `part-{n:05d}.h5` (одна часть = один посчитанный пакет,
  n — по порядку записи), `progress.jsonl` (строка на случай: `case_id, line_id, k, series, status, iters, seconds,
  part, batch_size, t` ISO), `run.jsonl` (строка на пакет/запуск: время, размер, устройство, ошибки), `ckpt/line-<id>.h5`
  (float32 состояние последнего случая незавершённой линии с тёплым стартом; удаляется, когда линия досчитана),
  `trial.json`, `bench.json`.
- Атрибуты корня части: `contract = "P3 v1"`, `kind = "phase"`, `plan` (путь), `plan_sha256`, `solver_version`
  (`s<n>-<7 знаков хеша air3d/*.py и batch-модуля>`), `device`, `batch_size`, `git_commit`, `created`, `command`,
  `n_records`, `agl_m` (13 высот S5), `snap_levels_agl_m` = [25, 600].
- Наборы части (M — случаев в части, ось 0 — случай):

  | набор | форма, тип | что |
  |---|---|---|
  | `cases` | (M,) составной | `case_id` i8, `line_id` i4, `k` i4, `series` i1 (enum P2), `relief_id` i4, `fr` f4 (цель), `froude_table` f4 (`conditions.derive`), `u10` f4, `u_sat` f4, `wdir_from_deg` f4, `n_bv` f4, `z_i_agl_m` f4, `heat_flux_wm2` f4, `zi_over_L` f4 (−z_i/L), `dx_m` f4, `start_case_id` i8 (−1 — холодный), `status` i1 (0 ok, 1 max, 2 diverged), `iters` i4, `target` i1 (0 final, 1 late_mean), `late_n` i2, `late_spread60_p90` f4 (м/с), `resid_final` f4, `resid_rel_final` f4, `seconds` f4 (стенное время пакета / M), `batch_size` i2 |
  | `fields/f` | (M, 4, 13, 96, 96) f2 | итог: u, v, w (м/с), θ′ (К) на 13 высотах S5 |
  | `inputs/hc`, `inputs/heat_flux`, `inputs/hbl` | (M, 96, 96) f4, f2, f2 | как S5 |
  | `trace/iter` | (M, T) i4 | итерации снимков 100, 150, … ≤ max_outer; −1 — снимка нет (сошлось раньше) |
  | `trace/resid`, `trace/du_max` | (M, T) f4 | метрика сходимости; max\|u_t − u_{t−50}\| (м/с) |
  | `trace/fields` | (M, T, 3, 2, 96, 96) f2 | u, v, w на 25 и 600 м в моменты снимков |
  | `order` | (M,) составной | параметры порядка §4.1 из итогового поля — `phase_stats.field_features` (имена полей — как у функции) |
  | `window/fields` | (Mw, 4, Kw, Nyw, Nxw) f2 | только серия SEPARATION с dx = 100 м: поле окна; атрибуты `dx_m`, `x0_m`, `y0_m`, `agl_m` окна, `case_id` (Mw,) |
  | `bubble` | (M,) составной | только SEPARATION (оба dx): `has_reverse` i1, `L_over_h`, `H_over_h` f4 (длина по ветру от бровки до присоединения и высота области u·e < 0 в вертикальном сечении по ветру через центр формы), `urev_over_U` f4 (min u·e у земли / U_sat, ≤ 0), `xc_over_h`, `zc_over_h` f4 (центр вихря — экстремум функции тока ψ в сечении, x от бровки, z над землёй), `area_rev_frac` f4 (доля площади окна с обратным течением на нижнем уровне), `shadow_angle_deg` f4 (угол «линии тени»: atan(Δz/L) от бровки до точки присоединения у земли, Δz — перепад бровка → земля в точке присоединения; −1, если обратного течения нет), `fr_local` f4 (U притока на высоте бровки / (N·h)), `slope_lee` f4 (max уклон подветренного склона на сетке случая) — числа для калибровки `configs/atmosphere.json` → `lee` (shadow_angle_deg, rotor_reverse, rotor_height_fraction, depth_scale_m, relief_scale_m) и порогов по крутизне и местному Fr |

  T = (max_outer − 100)/50 + 1 (19 при 1000). Чанк — один случай, gzip 4 + shuffle. Значения конечные: NaN — ошибка
  записи; разошедшееся решение — нули и status 2 (как S5).
- Инварианты: часть пишется только целиком; набор посчитанных случаев = объединение `cases/case_id` по частям
  (`progress.jsonl` — для людей и ETA, не источник правды); дублей `case_id` нет; повтор случая на том же устройстве и
  версии с тем же составом пакета — побитно. Бюджет диска на весь счёт — ≤ 20 ГБ (иначе — шлюз).

## P4. Решатель: пакетный вызов и опции (версия 1)
**Владелец:** AP-1 (`tools/research/air_phase/batch_solver.py`; правки `air3d` допустимы при соблюдении инварианта 1).
**Потребители:** AP-3.

```python
@dataclass
class CaseSpec:            # один случай
    g100: np.ndarray       # (384, 384) float64, м н. у. м. (P1 / S1)
    ctx: dict              # lat, lon, month, day, hour_local, utc_offset (Plan.context)
    u10: float; wdir_from_deg: float; alpha: float; max_profile: float
    n_bv_s: float | None; z_i_agl_m: float | None; heat_flux_wm2: float | None   # None — путь S2/решателя как есть
    dx_m: float = 400.0    # 100.0 — окно 100 м вокруг формы (SEPARATION), область 400 м — как есть
@dataclass
class Numerics:            # как P2 Numerics
    advection_order: int = 1; omega_u: float = 1.0; omega_k: float = 1.0; k_floor_m2s: float | None = None
    criterion: str = "abs"; tol: float | None = None; max_outer: int = 1000
    snap_from: int = 100; snap_step: int = 50; late_from: int = 500; late_step: int = 50
def solve_batch(specs: list[CaseSpec], num: Numerics | list[Numerics],
                init: list[State | None] | None = None) -> list[CaseResult]
# CaseResult: status, iters, target, late_n, late_spread60_p90, resid_final, resid_rel_final,
#   fields (4, 13, 96, 96) f4, hc/heat_flux/hbl (96, 96), trace {iter, resid, du_max, fields},
#   state (для тёплого старта, float32), window (поле окна, если dx_m = 100), seconds, froude_table, zi_over_L
```
- Инвариант 1: пакет из 1 случая, без override, `Numerics()` по умолчанию — поле побитно как решение «h»
  `airlite_gen.solve_case` (тот же рельеф и условия). Тест.
- Инвариант 2: пакет B > 1 против тех же случаев по одному: одинаковые `status`, |Δiters| ≤ 2 % , max|Δu| ≤ 1e-3 м/с
  у сошедшихся; измеренное расхождение — в отчёт. Случаи пакета могут иметь разные `Numerics` и сходиться в разное
  время (сошедшийся замораживается, остальные считаются дальше).
- Инвариант 3 (override): N — dθ/dz = θ₀N²/g над z_i, под z_i — перемешанный слой; z_i — над базой рельефа; H —
  однородный поток явного тепла (Вт/м²). `froude_table` из `conditions.derive` при этих override = цель Fr ± 1 %.
- Инвариант 4 (тёплый старт): вдали от границ (Fr = 3, s = 0,15, H = 0) тёплый и холодный старт дают одно поле
  (max|Δu| ≤ 0,02·U_sat).
- Относительный критерий: метрика решателя / её масштаб (скорость — U_sat; невязка импульса — U_sat²/a); порог по
  умолчанию — равный нынешнему абсолютному при U_sat = 5 м/с. Определение метрики — в docstring и отчёте.
- `k_floor_m2s` — нижний предел турбулентной K вместо k_fa = 1 м²/с; `omega_*` — недорелаксирование
  u ← u + ω(u* − u), K ← K + ω(K* − K).
- Окно 100 м — вложенное окно решателя (`init_nest`/`set_nest_bc`) с переносом 2-го порядка; размер и положение (по ветру
  от бровки должно влезать ≥ 15 h) — атрибуты результата.
- Замер батча: `bench.json` — пропускная способность (случаев/ч) по B (и, для сравнения, по числу процессов на GPU),
  пик памяти GPU; выбранный B по умолчанию — константа в `batch_solver.py`.

## P5. Скрипт прогона `run_phase.py` (версия 1)
**Владелец:** AP-3. **Потребители:** большой запуск, координатор (шлюз).

```
run_phase.py plan   [--name ap_v1] [--series grid,sweep,relax,separation,eroded] [--out $AIR_SYNTH_DATA/phase]
run_phase.py run    --plan DIR [--series …] [--batch B] [--limit N] [--out DIR]
run_phase.py trial  --plan DIR [--out DIR]       # малый набор по всем сериям → trial.json (время/случай по сериям, оценка часов и ГБ)
run_phase.py bench  [--batch 1,2,4,8,16,32] [--n 32]   # → bench.json (P4)
run_phase.py status --plan DIR [--out DIR]       # готово/всего по сериям, ETA, объём
tools/research/air_phase/run_all.sh              # plan (если нет) + run всех серий; для dp job --lock gpu
```
- `run` — все серии одной командой, порядок GRID → SEPARATION → SWEEP → RELAX → ERODED; продолжение — той же командой
  (посчитанное по частям P3 пропускается, тёплые цепочки — с `ckpt/`; нет ckpt — пересчитать предыдущий случай линии).
- Пакет: поперёк линий (точка k многих линий); случаи одной цепочки WARM_PREV — строго последовательно.
- Убийство процесса в любой момент не портит каталог (части атомарны); код выхода 0 — всё посчитано, ≠ 0 — ошибка
  (NaN, исключение) с записью в `run.jsonl`.
- Без Godot; GPU — только под общим замком (`dp job --lock gpu start air-phase-run <таймаут> …/run_all.sh`).
