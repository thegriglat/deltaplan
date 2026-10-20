---
type: "research"
status: "active"
module: "spin-recovery"
area: "flight"
updated: "2026-10-21"
summary: "Стенд штопора SR-К1 (spin_run.gd): вход, выходы release/standard/pull_release, таблица вариантов; SR-2 — база, крутка, sport против laminar."
related: ["docs/research/pendulum/spin-recovery.md", "docs/contracts/spin-recovery.md", "docs/plan/spin-recovery.md"]
conclusion: "стенд повторяет тест штопора (training/standard/1/120 — выход 4,3 с); данные SR-2 в out/sr-2/"
data: "tools/research/spin_recovery/out/sr-2/"
applied_in: "—"
---
# Стенд штопора (spin-recovery)

Сценарий и метрики — SR-К1, формат данных — SR-К2 (`docs/contracts/spin-recovery.md`). Код игры не меняется: правки —
словарями конфига до `PendulumModel.setup`, полями экземпляра после него или наследником `PendulumWingStrips`.

## Файлы
- `spin_run.gd` + `spin_run.tscn` — один прогон (крыло × вариант × режим × шаг) → json. Варианты — словарь `VARIANTS` в начале
  файла (ключи правки описаны в шапке): `wing_pend`, `app`, `pnl_off`, `arms`, `strips_script`, `post`, `rebalance`. SR-3 добавляет
  варианты только в `VARIANTS`. Вариант с геометрией/аэродинамикой балансируется автоматически (`match_polar_cl_max`, затем `dcm0`
  секущими под паспортный трим, допуск 0,01 км/ч).
- `run_sr2.py` — пачка SR-2 (параллельные процессы Godot), `summary.py` — `runs.jsonl`, `summary.json`, `tables.md`.
- `contract_check.py` — контрактный тест (владелец — координатор).
- Режимы: `release` (с `t_rec0` ввод 0), `standard` (SR-К1, по Жеглову), `pull_release` — диагностика SR-2: «на себя» как в
  `standard`, затем pitch = 0 (а не −2·(V−Vтрим)/Vтрим).

## Воспроизведение SR-2
```
export XDG_DATA_HOME=~/.cache/dp-xdg/$(basename "$PWD"); godot --headless --path . --import   # один раз
.dpcli/dpcli job start sr2 600 .dpcli/dpcli lock cpu sr2 -- python3 tools/research/spin_recovery/run_sr2.py -j 10
python3 tools/research/spin_recovery/summary.py
python3 tools/research/spin_recovery/contract_check.py tools/research/spin_recovery/out/sr-2
# один прогон с ходом выхода (stdout): 
godot --headless --path . res://tools/research/spin_recovery/spin_run.tscn -- --wing=sport --variant=game --mode=standard --dt=0.0083333333333 --trace=1
```
Прогон ≈ 3–10 с, пачка (180 прогонов) ≈ 1–2 мин. Данные — `out/sr-2/` (`raw/*.json` — по прогону с `extra`, `runs.jsonl`,
`summary.json`, `tables.md`); все коммитятся (≈ 1 МБ). Источники чисел: `configs/wings/{sport,laminar,training}.json`; данных
сторонних лицензий нет.

## Допущения
- ρ = 1,225 постоянная, штиль, эталонная масса пилота (как `tests/flight/pendulum/pendulum_sim.gd`).
- `S.BankHold` берётся как есть: интеграл ПИД считается с шагом 1/120 независимо от `dt` — при 1/60 и 1/30 пилот-регулятор
  чуть другой (часть различий по шагу — оттуда).
- Площадь крыла не меняется при смене `tip_chord_m`: `PendulumWingStrips.setup` масштабирует хорды так, что Σ площади = `area_m2`
  (меняется только распределение хорды по размаху).
