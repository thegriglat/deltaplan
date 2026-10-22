extends TestCase
## Контракт TP-К7 v1 (docs/contracts/trike-pilot.md): колёса дельталёта в «Маятнике» — руление, тормоз, посадка на колёса.
## Крыло trike_ixess15, тележка из configs/tow_tug.json (числа буксировщика), блок wheels — configs/trike_pilot.json.
## Инварианты (1)-(8), каждый отдельным тестом.

const Sim := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const DT := 1.0 / 120.0


func _flat(_x: float, _z: float) -> float:
	return 0.0


func _wheels(extra := true, land := true, steer := true) -> Dictionary:
	var g: Dictionary = Config.get_config("tow_tug").ground
	var w := {
		"keel_angle_deg": float(g.keel_angle_deg), "rotate_deg": float(g.rotate_deg),
		"rolling_crr": float(g.rolling_crr), "wheel_base_agl_m": float(g.wheel_base_agl_m)}
	if extra:
		var tp: Dictionary = Config.get_config("trike_pilot").wheels
		for k: String in ["wheelbase_m", "steer_max_deg", "lat_mu", "brake_mu"]:
			w[k] = float(tp[k])
		w["land_on_wheels"] = land
		if not steer:
			w.erase("steer_max_deg")
	return w


func _model(extra := true, land := true, steer := true) -> PendulumModel:
	var cfg: Dictionary = Config.get_config("tow_tug")
	var cart: Dictionary = cfg.cart
	var a := {"hang_length_m": float(cart.cg_below_hang_m), "arms_force_max_n": float(cart.arms_force_max_n), "pilot_cda_m2": float(cart.cda_m2)}
	var m := Sim.make(String(cfg.wing), float(cart.mass_kg), a)
	m.reset_on_wheels(Vector3.ZERO, 0.0, _wheels(extra, land, steer))
	return m


func _in(pitch := 0.0, turn := 0.0, brake := false) -> ControlInput:
	var c := ControlInput.new()
	c.pitch = pitch
	c.turn = turn
	c.brake = brake
	return c


## Тяга винта тележки (газ 1) по tow_tug.json, умноженная на k; V — скорость тележки.
func _thrust(k := 1.0) -> Callable:
	var t: Dictionary = Config.get_config("tow_tug").thrust
	var vs: Array = t.v_ms
	var fs: Array = t.full_n
	return func(s: Dictionary) -> Dictionary:
		var v := (s.pilot_vel as Vector3).length()
		var f: float = fs[fs.size() - 1]
		for i in range(1, vs.size()):
			if v <= float(vs[i]):
				f = lerpf(float(fs[i - 1]), float(fs[i]), clampf((v - float(vs[i - 1])) / (float(vs[i]) - float(vs[i - 1])), 0.0, 1.0))
				break
		return {"pilot": Vector3(0.0, 0.0, -f * k)}


func _vs(m: PendulumModel) -> float:
	return sqrt(2.0 * m.mass * Units.G / (m._rho_ref * m.area * m._polar.cl_max))


func _hspeed(m: PendulumModel) -> float:
	return Vector2(m.pilot_velocity.x, m.pilot_velocity.z).length()


## (1) Без новых ключей — TT-К3; ключи без ввода turn/brake и без посадки дают то же бит в бит. Сценарий: тяга,
## pitch +1 после 1,1·vs, отрыв и полёт; 14 с. Числа — сняты на коммите без TP-7.
func test_defaults_unchanged() -> void:
	var a := _model(false)
	var b := _model(true, false, false)  # без steer_max_deg штанга первого порядка (TP-К7 v2)
	a.set_external_force(_thrust())
	b.set_external_force(_thrust())
	var vs := _vs(a)
	var pitch := 0.0
	var took := false
	for i in int(14.0 / DT):
		if pitch == 0.0 and a.pilot_velocity.length() >= 1.1 * vs:
			pitch = 1.0
		a.step(DT, _in(pitch), Callable(), _flat)
		b.step(DT, _in(pitch), Callable(), _flat)
		took = took or not a.on_wheels
	check(took and not b.on_wheels, "отрыв был")
	check(a.position == b.position and a.velocity == b.velocity, "ключи без ввода и посадки = без ключей (равенство)")
	print("    золото: pos (%.9f, %.9f, %.9f) vel (%.9f, %.9f, %.9f)" % [a.position.x, a.position.y, a.position.z, a.velocity.x, a.velocity.y, a.velocity.z])
	check(a.position == GOLD_POS and a.velocity == GOLD_VEL, "позиция и скорость равны прежним: %s %s" % [a.position, a.velocity])


