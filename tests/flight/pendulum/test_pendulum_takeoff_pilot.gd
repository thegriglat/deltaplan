extends TestCase
## Разбег и старт по словам пилота (PD-28, 11.10; docs/research/pendulum.md → «Разбег и старт (PD-28)»):
## 1. «Если за 10 м не взлетел, то не взлетишь» — на склоне 15–20° в штиль и во встречный 2–3 м/с
##    учебное отрывается за ≤ 12 м (техника по Жеглову 1983, с. 110: бег в нейтрали, когда крыло
##    потянуло вверх — небольшая отдача ручки).
## 2. «От себя» на разбеге при недостатке скорости: в начале — торможение (растёт сопротивление),
##    в конце — крыло взмывает и сваливается, взлёта нет.
## 3. При достаточной скорости небольшая отдача ускоряет отрыв, потом ручку на себя — разгон с
##    просадкой.
## 4. Боковой ветер 10–15°: нужно усилие удержать; без него наветренное крыло задирается и крыло
##    разворачивает «по циркулю» носом к ветру; в полёте у земли — флюгер, крен удерживается телом.

const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const WINGS := ["training", "laminar", "sport"]
const MAX_X_TRAINING := 12.0
const PUSH := 0.3  ## небольшая отдача
const PUSH_AT := 0.3  ## отдача, когда стропа взяла эту долю веса пилота (крыло тянет вверх)


static func slope_fn(deg: float) -> Callable:
	var k := tan(deg_to_rad(deg))
	return func(_x: float, z: float) -> float: return k * z


## Ветер speed, м/с, вдоль склона slope_deg; side_deg — откуда дует от носа (+ справа). Пилот бежит
## на север (−Z игры) под горку.
static func wind_fn(speed: float, slope_deg: float, side_deg := 0.0) -> Callable:
	var a := deg_to_rad(slope_deg)
	var b := deg_to_rad(side_deg)
	var v := Vector3(-speed * cos(a) * sin(b), speed * sin(a), speed * cos(a) * cos(b))
	return func(_p: Vector3) -> Vector3: return v


## Разбег: стоит 1 с, потом бежит. ctrl(t, m, st) → Vector2(pitch, roll); st — состояние сценария
## (Dictionary, общее с ctrl). → {took_off, x, v_kmh, t_run, failure, x_unload, model, st}; после
## отрыва считает ещё after_s и кладёт в st то, что собирает ctrl.
static func run(
	wing: String, slope: float, wind: Callable, ctrl: Callable, after_s := 3.0, t_max := 20.0
) -> Dictionary:
	var m := S.make(wing)
	var g := slope_fn(slope)
	m.reset_on_ground(Vector3.ZERO, 0.0)
	var x0 := m.pilot_position
	var st := {"t_lift": -1.0}
	var out := {"took_off": false, "failure": "", "model": m, "st": st, "x_unload": NAN}
	var t := 0.0
	var inp := S.input()
	while t < t_max:
		inp.run = t > 1.0 - 1.0e-9 and not out.took_off
		var c: Vector2 = ctrl.call(t, m, st)
		inp.pitch = c.x
		inp.roll = c.y
		m.step(S.DT, inp, wind, g)
		t += S.DT
		if m.mode == FlightModel.Mode.FAILED:
			out.failure = m.takeoff_failure
			break
		if t > 1.5 and is_nan(out.x_unload) and m.ground.feet_load <= 0.0:
			out.x_unload = -(m.pilot_position.z - x0.z)
		if not out.took_off and m.mode == FlightModel.Mode.AIR:
			out.took_off = true
			st.t_lift = t
			out.t_run = t - 1.0
			out.x = -(m.pilot_position.z - x0.z)
			out.v_kmh = m.telemetry.airspeed * 3.6
		if out.took_off and m.mode != FlightModel.Mode.AIR and m.mode != FlightModel.Mode.GROUND:
			out.after_mode = m.mode
			break
		if out.took_off and t >= st.t_lift + after_s:
			break
	out.t_end = t
	return out


## Техника по Жеглову: бег в нейтрали, стропа взяла PUSH_AT веса пилота — отдача PUSH до отрыва.
static func zheglov(t: float, m: PendulumModel, st: Dictionary) -> Vector2:
	if st.t_lift >= 0.0:
		return Vector2.ZERO
	if not st.has("push") and t > 1.5 and m.strap_tension > PUSH_AT * m.pilot_mass * Units.G:
		st.push = t
	return Vector2(PUSH if st.has("push") else 0.0, 0.0)


static func neutral(_t: float, _m: PendulumModel, _st: Dictionary) -> Vector2:
	return Vector2.ZERO


