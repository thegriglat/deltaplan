extends TestCase
## TP-13: полный цикл дельталёта без записи приватных полей модели: Glider.setup_trike + reset_on_wheels на ровной земле,
## engine_toggle, полный газ, штанга простым регулятором, отрыв, набор 30-50 м, газ 0, планирование, посадка на колёса
## (landed с on_wheels, без аварии), руление turn ±1 и тормоз до остановки; FlightStats кончает полёт "landed" только
## после настоящего полёта (armed). Шаг 1/120 с, ровная земля y = 0, без ветра.

const DT := 1.0 / 120.0
const G := 9.81
const RHO := 1.225
const APPROACH_VS := 1.15  ## скорость захода на посадку, доли vs
const FLARE_AGL_M := 2.0
const CL_MAX := 1.77  ## tow_tug.json, ground.rotate_deg_doc: CL_max крыла iXess 15


static func flat(_x: float, _z: float) -> float:
	return 0.0


func _trike() -> Glider:
	var g := Glider.new()
	g.set_ground_fn(flat)
	g.setup_trike(Config.get_config("tow_tug"), 0.0, Config.get_config("trike_pilot"))
	g.reset_on_wheels(Vector3.ZERO, 0.0)
	return g


func _vs(g: Glider) -> float:
	var wing: Dictionary = Config.get_config("wings/trike_ixess15")
	return sqrt(2.0 * g.model.mass * G / (RHO * float(wing.area_m2) * CL_MAX))


## Результат цикла. Заполняет _run().
class Run:
	extends RefCounted
	var took_off := 0
	var landed := 0
	var landed_result: Dictionary = {}
	var t_air := -1.0  ## время отрыва, с
	var x_air := 0.0  ## разбег, м
	var v_air := 0.0  ## скорость отрыва, м/с
	var h_max := 0.0  ## набрано над землёй, м
	var t_gas0 := -1.0  ## момент «газ 0»
	var t_touch := -1.0
	var vz_touch := 0.0  ## вертикальная перед касанием, м/с (вниз < 0)
	var v_touch := 0.0  ## путевая скорость перед касанием
	var phase_after_touch := ""
	var crashed := false
	var turn_dpsi := {1.0: 0.0, -1.0: 0.0}  ## изменение курса за руление, рад
	var turn_v := {1.0: 0.0, -1.0: 0.0}
	var t_stop := -1.0
	var x_stop := 0.0  ## путь по земле от касания до остановки, м
	var max_pitch_step := 0.0
	var phase_end := ""
	var stats: FlightStats
	var finished_before_air := false  ## полёт «кончился» на разбеге (должно быть false)
	var finish_t := -1.0
	var finish_reason := ""
	var armed_t := -1.0
	var failed := false