const GOLD_POS := Vector3(0.0, 40.243816376, -177.72203064)
const GOLD_VEL := Vector3(0.0, 5.191807747, -13.54156208)


## Тележка катится со скоростью v (без тяги): в _dol_v; pitch -1 держит её на земле.
func _rolling(v: float) -> PendulumModel:
	var m := _model()
	m._dol_v = v
	m._wh_pitch = -1.0
	return m


## Скорость изменения курса по шагам, рад/с (средняя за t_s после 0,5 с), и средняя скорость.
func _yaw_rate(m: PendulumModel, turn: float, t_s: float) -> Array[float]:
	var sum_r := 0.0
	var sum_v := 0.0
	var sum_lat := 0.0
	var worst_lat := 0.0
	var n := 0
	var prev := m.heading
	for i in int((0.5 + t_s) / DT):
		m.step(DT, _in(-1.0, turn), Callable(), _flat)
		var d := wrapf(m.heading - prev, -PI, PI)
		prev = m.heading
		if i * DT >= 0.5:
			var v := m._dol_v
			sum_r += d / DT
			sum_v += v
			sum_lat += v * d / DT
			worst_lat = maxf(worst_lat, absf(v * d / DT))
			n += 1
	return [sum_r / n, sum_v / n, worst_lat]


## (2) Руление: v = 5 м/с, turn +1 — dψ/dt по формуле ± 5 %, turn −1 — зеркально, v = 0 — курс не меняется.
## Формула — с пределом шин (3): при 35° и 5 м/с кинематический поворот дал бы 9,7 м/с² > lat_mu·g — шины скользят,
## поэтому на 5 м/с работает предел, а чистая формула без предела проверяется на 2,5 м/с (ниже предела).
func test_steering() -> void:
	var w: Dictionary = Config.get_config("trike_pilot").wheels
	var steer := deg_to_rad(float(w.steer_max_deg))
	var wb := float(w.wheelbase_m)
	var lim := float(w.lat_mu) * Units.G
	for turn in [1.0, -1.0]:
		var m := _rolling(5.0)
		var r := _yaw_rate(m, turn, 1.0)
		var want := r[1] * tan(turn * steer) / wb
		var capped := clampf(want, -lim / r[1], lim / r[1])
		print("    turn %+.0f: v=%.2f, dψ/dt %.4f (формула %.4f, с пределом %.4f) рад/с" % [turn, r[1], r[0], want, capped])
		check(Sim.finite(m) and m.on_wheels, "turn %+.0f: конечна, на колёсах" % turn)
		check(absf(r[0] - capped) <= 0.05 * absf(capped), "turn %+.0f: dψ/dt = формула ± 5 %%" % turn)
		check(signf(r[0]) == turn, "turn %+.0f: знак (+ вправо, курс по часовой)" % turn)
	var ms := _rolling(2.5)
	var rs := _yaw_rate(ms, 1.0, 0.5)
	var want_s := rs[1] * tan(steer) / wb
	print("    v=%.2f: dψ/dt %.4f (формула без предела %.4f)" % [rs[1], rs[0], want_s])
	check(rs[1] * want_s < lim and absf(rs[0] - want_s) <= 0.05 * want_s, "2,5 м/с: чистая формула ± 5 %%")
	var m0 := _model()
	var h0 := m0.heading
	for i in int(2.0 / DT):
		m0.step(DT, _in(0.0, 1.0), Callable(), _flat)
	check(absf(m0.heading - h0) < 1.0e-6, "v = 0: курс не меняется")


