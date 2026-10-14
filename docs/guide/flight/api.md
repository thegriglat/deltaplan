---
type: "guide"
status: "active"
module: "flight"
area: "flight"
updated: "2026-10-15"
summary: "API FlightModel и Glider, визуал крыла и пилота, тень от неба под парусом, оценка усилия на трапеции."
related: ["docs/guide/flight.md"]
---
# API, визуал, усилие на трапеции

## API

```gdscript
# FlightModel (RefCounted)
signal took_off
signal landed(result: Dictionary)   # {grade: "soft"|"hard"|"crash", vertical_speed_ms,
                                    #  horizontal_speed_ms, bank_deg, position, flight_time_s}
signal takeoff_failed(reason: String)
var telemetry: Telemetry
var mode: FlightModel.Mode           # GROUND, AIR, LANDED, FAILED
func setup(wing: Dictionary, pilot: Dictionary, flight_override := {}) -> void
func reset_on_ground(pos: Vector3, heading_deg: float) -> void
func reset_in_air(pos: Vector3, heading_deg: float, airspeed_ms := 0.0, wind := Vector3.ZERO) -> void
func step(dt: float, input: ControlInput, air_fn: Callable, ground_fn: Callable) -> void
func phase() -> String               # standing/walking/running/flying/landed/failed
func trim_speed() -> float; func stall_speed() -> float; func steady_glide(v) -> Vector2
static func clamp_pilot_mass(wing: Dictionary, mass_kg: float) -> float

# Glider (Node3D, scenes/glider/glider.tscn); начало координат — ноги пилота.
# Режим «Маятник» (controls.json → roll_control_mode == "pendulum") подставляет PendulumModel
# с той же поверхностью (контракт PD-К1) — см. pendulum.md
signal telemetry_updated(t: Telemetry)   # каждый шаг физики, один и тот же объект
signal landed(result: Dictionary)
signal takeoff_failed(reason: String)
signal took_off
@export var wing_id := "sport"; @export var pilot_mass_kg := 0.0; @export var auto_start
var control: ControlInput
func setup(wing_name: String, mass_kg := 0.0, apparatus := {}) -> void   # масса — в диапазоне крыла;
                                        # apparatus — вкладка «Аппарат» (только «Маятник»)
var model                              # FlightModel или PendulumModel (режим pendulum)
func is_pendulum() -> bool
func set_input(c: ControlInput) -> void
func set_air_fn(f: Callable) -> void      # f(pos: Vector3) -> Vector3
func set_ground_fn(f: Callable) -> void   # f(x: float, z: float) -> float
func reset_on_ground(pos: Vector3, heading_deg: float) -> void
func reset_in_air(pos: Vector3, heading_deg: float, airspeed_ms := 0.0) -> void
func step(dt: float) -> void            # шаг физики; _physics_process зовёт его сам —
                                        # интегратор может выключить physics_process и шагать сам
func get_telemetry() -> Telemetry
func phase() -> String
func get_marker(name: String) -> Node3D   # PilotHead, InstrumentMount, VarioMount, BaseBar, HangPoint, WingTipL/R
```

## Визуал

`Glider` создаёт сцену `flight.json → visual.scene` (`scenes/glider/glider_visual.tscn`, скрипт `GliderVisual`) и
вызывает `build(wing, pilot, visual_cfg)`. Нода `Visual` стоит в начале координат планера (ноги пилота). Оси
моделей: 1 ед. = 1 м, вперёд −Z, вверх +Y. Контракт имён нод, маркеров и осей крыла и пилота — в
[models/wing-contract.md](../models/wing-contract.md) и [models/pilot.md](../models/pilot.md); здесь только то, что делает с ними `GliderVisual`.

- **Крыло** — `wings/<id>.json → visual.visual_model`. Модель ставится так, что `HangPoint` оказывается на высоте
  `flight.json → visual.hang_height_m` (2,0 м) над ногами. Нет модели — предупреждение в лог и заглушка из примитивов
  с теми же именами нод; нет маркера из `WING_MARKERS` — предупреждение.
- **Пилот** — `pilot.json → visual.visual_model`. Модель висит под нодой-обёрткой `Pilot`, которая сдвигается по
  крену (±`pilot_shift_m` = 0,35 м) и тангажу (±`pilot_bar_m` = 0,3 м); положение тела относительно карабина —
  `pilot.json → visual.body_below_hang_m`, `body_back_m`. На земле пилот стоит вертикально: анимации `stand`/`walk`/`run`
  и наклон назад `run_anim.lean_back_deg` вокруг хвата (подробности — [models/pilot.md](../models/pilot.md)).
  Маркер `PilotHead` обёртки следует за `Head` модели (`get_marker("PilotHead")`, `GliderVisual.get_head_transform()`) —
  для кабинной камеры.
