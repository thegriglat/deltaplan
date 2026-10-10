class_name PendulumGround
extends RefCounted
## Земля «Маятника» (PD-К1 v2, R6 плана): пилот стоит, идёт, бежит с крылом на руках.
## Порт Sim._legs, _ground_hands, _ground_torque прототипа (tools/research/pendulum/pendulum/
## model.py) с обобщением на рельеф и курс:
## - ноги — пружина-демпфер к земле под ЦМ пилота (только толкают); бег — сила ног
##   F·(1 − v/v_ног) по курсу (как GroundRun; быстрее v_ног ноги тормозят ∝ доле веса на ногах),
##   но не больше сцепления μ·N (у прототипа бег толкал полной силой при любой опоре),
##   боковое скольжение — вязкое трение ≤ μ·N; стоя и шагом — сцепление покоя: ступни держат
##   точку опоры (пружина, проскальзывает при силе > μ·N), точка идёт со скоростью шага;
## - руки на стойках — связь хват (на стойке) — плечи пилота с пределом силы; вниз крыло не
##   тянут больше grip_down_max_n; вертикальная опора — под ЦМ крыла (пилот несёт его
##   уравновешенным), горизонтальная — в хвате;
## - руки держат тангаж (нос к склону по курсу), крен (input.roll, предел ∝ доле веса на ногах,
##   как ground_bank) и курс бега (input.turn стоя и шагом, на бегу — дугой заданного крена).
## Координаты — мир NED модели (локальное начало), земля под пилотом — плоскость, которую модель
## снимает с ground_fn раз в шаг.

const UP_NED := Vector3(0.0, 0.0, -1.0)

# конфиг (configs/pendulum.json → ground; pilot.json → run, walk; flight.json → ground_bank)
var leg_len: float = 1.0
var leg_k: float = 3.0e4
var leg_c: float = 0.0
var mu: float = 0.8
var side_damp: float = 2000.0
var stand_k: float = 2.0e4
var stand_c: float = 0.0
var shoulder_fwd: float = 0.35
var shoulder_up: float = 0.45
var grip_k: float = 3000.0
var grip_c: float = 0.0
var grip_max: float = 600.0
var grip_down_max: float = 100.0
var pitch_k: float = 300.0 / deg_to_rad(10.0)  ## Н·м/рад
var pitch_max: float = 300.0
var roll_cmd_max: float = deg_to_rad(15.0)
var roll_max: float = 200.0
var hold_tau: float = 0.3
var run_force: float = 420.0
var run_vmax: float = 6.5
var run_bonus: float = 0.3
var stop_decel: float = 4.0
var turn_accel_max: float = 2.0
var walk_speed: float = 1.2
var walk_back: float = 0.6
var walk_turn: float = deg_to_rad(45.0)
var walk_max_slope: float = 1.0
var walk_min_factor: float = 0.15
var alpha_neutral: float = deg_to_rad(14.0)
var alpha_range: float = deg_to_rad(18.0)
var m_total: float = 100.0

## Хват за стойки в осях крыла B (около ЦМ крыла).
var grip_b := Vector3.ZERO

# земля под пилотом: плоскость в локальной NED — «вниз» земли z_g(p) = gz + gn·(p.x − px) + ge·(p.y − py)
var gz: float = 0.0
var gpx: float = 0.0
var gpy: float = 0.0
var gn: float = 0.0  ## dz_вниз/d(север) = −dh/d(север)
var ge: float = 0.0

# состояние
var contact := false  ## ступни на земле (последний подшаг)
var feet_load: float = 1.0  ## N / (m·g), 0…1
var heading_cmd: float = 0.0  ## курс бега (ноги, корпус), рад
var anchor := Vector2.ZERO  ## точка опоры ступней (север, восток), локальная NED
var v_walk: float = 0.0  ## скорость точки опоры по курсу, м/с
var running := false
var phase: String = "standing"
var decel: float = 4.0  ## торможение точки опоры (стоя/шагом — stop_decel; после посадки — runout)
var flow_gamma: float = 0.0  ## наклон набегающего потока к горизонту (+ — снизу вверх), рад
var min_airspeed: float = 0.5