## (3) v = 15 м/с, turn +1 — боковое ускорение v·dψ/dt ≤ lat_mu·g + 1 %; крыло и тележка поворачиваются вместе.
func test_lateral_limit() -> void:
	var lim := float(Config.get_config("trike_pilot").wheels.lat_mu) * Units.G
	var m := _rolling(15.0)
	var r := _yaw_rate(m, 1.0, 1.0)
	print("    v=%.2f: макс. v·dψ/dt %.3f м/с², предел %.3f" % [r[1], r[2], lim])
	check(Sim.finite(m) and m.on_wheels, "конечна, на колёсах")
	check(r[2] <= lim * 1.01, "боковое ускорение <= lat_mu·g + 1 %%: %.3f <= %.3f" % [r[2], lim])
	check(r[2] >= lim * 0.9, "предел действует (поворот не слабее): %.3f" % r[2])
	var ah := atan2(m.pilot_velocity.x, -m.pilot_velocity.z)  # курс скорости тележки (игра: x восток, -z север)
	check(absf(wrapf(ah - m.heading, -PI, PI)) < deg_to_rad(3.0), "скорость вдоль курса крыла: %.2f°" % rad_to_deg(wrapf(ah - m.heading, -PI, PI)))


## (4) Тормоз с 10 м/с без тяги: остановка, путь = v²/(2·(brake_mu+crr)·g) ± 10 %, скорость не < 0.
func test_brake() -> void:
	var m := _rolling(10.0)
	var w: Dictionary = Config.get_config("trike_pilot").wheels
	var crr := float(_wheels().rolling_crr)
	var p0 := m.pilot_position
	var vmin := INF
	var t_stop := -1.0
	for i in int(20.0 / DT):
		m.step(DT, _in(-1.0, 0.0, true), Callable(), _flat)
		vmin = minf(vmin, m._dol_v)
		if m._dol_v <= 0.0 and t_stop < 0.0:
			t_stop = m.time_s
			break
	for i in int(1.0 / DT):
		m.step(DT, _in(-1.0, 0.0, true), Callable(), _flat)
		vmin = minf(vmin, m._dol_v)
	var s := Vector2(m.pilot_position.x - p0.x, m.pilot_position.z - p0.z).length()
	var want := 100.0 / (2.0 * (float(w.brake_mu) + crr) * Units.G)
	print("    остановка за %.2f с, путь %.2f м (формула %.2f, без аэродинамики), v_min %.4f" % [t_stop, s, want, vmin])
	check(t_stop > 0.0, "остановилась")
	check(vmin >= 0.0, "скорость не уходит < 0: %.5f" % vmin)
	check(absf(s - want) <= 0.1 * want, "путь = v²/(2(brake_mu+crr)g) ± 10 %%: %.2f / %.2f" % [s, want])
	check(m.on_wheels and Sim.finite(m), "на колёсах, конечна")
	var m2 := _rolling(10.0)  # без тормоза путь длиннее
	for i in int(t_stop / DT):
		m2.step(DT, _in(-1.0), Callable(), _flat)
	check(m2._dol_v > 2.0, "без тормоза за то же время скорость остаётся: %.2f" % m2._dol_v)


## Ввод pitch, держащий скорость v_t (регулятор P, K = 0,3 с/м, как автопилот).
func _hold(m: PendulumModel, v_t: float) -> float:
	return clampf(0.3 * (m.pilot_velocity.length() - v_t), -1.0, 1.0)


## Модель в воздухе на высоте h_m над землёй в трим-полёте (reset_in_air), как будто взлетевшая с колёс: низ колёс под
## тележкой на wheel_base_agl_m, параметры колёс — от reset_on_wheels (так же состояние после отрыва).
func _trim_glide(h_m: float) -> PendulumModel:
	var m := _model()
	var w := {"dol": m._wh_dol.duplicate(), "wb": m._wh_wheelbase, "st": m._wh_steer_max, "mu": m._wh_lat_mu, "br": m._wh_brake_mu}
	m.reset_in_air(Vector3(0.0, h_m, 0.0), 0.0)
	m._wh_dol = w.dol
	m._wh_wheelbase = w.wb
	m._wh_steer_max = w.st
	m._wh_lat_mu = w.mu
	m._wh_brake_mu = w.br
	m._wh_land = true
	m._wh_base = float(m._wh_dol.wheel_base_agl_m)
	m._seated = true
	return m