func _run() -> Dictionary:
	var g := _trike()
	var vs := _vs(g)
	var r := Run.new()
	g.took_off.connect(func() -> void: r.took_off += 1)
	g.landed.connect(func(res: Dictionary) -> void:
		r.landed += 1
		r.landed_result = res)
	var st := FlightStats.new()
	st.trike = true
	st.reset(g.model.position)
	r.stats = st
	var stage := "roll"  ## roll -> climb -> glide -> rollout -> taxi_r -> taxi_l -> brake -> done
	var t := 0.0
	var i_acc := 0.0
	var v_prev := 0.0
	var vdot := 0.0
	var prev_vel: Vector3 = g.model.pilot_velocity
	var touch_pos := Vector3.ZERO
	var taxi_t := 0.0
	var engine_off := false
	var taxi_h0 := 0.0
	for k in int(300.0 / DT):
		var c := ControlInput.new()
		var tel := g.get_telemetry()
		var v := tel.airspeed
		vdot += ((v - v_prev) / DT - vdot) * minf(DT / 0.5, 1.0)
		v_prev = v
		var flying := g.phase() == "flying"
		if t < 0.2:
			c.engine_toggle = true
		match stage:
			"roll", "climb":
				if t > 4.0 and stage == "roll":
					c.throttle_axis = 1.0
				if stage == "climb":
					c.throttle_axis = 1.0
				if flying:
					if r.t_air < 0.0:
						r.t_air = t
						r.v_air = v
						r.x_air = g.model.position.length()
						stage = "climb"
					var e := v - 1.3 * vs
					i_acc = clampf(i_acc + 0.05 * e * DT, -1.0, 1.0)
					c.pitch = clampf(i_acc + 0.25 * e + 0.6 * vdot, -1.0, 1.0)
					r.h_max = maxf(r.h_max, tel.altitude_agl)
					if tel.altitude_agl >= 40.0:
						stage = "glide"
						r.t_gas0 = t
				elif v >= 1.1 * vs:
					c.pitch = 0.3
			"glide":
				c.throttle_axis = -1.0  # газ -> 0 (рычаг)
				if not engine_off and t > r.t_gas0 + 2.0:
					c.engine_toggle = true  # заглушить перед посадкой (тяга винта колёсам не нужна)
					engine_off = true
				var e2 := v - APPROACH_VS * vs
				i_acc = clampf(i_acc + 0.05 * e2 * DT, -1.0, 1.0)
				c.pitch = clampf(i_acc + 0.25 * e2 + 0.6 * vdot, -1.0, 1.0)
				if tel.altitude_agl < FLARE_AGL_M:
					c.pitch = -1.0  # у земли штанга на себя: нагрузка с крыла на колёса (иначе подъёмная сила не даёт сесть)
				r.h_max = maxf(r.h_max, tel.altitude_agl)
				if not flying:
					stage = "rollout"
					r.t_touch = t
					r.vz_touch = prev_vel.y
					r.v_touch = Vector2(prev_vel.x, prev_vel.z).length()
					r.phase_after_touch = g.phase()
					touch_pos = g.model.position
					taxi_t = 0.0
			"rollout":
				c.throttle_axis = -1.0
				c.pitch = -1.0  # штанга от себя - тележка на колёсах (как в k7)
				c.brake = true  # на скорости посадки крыло несёт вес - гасим тормозом, иначе снова взлетит
				if Vector2(g.model.pilot_velocity.x, g.model.pilot_velocity.z).length() < 8.0:
					stage = "taxi_r"
					taxi_t = 0.0
					taxi_h0 = g.model.heading
					taxi_t = 0.0
					taxi_h0 = g.model.heading
					r.turn_v[1.0] = 0.0
			"taxi_r":
				c.pitch = -1.0
				c.turn = 1.0
				taxi_t += DT
				r.turn_v[1.0] += Vector2(g.model.pilot_velocity.x, g.model.pilot_velocity.z).length() * DT
				if taxi_t >= 1.5:
					r.turn_dpsi[1.0] = wrapf(g.model.heading - taxi_h0, -PI, PI)
					stage = "taxi_l"
					taxi_t = 0.0
					taxi_h0 = g.model.heading
			"taxi_l":
				c.pitch = -1.0
				c.turn = -1.0
				taxi_t += DT
				r.turn_v[-1.0] += Vector2(g.model.pilot_velocity.x, g.model.pilot_velocity.z).length() * DT
				if taxi_t >= 1.5:
					r.turn_dpsi[-1.0] = wrapf(g.model.heading - taxi_h0, -PI, PI)
					stage = "brake"
			"brake":
				c.pitch = -1.0
				c.brake = true
				if Vector2(g.model.pilot_velocity.x, g.model.pilot_velocity.z).length() < 0.05:
					r.t_stop = t
					r.x_stop = (g.model.position - touch_pos).length()
					stage = "done"
		if stage == "done" and r.t_stop > 0.0 and t > r.t_stop + 5.0:
			break
		g.set_input(c)
		prev_vel = g.model.pilot_velocity
		var pa := Vector2(g.model.theta, g.model.bank)
		g.step(DT)
		if g.model.mode == FlightModel.Mode.LANDED or g.model.mode == FlightModel.Mode.FAILED:
			r.crashed = true
		if r.t_touch > 0.0 and absf(t - r.t_touch) < 0.05:
			r.max_pitch_step = maxf(r.max_pitch_step, rad_to_deg(maxf(absf(g.model.theta - pa.x), absf(g.model.bank - pa.y))))
		st.update(g.get_telemetry(), DT)
		if r.t_air < 0.0 and st.is_finished():
			r.finished_before_air = true
		if st.armed and r.armed_t < 0.0:
			r.armed_t = t
		if st.is_finished() and r.finish_t < 0.0:
			r.finish_t = t
			r.finish_reason = st.finish_reason()
		t += DT
	r.phase_end = g.phase()
	r.failed = not (is_finite(g.model.position.x) and is_finite(g.model.position.y) and is_finite(g.model.position.z))
	g.free()
	return {"r": r, "vs": vs}


