# WPC-1: паспорта крыльев против модели полёта

Задача модуля «проверка физики и параметров крыльев» (`docs/plan/wing-physics-check.md`, WPC-1). Выход — контракт К4 v2 (`docs/wing-physics-check_contracts.md`).

## Воспроизведение (из корня репозитория, ≈ 12 мин на 8 ядрах)

```
XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import          # один раз в новой копии
XDG_DATA_HOME=$(mktemp -d) godot --headless --path . res://tools/research/wing_physics_check/wings_audit_run.tscn
python3 tools/research/wing_physics_check/wings_audit.py               # картинки — если есть matplotlib
```
`wings_audit_run.gd` продолжает с места (пропускает готовые ключи `out/model_runs.jsonl`); `-- --wings=a,b` — только эти крылья; `-- --quick` — грубая сетка для оценки времени. Пересчитать всё — удалить `out/model_runs.jsonl` (и `out/start_sites.json`, если менялся рельеф).

## Что меряется (модель)

Настоящая `FlightModel` (как `tests/flight/flight_sim.gd`), спокойный воздух, плотность постоянная 1,225 (`altitude_dependent = false`), шаг 1/120 с. Каждое крыло × {`ref` — `pilot_mass_ref_kg`; `pilot85` — `configs/pilot.json` 85 кг, ограниченная диапазоном крыла}:
- перебор трапеции −1 … +1 (сетка 0,025 у трима, 0,1 у краёв), на точку 25 с установления + 5 с усреднения (дрейф между окнами — `drift_kmh`, ≤ 0,7 км/ч); золотое сечение по трапеции для мин. снижения и макс. качества; снижение на 80 км/ч — секущая по трапеции;
- `stall` — сваливание модели в прямолинейном полёте `FlightModel.stall_speed()` = √(2Mg/(ρ S CL_max)), CL_max — первая точка поляры; `min_steady_kmh` — самая малая установившаяся скорость без срыва в переборе;
- высота: та же модель с `altitude_dependent = true` (ρ = 1,225·exp(−h/10400)) на 0/500/1000/1500/2000 м и на высоте каждого старта (`out/start_sites.json`, из рельефа локаций): сваливание, трим/«на себя» (замер на 1000/1500/2000 м);
- `analytic` — `FlightModel.steady_glide` по скоростям (как `tests/flight/test_polar.gd`) для сверки.

## Паспорт

`tools/research/data/wing_passports/wings_merged.json` (ключ — первый «…|…» в `_doc` конфига; нет поля — другой размер того же семейства с пометкой), `polars_points.json` (точки поляр Wills Wing), для крыльев без ключа — числа из источников, названных в `_doc` их конфигов (таблица `MANUAL` в `wings_audit.py`). Паспорт — эталон, не пересматривается; только явные ошибки разбора не берутся (верхние границы «or less»/«<»; Vms плакатов WW 25/40; «trim» Sting 3 = «maximum steady state speed»; «best glide 23» Bautek — это скорость в mph).
Приведение паспортной скорости к массе случая: V·√(M/M_паспорта): DHV Vmin/Vmax VG 0 — середина «Startgewicht»; поляры WW — 1,3·мин. пилот + крыло (правило страницы WW); прочее — середина hook-in + крыло. Качество не приводится.
`stall` паспорта = DHV Vmin VG 0 (если есть), иначе «stall speed» производителя; `full_pull` = DHV Vmax VG 0 (иначе VG 100).

## Выход (`out/`)
- `wings_audit.csv` — К4 v2: по строке на (крыло, масса, величина); `stall_start_alt` и `takeoff_gs_w*` — на самом высоком старте (ongudai/kayancha_south 1869 м), источник ρ — в `passport_src`.
- `model_runs.jsonl` — сырые замеры (все точки перебора), `start_sites.json` — высоты стартов.
- `penetration_est.csv` — путевая скорость против 6 м/с (V·cosγ − 6) на триме и «на себя», 0/1000/1500/2000 м; проверка ρ-масштаба трима.
- `takeoff.csv` — отрыв: Vmin на высоте каждого старта (85 кг), нужная путевая при ветре 0/3/6/10 м/с, достижимая скорость бега в модели и признак отрыва.
- `ww_v2_check.csv` — снижение модели в скоростной точке поляр WW (530 fpm).
- `summary.json` — сводка по группам, расхождения > 10 %, диапазоны путевой.
- `fig_diff_pct.png`, `fig_penetration_6ms.png`, `fig_takeoff.png`.

## Границы
Установившийся прямолинейный полёт в штиле; без VG (модель — одна «средняя» поляра); экранный эффект и динамика разбега не моделируются в оценке отрыва (он — по Vmin и формуле предела бега `scripts/flight/ground_run.gd:239–242`). Паспортные массы, где карточка их не называет, — допущение (см. выше).

## Источники и лицензии
Числа паспортов — факты со страниц производителей и DHV Geräteportal (см. `tools/research/data/wing_passports/README.md`, `sources.md`, запись в `ASSETS.md`); Wills Wing polar data — https://www.willswing.com/polar-data-for-wills-wing-hang-gliders/ ; «Атлас» — «Крылья Родины» (Кареткин, Рябцев, Бабкин; `docs/research/atlas_wing.md`). PDF не храним.