## Планирование без тяги (pitch 0) до касания. → {m, landed: bool, ...}
func _glide_to_touch(m: PendulumModel) -> Dictionary:
	m.set_external_force(Callable())
	var res := {"landed": false, "n_landed": 0, "n_took": 0, "dv": 0.0, "v_before": 0.0, "v_after": 0.0, "lat_loss": 0.0, "vz": 0.0}
	var rs := [0, 0]
	m.landed.connect(func(r: Dictionary) -> void:
		rs[0] += 1
		res["result"] = r)
	m.took_off.connect(func() -> void: rs[1] += 1)
	var prev := m.pilot_velocity
	var prev_a := Vector2(m.theta, m.bank)
	res["da"] = 0.0
	var v_trim := float(m.solve_trim().V)
	for i in int(40.0 / DT):
		m.step(DT, _in(_hold(m, v_trim)), Callable(), _flat)
		if rs[0] > 0:
			res["da"] = rad_to_deg(maxf(absf(m.theta - prev_a.x), absf(m.bank - prev_a.y)))
			var f := Vector2(sin(m.heading), -cos(m.heading))
			var before := Vector2(prev.x, prev.z)
			res["v_before"] = before.dot(f)
			res["v_after"] = Vector2(m.pilot_velocity.x, m.pilot_velocity.z).dot(f)
			res["lat_loss"] = absf(before.dot(Vector2(-f.y, f.x)))
			res["vz"] = prev.y
			break
		prev = m.pilot_velocity
		prev_a = Vector2(m.theta, m.bank)
	res["landed"] = rs[0] > 0
	res["n_landed"] = rs[0]
	res["n_took"] = rs[1]
	return res


## (5) Планирование без тяги до касания — "wheels", landed с on_wheels, путевая скорость в шаг касания меняется
## не более чем на 0,5 м/с сверх потери боковой; затем с тормозом — остановка.
func test_glide_landing() -> void:
	var m := _trim_glide(8.0)
	check(not m.on_wheels and m.phase() == "flying", "в воздухе: %s" % m.phase())
	var g := _glide_to_touch(m)
	var r: Dictionary = g.get("result", {})
	print("    касание: vz %.2f, v до %.2f после %.2f, боковая %.2f, landed %d раз, took_off %d раз, grade %s" % [g.vz, g.v_before, g.v_after, g.lat_loss, g.n_landed, g.n_took, r.get("grade")])
	print("    тангаж/крен за шаг касания %.3f°, вертикальная в касание %.2f м/с" % [g.da, g.vz])
	check(g.landed, "сигнал landed подан")
	check(float(g.da) <= 1.0, "тангаж и крен за шаг касания <= 1°: %.3f" % g.da)
	check(bool(r.get("on_wheels", false)), "result.on_wheels")
	check(m.phase() == "wheels" and m.on_wheels, "phase() = wheels: %s" % m.phase())
	check(absf(float(g.v_after) - float(g.v_before)) <= 0.5 + float(g.lat_loss), "путевая скорость в шаг касания: %.2f -> %.2f" % [g.v_before, g.v_after])
	check(Sim.finite(m) and m.mode == FlightModel.Mode.GROUND, "конечна, не авария")
	var stopped := false
	for i in int(30.0 / DT):
		m.step(DT, _in(-1.0, 0.0, true), Callable(), _flat)
		if m.phase() == "wheels" and m._dol_v <= 0.0:
			stopped = true
			break
	print("    остановка с тормозом: %s, t=%.2f, фаза %s" % [stopped, m.time_s, m.phase()])
	check(stopped, "с тормозом остановилась на колёсах")