- **Парус** — после загрузки крыла `SailMaterial.apply(Sail, "<имя модели>")` (шейдер — [models/sail-shader.md](../models/sail-shader.md),
  параметры — `configs/sail.json`), каждый кадр `GliderVisual.set_flight(airspeed, stall, turbulence)`:
  `stall` = `FlightModel.stall_amount()` (доля сорванного потока 0..1), `turbulence` = средний разброс мгновенной
  перегрузки `FlightModel.load.jitter` / `sail.json → turbulence_full_g` (0,5 g): в спокойном воздухе ~0, в термике
  ~0,1–0,3, в облачной болтанке — до 1. Боты (`BotGlider`) считают то же самое.
- **Тень от неба** под крылом — [sky-shade.md](sky-shade.md). **Ленточки** на тросах — [telltale.md](../telltale.md).

## Усилие на трапеции (PH-1, PH-К1, рамка индикатора подвески)

`Telemetry.bar_force: Vector2`, Н — сила рук на тело пилота в осях крыла (знаки как у `pilot_shift`, FB-К1:
`x +` — вправо, `y +` — к носу). Виджет `PilotShiftIndicator` меняет только толщину рамки круга:
`w = w0 + (w_max − w0)·clamp(|F| / F_full, 0, 1)`, `w0 = max(1, 0,015·d)`, `w_max = force_ring_max_frac·d`,
`F_full = force_full_n` (`configs/ui.json → pilot_shift`). Цвет, прозрачность и точка не меняются.

- **Маятник** — `PendulumModel.bar_force` (сила рук модели, Н, `arms.force_b`, предел `arms.force_max_n` = 300 Н;
  на земле — `ground.grip_force`), спроецированная в оси крыла.
- **«Смещение веса»** (`FlightModel`) — силы рук в модели нет (тангаж кинематический), усилие оценивается из
  параметров крыла: `FlightModel.bar_force_estimate(v)`.
  1. Скорость v ≠ V_трим держится сдвигом ЦМ пилота против аэродинамического момента (устойчивость по скорости):
     `Δx = (v − V_трим) / (k·s)`, `k = wing.pendulum.ref.kmh_per_cm_hang` (км/ч на см сдвига подвески на эталонной
     массе, из баланса моментов крыла, `tools/flight/pendulum_params.py`), `s = speed_scale()`.
  2. Крен: в модели установившийся крен держится смещением (`roll_input_for_bank`) — упрощение кинематики; в жизни
     вираж держится почти без усилия (Ochi < 10 Н). Поэтому усилие — от отклонения ввода от «держащего»:
     Δy = (roll − `roll_input_for_bank(bank, v)`)·`arms.shift_y_max_m`: есть при вводе в крен и выводе, в
     установившемся вираже ≈ 0. Замер маятника (sport, вираж 30° под ПИД-регулятором крена): среднее x = −39 Н,
     |x| ≤ 42 Н, при вводе пик до предела рук (~300 Н) — порог теста 60 Н. В режиме `rate` (ввод — скорость крена) держащий ввод 0: сила только пока крен вводят. В режиме `weight_shift` ввод 0,3 даёт ≈70 Н, полный ввод — предел рук (в маятнике пик при вводе ≈300 Н).
  3. Руки держат пилота на подвеске длиной L (`pilot.visual.hang_length_m`): `F = m_p·g·Δ/L` по каждой оси,
     длина вектора не больше `pendulum.arms.force_max_n`.
  Приближения: Cm(α) линеен около трима, квазистатика (без динамики и инерции пилота), перегрузка n = 1, малые углы
  подвески (`Δ ≪ L`; при больших скоростях упирается в предел рук). На земле — ноль.
- **Проверка** — `tests/flight/test_bar_force.gd`: на триме |F| < 15 Н; при pitch на себя `y > 0`, растёт со скоростью;
  на одной скорости (≈1,2–1,3·V_трим) силы двух моделей различаются меньше чем в ×3 (замер крыла `sport`:
  1,18·V_трим — 53 Н маятник и 46 Н оценка, 1,27·V_трим — 72 и 67 Н).
- **Физический предел оценки**: в маятнике сила — результат динамики (PD-регулятор рук и натяжение стропы), в
  «смещении веса» — статическая оценка по моменту; при быстром вводе пилота на «смещении веса» усилие следует за
  скоростью, а не за вводом.
