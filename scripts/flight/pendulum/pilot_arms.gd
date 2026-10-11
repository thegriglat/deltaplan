class_name PendulumPilotArms
extends RefCounted
## Руки пилота «Маятника»: сила между пилотом и трапецией к заданному положению пилота относительно
## точки подвески в осях крыла (x, y), с пределом силы — порт Sim._hands_force
## (tools/research/pendulum/pendulum/model.py).
##
## Руки — пружина-демпфер (жёсткость m/τ², демпфирование критическое) плюс прямая подача силы
## маятника m·g/L·(цель − нейтраль): пилот, сдвинутый от нейтрали на Δ, тянется стропой назад
## силой ≈ m·g·Δ/L, руки держат её сразу, без накопления ошибки (PD-19). Интеграл (ti > 0) —
## только для сравнения: ПИ-удержание с запаздыванием ti ≈ 0,6 с раскачивало фугоиду (затухание
## sport 0,95 за период вместо 0,80 по Ланчестеру, ζ ≈ 1/(√2·K)), большие размахи кончались
## срывом наверху и петлёй.
##
## Ввод: roll −1…1 → пилот поперёк на roll·shift_y_max (+ вправо); pitch +1 («от себя») → назад
## на shift_x_push, −1 («на себя») → вперёд на shift_x_pull. Вертикально — стропа, не руки.

var force_max: float = 300.0
var tau: float = 0.3
var ti: float = 0.0  ## ≤ 0 — без интегральной части
var shift_y_max: float = 0.45
var shift_x_pull: float = 0.45
var shift_x_push: float = 0.3

## Положение пилота относительно подвески при нейтрали (оси B: x вперёд, y вправо, z вниз), м.
var neutral_rel := Vector3.ZERO
## Сила рук на пилота в осях B, Н (последний расчёт).
var force_b := Vector3.ZERO
var _int := Vector3.ZERO


func setup(arms: Dictionary) -> void:
	force_max = float(arms.force_max_n)
	tau = float(arms.tau_s)
	ti = float(arms.ti_s)
	shift_y_max = float(arms.shift_y_max_m)
	shift_x_pull = float(arms.shift_x_pull_m)
	shift_x_push = float(arms.shift_x_push_m)


func reset() -> void:
	_int = Vector3.ZERO
	force_b = Vector3.ZERO


## rel, vrel — положение и скорость пилота относительно подвески в осях крыла (B);
## m_pilot — масса пилота; h — шаг; relaxed — руки отпущены; force_y — заданное поперечное
## усилие (NAN — нет). → сила рук на пилота в осях B.
func compute(
	rel: Vector3, vrel: Vector3, roll: float, pitch: float, m_pilot: float, h: float,
	relaxed: bool, force_y: float
) -> Vector3:
	if relaxed:
		reset()
		return force_b
	var tgt := neutral_rel
	var ry := clampf(roll, -1.0, 1.0)
	var px := clampf(pitch, -1.0, 1.0)
	tgt.y += ry * shift_y_max
	tgt.x += -px * (shift_x_push if px > 0.0 else shift_x_pull)
	var k := m_pilot / (tau * tau)
	var d := 2.0 * m_pilot / tau
	var e := tgt - rel
	e.z = 0.0
	if ti > 0.0:
		_int += e * (h / ti)
	var f := (e + _int) * k - vrel * d
	# прямая подача: возвращающая сила маятника при заданном смещении, L = |нейтраль|
	var L := neutral_rel.length()
	if L > 0.1:
		var off := tgt - neutral_rel
		off.z = 0.0
		f += off * (m_pilot * Units.G / L)
	f.z = 0.0
	var fn := Vector2(f.x, f.y).length()
	if fn > force_max:
		f *= force_max / fn
		if ti > 0.0:
			_int -= e * (h / ti)  # антинасыщение
	if not is_nan(force_y):
		f.y = force_y
		fn = Vector2(f.x, f.y).length()
		if fn > force_max:
			f *= force_max / fn
	force_b = f
	return f
