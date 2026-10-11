extends RefCounted
## Помощники тестов «Маятника» (PD-2): модель с крылом, эталон прототипа (reference.json),
## регулятор крена пилота-испытателя, детерминированная болтанка (сумма синусоид).

const DT := 1.0 / 120.0
const REF := "res://tests/flight/pendulum/reference.json"
## Старт сценариев прототипа: ЦМ крыла на высоте 1000 м (NED z = −1000), курс север.
const START_CG := Vector3(0.0, 1000.0, 0.0)

static var _ref: Dictionary = {}


static func ref() -> Dictionary:
	if _ref.is_empty():
		_ref = JSON.parse_string(FileAccess.get_file_as_string(REF))
	return _ref


static func scenario(name: String, wing_name: String) -> Dictionary:
	return ref().scenarios[name][wing_name]


## Модель с крылом wing_name; масса пилота ≤ 0 — эталонная крыла. Плотность постоянная 1,225.
## Блок pendulum — из конфига крыла (PD-1); proto_block — блок, посчитанный прототипом
## (reference.json → blocks): сверка самого порта там, где отклик чувствителен к трим-у (болтанка).
static func make(
	wing_name: String, pilot_mass_kg: float = 0.0, apparatus: Dictionary = {},
	proto_block := false
) -> PendulumModel:
	var wing: Dictionary = Config.get_config("wings/" + wing_name).duplicate(true)
	if proto_block:
		wing["pendulum"] = ref().blocks[wing_name]
	var pilot: Dictionary = Config.get_config("pilot").duplicate(true)
	pilot.mass_kg = pilot_mass_kg if pilot_mass_kg > 0.0 else float(wing.pilot_mass_ref_kg)
	var m := PendulumModel.new()
	m.setup(wing, pilot, {"air_density": {"altitude_dependent": false}}, apparatus)
	return m


## Сброс как в прототипе: ЦМ крыла в START_CG, курс север. → смещение ЦМ от START_CG
## (для сдвига поля болтанки, чтобы ЦМ видел то же поле, что в прототипе).
static func reset(m: PendulumModel) -> Vector3:
	m.reset_in_air(Vector3(0.0, 1000.0, 0.0), 0.0)
	var d := cg(m) - START_CG
	m.reset_in_air(Vector3(0.0, 1000.0, 0.0) - d, 0.0)
	return cg(m) - START_CG


static func cg(m: PendulumModel) -> Vector3:
	return m._world(m._pos)


static func input(pitch: float = 0.0, roll: float = 0.0) -> ControlInput:
	var c := ControlInput.new()
	c.pitch = pitch
	c.roll = roll
	return c


## Воздушная скорость ЦМ крыла, м/с.
static func airspeed(m: PendulumModel) -> float:
	return m.telemetry.airspeed


## Положение пилота относительно подвески в осях B прототипа (x вперёд, y вправо, z вниз).
static func rel_b(m: PendulumModel) -> Vector3:
	return Vector3(-m.pilot_rel.z, m.pilot_rel.x, -m.pilot_rel.y)


static func finite(m: PendulumModel) -> bool:
	for v: Vector3 in [m.position, m.velocity, m.pilot_position, m.pilot_velocity]:
		if not (is_finite(v.x) and is_finite(v.y) and is_finite(v.z)):
			return false
	return is_finite(m.bank) and is_finite(m.theta) and is_finite(m.heading)


## Регулятор пилота-испытателя (как BankHold прототипа): ПИД по крену → положение поперёк.
class BankHold:
	var target: float
	var kp: float
	var kd: float
	var ki: float
	var i: float = 0.0

	func _init(target_: float, kp_: float, kd_: float, ki_: float) -> void:
		target = target_
		kp = kp_
		kd = kd_
		ki = ki_

	func roll(m: PendulumModel) -> float:
		var e := target - m.bank
		i = clampf(i + ki * e / 120.0, -1.0, 1.0)
		return clampf(kp * e - kd * m.roll_rate + i, -1.0, 1.0)


## Болтанка из reference.json (оси игры): u(p) = Σ a·cos(k·(p − offset) + φ).
class Turbulence:
	var k: PackedVector3Array = []
	var a: PackedVector3Array = []
	var ph: PackedFloat64Array = []
	var offset := Vector3.ZERO

	func _init(modes: Dictionary, offset_: Vector3) -> void:
		for v: Array in modes.k:
			k.append(Vector3(v[0], v[1], v[2]))
		for v: Array in modes.a:
			a.append(Vector3(v[0], v[1], v[2]))
		for v: float in modes.phase:
			ph.append(v)
		offset = offset_

	func air(p: Vector3) -> Vector3:
		var q := p - offset
		var u := Vector3.ZERO
		for j in k.size():
			u += a[j] * cos(k[j].dot(q) + ph[j])
		return u
