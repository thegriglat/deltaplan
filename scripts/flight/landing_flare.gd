class_name LandingFlare
extends RefCounted
## Выравнивание и посадка (FR-10): у земли трапеция «от себя» ставит крыло на закритику,
## оно гасит скорость и кратко «подвешивается»; касание ногами оценивает LandingJudge,
## затем пилот добегает остаток скорости. Параметры — flight.json → flare, landing.

## Идёт выравнивание (ноги ниже flare.height_m и трапеция резко от себя).
var active: bool = false
## Насколько пилот выравнивает: трапеция «от себя» у земли (ниже flare.height_m), 0..1.
var amount: float = 0.0
## Сколько секунд длится текущее выравнивание.
var time: float = 0.0
## Сколько секунд крыло «висит» (с верхней точки подскока на выравнивании), −1 — ещё нет.
var hang_time: float = -1.0
## Высота верхней точки подскока, м.
var apex_y: float = 0.0
## Ноги после касания (PD-К6 v1): сгиб коленей, м (тело ниже ступней-земли), и его скорость, м/с (> 0 — вниз).
var knee_y: float = 0.0
var knee_v: float = 0.0
var _legs: PilotLegs = null


func reset() -> void:
	active = false
	amount = 0.0
	time = 0.0
	hang_time = -1.0
	knee_y = 0.0
	knee_v = 0.0
	_legs = null  # масса могла поменяться (setup)


## Обновить состояние: agl — высота ног над землёй, м.
func update(m: FlightModel, input: ControlInput, agl: float, dt: float) -> void:
	var fl: Dictionary = m.flight.flare
	active = agl < float(fl.height_m) and input.pitch >= float(fl.push_threshold)
	amount = clampf(input.pitch, 0.0, 1.0) if agl < float(fl.height_m) else 0.0
	time = time + dt if active else 0.0
	if not active:
		hang_time = -1.0
	elif hang_time >= 0.0:
		hang_time += dt
	elif m.velocity.y < 0.0:
		hang_time = 0.0  # верхняя точка подскока: крыло «подвешивается»
		apex_y = m.position.y


## Целевой тангаж киля: пилот стоит вертикально и выталкивает трапецию до упора.
func theta_target(m: FlightModel, trim_theta: float, pitch: float) -> float:
	var p := clampf(pitch, 0.0, 1.0)
	return lerpf(trim_theta, Units.deg(float(m.flight.flare.pitch_deg)), p)


func pitch_time(m: FlightModel) -> float:
	return float(m.flight.flare.pitch_time_s)


## Множители аэродинамики на выравнивании: Vector3(время развития срыва, множитель CL_max,
## множитель нормальной силы сорванного паруса).
func aero_factors(m: FlightModel, loss_time: float) -> Vector3:
	var fl: Dictionary = m.flight.flare
	# динамические эффекты живут, пока крыло «висит»; дальше — обычный сорванный парус
	if not active or not hanging(m):
		return Vector3(loss_time, 1.0, 1.0)
	return Vector3(float(fl.lift_loss_time_s), float(fl.dynamic_cl_factor), float(fl.cn_factor))


## Крыло «висит»: с верхней точки подскока опустилось не больше hang_drop_m.
func hanging(m: FlightModel) -> bool:
	return hang_time >= 0.0 and apex_y - m.position.y < float(m.flight.flare.hang_drop_m)


## «Подвешивание»: с верхней точки подскока на выравнивании задранный парус (вихрь
## динамического срыва, экран земли) опускает крыло не быстрее hang_sink_ms, пока гасится
## путевая. Держит не больше hang_support веса и только пока крыло опустилось меньше
## hang_drop_m; поднять крыло она не может. Выровнял высоко — потом «плюх». Возвращает силу, Н.
func hang_force(m: FlightModel) -> Vector3:
	var fl: Dictionary = m.flight.flare
	var excess := -m.velocity.y - float(fl.hang_sink_ms)
	if hang_time < 0.0 or excess <= 0.0:
		return Vector3.ZERO
	if not hanging(m):
		return Vector3.ZERO
	var need := m.mass * excess / float(fl.hang_damp_s)
	return Vector3.UP * minf(need, m.mass * Units.G * float(fl.hang_support))


## Касание ногами: оценка посадки; пилот встаёт на ноги и добегает (после аварии — стоп).
func touchdown(m: FlightModel, ground_fn: Callable, gh: float) -> Dictionary:
	var lc: Dictionary = m.flight.landing
	var p := m.position
	var n := LandingJudge.ground_normal(ground_fn, p.x, p.z, float(lc.normal_sample_m))
	var result := LandingJudge.evaluate(m.velocity, n, rad_to_deg(m.bank), lc)
	result["position"] = Vector3(p.x, gh, p.z)
	result["flight_time_s"] = m.time_s
	m.position.y = gh
	reset()
	# ноги гасят вертикальную скорость сгибанием коленей (runout), а не за шаг; авария — стоп
	knee_y = 0.0
	knee_v = maxf(-m.velocity.y, 0.0)
	m.velocity = Vector3(m.velocity.x, -knee_v, m.velocity.z)
	if result.grade == "crash":
		m.velocity = Vector3.ZERO
		knee_v = 0.0
	m.roll_rate = 0.0
	m.stalled = false
	return result


## Пробежка после касания: горизонтальная скорость гасится ногами, вертикальная — сгибанием коленей
## (PilotLegs, pilot.json → legs): тело на knee_y ниже земли под ступнями, потом встаёт.
func runout(m: FlightModel, dt: float, ground_fn: Callable) -> void:
	var decel := float(m.flight.landing.runout_decel_ms2)
	var vh := Vector3(m.velocity.x, 0.0, m.velocity.z).move_toward(Vector3.ZERO, decel * dt)
	m.position += vh * dt
	_knees(m, dt)
	m.velocity = Vector3(vh.x, -knee_v, vh.z)
	var gh := FlightModel.ground_height(ground_fn, m.position.x, m.position.z)
	if gh > -INF:
		m.position.y = gh - knee_y


## Сгиб коленей за шаг dt (подшаги ≤ 1/480 с: упор жёсткий). Колени прямые и тело не опускается — стоит.
func _knees(m: FlightModel, dt: float) -> void:
	if knee_y <= 0.0 and knee_v <= 0.0:
		knee_y = 0.0
		knee_v = 0.0
		return
	if _legs == null:
		_legs = PilotLegs.new()
		_legs.setup(m.pilot.legs, m.mass)
	var n := maxi(1, ceili(dt * 480.0 - 1.0e-9))
	var h := dt / n
	for i in n:
		var f := _legs.force(knee_y, knee_v) if knee_y > 0.0 else _legs.hold
		knee_v += (Units.G - f / m.mass) * h
		knee_y += knee_v * h
		if knee_y <= 0.0 and knee_v <= 0.0:
			knee_y = 0.0
			knee_v = 0.0
			return
