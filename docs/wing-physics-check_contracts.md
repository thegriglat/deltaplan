# Контракты модуля wing-physics-check

План — `docs/plan/wing-physics-check.md`. Контракты К1–К3 фиксируют то, что уже есть в коде (main 3820bda); К4–К6 — новые форматы данных модуля. Менять — только через координатора (версия +1, уведомить потребителей). Контрактный тест — `tests/contracts/test_wing_physics_contracts.gd`.

## К1. Конфиг крыла → модель полёта (v1)
Владелец: данные крыльев (`configs/wings/<id>.json`, генераторы `tools/research/data/wing_passports/`). Потребители: `FlightModel.setup` (`scripts/flight/flight_model.gd:94`), `WingPolar`, `WingCatalog`, тесты `tests/flight/*`, задачи WPC-1, WPC-3.
- `area_m2` (м²), `span_m` (м), `wing_mass_kg`, `pilot_mass_min_kg`, `pilot_mass_max_kg`, `pilot_mass_ref_kg` (кг, пилот с подвеской).
- `polar.points_kmh_ms`: массив пар [воздушная скорость км/ч, снижение м/с] при эталонной полной массе (`pilot_mass_ref_kg + wing_mass_kg`) и плотности `flight.air_density.polar_ref_kgm3` (1,225); первая точка — сваливание в прямолинейном полёте; скорости строго растут.
- `trim_speed_kmh`, `full_pull_speed_kmh`, `full_push_speed_kmh` — скорости при трапеции 0 / −1 (на себя) / +1 (от себя) при эталонной массе и плотности; трапеция задаёт угол атаки (`_alpha_command`, flight_model.gd:285), поэтому при другой массе/плотности скорость × √(M·ρ_эт/(M_эт·ρ)).
- `reference.{stall_speed_kmh, min_sink_ms, min_sink_speed_kmh, best_glide, best_glide_speed_kmh}` (+ `sink_at_80_kmh_ms`, если крыло летает 80 км/ч) — ориентиры для тестов (при эталонной массе, уровень моря).
- Инварианты: stall_speed < trim < full_pull; full_push < trim (full_push может быть ниже сваливания — полное выжимание сваливает).

## К2. Скорость воздуха → модель полёта (v1)
Владелец: `Atmosphere.air_velocity_at(pos: Vector3) -> Vector3` (`scripts/atmosphere/atmosphere.gd:636`; `CalmAir` — то же). Потребители: `FlightModel.step(dt, input, air_fn, ground_fn)` (через `Glider.set_air_fn`), WPC-2, WPC-3.
- Мир: X — восток, Y — вверх, −Z — север; м/с; скорость воздуха относительно земли (куда дует). Ветер «с севера» (from_deg = 0) → +Z.
- Модель полёта: воздушная скорость = `velocity − air` (velocity — относительно земли), курс — по горизонтальной воздушной скорости. Проверено `tests/flight/test_air.gd::test_headwind_groundspeed`, `test_wind_drift`.

## К3. Ветер меню → атмосфера (v1)
Владелец: `Atmosphere.set_wind(speed_kmh, from_deg, ref_msl)` (atmosphere.gd:513), `WindModel` (`scripts/atmosphere/wind_model.gd`). Вызывающий: `Game` (`scripts/game/game.gd:281`) — скорость из настроек, направление «в старт» или румб, `ref_msl` = высота старта.
- Аналитика: `speed_kmh` — скорость U на `wind.reference_height_m` (10 м) над рельефом; на высоте agl над местной землёй U = U10·min((max(agl, z0)/10)^α, max_profile)·altitude_factor(msl); altitude_factor = clamp(1 + 0,6·(msl − ref_msl)/1000, 0,5, 2).
- Поле (GPU): как U10 меню задаёт приток решателя и сколько поле даёт на старте — **устанавливает WPC-2** (вносится сюда v2 без смены интерфейса).

## К4. Таблица «паспорт против модели» (v2, новый)
Владелец: WPC-1. Потребители: координатор, задачи волны 2, регрессионные тесты.
Файл `tools/research/wing_physics_check/out/wings_audit.csv`, UTF-8, разделитель `,`, точка — десятичный знак, по строке на (крыло, масса):
`wing,group,mass_case,pilot_mass_kg,total_mass_kg,src_key,quantity,unit,model,config,passport,passport_src,diff_pct`
- `mass_case`: `ref` | `pilot85`; `quantity`: `stall` | `trim` | `full_pull` | `min_sink` | `min_sink_speed` | `best_glide` | `best_glide_speed` | `sink_at_80` | `stall_start_alt` (v2: сваливание на высоте старта) | `takeoff_gs_w0` | `takeoff_gs_w3` | `takeoff_gs_w6` | `takeoff_gs_w10` (v2: путевая скорость отрыва ≈ Vmin на высоте старта − встречный ветер 0/3/6/10 м/с, км/ч); скорости — км/ч, снижение — м/с, качество — безразмерное; `model` — из установившегося полёта FlightModel (ρ = 1,225), `config` — из конфига, `passport` — пусто, если в паспорте нет; `diff_pct` = (model − passport)/passport·100, пусто без паспорта.

## К5. Профили ветра у стартов (v1, новый)
Владелец: WPC-2. Потребители: координатор, WPC-3 (выбор точек), волна 2.
Файл `tools/research/wing_physics_check/out/wind_profile.csv`, по строке на точку:
`location,start,mode,wind_set_ms,hour,offset_m,agl_m,msl_m,ground_msl_m,u_h_ms,u_along_ms,w_ms,u_profile_model_ms`
- `mode`: `analytic` | `field`; `offset_m` — расстояние от старта по ветру вперёд (против ветра — отрицательное: 0 — над стартом, −50/−150/−300 — над склоном перед стартом, откуда дует), `u_h_ms` — модуль горизонтального ветра, `u_along_ms` — компонента вдоль направления «из старта в ветер» со знаком (+ — дует на старт), `w_ms` — вертикальный поток (+ вверх), турбулентность выключена; `u_profile_model_ms` — U(agl) по формуле К3 для сравнения.

## К6. Пачка полётов (v1, новый)
Владелец: WPC-3. Потребители: координатор, WPC-9 (до/после), регрессионные тесты волны 2.
Файл `tools/research/wing_physics_check/out/penetration.csv`, по строке на запуск (повторный запуск пропускает готовые ключи):
`key,series,location,start,mode,wing,pilot_mass_kg,wind_set_ms,pitch,agl0_m,duration_s,gs_into_wind_ms,airspeed_ms,vz_ms,wind_h_ms,wind_w_ms,agl_end_m,climb_m,note`
- `series`: `penetration` (прямо в ветер) | `ridge` (восьмёрка у гребня); `gs_into_wind_ms` — средняя за последние 30 с путевая скорость вдоль направления «в ветер» (+ — вперёд, против ветра; − — сносит назад); `airspeed_ms`, `vz_ms` (+ вверх), `wind_h_ms`, `wind_w_ms` — средние за то же окно в точке аппарата; `climb_m` — набор за полёт; `note` — касание земли и т. п.

## История
- К4 v2 (01.10): добавлены значения `quantity` для проверки отрыва на старте (данные пилота о старте при 0/3/6/10 м/с); колонки те же. Потребитель WPC-1 уведомлён.