## 1. Путь до отрыва: склон 15 и 20°, штиль и встречный 2,5 м/с; учебное ≤ 12 м.
func test_liftoff_distance() -> void:
	for w: String in WINGS:
		for slope: float in [15.0, 20.0]:
			for wind: float in [0.0, 2.5]:
				var r := run(w, slope, wind_fn(wind, slope), zheglov, 1.0)
				var n := run(w, slope, wind_fn(wind, slope), neutral, 1.0)
				check(r.took_off and n.took_off, "%s %.0f° %.1f м/с: отрыв (срыв «%s» / «%s»)" % [
					w, slope, wind, r.failure, n.failure])
				if not (r.took_off and n.took_off):
					continue
				print("    %s склон %.0f° ветер %.1f: отдача — %.1f м (ноги без веса %.1f), %.2f с бега, %.1f км/ч; нейтраль — %.1f м, %.1f км/ч" % [
					w, slope, wind, r.x, r.x_unload, r.t_run, r.v_kmh, n.x, n.v_kmh])
				check(r.x < n.x, "%s %.0f° %.1f: отдача — отрыв раньше (%.1f против %.1f м)" % [w, slope, wind, r.x, n.x])
				if w == "training":
					check(r.x <= MAX_X_TRAINING, "training %.0f° %.1f м/с: путь до отрыва %.1f ≤ %.0f м" % [
						slope, wind, r.x, MAX_X_TRAINING])


## 2а. «От себя» до упора с начала разбега: крыло тормозит — скорость через 1,5 с бега ниже.
func test_push_early_brakes() -> void:
	var push := func(_t: float, _m: PendulumModel, _st: Dictionary) -> Vector2: return Vector2(1.0, 0.0)
	var vs := {}
	for name: String in ["neutral", "push"]:
		var m := S.make("training")
		var g := slope_fn(15.0)
		var air := wind_fn(0.0, 15.0)
		m.reset_on_ground(Vector3.ZERO, 0.0)
		var inp := S.input()
		var t := 0.0
		while t < 2.5:
			inp.run = t > 1.0 - 1.0e-9
			inp.pitch = 1.0 if name == "push" else 0.0
			m.step(S.DT, inp, air, g)
			t += S.DT
		vs[name] = -m.pilot_velocity.z
		check(m.mode == FlightModel.Mode.GROUND, "%s: ещё на земле через 1,5 с бега" % name)
	print("    через 1,5 с бега: нейтраль %.2f м/с, «от себя» до упора %.2f м/с" % [vs.neutral, vs.push])
	check(vs.push < vs.neutral - 0.5, "«от себя» с начала разбега тормозит (%.2f против %.2f м/с)" % [vs.push, vs.neutral])


## 2б. «От себя» до упора в конце разбега на малой скорости (ниже скорости срыва): крыло взмывает и
## сваливается, полёта нет (срыв взлёта или жёсткое касание).
func test_push_late_low_speed_stalls() -> void:
	var ctrl := func(_t: float, m: PendulumModel, st: Dictionary) -> Vector2:
		if not st.has("push") and m.telemetry.airspeed * 3.6 > 20.0:
			st.push = true
		st.max_bank = maxf(st.get("max_bank", 0.0), absf(rad_to_deg(m.bank)))
		st.max_alpha = maxf(st.get("max_alpha", -90.0), rad_to_deg(m.alpha))
		return Vector2(1.0 if st.has("push") else 0.0, 0.0)
	var r := run("training", 15.0, wind_fn(0.5, 15.0, 30.0), ctrl, 6.0)
	var st: Dictionary = r.st
	var m: PendulumModel = r.model
	print("    поздняя отдача на 20 км/ч: отрыв %s (%.1f км/ч), срыв «%s», режим %d, посадка %s; крен до %.0f°, α до %.0f°" % [
		r.took_off, r.get("v_kmh", NAN), r.failure, m.mode, m.landing_result.get("grade", "-"),
		st.get("max_bank", 0.0), st.get("max_alpha", 0.0)])
	var flew: bool = r.took_off and m.mode == FlightModel.Mode.AIR
	check(not flew, "поздняя отдача на малой скорости: не улетел")


## 3. Достаточная скорость: небольшая отдача — отрыв раньше; затем «на себя» — разгон с просадкой.
func test_push_then_pull() -> void:
	var pull := func(t: float, m: PendulumModel, st: Dictionary) -> Vector2:
		var c: Vector2 = zheglov(t, m, st)
		if st.t_lift >= 0.0:
			# руки на штанге (через 1 с) — плавно «на себя» до −0,3 за 2 с (Жеглов, с. 110: за 2–3 с)
			var dt: float = t - st.t_lift
			c = Vector2(-0.3 * clampf((dt - 1.0) / 2.0, 0.0, 1.0), 0.0)
			_track(m, st, dt)
		return c
	var hold := func(t: float, m: PendulumModel, st: Dictionary) -> Vector2:
		var c: Vector2 = zheglov(t, m, st)
		if st.t_lift >= 0.0:
			c = Vector2.ZERO
			_track(m, st, t - st.t_lift)
		return c
	var a := run("training", 15.0, wind_fn(0.0, 15.0), pull, 4.0)
	var b := run("training", 15.0, wind_fn(0.0, 15.0), hold, 4.0)
	check(a.took_off and b.took_off, "оба отрыва")
	if not (a.took_off and b.took_off):
		return
	var sa: Dictionary = a.st
	var sb: Dictionary = b.st
	print("    после отрыва (%.1f км/ч): «на себя» — V через 4 с %.1f км/ч, ступни над склоном %.2f м (мин. %.2f); нейтраль — %.1f км/ч, %.2f м" % [
		a.v_kmh, sa.v_23 * 3.6, sa.h_23, sa.h_min, sb.v_23 * 3.6, sb.h_23])
	check(sa.v_23 > sb.v_23 + 1.0, "«на себя» после отрыва — разгон")
	check(sa.h_23 < sb.h_23, "«на себя» — просадка (ниже, чем в нейтрали)")
	check((a.model as PendulumModel).mode == FlightModel.Mode.AIR, "«на себя» — летит, склон не задел")


