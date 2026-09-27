extends RefCounted
## Вспомогательные функции для тестов полёта и инструмента таблицы поляры.

const DT := 1.0 / 120.0


## Модель с крылом wing_name ("sport" …) и массой пилота (≤0 — эталонная крыла).
## Плотность постоянная (как на уровне моря), чтобы сравнивать с полярой напрямую.
static func make(
	wing_name: String, pilot_mass_kg: float = 0.0, flight_override: Dictionary = {}
) -> FlightModel:
	var wing: Dictionary = Config.get_config("wings/" + wing_name)
	var pilot: Dictionary = Config.get_config("pilot").duplicate(true)
	pilot.mass_kg = pilot_mass_kg if pilot_mass_kg > 0.0 else float(wing.pilot_mass_ref_kg)
	var ov := {"air_density": {"altitude_dependent": false}}
	ov = Config._deep_merge(ov, flight_override)
	var m := FlightModel.new()
	m.setup(wing, pilot, ov)
	return m


static func input(pitch: float = 0.0, roll: float = 0.0, run: bool = false) -> ControlInput:
	var c := ControlInput.new()
	c.pitch = pitch
	c.roll = roll
	c.run = run
	return c


static func run_for(
	m: FlightModel,
	seconds: float,
	inp: ControlInput,
	air_fn: Callable = Callable(),
	ground_fn: Callable = Callable()
) -> void:
	var n := int(round(seconds / DT))
	for i in n:
		m.step(DT, inp, air_fn, ground_fn)


## Установившееся планирование при трапеции pitch: Vector2(воздушная скорость, снижение) м/с.
static func settle(m: FlightModel, pitch: float, seconds: float = 40.0) -> Vector2:
	m.reset_in_air(Vector3(0, 3000, 0), 0.0)
	var inp := input(pitch)
	run_for(m, seconds, inp)
	# усредняем последние 5 с
	var sv := 0.0
	var ss := 0.0
	var n := int(5.0 / DT)
	for i in n:
		m.step(DT, inp, Callable(), Callable())
		sv += m.telemetry.airspeed
		ss += -m.telemetry.vario
	return Vector2(sv / n, ss / n)
