extends RefCounted
## TW-1: варианты автопилота теста без правки scripts/game/autopilot.gd — подклассы Autopilot.
##   base   — как в игре;
##   vi11   — патч VI-11: разбег с углом атаки 8° до 10 м/с, затем цель; после отрыва до 15 м
##            над землёй тангаж в полосе −6…+12° (и нос не выше 0° ниже 9 м/с);
##   alphaN — разбег с постоянной целью угла атаки N° (опыт «фиксированный угол атаки»), полёт как base;
##   climb  — base на разбеге + только полоса тангажа после отрыва (как vi11, без разбега на 8°);
##   runN   — только разбег на 8° до N м/с (без полосы тангажа).


const PILOT := preload("res://tools/research/takeoff_wind/TW-1/ap_pilot.gd")


static func make(name: String) -> Autopilot:
	if name.begins_with("pilot"):
		# pilot[_rB][_pP][_sS]: разбег с трапецией B (доля хода, «m» — минус), после отрыва P на S с
		var pa = PILOT.new()
		for part in name.split("_").slice(1):
			var v := float(part.substr(1).replace("m", "-"))
			match part[0]:
				"r": pa.run_bar = v
				"p": pa.pull_bar = v
				"s": pa.pull_s = v
		return pa
	if name == "vi11":
		return Vi11.new()
	if name.begins_with("spd"):
		# spdV: как vi11, но в полосе после отрыва нос опускается, пока воздушная < V м/с
		var sp := Vi11.new()
		sp.min_climb_airspeed_ms = float(name.substr(3))
		sp.speed_hold = true
		return sp
	if name == "climb":
		var c := Vi11.new()
		c.rotate_airspeed_ms = 0.0
		return c
	if name.begins_with("run"):
		var r := Vi11.new()
		r.rotate_airspeed_ms = float(name.substr(3))
		r.band = false
		return r
	if name.begins_with("alpha"):
		var a := FixedAlpha.new()
		a.alpha_deg = float(name.substr(5))
		return a
	return Autopilot.new()


class FixedAlpha:
	extends Autopilot
	var alpha_deg := 12.0

	func _nose_dir(t: Telemetry) -> int:
		if t.phase != "running":
			return 0
		if t.stalled:
			return -1
		if t.airspeed < 1.0:
			return 0
		var fl := rad_to_deg(asin(clampf(t.air_velocity.y / t.airspeed, -1.0, 1.0)))
		var alpha := t.pitch_deg - fl
		if alpha > alpha_deg + alpha_tol_deg:
			return -1
		if alpha < alpha_deg - alpha_tol_deg:
			return 1
		return 0


class Vi11:
	extends Autopilot
	var takeoff_climb_agl_m := 15.0
	var min_climb_pitch_deg := -6.0
	var min_climb_airspeed_ms := 9.0
	var max_climb_pitch_deg := 12.0
	var run_alpha_deg := 8.0
	var rotate_airspeed_ms := 10.0
	var band := true
	## spdV: «на себя», пока воздушная ниже min_climb_airspeed_ms (при любом тангаже выше −6°)
	var speed_hold := false

	func drive(t: Telemetry, dt: float) -> void:
		super.drive(t, dt)
		if not band or t.phase != "flying" or t.altitude_agl >= takeoff_climb_agl_m:
			return
		var nose := 0
		var slow := t.airspeed < min_climb_airspeed_ms and (t.pitch_deg > 0.0 or (speed_hold and t.pitch_deg > min_climb_pitch_deg))
		if t.pitch_deg > max_climb_pitch_deg or slow:
			nose = -1
		elif t.pitch_deg < min_climb_pitch_deg:
			nose = 1
		_press("pitch_pull_in", nose < 0)
		_press("pitch_push_out", nose > 0)

	func _nose_dir(t: Telemetry) -> int:
		if t.phase != "running":
			return 0
		if t.stalled:
			return -1
		if t.airspeed < 1.0:
			return 0
		var target := strong_alpha_deg if _wind_ms >= strong_wind_ms else calm_alpha_deg
		if t.airspeed < rotate_airspeed_ms:
			target = minf(target, run_alpha_deg)
		var fl := rad_to_deg(asin(clampf(t.air_velocity.y / t.airspeed, -1.0, 1.0)))
		var alpha := t.pitch_deg - fl
		if alpha > target + alpha_tol_deg:
			return -1
		if alpha < target - alpha_tol_deg:
			return 1
		return 0