func setup(
	gc: Dictionary, pilot: Dictionary, flight: Dictionary, wing: Dictionary,
	m_pilot: float, m_wing: float
) -> void:
	leg_len = float(gc.leg_length_m)
	leg_k = float(gc.leg_stiffness_n_per_m)
	leg_c = 2.0 * sqrt(leg_k * m_pilot)
	mu = float(gc.foot_friction)
	side_damp = float(gc.side_damping_n_s_per_m)
	stand_k = float(gc.stand_stiffness_n_per_m)
	stand_c = 2.0 * sqrt(stand_k * m_pilot)
	shoulder_fwd = float(gc.shoulder_forward_m)
	shoulder_up = float(gc.shoulder_up_m)
	grip_k = float(gc.grip_stiffness_n_per_m)
	grip_c = 2.0 * sqrt(grip_k * m_wing)
	grip_max = float(gc.grip_force_max_n)
	grip_down_max = float(gc.grip_down_max_n)
	pitch_k = float(gc.pitch_hold_nm_per_deg) * 180.0 / PI
	pitch_max = float(gc.pitch_moment_max_nm)
	var gb: Dictionary = flight.ground_bank
	roll_cmd_max = deg_to_rad(float(gb.command_max_deg))
	roll_max = float(gb.pilot_moment_max_nm)
	hold_tau = float(gb.pilot_response_s)
	var rc: Dictionary = pilot.run
	run_force = float(rc.force_n)
	run_vmax = float(rc.speed_max_ms)
	run_bonus = float(rc.unload_speed_bonus)
	stop_decel = float(rc.stop_decel_ms2)
	turn_accel_max = float(rc.turn_accel_max_ms2)
	var wc: Dictionary = pilot.walk
	walk_speed = float(wc.speed_ms)
	walk_back = float(wc.back_speed_ms)
	walk_turn = deg_to_rad(float(wc.turn_rate_dps))
	walk_max_slope = float(wc.max_slope_tan)
	walk_min_factor = float(wc.min_slope_factor)
	var la: Dictionary = wing.launch
	alpha_neutral = deg_to_rad(float(la.alpha_neutral_deg))
	alpha_range = deg_to_rad(float(la.alpha_range_deg))
	m_total = m_pilot + m_wing
	decel = stop_decel
	min_airspeed = float(flight.min_airspeed_ms)


## Хват на стойке: на grip_along_upright_m от верхнего узла (6 см под килем у подвески) к
## середине штанги. hang_n, bar_n — подвеска и штанга в осях «от носа» (x назад, z вниз);
## to_b — перевод точки «от носа» в оси B.
func set_grip(hang_n: Vector3, bar_n: Vector3, along: float, cg_n: Vector3) -> void:
	var top := hang_n + Vector3(0.0, 0.0, 0.06)
	var d := bar_n - top
	var g := top + d * (along / maxf(d.length(), 1.0e-6))
	grip_b = Vector3(cg_n.x - g.x, g.y, g.z - cg_n.z)


func reset(heading: float, pilot_local: Vector3) -> void:
	contact = true
	feet_load = 1.0
	heading_cmd = heading
	anchor = Vector2(pilot_local.x, pilot_local.y)
	v_walk = 0.0
	running = false
	phase = "standing"
	decel = stop_decel


## Плоскость земли: в локальной точке (px, py) земля на «глубине» z (NED, вниз), уклоны —
## dz/d(север), dz/d(восток).
func set_plane(px: float, py: float, z: float, dzdn: float, dzde: float) -> void:
	gpx = px
	gpy = py
	gz = z
	gn = dzdn
	ge = dzde


## «Глубина» земли (NED z) под локальной точкой p.
func ground_z(p: Vector3) -> float:
	return gz + gn * (p.x - gpx) + ge * (p.y - gpy)


## Высота точки над землёй, м.
func agl(p: Vector3) -> float:
	return ground_z(p) - p.z


func fwd() -> Vector3:
	return Vector3(cos(heading_cmd), sin(heading_cmd), 0.0)


## Тангенс уклона по курсу бега (+ — в гору).
func slope_along() -> float:
	var f := fwd()
	return -(gn * f.x + ge * f.y)


## Наклон набегающего потока (как GroundRun._aero_force): трапеция ставит нос к потоку; пока
## потока нет (штиль, стоит) — вдоль склона по курсу. v_air — скорость пилота относительно
## воздуха у крыла (NED): качание крыла на руках поток не меняет.
func set_flow(v_air: Vector3) -> void:
	var f := fwd()
	var dir3 := Vector3(f.x, f.y, -slope_along()).normalized()
	var u := v_air + dir3 * maxf(min_airspeed - v_air.length(), 0.0)
	u = u.normalized() if u.length() > 1.0e-3 else dir3
	flow_gamma = asin(clampf(-u.z, -1.0, 1.0))


## Перед шагом: фаза, курс бега. input — ControlInput; v_pilot — скорость пилота (NED);
## bank_cmd — заданный крен; free — ступни свободны от ввода (после посадки: стоит).
func begin_step(dt: float, input: ControlInput, v_pilot: Vector3, free: bool) -> void:
	var was_running := running
	running = input.run and not free
	var walk := 0.0 if running or free else clampf(input.walk, -1.0, 1.0)
	phase = "running" if running else ("walking" if absf(walk) > 0.01 else "standing")
	var f := fwd()
	var v_f := v_pilot.x * f.x + v_pilot.y * f.y
	if was_running and not running:
		v_walk = maxf(v_f, 0.0)  # бросил бежать — тормозит ногами, а не встаёт как вкопанный
	if not running:
		var sf := clampf(1.0 - absf(slope_along()) / walk_max_slope, walk_min_factor, 1.0)
		var target := walk * sf * (walk_speed if walk >= 0.0 else walk_back)
		v_walk = move_toward(v_walk, target, decel * dt)
		var w := 0.0 if free else clampf(input.turn, -1.0, 1.0) * walk_turn
		heading_cmd += w * dt
	else:
		# на бегу курс — дугой заданного рукой крена (как GroundRun: a = g·tg φ_зад ≤ a_max)
		var bank_cmd := clampf(input.roll, -1.0, 1.0) * roll_cmd_max
		var a := clampf(Units.G * tan(bank_cmd), -turn_accel_max, turn_accel_max)
		heading_cmd += clampf(a / maxf(v_f, 0.5), -walk_turn, walk_turn) * dt


