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
## «От себя» у земли (PD-29, PD-35): пилот стоит в подвеске, руки на стойках у плеч — ход кистей ближе к
## подвеске, крыло поворачивается относительно стропы сильнее; эквивалентное смещение ЦМ пилота, м.
## < 0 — по досягаемости рук (PD-35): пилот толкает до вытянутых рук, цель — поворот крыла к стропе на
## flare_reach + flare_reach_soft (через зону спада упора), L·sin этого угла; без досягаемости — shift_x_push.
var shift_x_push_flare: float = -1.0
## Доля хода стоящего пилота 0…1 (модель задаёт по высоте ступней).
var flare_mix: float = 0.0
## Досягаемость рук стоящего пилота (PD-30): хват на стойке поворачивается с крылом около подвески;
## «от себя» толкает, пока плечо — хват ≤ длины руки. Угол крыла к стропе, на котором руки
## вытянуты, рад (0 — без предела) и ширина спада упора до него, рад.
var flare_reach: float = 0.0
var flare_reach_soft: float = 0.0
## Угол крыла к стропе от нейтрали (нос вверх +), рад — последний расчёт (для разбора).
var phi: float = 0.0

## Положение пилота относительно подвески при нейтрали (оси B: x вперёд, y вправо, z вниз), м.
var neutral_rel := Vector3.ZERO
## Сила рук на пилота в осях B, Н (последний расчёт).
var force_b := Vector3.ZERO
## Цель положения пилота относительно подвески в осях крыла — последний расчёт (для разбора).
var target_b := Vector3.ZERO
var _int := Vector3.ZERO


func setup(arms: Dictionary) -> void:
	force_max = float(arms.force_max_n)
	tau = float(arms.tau_s)
	ti = float(arms.ti_s)
	shift_y_max = float(arms.shift_y_max_m)
	shift_x_pull = float(arms.shift_x_pull_m)
	shift_x_push = float(arms.shift_x_push_m)
	shift_x_push_flare = float(arms.get("flare_shift_x_push_m", -1.0))
	var fr: Dictionary = arms.get("flare_reach", {})
	flare_reach = 0.0
	if bool(fr.get("enabled", false)):
		flare_reach = reach_angle(
			float(fr.shoulder_below_hang_m), float(fr.grip_below_hang_m),
			float(fr.grip_ahead_m), float(fr.arm_length_m))
		flare_reach_soft = deg_to_rad(float(fr.soft_deg))


## Угол поворота крыла к стропе (нос вверх), на котором рука вытянута, рад: хват (на стойке, grip_below
## под подвеской и grip_ahead впереди стропы) поворачивается с крылом около подвески; плечо — на
## стропе shoulder_below под подвеской; |плечо − хват| = arm.
static func reach_angle(shoulder_below: float, grip_below: float, grip_ahead: float, arm: float) -> float:
	var r := Vector2(grip_ahead, grip_below).length()
	var psi0 := atan2(grip_ahead, grip_below)
	var c := (r * r + shoulder_below * shoulder_below - arm * arm) / (2.0 * r * shoulder_below)
	return acos(clampf(c, -1.0, 1.0)) - psi0


## Ход «от себя» стоящего пилота, м (смещение ЦМ назад в осях крыла): задан или по досягаемости рук.
func flare_push() -> float:
	if shift_x_push_flare >= 0.0:
		return shift_x_push_flare
	if flare_reach <= 0.0:
		return shift_x_push
	return neutral_rel.length() * sin(flare_reach + flare_reach_soft)


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
	var push := lerpf(shift_x_push, flare_push(), flare_mix)
	tgt.x += -px * (push if px > 0.0 else shift_x_pull)
	target_b = tgt
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
	# досягаемость (стоящий пилот): угол крыла к стропе φ (нос вверх — пилот назад в осях крыла);
	# у вытянутых рук упор «от себя» спадает до нуля — хват ушёл вперёд-вверх, за голову; руки
	# дальше только держат (тянут на себя), прямая подача не толкает
	phi = atan2(-rel.x, rel.z) - atan2(-neutral_rel.x, neutral_rel.z)
	if flare_reach > 0.0 and flare_mix > 0.0 and f.x < 0.0:
		var c := clampf((flare_reach - phi) / maxf(flare_reach_soft, 1.0e-3), 0.0, 1.0)
		f.x *= lerpf(1.0, c, flare_mix)
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
