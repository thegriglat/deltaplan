---
type: "guide"
status: "active"
module: "air-model"
area: "air"
updated: "2026-10-15"
summary: "Модель воздуха в трёх масштабах: среднее поле (фазы + Пикар на GPU), термики и возмущения из поля; вход и оглавление частей."
related: ["docs/guide/atmosphere.md", "docs/guide/air-model-gpu.md", "docs/guide/air-model/field-cpu.md", "docs/guide/air-model/runtime.md", "docs/guide/air-model/thermals.md", "docs/guide/air-model/turbulence.md", "docs/contracts/air-model.md"]
---

# Модель воздуха в трёх масштабах

План и задачи — `docs/archive/plan/air-model.md`; журнал — `docs/archive/plan/air-model-progress.md`; контракты стыков — `docs/contracts/air-model.md` (C1–C10), фаз — `docs/contracts/air-phase.md`. Здесь — описание того, что работает в игре; решатель на GPU — [air-model-gpu.md](air-model-gpu.md), аналитическая атмосфера (профиль ветра, термики по клеткам, облака) — [atmosphere.md](atmosphere.md).

## Суть

Воздух пилота — сумма трёх масштабов. Атмосфера (`Atmosphere.air_velocity_at`) спрашивает поле, где оно есть, и аналитику, где его нет.

| Масштаб | Что | Откуда | Где описано |
|---|---|---|---|
| 1. Среднее поле | u, v, w_mech (обтекание рельефа), w_conv (от нагрева), θ′ на сетке: область 400 м (38,4 км вокруг места) и окна 100 и 50 м вокруг пилота | фазы (классификатор A/B/C/D/F/G/H) + итерация Пикара на GPU; вход — рельеф, погода на час, поток тепла `SurfaceHeat` | [field-cpu](air-model/field-cpu.md), [runtime](air-model/runtime.md), [phases](air-model/phases.md), [air-model-gpu](air-model-gpu.md) |
| 2. Термики | пузыри: где, какой силы и радиуса, потолок, снос | источники из поля: законы Дирдорфа и Аллена, число ядер от толщины слоя и w* | [thermals](air-model/thermals.md) |
| 3. Возмущения | болтанка, рывки, подветренная зона, обратный поток | σ и масштабы из поля (u*, сдвиг, N², w*), спектр фон Кармана | [turbulence](air-model/turbulence.md) |

Поток данных в игре:

```
место + час + ветер меню + погода
  → AirPlace.domain_case (рабочий поток) → AirPhaseJob (фазы) → AirPicardJob (Пикар, GPU порциями) → проекция
  → WindField (CPU, центры клеток) → AirFieldSet (уровни: окно 50 м, окно 100 м, область 400 м)
  → Atmosphere.air_velocity_at: горизонталь и w_mech из поля, w_conv — только через термики (масштаб 2),
    болтанка и подветренная зона — из поля (масштаб 3)
```

Нет поля (headless, нет GPU, ошибка или таймаут расчёта) или `air_model.enabled = "off"` («Эвристика» в настройках) — работает прежняя аналитика, побитно. Пересчёт идёт при загрузке места и в полёте по сроку (15 игровых минут, смена ветра или погоды), новое поле подменяет старое плавно (60 с).

## Части

| Часть | Что |
|---|---|
| [Поле на CPU (масштаб 1 → игра)](air-model/field-cpu.md) | раскладка сетки, выборка `WindField.sample`, уровни и подмена `AirFieldSet`, клипмапы, «Стык 1 ↔ 2» с атмосферой, ключи `air_model`, запасной путь и детерминизм |
| [Загрузка и пересчёт поля (`AirRuntime`)](air-model/runtime.md) | конвейер фазы → Пикар → проекция, старт Пикара, два прохода под ветер меню (C9 v3), загрузка, полёт, числа, ограничения |
| [Фазы (P10, `AirPhase`)](air-model/phases.md) | классификатор A/B/C/D/F/G/H, механизмы, код и вызов, числа CPU-тестов |
| [Вход решателя: поток тепла `SurfaceHeat`](air-model/surface-heat.md) | Солнце → Rn → H по классу покрова, вода и лёд, z0 по клетке, замер до и после, чего не умеет |
| [Масштаб 2: термики из поля (AM-07)](air-model/thermals.md) | входы, законы, выбор источников, числа против литературы, сеть, чего не умеет |
| [Масштаб 3: возмущения из поля (AM-08)](air-model/turbulence.md) | что берётся из поля, законы (механика, устойчивость, конвекция, зона за гребнем, спектр), числа, чего не умеет |
| [Границы модели и калибровка](air-model/limits.md) | разрешение сетки и перенос, калибровка AM-09, слова пилота против модели, профиль притока и длина перемешивания (Б2) |
| [Отладка поля](air-model/debug.md) | поле из файла `--air-field`, срезы, F3 и F4 в игре, трава и рябь по полю |

