---
type: "research"
status: "active"
module: "trike-fix"
area: "flight"
updated: "2026-11-02"
summary: "Инструмент TKF-1: замер углов тележки к крылу дельталёта игрока (TKF-К1 v1), кадры «до»; воспроизведение"
related: ["docs/research/trike-fix/coupling.md", "docs/contracts/trike-fix.md"]
---
# TKF-1: связь тележка—крыло (инструмент и данные)

Записка с выводами — `docs/research/trike-fix/coupling.md`. Файлы с префиксом `coupling_` и `check_summary.py` — TKF-1 (остальные в каталоге — TKF-2/3).

## Воспроизведение (из корня копии; Godot — под замком cpu, профиль `XDG_DATA_HOME=~/.cache/dp-xdg/$(basename "$PWD")`, до этого `godot --headless --path . --import`)
```
.dpcli/dpcli lock cpu TKF-1 -- godot --headless --path . res://tools/research/trike-fix/coupling_run.tscn   # out/summary.json + out/<сценарий>.csv (~5 мин)
python3 tools/research/trike-fix/check_summary.py tools/research/trike-fix/out/summary.json                  # exit 0
.dpcli/dpcli lock cpu TKF-1 -- godot --path . --resolution 1280x720 res://tools/research/trike-fix/coupling_shots.tscn -- \
  --out=/home/greg/deltaplan/build/screenshots/trike-fix/before                                              # кадры «до» (не headless)
```
Для кадров «после» (TKF-7): тот же `coupling_shots.gd`, `--out=…/after`, моменты — `coupling_moments.json` (взяты из `before`: те же сценарий и время).
Ключи `coupling_run.gd`: `--only=a,b`, `--out=<каталог>`, `--dt=<Гц>` (по умолчанию 120).

## Как измерено
- Дельталёт: `Glider.setup_trike(tow_tug, 0, trike_pilot)`, старт `reset_in_air(300 м, 80 км/ч)`. Шаг модели — **1/120 с** (как в игре, `physics_ticks_per_second=120`; в контракте TKF-К1 написано 1/60 — на 60 Гц повторены turn45_idle, reversal45, roll_pump: отличие < 1°). Вместо `Glider.step` — те же вызовы `model.step` + `TrikeRig.refresh(dt)`, но тяга задана напрямую (способ контракта «прямым заданием thrust_n»): `T = idle(V) + g·(full(V) − idle(V))` по таблице `configs/tow_tug.json`, V — воздушная скорость; газ 0 = холостая тяга, не нуль.
- `C_vis = TrikeRig.cart_basis`, `C_phys = TrikeRig._cart_model_basis(...)` (приватная функция вызвана из инструмента). Штанга: `wing_frame_bar` из `tools/research/tow-trike/trapeze.json` (0; 0,6793; −1,5287 в осях крыла от HangPoint) → в оси тележки; `bar_deg = atan2(y, −z) − atan2(0,72; 1,51)` (проекция на плоскость x = 0 тележки, «+» к full_push; нуль — `bar.trim` из `trike_params.json`). Пределы: +4,948° / −8,389°.
- `roll_rel_deg` — наклон нормали крыла вокруг продольной оси тележки; `yaw_rel_deg` — киль крыла, спроецированный ⟂ мачте, против продольной оси тележки; `mast_normal_deg` и `vis_lag_deg` — по контракту.
- Регулятор крена: ПИД 6 / 2,5 / 1 (как `BankHold` тестов маятника), цель нарастает за 3 с после 2 с прямого полёта. `pitch_pump`: период 2,6 с (≈ 2π√(L/g), L = 1,71 м); проверены 2,0/3,2/4,0 с (доп. сценарии `pitch_pump_*`) — вывод не меняется.
- Доп. поля в `summary.json` (контракт их допускает): `cart_phys_rate_dps_max/_p99` — угловая скорость C_phys; `vis_lag_deg_max_by_limit_dps` — отставание вида при других пределах поворота (40/60/90/180 °/с, тот же `_turn_toward`); `wheels_to_air_jump_deg` — скачок целевой ориентации колёса→воздух. Доп. сценарии: `turn45_full`, `reversal45_idle`, `roll_pump_idle`, `pitch_pump_*`.
- Ограничения: min/max airspeed включают начальный переходный процесс (старт на 80 км/ч при полном газе → 53…92 км/ч в `trim_full`); внешних данных нет, лицензий нет.

## Источники (реальность)
См. `docs/research/trike-fix/coupling.md`: Gratton (Brunel, «Towards the tumble resistant microlight»), Gratton 2001 (Proc IMechE G 215, 147–154; только аннотация), AAIB bulletin G-CEVW (Quik GT450).
