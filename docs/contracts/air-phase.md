---
type: "contract"
status: "active"
module: "air-phase"
updated: "2026-10-06"
summary: "Контракты air-phase: P1 идеальные рельефы, P2 план опытов (protobuf), P3 результаты замеров (HDF5 + jsonl), P4 пакетный решатель, P5 скрипт прогона run_phase.py, P6 метрики слоёв и таблица признаков, P7 выход задач разбора"
related: ["docs/plan/air-phase.md", "docs/contracts/air-synth.md", "docs/research/air_phase.md"]
contracts: [{"id": "P1", "version": 1}, {"id": "P2", "version": 5}, {"id": "P3", "version": 3}, {"id": "P4", "version": 4}, {"id": "P5", "version": 1}, {"id": "P6", "version": 2}, {"id": "P7", "version": 1}]
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

## P2. План опытов — манифест protobuf (версия 5)
**Владелец:** AP-2 (`.proto` — координатор, `tools/research/air_phase/proto/phase_plan.proto`). **Потребители:** AP-3, разбор.

- Файлы: `$AIR_SYNTH_DATA/phase/<plan>/plan.pb` (сериализованный `Plan`) + `plan.json` (тот же план в JSON для людей,
  генерируется из pb) + `reliefs` — ссылка на корпус P1. `Plan.contract = "P2 v5"` (ap_v1 — "P2 v3", ap_v2 — "P2 v4": читаются, новые версии только добавляют поля).
- Линия — набор точек Fr при прочих равных; случай = (line_id, k), `case_id = first_case_id + k`, номера сквозные
  и плотные по плану. Порядок точек в линии = порядок счёта (`fr_f64`, little-endian float64 в `bytes`).
- `start = WARM_PREV`: случай k стартует с полного состояния (float32) случая k − 1 той же линии; k = 0 — холодный.
  `COLD` — фон (`init_background`). `direction` — UP/DOWN для SWEEP (порядок Fr уже в `fr_f64`), иначе DIR_NONE.
- `ref_line_id` — линия GRID той же конфигурации (для SWEEP/RELAX/SEPARATION-400 м), −1 — нет.
- Значения по умолчанию (поле 0 в proto3) не используются как «не задано»: построитель заполняет все поля `Numerics`
  явно; `n_bv_s`, `h_over_zi`, `heat_flux_wm2` — всегда заданы (override), `wdir_from_deg` — всегда задан.
- Серии и состав — план модуля §3; построитель печатает число линий и случаев по сериям.
- **v2 (06.10, решение пользователя — огибающая «линии тени» как склон для Пикара):** серии `ENVELOPE` (идеальные формы)
  и `ENVELOPE_REAL` (реальные места); `Numerics.envelope_angle_deg` (0 — без огибающей), `envelope_wall`
  (`WALL_GROUND` | `WALL_LOW_Z0` | `WALL_SLIP`), `envelope_z0_m`; `Line.conditions` + `cond_id` — случай из строки таблицы
  S2 (override-поля линии не действуют, `fr_f64` — одна точка = `froude` таблицы), иначе `""` и −1. Инвариант:
  `envelope_angle_deg > 0` ⇔ `envelope_wall != WALL_NONE`. `ref_line_id` у ENVELOPE — линия SEPARATION с dx = 100 той же
  формы/s/Fr/H/угла ветра (эталон); у ENVELOPE_REAL — линия той же (relief_id, cond_id) без огибающей.
- **v3 (06.10):** у линий с `conditions` поле `heat_flux_wm2` выбирает решение S5: `−1` — «h» (с нагревом, как S2),
  `0` — «m» (без нагрева); прочие override-поля не действуют. Состав ENVELOPE_REAL — план §3.
- **v4 (06.10, план ap_v2):** серия `FIXED_U = 8` — Fr меняется при фиксированном U_sat через N и h (отделить
  блокирование D от штиля H, air_phase.md §5.2). Высота формы — `Relief.h_m` (не `Context.h_m`, тот — значение
  по умолчанию); всё, что зависит от h (U10 из Fr, z_i = h/h_over_zi, масштаб a относительного критерия, доли h в
  `bubble`), берётся из рельефа линии. Корпус идеальных форм ap_v2 — `corpus/ideal_v2` (P1, имя `<shape>_s<s>_h<h>`).
