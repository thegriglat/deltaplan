---
type: "research"
status: "active"
module: "air-cascade"
updated: "2026-10-24"
conclusion: "Экспорт воспроизводит фикстуру: итерации 191/231/201/131, поле у старта до 5e-7 м/с"
data: "~/data/air_cascade/ongudai/ (вне git, 4×38 МБ)"
applied_in: ""
summary: "AC-R2: Онгудай 400 м в формате R1 из air.py (f64); PR-3: пара 12:00 / 12:15 (R5) со входом от кода игры и как игра греет старт"
---
# Экспорт Онгудая 400 м в формат R1 (AC-R2)

Случай: Онгудай, область 38,4 км, сетка 96×96×50 (dx 400 м, dz 105 м, z_bot 420 м), 12:00, ветер с 150°,
z_i 3362 м. Эталон — `tools/research/air3d/air.py` (CuPy, float64, критерий 2e-5 / 5e-7 / 1e-6, проверка
каждые 10 итераций), путь решения как у `picard_gpu_refs.solve`. Формат — R1 v1
(`docs/contracts/air-cascade.md`): постоянный вход после подготовки `Air`, решение `sol_*` после
`finalize`, `history`, `criterion`, `params`, `case_params`, `mg_levels_xyz`, `source`, `crop`, `t_ref_s`;
блоков одной итерации нет. Упаковка (`Pack`, порядок) — из `air3d/fixtures.py`.

## Воспроизведение
```
cd tools/research/heat_ca && uv venv .venv && uv pip install --python .venv/bin/python -r requirements.txt && cd -
tools/research/heat_ca/.venv/bin/python tools/research/air_cascade/export/export_ongudai.py   # ~1 мин, RTX 4070 SUPER
python3 tools/research/air_cascade/picard_rs/contract/check_contract.py --ref ~/data/air_cascade/ongudai/*.json
```
Выход — `$AIR_CASCADE_DATA/ongudai/` (по умолчанию `~/data/air_cascade/ongudai/`, вне git). Запись во
временный файл и переименование. Код выходит с 1, если итерации расходятся с фикстурой более чем на 10
или поле у старта вне допуска.

## Результат
| случай | итерации экспорта | итерации фикстуры | t_ref_s | размер .bin |
|---|---|---|---|---|
| ongudai_d400_u3_heat | 191 | 191 (f64) | 9,12* | 38,3 МБ |
| ongudai_d400_u3_mech | 231 | 231 (f64) | 4,43 | 38,3 МБ |
| ongudai_d400_u0_heat | 201 | 201 (f32) | 4,81 | 38,3 МБ |
| ongudai_d400_u6_heat | 131 | 131 (f32) | 3,12 | 38,3 МБ |

\* первый случай включает прогрев CuPy (компиляция ядер); `t_ref_s` = `wall − t_check` решения (без
проверок невязки), справочно, RTX 4070 SUPER. Для 0 и 6 м/с в фикстуре есть только f32, f64-экспорт совпал.
Максимальная разница итераций — 0 (допуск 10).

Поле у старта (crop i0 58, j0 39, n 16; центры клеток; u3_heat с `w_mech` из u3_mech, `w_conv = w − w_mech`)
против `crop_*` фикстуры: max |Δ| u 2,4e-7, v 4,8e-7, w_mech 6e-8, w_conv 3e-8 м/с (допуск 1e-3·u_scale =
6e-3), θ′ 3e-8 К (допуск 0,05) — совпадение на уровне float32-округления.

## Допущения и границы
- Слоя рельефа `data/terrain/ongudai` в копиях нет, поэтому вход собран из массивов фикстуры: `hc`, `H`
  (до гашения у края, делает сам `Air`), `gam` (в центрах уровней) — они хранятся в float32, исходный
  float64 не восстановить; `params` и `profiles[U10]` (alpha, max_profile) — из JSON (assert: равны
  умолчаниям `Params`, `dtau_u` 120 м). Итерации совпали, значит влияние округления входа ничтожно.
- «mech» — тот же случай с H = 0, холодный старт (`Q = 0`).
- Источники/лицензии: код и фикстура — репозиторий; рельеф Онгудая — DEM проекта (см. `ASSETS.md`); внешних
  данных не добавлено.

