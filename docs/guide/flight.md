---
type: "guide"
status: "active"
module: "flight"
area: "flight"
updated: "2026-10-15"
summary: "Вход в гайд по полёту: FlightModel и Glider (scripts/flight/), три режима крена, земля и посадка, Маятник; оглавление частей."
related: ["docs/guide/flight/model.md", "docs/guide/flight/wings.md", "docs/guide/flight/api.md", "docs/guide/flight/polar-table.md", "docs/guide/flight/ground-bank.md", "docs/guide/flight/ground-pose.md", "docs/guide/flight/sky-shade.md", "docs/guide/flight/pendulum.md", "docs/research/pendulum.md", "docs/contracts/pendulum.md"]
---
# Модель полёта (scripts/flight/)

Реализует FR-1…FR-10. Логика — в `RefCounted`-классах (тестируются headless), нода `Glider` —
тонкая обёртка: время, ввод, визуал. Исследование массы пилота и источники поляр —
[research/pilot_mass.md](../research/pilot_mass.md).

Гайд описывает код `main` на версию 1.5.15 и разбит на части (D4): этот файл — вход, подробности — в `docs/guide/flight/`.

| Файл | Что |
|---|---|
| `flight_model.gd` — `FlightModel` | полёт: силы, тангаж, крен, срыв, касание земли, телеметрия |
| `wing_polar.gd` — `WingPolar` | поляра крыла CL→CD из точек (V, снижение) |
| `ground_run.gd` — `GroundRun` | стоит / идёт / разбег, отрыв, крен крыла на земле, ошибки разбега |
| `landing_flare.gd` — `LandingFlare` | выравнивание, «подвешивание», касание, пробежка, авария |
| `landing_judge.gd` — `LandingJudge` | оценка посадки |
| `pilot_legs.gd` — `PilotLegs` | ноги на касании: сгиб коленей на конечном ходе (общая для `FlightModel` и «Маятника») |
| `flight_telemetry.gd` — `FlightTelemetry` | заполнение Telemetry |
| `load_meter.gd` — `LoadMeter` | перегрузка n = L/W (`FlightModel.load`), сглаживание 0,15 с |
| `glider.gd` — `Glider` (`scenes/glider/glider.tscn`) | нода: шаг физики, интерполяция, сигналы; подставляет `FlightModel` или `PendulumModel` |
| `glider_visual.gd` — `GliderVisual` (`scenes/glider/glider_visual.tscn`) | крыло + пилот, маркеры, заглушки, ленточки, приборы на кисти |
| `sky_shade.gd` — `SkyShade` | тень от неба под парусом |
| `pendulum/` — `PendulumModel`, `WingStrips`, `PilotChain`, `PilotArms`, `PendulumGround`, `PendulumTouchdown` | режим «Маятник» |

## Суть модели

**Точечная масса с ориентацией** (`FlightModel`): положение, скорость, курс, крен, тангаж киля, угол атаки, флаг срыва;
полу-неявный Эйлер с `dt` = 1/120 с (`sim.json`). Подъёмная сила и сопротивление берутся из поляры крыла
(в спокойном воздухе модель сходится к ней точно), трапеция задаёт угол атаки, масса и высота масштабируют скорости
как √(M/ρ). Воздух опрашивается в центре и на концах крыла (термик на краю кренит крыло), вираж координированный.
Срыв — динамический (парашютирование, опускание носа, сваливание на крыло). Земля: ходьба, разбег, отрыв по L ≥ W,
крен крыла на плечах держит ограниченная «рука пилота». Посадка — выравнивание и оценка по нормали к склону. Что
модель не умеет — «Допущения» в [flight/model.md](flight/model.md).

**Режимы управления креном** (`controls.json → roll_control_mode`, по умолчанию `pendulum`):
«Маятник» `pendulum` — основной режим, отдельная модель: крыло на 16 полосах, пилот на цепи подвески, руки (с 1.5.4; нестационарная подъёмная
PD-29 в коде выключена; [flight/pendulum.md](flight/pendulum.md)). «Смещение веса» `weight_shift` и «Простое (аркадное)» `rate` — запасные режимы на `FlightModel`.

## Оглавление

| Часть | Разделы |
|---|---|
| [flight/model.md](flight/model.md) | Модель: силы, поляра, трапеция, масса и высота, крен (`rate`, `weight_shift`), сваливание, воздух, земля, выравнивание, посадка, ноги на касании, перегрузка; Допущения |
| [flight/wings.md](flight/wings.md) | Параметры (конфиги крыла, пилота, полёта); Крылья: 48 моделей по группам и классам ветра |
| [flight/api.md](flight/api.md) | API `FlightModel` и `Glider`; Визуал; Усилие на трапеции (`bar_force`, рамка индикатора подвески) |
| [flight/polar-table.md](flight/polar-table.md) | Таблица поляры: `training`, `laminar`, `sport` при трёх массах пилота |
| [flight/ground-bank.md](flight/ground-bank.md) | Крен на земле: уравнение моментов, рука пилота, порог бокового ветра, поворот на бегу |
| [flight/ground-pose.md](flight/ground-pose.md) | Поза крыла на земле (зазор над рельефом); Крыло стоя на старте (тангаж, флюгер, касания до перехода в лётное положение); Старт в сильный ветер |
| [flight/sky-shade.md](flight/sky-shade.md) | Тень от неба под крылом (физика, параметры, реализация) |
| [flight/pendulum.md](flight/pendulum.md) | Маятник: модель, включение, ввод, вкладка «Аппарат», земля, срыв и штопор, ленточки, камера, учтённое, границы |

Смежное: ленточки на тросах — [telltale.md](telltale.md); приборы и звук — [instruments.md](instruments.md); вывод движения
на платформу — [motion-rig.md](motion-rig.md); модели крыльев и пилота — [models.md](models.md).

## Тесты

`godot --headless --path . res://tests/run_tests.tscn -- --filter=flight` (1.5.15: 247 тестов, 0 упало, 5 пропущено) —
поляра и трим каждого крыла, ориентиры FR-1/FR-2, √M и неизменное качество, инерция, переложение 45→45, удержание крена;
режим «смещение веса» (`test_roll_weight_shift`): крен от смещения, выравнивание в центре (учебное быстрее спортивного),
крен без спирали, 45→45, клавиша X; радиус и снижение в вираже, сваливание (нос вниз, потеря высоты, на крыло, выход),
поток +2 м/с, снос и путевая, несимметричный подъём, порыв, разбег со встречным / попутным / боковым ветром, нос
высоко/низко, слабый разбег, ходьба и склон, оценка посадки, выравнивание (штиль / на 1 м и 3 м выше / встречный ветер),
пробежка, склон, нода `Glider`, крен на земле, поза крыла, «Маятник» (`tests/flight/pendulum/`).
