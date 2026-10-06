---
type: "reference"
status: "active"
module: "air-model"
updated: "2026-10-06"
summary: "air-phase: код и команды воспроизведения эмпирической фазовой карты по полям решателя SY-12 (признаки на случай, таблицы, рисунки) и схемы фазовой диаграммы"
related: ["docs/research/air_phase.md", "docs/research/air_phase_experts.md", "docs/research/air_phase_refs.md"]
---
# air-phase: воспроизведение

Итог и выводы — `docs/research/air_phase.md` (+ `air_phase_experts.md`, `air_phase_refs.md`). Здесь — код. Только CPU, Godot и GPU не нужны.

```bash
PY=/home/greg/deltaplan-air-synth-SY-11/tools/research/air_nn_pilot/.venv/bin/python   # numpy, scipy, h5py, matplotlib
$PY tools/research/air_phase/phase_stats.py --recompute   # признаки из полей (7320 + 96 случаев) → out/per_case*.npz, tables.md, summary.json, fig_*.png
$PY tools/research/air_phase/phase_stats.py               # таблицы и рисунки из кэша
$PY tools/research/air_phase/phase_diagram.py             # схема диаграммы → out/fig_phase_schematic.png
cp tools/research/air_phase/out/fig_{phase_schematic,nonconv_fr_hg,slowing_hg,order_hg,cases_hg,local_phase}.png docs/research/air_phase/
```

Данные (только чтение, `$AIR_SYNTH_DATA` или `~/air_synth_data`): `solve/hg_v2__hgw24__s0-939a467` (S5 v4), `conditions/hg_v2_hgw24` (S2 v4), `real/hg_v2` (S1 v4); места игры — `solve/game2__hgw24__s0-939a467`, `conditions/game2_hgw24`, `real/game_hg2`.

Файлы: `phase_stats.py` — признаки на случай (параметры порядка по полям m/h: застой, поворот, обратное течение, разгон, σ_w, конвективная добавка; оси Fr, w*/U, −z_i/L, крутизна, Δh/z_i), статистика сходимости Пикара по осям, логистическая регрессия, сигмоиды, разделимость, карта фаз одного случая; `phase_diagram.py` — схематические диаграммы по порогам из литературы. `out/` — результаты (per_case.npz ~2 МБ, рисунки).

## Замеры фаз на идеальном рельефе (модуль air-phase, AP-3): прогон всех серий

Контракты — `docs/contracts/air-phase.md` (P2 план, P3 результаты, P4 решатель, P5 этот скрипт); план — `docs/plan/air-phase.md`.

```bash
PY=/home/greg/deltaplan-air-synth/tools/research/air_nn_pilot/.venv/bin/python
D=${AIR_SYNTH_DATA:-$HOME/air_synth_data}
$PY tools/research/air_phase/run_phase.py plan --name ap_v1                  # план P2 (plan_build.build_plan, AP-2)
/home/greg/deltaplan/tools/dp lock gpu ap3-trial -- $PY tools/research/air_phase/run_phase.py trial --plan $D/phase/ap_v1
                                                                             # → $D/phase/ap_v1_trial__<v>/ + out/trial.json
/home/greg/deltaplan/tools/dp job --lock gpu start air-phase-run <таймаут_с> $PWD/tools/research/air_phase/run_all.sh
                                                                             # весь счёт; продолжение — та же команда
$PY tools/research/air_phase/run_phase.py status --plan $D/phase/ap_v1      # готово/всего по сериям, ETA, объём
$PY -m pytest -q tools/research/air_phase/tests                             # контракт + каркас на заглушке (+ GPU-тест под замком)
```

- Файлы: `run_phase.py` — подкоманды P5, планировщик пакетов; `phase_io.py` — план → случаи (Fr → U10: U_sat = Fr·N·h,
  U10 = U_sat/max_profile), запись части P3 (процесс-писатель), ckpt тёплых цепочек; `bubble.py` — параметры пузыря
  обратного течения (метод — в docstring); `run_all.sh` — план, если нет, + run всех серий.
- Пакет: `solve_batch` (AP-1) держит B случаев одновременно (скользящее окно, B — `batch_solver.B_DEFAULT`); вызов —
  `chunk` = 4B случаев (= одна часть P3). Готовые случаи сортируются по (серия GRID → SEPARATION → ENVELOPE →
  ENVELOPE_REAL → SWEEP → RELAX → ERODED, k, case_id) и берутся одной группой шага сетки: поперёк линий.
