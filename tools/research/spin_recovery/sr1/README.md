---
type: "research"
status: "active"
module: "spin-recovery"
area: "flight"
updated: "2026-10-21"
summary: "SR-1: стенд и команды воспроизведения — доходит ли ввод мыши до трапеции в штопоре sport."
related: ["docs/research/pendulum/spin-recovery.md", "docs/contracts/spin-recovery.md"]
conclusion: "см. docs/research/pendulum/spin-recovery.md, раздел «Гипотеза 0»"
data: "tools/research/spin_recovery/out/sr-1/"
applied_in: "—"
---
# SR-1: доходит ли ввод мыши до трапеции в штопоре

Задача spin-recovery SR-1 (гипотеза 0). Сценарий — SR-К1, данные — SR-К2 (`docs/contracts/spin-recovery.md`), вывод — раздел
«Гипотеза 0 — ввод и руки (SR-1)» в `docs/research/pendulum/spin-recovery.md`.

## Файлы
- `sr1_run.gd` + `sr1_run.tscn` — стенд (Godot 4.7.2): сценарий штопора через путь ввода игры (`game`: события мыши
  через `Viewport.push_input`), прямым `ControlInput` в модель (`model`) и с пределом усилия рук 1000 Н (`model_f1000`);
  пробы отклика на шаг ввода в штопоре и на триме; отпускание рук VM-12.
- `build_out.py` — из сырого вывода собирает `runs.jsonl`, `summary.json`, `tables.md`, переносит трассы (сырой вывод и трассы в репозитории не хранятся).

## Воспроизведение (≈ 15 мин, один процесс)
```
export XDG_DATA_HOME=~/.cache/dp-xdg/$(basename "$PWD")
godot --headless --path . --import                 # первый раз
godot --headless --path . res://tools/research/spin_recovery/sr1/sr1_run.tscn -- \
  --out=$PWD/tools/research/spin_recovery/out/sr-1/raw [--wings=sport,laminar,training] \
  [--variants=game,model,model_f1000] [--modes=probes,standard,release,release_center,probe_vm12]
python3 -I tools/research/spin_recovery/sr1/build_out.py <git-хеш драйвера>
python3 tools/research/spin_recovery/contract_check.py tools/research/spin_recovery/out/sr-1
```
Итоговые данные посчитаны драйвером из коммита `779f2390eab6863d15860105011213790de95d8e`.

## Допущения
Штиль, ρ = 1,225 const (`PendulumModel._alt_dep = false`), шаг 1/120 с, 3000 м над рельефом, `--bots=0`, масса пилота —
эталонная крыла, режим крена pendulum, настройки мыши и рук — как в игре (`configs/controls.json`, `configs/pendulum.json`).
Мышь идеальная: за шаг одно событие, ровно нужной величины; пилот-испытатель `BankHold` вместо человека.
Код игры не менялся; в стенде читаются приватные поля (`_mouse_offset`, `arms._rel_on`, `PendulumModel._alt_dep`).

## Данные и лицензии
Свои расчёты; внешних данных нет, лицензий не требуется. Данные — `tools/research/spin_recovery/out/sr-1/` (≈ 9 МБ трасс,
каждый файл < 0,5 МБ; всё коммитится).
