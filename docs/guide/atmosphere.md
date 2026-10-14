---
type: "guide"
status: "active"
module: "atmosphere"
area: "air"
updated: "2026-10-15"
summary: "Модуль scripts/atmosphere/: API Atmosphere, устройство и части — погода, поле скоростей, облака, калибровка, склон; тесты и конфиги."
related: ["docs/guide/air-model.md", "docs/guide/atmosphere/weather.md", "docs/guide/atmosphere/wind-field.md", "docs/guide/atmosphere/clouds.md", "docs/guide/atmosphere/calibration.md", "docs/guide/atmosphere/ridge-starts.md"]
---

# Атмосфера

Модуль `scripts/atmosphere/`: ветер, термики, фоновое опускание, склоновый подъём,
подветренные зоны и роторы (FR-8, FR-11…FR-16), кучевые облака, их тени и птицы
(FR-14, FR-14a, FR-22, VR-1, VR-2). Модели и формулы — [research/thermals.md](../research/thermals.md). Поле воздуха (фазы + Пикар на GPU, термики и возмущения из поля) — [air-model.md](air-model.md).

## Подключение (главная сцена)

```gdscript
var atmo := Atmosphere.new()            # или узел в сцене со скриптом atmosphere.gd
add_child(atmo)
atmo.set_weather("weather/medium")      # FR-16: weak / medium / strong или свой словарь
atmo.set_wind(15.0, 270.0)              # км/ч на 10 м, откуда дует (0 — с севера)
atmo.set_ground(terrain.height_at, terrain.thermal_source_strength_at, terrain.surface_at)
atmo.set_sun_direction(sun_node.global_transform.basis.z)  # к солнцу (тени облаков → термики)
atmo.focus_node = glider                # вокруг кого генерировать термики (иначе — камера)
# MVP: несколько статичных термиков у старта
atmo.set_thermal_mode("both")           # или "static" — только статичные
atmo.load_static_thermals(location.get("thermals", []))  # [{x_m, z_m, strength_ms, radius_m}]
```

Нода сама вызывает `step(dt)` из `_physics_process` и сама рисует облака и птиц
(дочерние `Clouds`, `Birds`; в headless не создаются).

## API `Atmosphere` (Node3D, группа `"atmosphere"`)

| Метод | Что |
|---|---|
| `air_velocity_at(pos: Vector3) -> Vector3` | скорость воздуха (ветер + вертикальные потоки + пульсации), м/с, мир. Зовите для центра и концов крыла. |
| `mean_wind_at(pos) -> Vector3` | средний ветер без пульсаций и вертикальных потоков (колдун на старте, взлёт). |
| `step(dt)` | продвинуть время атмосферы (сама нода зовёт из `_physics_process`). |
| `set_ground(height_fn, sun_fn, surface_fn = Callable())` | рельеф `(x, z) -> высота над уровнем моря`, сила источника термиков `(x, z) -> 0..1`, класс поверхности `(x, z) -> int` (для пылевых вихрей). |
| `set_weather(name_or_dict, blend_s = -1)`, `configure(atmo_cfg, weather_cfg)` | погода: словарь `WeatherModel.derive` (игра) или эталон `configs/weather/*` (тесты); `blend_s ≥ 0` — мягкий переход без пересоздания термиков (ход дня, сигнал `weather_updated`) / полная настройка (тесты). |
| `set_wind(speed_kmh, from_deg, ref_msl = NAN)` | ветер прогноза (FR-16) на высоте `ref_msl` (старт): выше — сильнее (`wind.altitude_*`). |
| `set_sun_direction(to_sun)` | солнце: тени облаков ослабляют новые термики (VR-2). |
| `set_cloudbase_msl(m)`, `get_cloudbase_msl()` | нижняя кромка; по умолчанию средняя высота земли в радиусе 10 км + пресет. |
| `set_thermal_mode("dynamic"｜"static"｜"both")` | генерация по рельефу / только статичные (MVP) / оба. |
| `add_static_thermal(x, z, strength_ms, radius_m) -> id`, `load_static_thermals(arr)`, `clear_static_thermals()` | статичные термики. |
| `set_focus(pos)` / `focus_node` | центр генерации термиков. |
| `thermals_near(pos, r) -> Array[Dictionary]` | для тестов и отладки. **Пилоту не показывать** (FR-22). |
| `time_s`, `turbulence_enabled` | время атмосферы; выключатель пульсаций (тесты). |

Сигнал `weather_changed` — после смены погоды (`configure`), `weather_updated` — после мягкого обновления.

## Устройство