## T+15: случаи h1200 / h1215 (PR-3, R5 v1)
Пара для тёплого старта «12:00 → 12:15» (срок пересчёта игры `recompute_game_min` = 15 игровых минут,
`configs/atmosphere.json → air_model`): `ongudai_d400_u3_{heat,mech}_h1200` (T) и `…_h1215` (T+15), ветер 3 м/с со 150°,
эталон — холодный `air.py` f64 (критерий 2e-5 / 5e-7 / 1e-6), формат R1 v1 + R5 v1 (`source.hour`, `warm_from`, `changed`).

**Почему новая пара, а не старые 12:00.** Вход часа снят **кодом игры** (`warm/dump_inputs.gd`: `AirPlace.context/day/gamma/surface_flux`,
`AirCase.set_inflow/set_zi_terrain`), а он сегодня не равен входу фикстуры `ongudai_d400_h12` (её писал `air3d/picard_gpu_refs.py`
по `weather.py` до смены погоды и поверхности игры; `weather.py` на текущем `configs/weather_model.json` уже не запускается —
нет `dew_point_c`): на 12:00 `t_max` 23,56 °C против 26, `z_i` 2930 м против 3362, H до 108 Вт/м² разницы (max H 258 против
фикстурного). Поэтому 12:00 существующих случаев (191/231 итераций) тем же путём не воспроизводится; **существующие файлы не тронуты**
(md5 в приёмке), T-случаи — новые `…_h1200` (281 итерация heat, 341 mech), T+15 — `…_h1215` (281 и 341). Старые случаи остаются
эталоном AC-R2 и PR-1/PR-2.

**Что меняется 12:00 → 12:15 в игре** (без действий пилота; часы неба `SunClock.hour`, срок = `slot_hour`):

| вход | как меняется | где в игре | величина |
|---|---|---|---|
| H (поток тепла, Вт/м²) | солнце по склонам и `sky_heat/heat` дня на час | `air_place.gd:surface_flux` ← `SurfaceHeating.directions(hour)`, `AirPlace.day` | max|ΔH| 13,0, rms 5,2, среднее +4,8 на 258 (+2,6 %) |
| Q (K/с, 3D) | распределение H по столбцу зависит от `z_i − hs` | `air_case.gd:prepare` | max|ΔQ| 2,06e-4 (max Q 2,35e-4), rms ΔQ/Q 16 %, 29 % ячеек |
| z_i (м MSL) | `AirPlace.day`: θ-профиль на час | `air_place.gd:day` | 2929,5 → 2968,1 (+38,6 м) |
| nu_bg | из w*, h_bl (зависят от H и z_i) | `air.py:Air` ← `air_case.gd:prepare` | max|Δ| 8,4 из 181,8, rms 2,7 |
| γ = dθ̄/dz в центрах уровней | профиль над слоем: ни один центр уровня не в пределах ±5 м от z_i на обоих часах (скачок γ не задет) | `air_place.gd:gamma` | max|Δ| 0 (float32) |
| α, max_profile, класс | `WindProfile.apply_to_case` по высоте солнца | `air_case.gd:set_inflow` | α 0,112, max_profile 1,4045, класс B — не меняются (солнце 56,8° → 58,1°) |
| ветер U10, направление | **нет**: `conditions_of` берёт ветер атмосферы (задан настройками/прогнозом), от часа не зависит; погоды (t_max, небо) тоже | `air_runtime.gd:conditions_of`, `atmosphere.gd:set_wind` (вызывается только при загрузке/сменой настроек) | 0 |

`mech` (H = 0): вход **побитно тот же** — Q = 0, γ, профиль притока и ветер не меняются, z_i решению без нагрева не нужен
(`air_case.gd:prepare`: z_i входит только в `h_u`/w* при `hsv > 1e-6`; иначе `h_bl = h_mech`). Решение mech(12:15) = mech(12:00) побитно (max|Δ| 0): тёплый старт mech уже
точный. Решение heat меняется мало: max|Δu| 0,10, |Δv| 0,076, |Δw| 0,028 м/с, |Δθ′| 0,057 К (rms 0,009 / 0,009 / 0,003 / 0,004).