## (6) Касание с вертикальной -4 м/с: "wheels", не авария (_crash_start не вызывается), курс сохраняется.
func test_hard_vertical() -> void:
	var m := _trim_glide(30.0)
	# ПИ-регулятор внешней силы на тележку держит вертикальную скорость -4 м/с (мир игры: y вверх, снижение < 0):
	# F_y = 3000·e + I, I += 2500·e·h, e = -4 - vy; пределы ±6000 Н. Сила гаснет вместе с касанием (ловит vy ≈ -4).
	var integ := [0.0]
	m.set_external_force(func(s: Dictionary) -> Dictionary:
		var e := -4.0 - float((s.pilot_vel as Vector3).y)
		integ[0] = clampf(float(integ[0]) + 2500.0 * e * float(s.h), -6000.0, 6000.0)
		return {"pilot": Vector3(0.0, clampf(3000.0 * e + float(integ[0]), -6000.0, 6000.0), 0.0)})
	var crash := [false]
	var landed := [false]
	m.landed.connect(func(r: Dictionary) -> void: landed[0] = true)
	var vz := 0.0
	var prev := m.pilot_velocity.y
	var v_trim := float(m.solve_trim().V)
	for i in int(20.0 / DT):
		m.step(DT, _in(_hold(m, v_trim)), Callable(), _flat)
		crash[0] = crash[0] or m.mode == FlightModel.Mode.LANDED or m.mode == FlightModel.Mode.FAILED or m._crash_v != Vector3.ZERO
		if landed[0]:
			vz = prev
			break
		prev = m.pilot_velocity.y
	print("    вертикальная в касание %.2f м/с, фаза %s" % [vz, m.phase()])
	check(landed[0], "касание было")
	check(vz <= -3.5 and vz >= -4.5, "вертикальная в касание = -4 м/с ± 0,5: %.2f" % vz)
	check(not crash[0] and m.phase() == "wheels", "не авария, wheels: %s" % m.phase())
	check(Sim.finite(m) and absf(m.pilot_velocity.y) < 1.0, "вертикальная погашена: %.3f" % m.pilot_velocity.y)


## (7) После посадки тяга и pitch +1 после 1,1·vs — снова отрыв (took_off).
func test_retakeoff() -> void:
	var m := _trim_glide(8.0)
	var g := _glide_to_touch(m)
	check(g.landed and m.on_wheels, "села на колёса")
	for i in int(30.0 / DT):  # тормозом до остановки (на трим-скорости крыло с килем само несёт вес — колёса не держат)
		m.step(DT, _in(-1.0, 0.0, true), Callable(), _flat)
		if m.on_wheels and m._dol_v <= 0.0:
			break
	check(m.on_wheels and m._dol_v <= 0.0, "остановилась на колёсах")
	var took := [0]
	m.took_off.connect(func() -> void: took[0] += 1)
	m.set_external_force(_thrust())
	var vs := _vs(m)
	var pitch := -1.0
	var t0 := m.time_s
	for i in int(40.0 / DT):
		if pitch < 0.0 and m.pilot_velocity.length() >= 1.1 * vs:
			pitch = 1.0
		m.step(DT, _in(pitch), Callable(), _flat)
		if not m.on_wheels:
			break
	print("    повторный отрыв через %.2f с, took_off %d раз" % [m.time_s - t0, took[0]])
	check(took[0] >= 1 and not m.on_wheels and m.phase() == "flying", "снова взлетела")
	check(Sim.finite(m), "конечна")


## (8) Смена штанги на колёсах -1 -> +1: |Δv| ЦМ крыла за шаг <= 0,15 м/с (TP-К7 v2: второй порядок при ключах wheels).
## Ввод — ступенью (руки сглаживают с arms.tau) и со скоростью штанги SLEW 2/с (как автопилот TT-К3).
func test_bar_swing_on_wheels() -> void:
	var res: Array[float] = []
	for slew in [0.0, 2.0]:
		var m := _rolling(8.0)
		for i in int(1.0 / DT):
			m.step(DT, _in(-1.0), Callable(), _flat)
		var prev := m.velocity
		var prev_p := m.pilot_velocity
		var worst := 0.0
		var worst_p := 0.0
		var pin := -1.0
		for i in int(1.5 / DT):
			pin = 1.0 if slew == 0.0 else move_toward(pin, 1.0, slew * DT)
			m.step(DT, _in(pin), Callable(), _flat)
			worst = maxf(worst, m.velocity.distance_to(prev))
			worst_p = maxf(worst_p, m.pilot_velocity.distance_to(prev_p))
			prev = m.velocity
			prev_p = m.pilot_velocity
		print("    смена штанги -1 -> +1 (slew %.0f): макс. |dv|/шаг ЦМ крыла %.3f м/с, тележки %.3f; на колёсах: %s" % [slew, worst, worst_p, m.on_wheels])
		check(Sim.finite(m) and m.on_wheels, "slew %.0f: конечна, на колёсах" % slew)
		res.append(worst)
	check(res[0] <= 0.15 and res[1] <= 0.15, "|dv| ЦМ крыла за шаг <= 0,15 м/с (ступенью %.3f, плавно %.3f)" % [res[0], res[1]])