| Файл | Класс | Что |
|---|---|---|
| `atmosphere.gd` | `Atmosphere` (Node3D) | тонкая нода: время, сборка поля скоростей, визуал |
| `wind_model.gd` | `WindModel` | степенной профиль ветра, детерминированные пульсации (FastNoiseLite, нормированы на СКО = 1) |
| `wind_profile.gd` | `WindProfile` | профиль ветра по высоте: α по классу устойчивости Паскуилла–Тёрнера (ветер, высота солнца, облачность), насыщение на z_sat — одна функция для `WindModel` и решателя поля (C2 v4) |
| `ground_field.gd` | `GroundField` | кеш рельефа кусками 16×16 узлов по 30 м: высота, градиент, «линия тени» против ветра; билинейно |
| `thermal_field.gd` | `ThermalField` | генерация по клеткам (детерминированно), жизненный цикл, сетка поиска, профиль |
| `atmo_thermal.gd` | `AtmoThermal` | один термик: источник, наклон, времена жизни, облако |
| `cloud_model.gd` | `CloudModel` | стадия/размер/положение облака, выбор видимых, слияние наложившихся |
| `cloud_layer.gd` | `CloudLayer` (Node3D) | пул боксов с raymarch-шейдером |
| `cloud_shadow_map.gd`, `cloud_shadow_map.gdshader` | `CloudShadowMap` | карта теней облаков (пропускание прямого солнца) вокруг камеры |
| `cloud_common.gdshaderinc` | — | форма, плотность, свет, проход луча (общий код) |
| `cloud_volume.gdshader` | — | бокс на облако (Compatibility) |
| `cloud_compositor_effect.gd`, `cloud_raymarch_cs.gdshaderinc`, `cloud_composite_cs.gdshaderinc` | `CloudCompositorEffect` | compute: буфер пониженного разрешения + апскейл |
| `bird_flock.gd`, `bird.gdshader` | `BirdFlock` (Node3D) | птицы в MultiMesh |
| `cloud_physics.gd` | `CloudPhysics` | подсос, бурление в облаке, `cloud_density_at` |
| `storm_field.gd` | `StormField` | Cb: нисходящий поток, растекание, фронт порывов |
| `wave_field.gd` | `WaveField` | подветренные волны, роторы, гребни для лентикуляров |
| `cirrus_layer.gd`, `cirrus.gdshader` | `CirrusLayer` | перистая пелена |
| `dust_model.gd`, `dust_devils.gd`, `dust_devil.gdshader` | `DustModel`, `DustDevils` | пылевые вихри |
| `gust_dust_model.gd`, `gust_dust.gd`, `gust_dust.gdshader` | `GustDustModel`, `GustDust` | клубы пыли от порывов у земли |
| `atmosphere_preview.gd` | — | тестовая сцена `scenes/atmosphere/atmosphere_preview.tscn` |
| `atmo_day.gd` | `AtmoDay` | день как чистые функции времени: погода, солнце, сила источников |
| `atmo_fingerprint.gd`, `atmo_fingerprint_cli.gd` | `AtmoFingerprint` | отпечаток атмосферы для проверки детерминизма |
| `weather_model.gd`, `surface_heating.gd` | `WeatherModel`, `SurfaceHeating` | погода из прогноза; запаздывание прогрева по классам |
| `surface_heat.gd` | `SurfaceHeat` | поток тепла с поверхности — [air-model/surface-heat.md](air-model/surface-heat.md) |
| `field_turbulence.gd`, `gust_spectrum.gd` | `FieldTurbulence`, `GustSpectrum` | болтанка и рывки из поля — [air-model/turbulence.md](air-model/turbulence.md) |
| `thermal_signs.gd`, `thermal_signs.gdshader` | `ThermalSigns` | ласточки и пух у молодого термика |
| `wind_field_debug.gd` | `WindFieldDebug` | F3 — стрелки ветра, F4 — карта фаз — [air-model/debug.md](air-model/debug.md) |
| `air_model/` | — | среднее поле воздуха на GPU и CPU — [air-model.md](air-model.md), [air-model-gpu.md](air-model-gpu.md) |

## Части

| Часть | Что |
|---|---|
| [Погода из прогноза (FR-16)](atmosphere/weather.md) | прогноз пилота → погода дня: верх термиков, кромка, ход дня, закат |
| [Поле скоростей](atmosphere/wind-field.md) | формула скорости воздуха, термик, снос, склон, подветренная зона и ротор, подсос облака, слова пилота в числах |
| [Облака, тени, птицы, особая погода](atmosphere/clouds.md) | облака (compute и boxes), тени, птицы, ласточки и пух, перистая пелена, Cb, волна, пыль, известные проблемы |
| [Проходимость маршрута и калибровка](atmosphere/calibration.md) | бот-маршрутник, идеальный пилот, калибровка дней, сила источника из `SurfaceHeat` |
| [Склон на стартах (FR-12, FR-13)](atmosphere/ridge-starts.md) | парение у склона на 10 стартах |