**Различия с игрой, оставленные как есть (границы):**
- Слоя рельефа Онгудая нет в копиях: `hc` из фикстуры; поверхность — как `AirPlace.domain_case` без снимка (`surface = null`:
  класс NONE, влажность `m_norm`, воды нет). В настоящей игре H считается по снимку поверхности (классы, влага, реки) — абсолютные H
  другие, но *приращение* за 15 мин считается тем же кодом.
- Игра задаёт `z_i` по столбцам (`set_zi_terrain`, α 0,33: 3003…3273 м при скаляре 2930 на 12:00), `air.py` — скаляр (формат R1 несёт
  скаляр). Решатель игры по столбцам даст другое `nu_bg`/поле; эталон R5 — как у AC-R2 (скаляр).
- k притока: игра в полёте использует `inflow_k` загрузки (после двух проходов), здесь k = 1.
- Фаз (`AirPhaseJob`: заморозка колонн механизмов, ω) в эталоне нет — `air.py` их не знает.

## Тёплый старт игры
Только чтение кода (без замеров). Пересчёт в полёте: `air_runtime.gd:_process` (Stage.IDLE) → `needs_recompute` (смена ветра /
погоды / **срок**: `slot(hour, 15 мин)` изменился) → `_begin` (`_req.hour = slot_hour(clock.hour, 15 мин)`: 12:15, 12:30, …; `_passes = 1`,
`_k = inflow_k` или 1 при `wind_ref = inflow`) → `_prep_task` (вход решателя на `_req.hour`) → фазы → `_start_picard`.

- **Что греется.** `air_runtime.gd:_prev_pair`: `warm_start and not _loading` → `_warm` = `{mech, heat}`, оба — `AirPicardJob.state()`
  прошлого поля (`_warm_next.heat = _job.state(false)` в `_poll_solve`, `_warm_next.mech = _building.state(true)` в `_read_mech_state`;
  `_apply`: `_warm = _warm_next`). В `_start_picard`: `_job.warm = pair.mech` (первое решение — **без нагрева**), `_job.warm_heat = pair.heat`
  (второе — **с нагревом**), если размер совпал (`_warm_ok`: по `n = nx·ny·nz` с ореолом). **Греются оба решения** (mech и heat), каждое
  своим состоянием. Старое «греется только решение без нагрева, 70 + 90» в `docs/guide/air-model/runtime.md` — до `warm_heat`
  (AP-20, commit 8ffc7180a, 07.10.2026); код сегодня греет оба — расхождение в док. (в отчёте).
- **Какие поля.** `AirPicardJob.state()` = `{u, v, w, th, thd, p}` (массивы N с ореолом, float32; mech — `um, vm, wmech, thm, thdm, pm`).
  Загружаются в `start`/`_upload_heated_freeze`: u, v, w, θ′ (`th`), θ′_d (`thd`; нет ключа — нули), p. **Не греются и сбрасываются**: `nu`,
  `nuh` (K замыкания) — пересчитываются из входа нового часа (`_record_setup`, `local_k`/`_kloc`, `_relax_k` от `nuo/nuho` = свежие K);
  вход решателя (Q, nu_bg, γ, z_i, профиль, границы `_bc`) — целиком от `_req.hour`; история невязок, счётчик итераций, `late_*`, ω
  (`omega_fallback`) — заново.
- **Как стартует.** Фаза INIT: `_program("warm")` = `_bc(0)` (границы от поля, не от фона) + **4** V-цикла проекции вместо `_bc(1)` (фон) + 30 V-циклов
  холодного (`"init"`). Второе решение (с нагревом): `"reinit_warm"` (`_record_setup` + `_bc(0)` + 4 V-цикла) вместо `"reinit"` (+30). Дальше обычные
  пачки по 10 итераций до критерия (`check_every`), `final` (10 V-циклов). Фазы механизмов (`freeze_mask`, `freeze_field`, `mech_field`) строятся
  заново на новый час и поверх тёплого поля замораживают колонны H/F/G/D; ω := 1 (`use_map = false`).