static func _track(m: PendulumModel, st: Dictionary, dt: float) -> void:
	var h: float = m.ground.agl(m.chain.pilot()) - m.ground.leg_len
	if dt > 0.3:
		st.h_min = minf(st.get("h_min", 99.0), h)
	st.v_23 = m.telemetry.airspeed
	st.h_23 = h


## 4а. Боковой ветер 12° справа, 5 м/с, стоит на склоне 15°: руки держат, но наветренное (правое)
## крыло приподнято — его прижимает усилие рук (момент ≈ Ixx/τ²·крен); без усилия рук (предел
## момента 0) крыло разворачивает «по циркулю» носом к ветру (скольжение уходит — крен тоже).
func test_crosswind_standing() -> void:
	var res := {}
	for hold: bool in [true, false]:
		var m := S.make("training")
		var g := slope_fn(15.0)
		var air := wind_fn(5.0, 15.0, 12.0)
		m.reset_on_ground(Vector3.ZERO, 0.0)
		if not hold:
			m.ground.roll_max = 0.0
		var inp := S.input()
		var t := 0.0
		var min_bank := 0.0
		while t < 3.0 and m.mode == FlightModel.Mode.GROUND:
			m.step(S.DT, inp, air, g)
			t += S.DT
			min_bank = minf(min_bank, rad_to_deg(m.bank))
		res[hold] = {"bank": min_bank, "heading": rad_to_deg(wrapf(m.heading, -PI, PI)), "mode": m.mode, "fail": m.takeoff_failure}
	print("    боковой 12° 5 м/с стоя: держит — крен до %.1f°, курс %.1f°; отпустил — крен до %.1f°, курс %.1f° (%s)" % [
		res[true].bank, res[true].heading, res[false].bank, res[false].heading, res[false].fail])
	check(res[true].bank < -1.0 and res[true].bank > -5.0, "держит: наветренное крыло приподнято на 1–5° против рук")
	check(res[false].heading > res[true].heading + 5.0, "отпустил: нос к ветру («по циркулю»)")


## 4б. Разбег и полёт у земли с боковым 15° справа, 4 м/с: на разгрузке и после отрыва нос уходит
## к ветру (флюгер); без коррекции наветренное крыло поднимается, смещением тела крен удерживается.
func test_crosswind_takeoff() -> void:
	var out := {}
	for hold: bool in [false, true]:
		var bh := S.BankHold.new(0.0, 2.0, 0.6, 0.5)
		var ctrl := func(t: float, m: PendulumModel, st: Dictionary) -> Vector2:
			var c: Vector2 = zheglov(t, m, st)
			if t > 1.0:
				st.min_bank = minf(st.get("min_bank", 0.0), rad_to_deg(m.bank))
				st.max_abs_bank = maxf(st.get("max_abs_bank", 0.0), absf(rad_to_deg(m.bank)))
				st.heading = maxf(st.get("heading", -90.0), rad_to_deg(wrapf(m.heading, -PI, PI)))
			if st.t_lift >= 0.0:
				c = Vector2(0.0, bh.roll(m) if hold else 0.0)
			return c
		var r := run("training", 15.0, wind_fn(4.0, 15.0, 15.0), ctrl, 3.0)
		out[hold] = r
		check(r.took_off, "боковой ветер, удержание %s: отрыв (срыв «%s»)" % [hold, r.failure])
	if not (out[false].took_off and out[true].took_off):
		return
	var f: Dictionary = out[false].st
	var h: Dictionary = out[true].st
	print("    боковой 15° 4 м/с: путь %.1f м; без коррекции — крен до %.1f°, курс к ветру до %.1f°; держит телом — |крен| ≤ %.1f°, курс до %.1f°" % [
		out[false].x, f.min_bank, f.heading, h.max_abs_bank, h.heading])
	check(f.heading > 3.0, "флюгер: нос к ветру")
	check(f.min_bank < -3.0, "без коррекции наветренное крыло поднимается")
	check(h.max_abs_bank < 10.0, "смещением тела крен удерживается")
	check((out[true].model as PendulumModel).mode == FlightModel.Mode.AIR, "держит — летит")
