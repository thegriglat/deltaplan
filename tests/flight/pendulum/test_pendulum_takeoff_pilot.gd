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


## 4а. Боковой ветер 10–15° справа, 4–5 м/с, стоит на склоне 15° (PD-32): руки держат курс как
## тангаж (ground.yaw_hold_*) — крыло не разворачивает «по циркулю», ветер виден усилием на руках
## и небольшим креном (наветренное крыло приподнято). Без рук (предел 0) нос уходит к ветру.
## FB-3: стоя без поворота по умолчанию — флюгер (test_ground_stand); здесь он выключен (cn_beta = 0).
func test_crosswind_standing() -> void:
	var res := {}
	for side: float in [10.0, 15.0]:
		for hold: bool in [true, false]:
			var m := S.make("training")
			var g := slope_fn(15.0)
			var air := wind_fn(5.0 if side < 12.0 else 4.0, 15.0, side)
			m.reset_on_ground(Vector3.ZERO, 0.0)
			m.ground.cn_beta = 0.0  # FB-3: флюгер выключен — пилот держит курс бега и стоя
			if not hold:
				m.ground.yaw_max = 0.0
			var inp := S.input()
			var t := 0.0
			var min_bank := 0.0
			var max_dev := 0.0
			var max_m := 0.0
			while t < 4.0 and m.mode == FlightModel.Mode.GROUND:
				m.step(S.DT, inp, air, g)
				t += S.DT
				min_bank = minf(min_bank, rad_to_deg(m.bank))
				max_dev = maxf(max_dev, absf(rad_to_deg(wrapf(m.heading - m.ground.heading_cmd, -PI, PI))))
				max_m = maxf(max_m, absf(m.ground.yaw_moment))
			res[[side, hold]] = {"bank": min_bank, "dev": max_dev, "m": max_m, "mode": m.mode}
	for side: float in [10.0, 15.0]:
		var h: Dictionary = res[[side, true]]
		var f: Dictionary = res[[side, false]]
		print("    боковой %.0f° стоя: держит — курс ±%.1f°, крен до %.1f°, момент рук %.0f Н·м; без рук — курс %.1f°" % [
			side, h.dev, h.bank, h.m, f.dev])
		check(h.dev < 3.0, "боковой %.0f° стоя: курс крыла в пределах 3° от курса бега" % side)
		check(h.bank < -0.5 and h.bank > -6.0, "наветренное крыло приподнято на небольшой крен")
		check(h.m < 0.8 * m_yaw_cap() and h.m > 5.0, "момент рук по курсу виден и не на пределе")
		check(f.dev > h.dev + 5.0, "без рук: нос к ветру («по циркулю»)")


static func m_yaw_cap() -> float:
	return S.make("training").ground.yaw_max


## 4б. Разбег с боковым 10–15°, 4–5 м/с (PD-32): курс крыла держится у направления бега, пилот
## бежит вниз по склону (на север), крен небольшой, момент рук по курсу не на пределе; после
## отрыва руки на штанге — курс уже не держится на земле.
func test_crosswind_takeoff() -> void:
	for side: float in [10.0, 15.0]:
		var ctrl := func(t: float, m: PendulumModel, st: Dictionary) -> Vector2:
			var c: Vector2 = zheglov(t, m, st)
			if t > 1.0 and st.t_lift < 0.0:
				st.max_bank = maxf(st.get("max_bank", 0.0), absf(rad_to_deg(m.bank)))
				st.dev = maxf(st.get("dev", 0.0), absf(rad_to_deg(wrapf(m.heading - m.ground.heading_cmd, -PI, PI))))
				st.max_m = maxf(st.get("max_m", 0.0), absf(m.ground.yaw_moment))
			return c
		var r := run("training", 15.0, wind_fn(4.5, 15.0, side), ctrl, 1.0)
		check(r.took_off, "боковой %.0f° на разбеге: отрыв (срыв «%s»)" % [side, r.failure])
		var st: Dictionary = r.st
		var m: PendulumModel = r.model
		var east := absf(m.pilot_position.x)
		var north := absf(m.pilot_position.z)
		print("    разбег, боковой %.0f° 4,5 м/с: путь %.1f м, в сторону %.1f м; курс ±%.1f°, крен до %.1f°, момент рук до %.0f Н·м" % [
			side, r.get("x", NAN), east, st.get("dev", NAN), st.get("max_bank", NAN), st.get("max_m", NAN)])
		if not r.took_off:
			continue
		check(st.dev < 4.0, "боковой %.0f° разбег: курс в пределах 4° от курса бега" % side)
		check(east < 0.25 * north, "бежит вниз по склону, а не вбок")
		check(st.max_bank < 8.0, "крен небольшой")
		check(st.max_m < 0.8 * m_yaw_cap(), "момент рук по курсу не на пределе")