- **Что сбрасывается / не используется при тёплом старте:** грубый Пикар (`_coarse`, `warm_coarse` — только если нет `_warm`; `_after_phases`
  пропускает его при `_warm_ok`), проход 2 загрузки (`_pass_log`, `_warm_pass` — только при загрузке), `blend` подмены (`blend_s` 60 с — поверх).
  Ошибка/таймаут расчёта → `_fail`: `_warm_next` сбрасывается, `_warm` и поле остаются прежними (следующий срок — снова от них).
  **Тёплого состояния нет** (`_warm = {}`) после запечённого поля и кеша поля (`air_runtime.gd:_load_baked` / `_load_cached`),
  после смены места (`setup`, ~254) и аналитики (`_analytic`): первый пересчёт тогда идёт от грубого Пикара/фона, а не от поля.
- **Окна 100/50 м** (`AirClipmap`) тёплый старт берут от нового поля области (`set_domain_data`), в полёте — на прежних местах (`_start_windows`).
- Для R4: снимок = `{u, v, w, th, thd, p}` обоих решений на сетке 400 м с ореолом; K и вход пересоздаются из случая T+15.

### T+30: случай h1230 (PR-10, R5 v1)
Цепочка тёплых стартов T→T+15→T+30: `ongudai_d400_u3_heat_h1230` (12:30, `source.hour` 12,5, `warm_from` = `ongudai_d400_u3_heat_h1215`), собран
тем же путём (вход снят `warm/dump_inputs.gd --hours=12.5`, эталон — холодный `air.py` f64). Эталон: 261 итерация, t_ref_s 10,7 (первый
запуск процесса — с прогревом CuPy). Изменения 12:15 → 12:30: H max|Δ| 12,5 Вт/м² (rms 4,6, среднее +4,0; max H 257), z_i 2968 → 3004 м (+36),
γ max|Δ| 0,0058 К/м, `sun_elev` 58,1° → 59,2°, α и профиль ветра те же; производные nu_bg max|Δ| 7,9 (из 188), Kz 112 (из 120). Старые файлы не тронуты.
Команда: `dump_inputs.tscn -- --hours=12.5 --u10=3 --out=$HOME/data/air_cascade/ongudai/warm_inputs`, затем
`export_ongudai.py u3_heat_h1230` (предыдущий слот `h1215` должен лежать в `ongudai/`); проверки `check_r5.py` и `check_contract.py --ref` — как ниже.

### Воспроизведение PR-3
```
git -C . status --short                      # venv: tools/research/heat_ca/.venv (см. выше), не коммитится
.dpcli/dpcli lock cpu PR-3 --no-tmux -- timeout 600 env XDG_DATA_HOME=~/.cache/dp-xdg/$(basename "$PWD") godot --headless --path . --import   # первый раз
.dpcli/dpcli lock cpu PR-3 --no-tmux -- timeout 180 env XDG_DATA_HOME=~/.cache/dp-xdg/$(basename "$PWD") godot --headless --path . \
  res://tools/research/air_cascade/warm/dump_inputs.tscn -- --hours=12,12.25 --u10=3 --out=$HOME/data/air_cascade/ongudai/warm_inputs
tools/research/heat_ca/.venv/bin/python tools/research/air_cascade/export/export_ongudai.py u3_heat_h1200 u3_mech_h1200 u3_heat_h1215 u3_mech_h1215   # ~1 мин
python3 tools/research/air_cascade/export/check_r5.py ~/data/air_cascade/ongudai/ongudai_d400_u3_{heat,mech}_h1215.json
python3 tools/research/air_cascade/picard_rs/contract/check_contract.py --ref ~/data/air_cascade/ongudai/ongudai_d400_u3_{heat,mech}_h12{00,15}.json
```
Данные (вне git, 4 × 38 МБ + `warm_inputs/inputs_h12{00,15}.json` с H, γ, z_i, профилем часа от игры): `~/data/air_cascade/ongudai/`.
Эталон f64 (холодный, итерации / t_ref_s): heat h1200 281 / 11,9*, h1215 281 / 7,2; mech h1200 341 / 7,1, h1215 341 / 7,1 (\* прогрев CuPy).
Лицензий новых внешних данных нет: код и фикстура — репозиторий.
