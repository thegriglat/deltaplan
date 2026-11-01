---
type: contract
status: "active"
module: trike-fix
area: flight
updated: "2026-11-02"
summary: "Стыки trike-fix: замер углов тележки к крылу и сценарии (TKF-К1), замер отклика на штангу дельталёта (TKF-К2)."
related: ["docs/plan/trike-fix.md", "docs/contracts/trike-pilot.md", "docs/contracts/tow-trike.md"]
contracts: [{"id": "TKF-К1", "version": 1}, {"id": "TKF-К2", "version": 1}]
---
# Контракты trike-fix (код задач TKF)

## TKF-К1 v1. Углы тележки к крылу: определения, сценарии, `summary.json`
Владелец — TKF-1 (инструмент, данные, `check_summary.py`); потребители — TKF-4 (тест с порогами — v2 этого раздела),
TKF-7 (кадры и таблица «после» тем же инструментом). Контрактный тест — `tools/research/trike-fix/check_summary.py
<summary.json>` (пишет TKF-1): exit 0 — схема и единицы верны.

**Тела и базисы** (мир Godot; дельталёт игрока через `Glider.setup_trike(Config "tow_tug", 0, Config "trike_pilot")`):
- `W` — `TrikeRig.wing_basis` (крыло: −Z по килю вперёд, +Y — нормаль вверх).
- `C_vis` — `TrikeRig.cart_basis` (то, что рисуется, с ограничением поворота `CART_TURN_DEG_S`).
- `C_phys` — тот же базис без ограничения поворота (`_cart_model_basis(pilot_pos, hang_pos, wing_basis, on_wheels)`),
  то есть ориентация по физике «Маятника».
- Начало обеих моделей — `HangPoint` (`hang_pos`); оси `trike.glb` — TT-К6 (в Godot: +Y вверх, −Z вперёд, +X вправо).

**Величины** (каждая — для `C_vis` и `C_phys`, суффиксы `_vis`/`_phys`; градусы):
- `bar_deg` — положение середины базовой штанги трапеции (точка из модели/параметров крыла `trike_ixess15`, источник —
  в `README.md` инструмента), переведённой в оси тележки, на дуге TT-К6 вокруг `HangPoint`: угол от `trike_params.json
  bar.trim` в плоскости симметрии тележки, «+» — к `full_push`. Допустимо `−pull_deg ≤ bar_deg ≤ push_deg`
  (`bar.pull_deg`, `bar.push_deg`). За `push_deg` — штанга за передним подкосом (п. 1).
- `roll_rel_deg` — поворот крыла относительно тележки вокруг продольной оси тележки (−Z), «+» — правое крыло вниз.
- `yaw_rel_deg` — угол между проекцией киля крыла на плоскость ⟂ мачте тележки и продольной осью тележки, «+» — нос
  крыла вправо.
- `mast_normal_deg` — угол между мачтой (направление ЦМ тележки → `HangPoint` в данном базисе: −`C·CART_CM_MODEL`) и
  нормалью крыла `W.y`; > 90° — тележка выше плоскости крыла (п. 2, «сквозь крыло»).
- `vis_lag_deg` — угол между `C_vis` и `C_phys` (кватернионы).

**Сценарии** (штиль, ветер выключен; старт в воздухе 300 м над ровной землёй, 80 км/ч, горизонтально, штанга 0, шаг
игры 1/60 с; ввод `ControlInput`: `pitch` +1 — «от себя», −1 — «на себя»; `roll` +1 — вправо; `throttle_axis` через
`TrikeEngine` или прямым заданием `thrust_n` — способ в `README.md`):
- `trim_full` — газ полный, штанга 0, 30 с.
- `push_full` — газ полный, `pitch` +1 10 с, затем 0 10 с. `pull_full` — то же с `pitch` −1.
- `throttle_step` — штанга 0; газ 0 → полный на 5 с → 0 на 20 с; 35 с.
- `turn30`, `turn45` — газ половина и 0 (два прогона, суффиксы `_half`/`_idle`), вход в крен 30°/45° простым
  регулятором крена и удержание 20 с. `reversal45` — перекладка 45° → −45° → 45°, газ половина.
- `roll_pump` — газ полный, `roll` ±1 сменой каждые 2 с, 20 с.
- `pitch_pump` — газ полный, `pitch` ±1 с периодом, близким к собственному периоду качания тележки (подбор — в `README.md`),
  20 с.
Можно добавлять свои сценарии, эти — обязательны.

**`tools/research/trike-fix/out/summary.json`** (временный файл + переименование):
```
{"version": 1, "dt_s": 0.01667, "git": "<коммит>",
 "limits": {"push_deg": 4.95, "pull_deg": 8.39},
 "scenarios": {"<имя>": {"duration_s": f, "throttle": "<описание>",
   "airspeed_kmh": [min, max],
   "bar_deg_vis": [min, max], "bar_deg_phys": [min, max],
   "roll_rel_deg_vis": [min, max], "roll_rel_deg_phys": [min, max],
   "yaw_rel_deg_vis": [min, max], "yaw_rel_deg_phys": [min, max],
   "mast_normal_deg_max_vis": f, "mast_normal_deg_max_phys": f,
   "vis_lag_deg_max": f}}}
```
Ряды по времени — `out/<сценарий>.csv` (те же величины по шагам). `check_summary.py`: все обязательные сценарии и
ключи есть, числа конечны, `[min, max]` упорядочены, `limits` — из `trike_params.json`.

## TKF-К2 v1. Отклик дельталёта на штангу: `control_summary.json`
Владелец — TKF-2; потребитель — TKF-5. Контрактный тест — `tools/research/trike-fix/check_control.py
<control_summary.json>` (пишет TKF-2): exit 0 — схема верна.

- Аппараты: дельталёт игрока (как TKF-К1) при газе 0 / 0,5 / 1; дельтапланы `sport` и учебный (крыло и пилот по
  умолчанию, `Glider` с «Маятником») — для сравнения. Штиль, старт в воздухе на скорости трима.
- Величины: `roll_rate_dps` — установившаяся скорость крена при ходе штанги 0,25/0,5/1 (на крене < 45°);
  `t_30_30_s`, `t_45_45_s` — перекладка полным ходом от устойчивого крена до противоположного; `pitch_rate_dps` —
  наибольшая скорость тангажа крыла на полный ход «от себя»/«на себя» за первые 2 с; `bar_force_n` — сила на штанге
  (как в модели рук), если модель её даёт, иначе `null`.
- `tools/research/trike-fix/out/control_summary.json`:
  `{"version": 1, "git": "<коммит>", "cases": {"<аппарат>[_<газ>]": {"roll_rate_dps": {"0.25": f, "0.5": f, "1": f},
  "t_30_30_s": f, "t_45_45_s": f, "pitch_rate_dps": {"push": f, "pull": f}, "bar_force_n": f|null}},
  "reference": [{"source": "<ссылка>", "aircraft": "<аппарат>", "quantity": "<величина>", "value": f, "unit": "<ед>"}]}`.