- **v5 (06.10, AP-13):** `Numerics.top_above_m` (верх области над max рельефа, по умолчанию 3000 м) и `sponge_top_m`
  (губка у верха, по умолчанию 1000 м); построитель пишет явно; 0 (старые планы) = значение по умолчанию.
  `Relief.relief_id` — уникален в плане (на него ссылаются `Line.relief_id` и P3 `cases.relief_id`), id в корпусе — `Relief.corpus_relief_id` (у ideal_v1 совпадает с relief_id), корпус — `Relief.corpus`; пара (corpus, corpus_relief_id) уникальна.

## P3. Результаты замеров — HDF5 + jsonl (версия 3)
**Владелец:** AP-3. **Потребители:** разбор (следующий этап), отчёт на шлюзе.

- Каталог: `$AIR_SYNTH_DATA/phase/<plan>__<solver_version>/`: `part-{n:05d}.h5` (одна часть = один посчитанный пакет,
  n — по порядку записи), `progress.jsonl` (строка на случай: `case_id, line_id, k, series, status, iters, seconds,
  part, batch_size, t` ISO), `run.jsonl` (строка на пакет/запуск: время, размер, устройство, ошибки), `ckpt/line-<id>.h5`
  (float32 состояние последнего случая незавершённой линии с тёплым стартом; удаляется, когда линия досчитана),
  `trial.json`, `bench.json`.
- Атрибуты корня части: `contract = "P3 v2"`, `kind = "phase"`, `plan` (путь), `plan_sha256`, `solver_version`
  (`s<n>-<7 знаков хеша air3d/*.py и batch-модуля>`), `device`, `batch_size`, `git_commit`, `created`, `command`,
  `n_records`, `agl_m` (13 высот S5), `snap_levels_agl_m` = [25, 600].
- Наборы части (M — случаев в части, ось 0 — случай):

  | набор | форма, тип | что |
  |---|---|---|
  | `cases` | (M,) составной | `case_id` i8, `line_id` i4, `k` i4, `series` i1 (enum P2), `relief_id` i4, `fr` f4 (цель), `froude_table` f4 (`conditions.derive`), `u10` f4, `u_sat` f4, `wdir_from_deg` f4, `n_bv` f4, `z_i_agl_m` f4, `heat_flux_wm2` f4, `zi_over_L` f4 (−z_i/L), `dx_m` f4, `start_case_id` i8 (−1 — холодный), `status` i1 (0 ok, 1 max, 2 diverged), `iters` i4, `target` i1 (0 final, 1 late_mean), `late_n` i2, `late_spread60_p90` f4 (м/с), `resid_final` f4, `resid_rel_final` f4, `seconds` f4 (стенное время пакета / M), `batch_size` i2, `cond_id` i4 (−1 — override), `envelope_angle_deg` f4, `envelope_wall` i1 |
  | `fields/f` | (M, 4, 13, 96, 96) f2 | итог: u, v, w (м/с), θ′ (К) на 13 высотах S5 |
  | `inputs/hc`, `inputs/heat_flux`, `inputs/hbl` | (M, 96, 96) f4, f2, f2 | как S5 (`hc` — настоящая земля) |
  | `inputs/h_eff` | (M, 96, 96) f4 | только ENVELOPE / ENVELOPE_REAL: верх огибающей, м н. у. м. (= `hc` вне тени); высоты `fields/f` — над h_eff |
  | `trace/iter` | (M, T) i4 | итерации снимков (фактически 101, 151, … ≤ max_outer+1, как solve_late — настоящие номера); −1 — снимка нет (сошлось раньше) |
  | `trace/resid`, `trace/du_max` | (M, T) f4 | метрика сходимости; max\|u_t − u_{t−50}\| (м/с) |
  | `trace/fields` | (M, T, 3, 2, 96, 96) f2 | u, v, w на 25 и 600 м в моменты снимков |
  | `order` | (M,) составной | параметры порядка §4.1 из итогового поля — `phase_stats.field_features` (имена полей — как у функции) |
  | `window/fields` | (Mw, 4, Kw, Nyw, Nxw) f2 | только серия SEPARATION с dx = 100 м: поле окна; атрибуты `dx_m`, `x0_m`, `y0_m`, `agl_m` окна, `case_id` (Mw,) |
  | `bubble` | (M,) составной | только SEPARATION (оба dx): `has_reverse` i1, `L_over_h`, `H_over_h` f4 (длина по ветру от бровки до присоединения и высота области u·e < 0 в вертикальном сечении по ветру через центр формы), `urev_over_U` f4 (min u·e у земли / U_sat, ≤ 0), `xc_over_h`, `zc_over_h` f4 (центр вихря — экстремум функции тока ψ в сечении, x от бровки, z над землёй), `area_rev_frac` f4 (доля площади окна с обратным течением на нижнем уровне), `shadow_angle_deg` f4 (угол «линии тени»: atan(Δz/L) от бровки до точки присоединения у земли, Δz — перепад бровка → земля в точке присоединения; −1, если обратного течения нет), `fr_local` f4 (U притока на высоте бровки / (N·h)), `slope_lee` f4 (max уклон подветренного склона на сетке случая) — числа для калибровки `configs/atmosphere.json` → `lee` (shadow_angle_deg, rotor_reverse, rotor_height_fraction, depth_scale_m, relief_scale_m) и порогов по крутизне и местному Fr |

  **v3 (06.10, AP-10):** `bubble.fr_local` = U(h)/(N·h) по невозмущённому профилю притока (α, max_profile), не по колонне
  поля у края; сечение — через бровку окна (`brink_x_m/brink_y_m`) или наибольший подветренный уклон, а не через (0, 0)
  (косой ветер). Части ap_v1 записаны по v2 (старые `fr_local`, у косых случаев has_reverse = 0) и поля `bub_*` таблицы
  признаков — тоже: для SEPARATION брать пересчёт `tools/research/air_phase/analysis/AP-10/out/bubble_v2.csv`.
  T = (max_outer − 100)/50 + 1 (19 при 1000). Чанк — один случай, gzip 4 + shuffle. Значения конечные: NaN — ошибка
  записи; разошедшееся решение — нули и status 2 (как S5).
