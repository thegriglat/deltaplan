---
type: "research"
status: "active"
module: "pendulum"
updated: "2026-10-11"
summary: "Прототип «честного маятника» на Python: крыло — тело с 16 полосами, пилот — точка на цепи из N звеньев (XPBD), руки с пределом силы"
related: ["docs/research/pendulum.md", "docs/archive/plan/pendulum.md", "docs/guide/flight.md"]
conclusion: "Тангаж и трим получаются честно (трим ±0,3 км/ч, снижение = поляра, фугоида сама затухает, чувствительность к подвеске ≈ 1–2 км/ч на см — как в руководствах); крен жёсткого крыла от одного смещения ЦМ в 3–5 раз медленнее игры, спираль слабо неустойчива, без скольжения (этап A) самовыравнивания нет и счёт неустойчив в болтанке — нужен минимальный этап B и гибкость паруса."
data: "tools/research/pendulum/out/"
applied_in: "docs/research/pendulum.md, docs/archive/plan/pendulum.md"
---
# Прототип маятника (модуль pendulum)

Вывод и разбор — [docs/research/pendulum.md](../../../docs/research/pendulum.md), план — [docs/archive/plan/pendulum.md](../../../docs/archive/plan/pendulum.md).

## Что здесь
| Файл | Что |
|---|---|
| `pendulum/params.py` | параметры из `configs/wings/*.json`, `configs/pilot.json`, `tools/blender/glider_params.json`; оценки помечены EST; порт `WingPolar` |
| `pendulum/geometry.py` | полосы (strip theory, простая теория стреловидности), модель масс крыла (трубы + парус), инерции, присоединённая масса по крену |
| `pendulum/model.py` | `Sim`: крыло — твёрдое тело, пилот — точка на цепи N звеньев, XPBD с подшагами, руки (ПИД с пределом силы), земля (ноги, хват за стойки), рыскание `noslip` (этап A) / `free` (минимальный этап B) |
| `pendulum/trim.py` | балансировка (руки без усилия), Cm0 паруса под паспортный трим, нейтральная точка, Kn, калибровка сопротивления полос под поляру, боковые производные |
| `pendulum/air.py` | штиль, ветер, гауссов термик, замороженная турбулентность (спектр фон Кармана) |
| `pendulum/game_ref.py` | порт нынешней модели игры (крен weight_shift/rate, продольный канал с `phugoid_damping`) — для тех же сценариев |
| `pendulum/scenarios.py` | сценарии замеров (трим, переложение, полное смещение, «в центр», спираль, термик на краю, болтанка, маятник, фугоида, трапеция, подвеска, разбег, численная схема) |
| `run_all.py` | весь план одним прогоном → `out/results.jsonl` (строка на запуск, продолжение с места), `out/results.json`, ряды `out/series/*.npz` |
| `report.py` | итог: `out/tables.md`, `out/summary.json`, графики `out/fig/*.png` (для статьи; проверка — по таблицам) |
| `calibrate_classes.py` | PD-12: сетка V × flex_relief на опорных крыльях классов (`out/calib_classes.*`), проверка умолчаний класса на всех 48 крыльях (`--verify` → `out/calib_verify.*`), доп. рычаг cn_beta (`--levers` → `out/calib_levers.jsonl`) |
| `estimates.py`, `estimates.json` | оценки 05.10 (Fable): полюса Hiway Demon, частоты, ω·dt — см. ниже |

## Воспроизведение
```bash
PY=/home/greg/deltaplan/tools/research/heat_ca/.venv/bin/python   # numpy + matplotlib (не коммитится)
cd tools/research/pendulum
# весь план (283 запуска, ≈ 25 мин на 16 процессах; продолжает с места после прерывания)
/home/greg/deltaplan/.dpcli/dpcli job start pd-proto 3600 systemd-run --user --scope -p MemoryMax=12G -q \
  $PY run_all.py --jobs 16
$PY run_all.py --only reversal/sport   # часть плана по подстроке id
$PY report.py                          # таблицы, сводка, графики
python3 estimates.py                   # оценки 05.10
/home/greg/deltaplan/.dpcli/dpcli job start pd12-calib 3000 systemd-run --user --scope -p MemoryMax=12G -q $PY calibrate_classes.py --jobs 7   # PD-12, ≈ 20 мин; --verify, --levers — см. выше
```
Шаг физики как в игре — 1/120 с (`configs/sim.json → physics_hz`), 4 подшага XPBD, N = 3 звена, 16 полос — по умолчанию.