- Продолжение: посчитанное — объединение `cases/case_id` частей; тёплая цепочка — с `ckpt/line-<id>.h5` (пишется после
  части); если ckpt нет или он новее нужного — предыдущие случаи цепочки пересчитываются без записи.
- `order` — `phase_stats.field_features(f, e, u10, alpha, max_profile, "f")` по итоговому полю (имена с префиксом `f_`).
- `window/` (SEPARATION, dx = 100 м): `fields` (дополнены нулями до наибольшего окна части, настоящая форма —
  `window/shape`), `hc` (земля окна), `case_id`, `x0_m`, `y0_m` (угол окна; центры клеток x0 + 50 + 100·i), `status`,
  `iters`, `brink_x_m/brink_y_m`, `downwind_fit_over_h` — сверх контракта.
- Данные (не в git): `$AIR_SYNTH_DATA/phase/ap_v1__<solver_version>/` (полный счёт), `…/ap_v1_trial__<v>/` (проба).

## Разбор (этап 2): метрики слоёв, таблица признаков, сигмоиды (AP-6, контракт P6)

Критерий пользователя: качество поля — по тому, что из него берут слои игры (термики масштаба 2, подъём у склонов,
подветренная зона масштаба 3), а не по м/с. Формулы и пороги — из кода игры, ссылки на файлы/строки — в docstring
`layer_metrics.py`, описание каждой метрики с единицей и пометкой [игра]/[физика] — `layer_metrics.NAMES` и атрибут
`p6_names` таблицы.

```bash
PY=/home/greg/deltaplan-air-synth/tools/research/air_nn_pilot/.venv/bin/python
D=${AIR_SYNTH_DATA:-$HOME/air_synth_data}/phase
$PY tools/research/air_phase/features.py --plan $D/ap_v1 --results $D/ap_v1__s1-74644c4   # → $D/features_ap_v1.h5 (~4 мин, 16 процессов)
$PY tools/research/air_phase/features.py --plan $D/ap_v2 --results $D/ap_v2__s1-74644c4   # → $D/features_ap_v2.h5
$PY -m pytest -q tools/research/air_phase/tests/test_layer_metrics.py                     # синтетика: подветр, склон, термик, сигмоида
env AP_FEATURES=$D/features_ap_v1.h5 $PY -m pytest -q tools/research/air_phase/tests/test_contract_phase.py -k features_table
```

- `layer_metrics.py` — `layer_metrics(f, hc, heat_flux, hbl, case, *, w_mech=None)` → dict `th_*` (источники термиков,
  сила w0 = 1,24 w*, потолок частицы, снос — `air_thermals.gd::build`), `sl_*` (w слоя 50–300 м > 1 м/с над наветренным
  склоном; порог — min_sink крыльев игры), `lee_*` (признак отрыва поля `field_turbulence.gd::lee`, ΔU слоя смешения,
  разрешённое обратное течение); `layer_diff(a, b)` — разности; `layer_masks` + `iou` — совпадение карт слоёв.
- `features.py` — таблица `$AIR_SYNTH_DATA/phase/features_<plan>.h5` (P6 v2: в каталоге данных, не в копии; `--out` — иначе): все поля `cases`, `order`, `bubble`
  (bub_*), метрики слоёв, `w100_sl_*`/`w100_lee_*` по окну 100 м (SEPARATION), поля плана; `ref_case_id` (по
  `Line.ref_line_id`, тот же Fr ±1 %), `ref400_case_id` (ENVELOPE → SEPARATION 400 м без огибающей), `mech_case_id`
  (близнец H = 0 — w_mech для w_conv и вертикали склонов/подветра), `ref_iou_*` (IoU карт с ref_case_id).
- `sigmoid.py` — `fit_sigmoid(x, y, *, log=True, n_boot=200, noise=None)`: y = y₀ + Δy·σ((log x − log x_c)/w),
  бутстрэп-интервалы; резкая — w < 0,1 декады или скачок > 3σ шума стартов, плавная — w > 0,3.
- Отступления от игры (в P3 нет w_mech и кромки облаков, высоты над землёй решателя, верх поля 2000 м) — шапка
  `layer_metrics.py`.

### Разбор AP-8 (границы фаз GRID, второй старт, гистерезис)
`$PY tools/research/air_phase/analysis/AP-8/run.py --workers 16` (CPU, ≈ 70 мин) → `analysis/AP-8/{summary.json, section.md, fig_*.png, pairs.npz}`;
кэш подгонок — `out/AP-8/fits.json`, `fits_ok.json` (не в git, ~10 МБ; `--stage report` пересобирает сводку из кэша).