- Инварианты: часть пишется только целиком; набор посчитанных случаев = объединение `cases/case_id` по частям
  (`progress.jsonl` — для людей и ETA, не источник правды); дублей `case_id` нет; повтор случая на том же устройстве и
  версии с тем же составом пакета — побитно. Бюджет диска на весь счёт — ≤ 20 ГБ (иначе — шлюз).

## P4. Решатель: пакетный вызов и опции (версия 4)
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
    cond_row: dict | None = None   # строка S2 (ENVELOPE_REAL): условия как solve_corpus; n_bv_s/z_i None;
                                   # heat_flux_wm2: None — решение «h» (нагрев по S2), 0.0 — решение «m» (v3)
@dataclass
class Numerics:            # как P2 Numerics
    advection_order: int = 1; omega_u: float = 1.0; omega_k: float = 1.0; k_floor_m2s: float | None = None
    criterion: str = "abs"; tol: float | None = None; max_outer: int = 1000
    snap_from: int = 100; snap_step: int = 50; late_from: int = 500; late_step: int = 50
    envelope_angle_deg: float = 0.0; envelope_wall: str = "none"; envelope_z0_m: float | None = None  # none|ground|low_z0|slip
    top_above_m: float = 3000.0; sponge_top_m: float = 1000.0   # v4: верх области и губка; по умолчанию — побитно как v3
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
- **Огибающая (v2):** h_eff = max(h, линия тени), линия тени — от каждой бровки по ветру вниз под углом
  `envelope_angle_deg` к горизонту (марш по направлению ветра на сетке 400 м; бровка — клетка, за которой склон по ветру
  круче угла). Объём под огибающей — твёрдое тело для решателя (терренный σ-уровень по h_eff или маска `active` — на выбор
  исполнителя, способ — в docstring); на верхней грани огибающей — граница `envelope_wall` (ground — как земля; low_z0 —
  z0 = `envelope_z0_m`; slip — нулевое касательное напряжение; если решатель slip не умеет — реализовать или вернуть
  отказ `NotImplementedError` с записью в отчёт), вне тени — земля как есть. Поток тепла клетки — с настоящей земли
  (солнце по уклону/азимуту настоящего h) и подаётся на верх огибающей. Без огибающей — побитно как v1. Результат
  дополнительно: `h_eff` (96, 96).
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
- `trial` пишет в отдельный каталог `$AIR_SYNTH_DATA/phase/<plan>_trial__<solver_version>/` (формат P3, с полным счётом не
  смешивается) и копию `trial.json` в `tools/research/air_phase/out/trial.json` (поля как минимум: время на случай по сериям,
  `full_estimate_hours`, `full_estimate_gb`, размер батча, число случаев по сериям).
