extends RefCounted
## Правила ачивок (ST-6) по словарям потока S2 (docs/contracts/steam.md). О Game/Glider не знает.
## Тип и пороги правила — в configs/achievements.json (`rule`). Накопители полёта — словарь
## `acc` на ачивку: sample() вызывается 1 Гц в воздухе, check() — в конце полёта с посадкой.
## Прогресс `prog` — накопительная часть user://achievements.json (places, continents, wings, airtime_s).

const Continents := preload("res://scripts/steam/continents.gd")


static func _f(d: Dictionary, key: String) -> float:
	var v: Variant = d.get(key, NAN)
	return float(v) if (v is float or v is int) else NAN


static func _fin(x: float) -> bool:
	return not is_nan(x) and not is_inf(x)


## Накопление по сэмплу s (dt — секунд с прошлого сэмпла, 0 для первого).
static func sample(rule: Dictionary, acc: Dictionary, s: Dictionary, dt: float) -> void:
	match String(rule.get("type", "")):
		"cloudbase":
			var cb := _f(s, "cloud_base_msl")
			var alt := _f(s, "alt_msl")
			if _fin(cb) and _fin(alt) and alt >= cb - float(rule.margin_m):
				acc["hit"] = true
		"sample_max":
			var v := _f(s, String(rule.key))
			if _fin(v):
				acc["max"] = maxf(float(acc.get("max", -INF)), v)
		"ridge":
			var agl := _f(s, "agl")
			if _fin(agl) and agl <= float(rule.agl_max_m):
				acc["run"] = float(acc.get("run", 0.0)) + dt
				acc["best"] = maxf(float(acc.get("best", 0.0)), float(acc["run"]))
			else:
				acc["run"] = 0.0
		"evening":
			var sun := _f(s, "sun_elev_deg")
			if _fin(sun) and sun < float(rule.sun_max_deg):
				acc["t"] = float(acc.get("t", 0.0)) + dt
		"gaggle":
			var v2 := _f(s, "vario")
			if s.get("circling", false) == true and _fin(v2) and v2 > float(rule.vario_min_ms) \
					and int(s.get("near_climbing_live", 0)) >= int(rule.near_min):
				acc["run"] = float(acc.get("run", 0.0)) + dt
				acc["best"] = maxf(float(acc.get("best", 0.0)), float(acc["run"]))
			else:
				acc["run"] = 0.0
		"egg":
			var eggs: Variant = s.get("eggs", {})
			if eggs is Dictionary:
				for id in rule.ids:
					if eggs.has(id):
						acc["min"] = minf(float(acc.get("min", INF)), float(eggs[id]))


## Накопительные счётчики по завершённому полёту (вызывать до check()).
static func update_progress(prog: Dictionary, ctx: Dictionary, fin: Dictionary) -> void:
	var places: Array = prog.places
	var key := String(ctx.get("place_key", ""))
	if key != "" and not places.has(key):
		places.append(key)
	var cont := Continents.of(_f(ctx, "lat"), _f(ctx, "lon"))
	if cont != "" and not prog.continents.has(cont):
		prog.continents.append(cont)
	var wing := String(ctx.get("wing", ""))
	if wing != "" and not prog.wings.has(wing):
		prog.wings.append(wing)
	var t := _f(fin, "flight_time_s")
	if _fin(t) and t > 0.0:
		prog["airtime_s"] = float(prog.get("airtime_s", 0.0)) + t
	prog["flights"] = int(prog.get("flights", 0)) + 1


## Выполнено ли правило. Вызывается только для полёта kind == "landed".
static func check(rule: Dictionary, acc: Dictionary, ctx: Dictionary, fin: Dictionary, prog: Dictionary) -> bool:
	var time_s := _f(fin, "flight_time_s")
	match String(rule.get("type", "")):
		"landed":
			return (rule.grades as Array).has(String(fin.get("grade", "")))
		"soft_landing":
			return String(fin.get("grade", "")) == "soft" \
					and _f(fin, "vertical_speed_ms") < float(rule.max_vertical_ms) \
					and _f(fin, "horizontal_speed_ms") < float(rule.max_horizontal_ms)
		"top_landing":
			if String(fin.get("grade", "")) == "crash" or not (time_s >= float(rule.min_time_s)):
				return false
			var lp: Vector3 = fin.get("land_pos", Vector3.INF)
			var sp: Vector3 = ctx.get("launch_pos", Vector3.INF)
			var d := Vector2(lp.x - sp.x, lp.z - sp.z).length()
			return d <= float(rule.max_dist_m) \
					and _f(fin, "land_alt_msl") >= _f(ctx, "launch_alt_msl") - float(rule.max_below_m)
		"fin_min":
			return _f(fin, String(rule.key)) >= float(rule.min)
		"cloudbase":
			return acc.get("hit", false) == true
		"sample_max":
			return float(acc.get("max", -INF)) >= float(rule.min)
		"ridge":
			return float(acc.get("best", 0.0)) >= float(rule.run_s)
		"upwind":
			var w := _f(ctx, "wind_ms")
			var from := _f(ctx, "wind_from_deg")
			if not (_fin(w) and _fin(from)) or w < float(rule.min_wind_ms):
				return false
			var a := deg_to_rad(from)
			var from_dir := Vector3(sin(a), 0.0, -cos(a))
			var lp2: Vector3 = fin.get("land_pos", Vector3.INF)
			var sp2: Vector3 = ctx.get("launch_pos", Vector3.INF)
			return (lp2 - sp2).dot(from_dir) >= float(rule.min_m)
		"evening":
			return float(acc.get("t", 0.0)) >= float(rule.total_s)
		"places":
			return (prog.places as Array).size() >= int(rule.count)
		"continents":
			return (prog.continents as Array).size() >= int(rule.count)
		"wings":
			return (prog.wings as Array).size() >= int(rule.count)
		"airtime":
			return float(prog.get("airtime_s", 0.0)) >= float(rule.total_s)
		"together":
			return ctx.get("net", false) == true and int(fin.get("live_peers", 0)) >= int(rule.min_peers)
		"gaggle":
			return ctx.get("net", false) == true and float(acc.get("best", 0.0)) >= float(rule.run_s)
		"last_down":
			return time_s >= float(rule.min_time_s) and int(fin.get("others_total", 0)) >= int(rule.min_others) \
					and int(fin.get("others_airborne", 1)) == 0
		"launch_alt":
			return _f(ctx, "launch_alt_msl") >= float(rule.min_m)
		"descent":
			return _f(ctx, "launch_alt_msl") - _f(fin, "land_alt_msl") >= float(rule.min_m)
		"storm":
			return _f(ctx, "cb_chance") >= float(rule.cb_min) and time_s >= float(rule.min_time_s)
		"launch_wind":
			return _f(ctx, "wind_ms") >= float(rule.min_ms)
		"overcast":
			return String(ctx.get("sky", "")) == String(rule.sky) and _f(fin, "height_gain_m") >= float(rule.min_gain_m)
		"winter":
			return _f(ctx, "temp_c") <= float(rule.temp_max_c) and time_s >= float(rule.min_time_s)
		"egg":
			return float(acc.get("min", INF)) <= float(rule.max_m)
		"surface":
			return String(fin.get("land_surface", "")) == String(rule.value)
		"camp":
			return _f(fin, "land_camp_m") <= float(rule.max_m)
	return false