## Сила ног на пилота (NED). x, v — ЦМ пилота; h — подшаг. Обновляет contact, feet_load, опору.
func legs(x: Vector3, v: Vector3, h: float) -> Vector3:
	var pen := agl(x) - leg_len  # > 0 — ноги не достают
	var F := Vector3.ZERO
	if pen >= 0.0:
		contact = false
		feet_load = 0.0
		anchor = Vector2(x.x, x.y)
		return F
	contact = true
	# земля под движущейся точкой уходит вниз со скоростью (NED z) gn·vx + ge·vy
	var vz_g := gn * v.x + ge * v.y
	var fz := maxf(leg_k * -pen + leg_c * (v.z - vz_g), 0.0)  # вверх
	F.z = -fz
	feet_load = minf(fz / (m_total * Units.G), 1.0)
	var f := fwd()
	var side := Vector3(-f.y, f.x, 0.0)
	var lim := mu * fz
	if running:
		var v_f := v.x * f.x + v.y * f.y
		var v_cap := run_vmax * (1.0 + run_bonus * (1.0 - feet_load))
		var fr := run_force * (1.0 - v_f / v_cap)
		if fr < 0.0:
			fr *= feet_load
		F += f * clampf(fr, -lim, lim)  # толкают сцеплением: не больше μ·N
		var v_s := v.dot(side)
		F -= side * (signf(v_s) * minf(absf(v_s) * side_damp, lim))
		anchor = Vector2(x.x, x.y)
	else:
		# сцепление покоя: опора идёт со скоростью шага, ступни тянет к ней пружина
		anchor += Vector2(f.x, f.y) * (v_walk * h)
		var e := Vector2(x.x, x.y) - anchor
		var vt := Vector2(f.x, f.y) * v_walk
		var fh := -e * stand_k - (Vector2(v.x, v.y) - vt) * stand_c
		var n := fh.length()
		if n > lim:
			fh *= lim / n
			# проскальзывание: опора подтягивается так, чтобы пружина давала предел
			var en := e.length()
			if en > 1.0e-9 and lim < stand_k * en:
				anchor = Vector2(x.x, x.y) - e * (lim / (stand_k * en))
		F += Vector3(fh.x, fh.y, 0.0)
	return F


## Руки на стойках: сила на крыло (NED). grip, v_grip — хват (мир); shoulder, v_sh — плечи.
func grip_force(grip: Vector3, v_grip: Vector3, x_p: Vector3, v_p: Vector3) -> Vector3:
	var f := fwd()
	var sh := x_p + f * shoulder_fwd + UP_NED * shoulder_up
	var fw := (sh - grip) * grip_k + (v_p - v_grip) * grip_c
	fw.z = minf(fw.z, grip_down_max)  # вниз (z+) крыло руками почти не тянут
	var n := fw.length()
	if n > grip_max:
		fw *= grip_max / n
	return fw


## Момент рук на крыло в осях B: тангаж — нос на alpha_neutral (+ pitch·alpha_range) к потоку, крен к input.roll, курс к курсу бега.
## R — B→NED, wb — угловая скорость в B, I — инерция (диагональ), pitch/roll — ввод.
func torque_b(R: Basis, wb: Vector3, I: Basis, pitch: float, roll: float) -> Vector3:
	var th := -asin(clampf(R.x.z, -1.0, 1.0))
	var ph := atan2(R.y.z, R.z.z)
	var ps := atan2(R.x.y, R.x.x)
	var th_cmd := flow_gamma + alpha_neutral + clampf(pitch, -1.0, 1.0) * alpha_range
	var ph_cmd := clampf(roll, -1.0, 1.0) * roll_cmd_max
	var m_th := pitch_k * (th_cmd - th) - 2.0 * sqrt(pitch_k * I.y.y) * wb.y
	var tau2 := hold_tau * hold_tau
	var m_ph := I.x.x / tau2 * (ph_cmd - ph) - 2.0 * I.x.x / hold_tau * wb.x
	# курс: ошибка больше 30° — корпус доворачивается за крылом (не копит)
	var e_ps := wrapf(heading_cmd - ps, -PI, PI)
	if absf(e_ps) > deg_to_rad(30.0):
		heading_cmd = ps + signf(e_ps) * deg_to_rad(30.0)
		e_ps = signf(e_ps) * deg_to_rad(30.0)
	var m_ps := I.z.z / tau2 * e_ps - 2.0 * I.z.z / hold_tau * wb.z
	var lim := roll_max * feet_load
	return Vector3(
		clampf(m_ph, -lim, lim), clampf(m_th, -pitch_max, pitch_max), clampf(m_ps, -lim, lim)
	)