- Пакет: поперёк линий (точка k многих линий); случаи одной цепочки WARM_PREV — строго последовательно.
- Убийство процесса в любой момент не портит каталог (части атомарны); код выхода 0 — всё посчитано, ≠ 0 — ошибка
  (NaN, исключение) с записью в `run.jsonl`.
- Без Godot; GPU — только под общим замком (`dp job --lock gpu start air-phase-run <таймаут> …/run_all.sh`).

## P6. Метрики слоёв и таблица признаков (версия 2)
**Владелец:** AP-6 (`tools/research/air_phase/layer_metrics.py`, `features.py`). **Потребители:** AP-7…AP-11.

- Критерий (решение пользователя 06.10): величины, которые из поля масштаба 1 берут следующие слои игры. Функция
  `layer_metrics(f: (4, 13, 96, 96) f4 [u, v, w, θ′], hc, heat_flux, hbl: (96, 96), case: dict) -> dict[str, float]`
  (case — строка `cases` P3 + h, s, форма из плана), только numpy, без GPU. Группы (имена с префиксом):
  `th_*` — термики (источники: где и сколько — доля площади/число и положение относительно вершины; сила — w* или
  подъём ядра по формулам масштаба 2 игры; потолок; снос — средний ветер в слое 0…z_i); `sl_*` — динамический подъём
  у склонов (площадь и средняя сила w > порог у наветренного склона на 50–300 м над землёй); `lee_*` — подветренная
  зона и ротор (площадь опускания/обратного течения за гребнем, глубина, сила). Формулы и пороги — из кода игры
  (`scripts/atmosphere/`, `docs/guide/air-model.md`, `docs/guide/atmosphere.md`) со ссылками на строки; чего в игре нет —
  физически обоснованно, помечено. Плюс разности метрик между двумя полями `layer_diff(a, b) -> dict` (для RELAX,
  SWEEP, ENVELOPE: «меняет ли решатель то, что видит слой»).
- **v2 (06.10):** общая таблица лежит в каталоге данных `$AIR_SYNTH_DATA/phase/features_<plan>.h5` (копии задач удаляются вместе с out/); `features.py --out` пишет туда же. Сравнение ENVELOPE с эталоном 100 м — по самому окну (`window/*`, метрики `w100_*`), не по `fields/f` эталона (это область 400 м).
- Таблица (v1: `tools/research/air_phase/out/features_<plan>.h5`) — (N,) составной набор `features`: все поля `cases` P3 + `order`
  P3 + `layer_metrics` + из плана: `shape`, `slope`, `h_m`, `h_over_zi`, `variant`, `ref_case_id` (холодный случай той же
  конфигурации — для SWEEP/RELAX/ENVELOPE), `u10`, `fr`; атрибуты `plan`, `results`, `git_commit`, `p6_names` (описание
  полей с единицами, JSON). Таблица пересобирается командой `features.py --plan <dir> --results <dir>` (CPU, пул
  процессов); файл в out/ не коммитится (в .gitignore), путь — в README.
- `fit_sigmoid(x, y, *, log=True, n_boot=200) -> {x_c, w_dec, y0, dy, x_c_ci, w_ci, sharp, smooth}` — модель §9 п. 6
  (y = y₀ + Δy·σ((log x − log x_c)/w)), резкая — w < 0,1 декады или скачок > 3σ шума между стартами, плавная — w > 0,3.

## P7. Выход задач разбора (версия 1)
**Владелец:** каждая задача AP-7…AP-11. **Потребитель:** AP-12 (сборка `docs/research/air_phase_results.md`).

- Каталог `tools/research/air_phase/analysis/<ID>/`: `run.py` (всё одной командой из `features_*.h5` и частей P3),
  `summary.json` (числа выводов: пороги, ширины, доли — с единицами в именах), `section.md` (готовый текст раздела по-русски:
  вывод → числа/таблица → оговорки и границы модели → ссылки на рисунки `fig_*.png` относительными путями; первая строка
  после заголовка — команда воспроизведения), `fig_*.png` (≤ 6, агенты их не открывают). Всё коммитится (данные
  исследования), кроме больших промежуточных файлов (> 5 МБ — в out/, не коммитить).