## VG (PB-2)
Натяжение паруса (VG, 0…1) как набор изменений параметров крыла — `pendulum/vg.py` (`apply_vg(p, vg)`, PB-К1): крутка
−6°·min(vg/0,75; 1) (калибровка по сдвигу трима T2C), гибкость паруса ×(1 − 0,7·vg), сопротивление полос ×(1 − 0,12·vg);
геометрический рычаг носа выключен (см. докстринг). Крылья с VG — по паспортам DHV (`pb2_passport.py`). Разбор разрыва
Vmax, физика, источники и вывод — `docs/research/pendulum/vg.md`; данные — `out/pb2/` (сводка PB-К2 `summary.json`,
`tables.md`, `calib.md`, `vg_wings.md`, графики `fig/*.png`).
```bash
PY=/home/greg/deltaplan/tools/research/heat_ca/.venv/bin/python
python3 tools/research/pendulum/pb2_passport.py                       # паспорта → out/pb2/passport.json, vg_wings.md
$PY tools/research/pendulum/pb2_calib.py --jobs 12                   # калибровка крутки и рычаги по одному → out/pb2/calib.*  (≈ 2 мин)
/home/greg/deltaplan/.dpcli/dpcli job start pb2-run 3600 systemd-run --user --scope -p MemoryMax=12G -q \
  $PY tools/research/pendulum/pb2_run.py run --jobs 12                # 364 запуска, ≈ 10 мин; продолжает с места
$PY tools/research/pendulum/pb2_run.py report                        # out/pb2/summary.json (PB-К2), tables.md, fig/
python3 tools/research/pendulum/pb_contract_check.py tools/research/pendulum/out/pb2/summary.json
```
Источники (числа с URL, PDF не храним): руководство Wills Wing T2C (DHV, нем.), Moyes Litespeed, Aeros Combat L; Kroo 1981
NASA TM-81269 (public domain); паспорта DHV — `tools/research/data/wing_passports/` (лицензии — там). Графики — свои.

## Оценки 05.10 (`estimates.py`)
Полюса разомкнутой модели Hiway Demon (Abouheaf, Gueaieb, Lewis, arXiv:2108.02393, табл. 1–2; модель Cook & Spottiswoode 2005) → ωn, ζ; маятник пилота; инерция крыла по трубам; `Cm_alpha` по двум точкам балансировки; ω·dt для 60/120/240 Гц; крен от момента веса при Cl_p = −0,45 (≈ 16°/с). Запуск: `python3 tools/research/pendulum/estimates.py`.

## Данные и лицензии
Свои расчёты; чужих данных в репозитории нет. Числа из литературы — с цитированием: статьи ICAS 2016/2022 — открытый архив ICAS; NASA TM-81269 (Kroo 1981) и NASA CP (Kroo & Chang, Ormiston, 1979) — public domain; arXiv:2108.02393 — числа из таблиц с цитированием; руководства Airborne Fun, Moyes Xtralite, Wills Wing Sport 2 — числа (подвеска, шаг регулировки) с URL, PDF не храним. Графики `out/fig/*.png` — свои.

## Сверка игры с прототипом (PD-8)
Один пакетный прогон: план (поля болтанки) → прототип (≤ 6 процессов) → игра (один godot) → цена шага (под flock) → итог. Данные и таблицы — `out/game_vs_proto.md`, `out/pd8_*.jsonl`, `out/pd8_summary.json`.
```
PY=/home/greg/deltaplan/tools/research/heat_ca/.venv/bin/python
$PY tools/research/pendulum/pd8_proto.py plan                      # out/pd8_plan.json (10 зёрен σ 1 м/с)
$PY tools/research/pendulum/pd8_proto.py run --jobs 6              # out/pd8_proto.jsonl (≈ 6 мин)
XDG_DATA_HOME=$(mktemp -d) godot --headless --path . res://tools/flight/pendulum_compare.tscn -- \
    --plan=tools/research/pendulum/out/pd8_plan.json --out=tools/research/pendulum/out/pd8_game.jsonl   # ≈ 75 с
XDG_DATA_HOME=$(mktemp -d) flock /tmp/heat_ca_gpu.lock godot --headless --path . \
    res://tools/flight/pendulum_compare.tscn -- --bench --out=tools/research/pendulum/out/pd8_bench.jsonl
$PY tools/research/pendulum/pd8_summary.py                         # out/game_vs_proto.md, pd8_summary.json
```
Лицензии: данные порождены своим кодом, внешних данных нет.