## Полный цикл: reset_on_wheels -> двигатель -> разбег -> отрыв -> набор 30-50 м -> газ 0 -> планирование -> посадка на
## колёса -> руление ±1 -> тормоз -> остановка -> FlightStats "landed". Числа - в вывод (в отчёт).
func test_full_cycle() -> void:
	var d := _run()
	var r: Run = d.r
	var vs: float = d.vs
	print("    vs %.1f м/с; отрыв: t %.1f с, разбег %.0f м, v %.1f м/с (%.2f vs); набрано до %.1f м AGL, газ 0 в %.1f с"
		% [vs, r.t_air, r.x_air, r.v_air, r.v_air / vs, r.h_max, r.t_gas0])
	print("    касание: t %.1f с, вертикальная %.2f м/с, путевая %.1f м/с, фаза %s; тангаж/крен за шаг %.3f°; landed %d раз, took_off %d раз"
		% [r.t_touch, r.vz_touch, r.v_touch, r.phase_after_touch, r.max_pitch_step, r.landed, r.took_off])
	print("    руление: dψ за 1,5 с turn+1 %.1f° (v ср. %.1f м/с), turn-1 %.1f° (v ср. %.1f м/с); остановка тормозом в %.1f с, путь от касания %.0f м"
		% [rad_to_deg(r.turn_dpsi[1.0]), r.turn_v[1.0] / 1.5, rad_to_deg(r.turn_dpsi[-1.0]), r.turn_v[-1.0] / 1.5, r.t_stop, r.x_stop])
	print("    FlightStats: armed с %.1f с, конец %.1f с (%s), time %.1f с" % [r.armed_t, r.finish_t, r.finish_reason, r.stats.flight_time_s])
	check(not r.failed, "позиция конечна")
	check(r.t_air > 0.0 and r.took_off >= 1, "оторвался (took_off %d)" % r.took_off)
	check(r.x_air <= 610.0, "разбег %.0f м <= 610 м полосы" % r.x_air)
	check(r.h_max >= 30.0 and r.h_max <= 55.0, "набор 30-50 м (с запасом инерции): %.1f" % r.h_max)
	check(r.t_gas0 > r.t_air, "газ 0 после отрыва")
	check(r.landed >= 1 and r.t_touch > 0.0, "посадка была (landed %d)" % r.landed)
	check(bool(r.landed_result.get("on_wheels", false)), "landed с on_wheels")
	check(not r.crashed, "аварии нет")
	check(r.phase_after_touch == "wheels", "после касания фаза wheels: %s" % r.phase_after_touch)
	check(r.vz_touch < 0.0, "снижение в касание: %.2f" % r.vz_touch)
	check(r.turn_dpsi[1.0] > deg_to_rad(5.0), "turn +1: курс вправо (по часовой): %.1f°" % rad_to_deg(r.turn_dpsi[1.0]))
	check(r.turn_dpsi[-1.0] < -deg_to_rad(5.0), "turn -1: курс влево: %.1f°" % rad_to_deg(r.turn_dpsi[-1.0]))
	check(r.t_stop > 0.0, "остановилась тормозом")
	check(r.phase_end == "wheels", "стоит на колёсах: %s" % r.phase_end)
	check(not r.finished_before_air, "на разбеге полёт не кончался")
	check(r.stats.armed, "FlightStats: взведён (настоящий полёт)")
	check(r.stats.is_finished() and r.finish_reason == "landed", "FlightStats: landed (%s)" % r.finish_reason)
	check(r.finish_t > r.t_stop - 0.5, "конец полёта - после остановки, не при касании: %.1f vs остановка %.1f" % [r.finish_t, r.t_stop])


func _tele(phase: String, pos: Vector3, agl: float, gs: float) -> Telemetry:
	var t := Telemetry.new()
	t.phase = phase
	t.position = pos
	t.altitude_msl = pos.y
	t.altitude_agl = agl
	t.groundspeed = gs
	t.on_ground = phase != "flying"
	return t


## Конец полёта дельталёта - только после настоящего полёта: подскок на разбеге (2 м, 10 м пути) и остановка не кончают.
func test_hop_does_not_finish() -> void:
	var st := FlightStats.new()
	st.trike = true
	st.reset(Vector3.ZERO)
	for i in 120:  # разбег
		st.update(_tele("wheels", Vector3(0.0, 0.0, -float(i) * 0.1), 0.0, 8.0), DT)
	for i in 60:  # подскок: 0,5 с в воздухе, 2 м
		st.update(_tele("flying", Vector3(0.0, 2.0, -12.0 - float(i) * 0.1), 2.0, 12.0), DT)
	for i in int(10.0 / DT):  # сел и стоит 10 с
		st.update(_tele("wheels", Vector3(0.0, 0.0, -18.0), 0.0, 0.0), DT)
	check(st.took_off, "отрыв был")
	check(not st.armed, "не взведён: подскок 2 м, 6 м пути")
	check(not st.is_finished(), "остановка после подскока полёт не кончает")
	check(not st.force_finish(), "force_finish без armed - нечего засчитывать")
	# настоящий полёт после этого: 12 м над землёй -> armed, посадка и остановка - конец
	for i in 120:
		st.update(_tele("flying", Vector3(0.0, 12.0, -20.0 - float(i)), 12.0, 15.0), DT)
	check(st.armed, "взведён на 12 м")
	for i in int(2.0 / DT):
		st.update(_tele("wheels", Vector3(0.0, 0.0, -150.0), 0.0, 5.0), DT)
	check(not st.is_finished(), "руление после посадки не кончает")
	for i in int(3.5 / DT):
		st.update(_tele("wheels", Vector3(0.0, 0.0, -150.0), 0.0, 0.0), DT)
	check(st.is_finished() and st.finish_reason() == "landed", "остановка 3 с после настоящего полёта - landed")


## Дальний подскок над землёй (по горизонтали ≥ 50 м от отрыва) взводит так же, как у дельтаплана.
func test_armed_by_distance() -> void:
	var st := FlightStats.new()
	st.trike = true
	st.reset(Vector3.ZERO)
	for i in 120:
		st.update(_tele("flying", Vector3(0.0, 3.0, -float(i)), 3.0, 15.0), DT)
	check(st.armed, "взведён по удалению >= 50 м")