Решатель на GPU: [блоки (AM-02)](air-model-gpu/blocks.md), [Пикар (AM-03)](air-model-gpu/picard.md), [клипмапы (AM-04)](air-model-gpu/clipmap.md).

## Код

| Файл (`scripts/atmosphere/...`) | Класс | Что |
|---|---|---|
| `air_model/wind_field.gd` | `WindField` | один уровень поля на CPU: выборка, край, ограничители, чтение файла |
| `air_model/air_field_set.gd` | `AirFieldSet` | набор уровней и плавная подмена |
| `air_model/air_runtime.gd` | `AirRuntime` | загрузка и пересчёт поля, два прохода, окна; узел-ребёнок `Game` |
| `air_model/air_place.gd`, `air_case.gd` | `AirPlace`, `AirCase` | вход решателя из места игры; подготовка по столбцам |
| `air_model/air_phase*.gd`, `air_phase.glsl` | `AirPhase`, `AirPhaseJob`, `AirPhaseCpu` | фазы |
| `air_model/air_picard_job.gd`, `air_picard.glsl` | `AirPicardJob` | Пикар на GPU |
| `air_model/air_window_*.gd`, `air_clipmap.gd` | `AirWindowCase`, `AirWindowJob`, `AirClipmap` | окна вокруг пилота |
| `air_model/air_gpu*.gd`, `air_multigrid.gd`, `air_*.glsl` | `AirGpu`, `AirGpuJob`, `AirMultigrid` | каркас GPU и блоки |
| `air_model/air_thermals.gd` | `AirThermals` | источники термиков из поля |
| `surface_heat.gd` | `SurfaceHeat` | поток тепла с поверхности |
| `field_turbulence.gd`, `gust_spectrum.gd` | `FieldTurbulence`, `GustSpectrum` | масштаб 3 |
| `wind_profile.gd` | `WindProfile` | профиль ветра по высоте для решателя и аналитики |
| `wind_field_debug.gd` | `WindFieldDebug` | F3 и F4 |

Конфиги: `configs/atmosphere.json` → `air_model`, `air_phase`, `lee`, `turbulence.field_*`; `configs/surface_heat.json`. Тесты — `tests/atmosphere/test_air_*.gd`, `test_wind_field.gd`, `test_lee_rotor.gd`; GPU-тесты — `tools/gpu_tests.sh`.

## Границы модели в одном месте
- Перенос 1-го порядка на сетках 400/100/50 м: разгон у бровки на 20–100 м занижен на 15–20 %, у вершины холма занижен даже на мелкой сетке; 2-й порядок и окно 25 м не включены ([limits](air-model/limits.md)).
- Слабый ветер (≲ 3 м/с днём, штиль): решатель не сходится за 3000 итераций; закрыто запасным путём по сходимости (P12 v2) ([runtime](air-model/runtime.md)).
- Все ядра термиков одной силы (доля w*), нет ячеек сильных термиков через 1–1,5 z_i; тени облаков на источники поля не действуют ([thermals](air-model/thermals.md)).
- Подветренная зона: пузырь отрыва из поля только при разрешении ≳ 8 клеток, иначе эвристика; болтанка над вершиной завышена ([turbulence](air-model/turbulence.md)).
- Влажность почвы — только геометрия рельефа, нет теней рельефа и адвекции в потоке тепла ([surface-heat](air-model/surface-heat.md)).