## Детерминизм
Мир одинаков у всех клиентов сетевой зоны: термики рождаются как чистая функция (клетка, цикл, зерно), день — `AtmoDay` (погода, солнце и сила источников как функции времени атмосферы; погода считается раз в `quantum_h` и между шагами интерполируется), поэтому атмосферу можно начать сразу с момента `t` (`Atmosphere.start_at`) без истории. Проверка — отпечаток `AtmoFingerprint` (термики, облака и воздух в 20 точках эталонного мира без рельефа), тест `tests/atmosphere/test_determinism.gd`; сравнить Linux и Windows — `scripts/atmosphere/atmo_fingerprint_cli.gd`. Поле воздуха в ключ мира не входит: отпечаток строится с `air_model.enabled = "off"`, видеокарта на него не влияет ([air-model/field-cpu.md](air-model/field-cpu.md)).


## Конфиги
- `configs/atmosphere.json` — модель (профиль, цикл, генерация, склон, подветренная зона,
  турбулентность, облака, птицы). Каждый параметр с `*_doc`.
- `configs/weather_model.json` — погода из прогноза (см. выше).
- `configs/weather/*.json` — эталоны для тестов физики и калибровки (в игре не выбираются): ветер, кромка,
  сила/радиус/частота термиков, фон, болтанка, облака, улицы, переразвитие, режим и статичные термики.
- Качество облаков: `clouds.quality` = `low` | `medium` | `high` (`clouds.quality_presets`).

## Производительность
Замеры (RTX 4070 SUPER, Forward+, окно ~960×1036; облака = разница кадра с облаками и без):

| Что | Время |
|---|---|
| `air_velocity_at` | ~10 мкс/вызов без поля (шаг планера: 3 точки × 120 Гц ≈ 3,6 мс/с CPU); с полем — [air-model/field-cpu.md](air-model/field-cpu.md), [air-model/turbulence.md](air-model/turbulence.md) |
| `step` | ~35–80 мкс в среднем |
| облака compute `low` (буфер 0,33) | 0,5–0,8 мс GPU |
| облака compute `medium` (0,5) | 2,5–3,1 мс GPU |
| облака compute `high` (0,75) | 3,9–8 мс GPU |
| облака boxes `medium` (полное разрешение) | 5,8–13 мс GPU |
| выбор видимых облаков (CPU) | ~2–5 мс раз в 1 с; форма — по кругу за 15 кадров |

Встроенная графика слабее в 10–15 раз: для неё `quality: "low"` (≈ 6–12 мс).
Задел: временное накопление (перепроекция прошлого кадра, 1/4 пикселей за кадр) — ещё в 2–4 раза дешевле.

## Тесты
`godot --headless --path . res://tests/run_tests.tscn -- --filter=atmosphere` — тесты `tests/atmosphere/`:
- атмосфера и термики: `test_atmosphere.gd` (профиль: ядро > 0, кольцо < фона, шире наверху; асимметрия на консолях, снос и наклон, жизненный цикл, фон, кромка ограничивает набор, склон, болтанка, источники по солнцу, статичные термики из конфига), `test_clouds_and_generation.gd`, `test_cloud_*.gd`, `test_birds.gd`, `test_wave.gd`, `test_hazards.gd`, `test_storm_rarity.gd`, `test_gust_dust.gd`;
- слова пилота в числах — `test_pilot_words.gd` (таблица в [wind-field.md](atmosphere/wind-field.md)); подветренная зона — `test_lee_rotor.gd`; калибровка дней — `test_calibration.gd`; склон на стартах — `test_ridge_starts.gd`; бот-маршрутник — `test_xc_bot.gd`;
- погода и нагрев: `test_weather_model.gd`, `test_weather_day.gd`, `test_surface_heating.gd`, `test_surface_heat.gd`, `test_wind_profile_simple.gd`;
- детерминизм: `test_determinism.gd`;
- поле воздуха (`test_air_*.gd`, `test_wind_field.gd`; часть требует GPU) — перечень в [air-model.md](air-model.md) и [air-model-gpu.md](air-model-gpu.md).

## Тестовая сцена
`godot --path . res://scenes/atmosphere/atmosphere_preview.tscn -- --weather=strong --view=side`
- `--view=horizon|side|near|under|sun|top|stages|birds|cb|cbnear|cbfar|wave|dust`, `--cirrus=<0..1>`, `--ground=ridge`, `--time=<с>`, `--wind=<км/ч>`;
- `--shot=<png>` — сохранить кадр и выйти; `--bench` — GPU-время кадра с облаками и без;
- WASD/QE — полёт, ПКМ — обзор, Shift — быстрее, 1–5 — ракурсы, T — +60 с.
