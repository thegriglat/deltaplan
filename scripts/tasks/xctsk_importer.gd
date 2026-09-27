class_name XctskImporter
extends RefCounted
## Импорт заданий XCTrack (.xctsk, JSON, "version": 1) в словарь формата configs/tasks/*.json.
## Формат: https://xctrack.org/Competition_Interfaces.html — turnpoints[{type?, radius,
## waypoint{name, lat, lon, altSmoothed}}], sss{type RACE|ELAPSED-TIME, direction ENTER|EXIT,
## timeGates["HH:MM:SSZ"]}, goal{type CYLINDER|LINE, deadline}, takeoff{timeOpen, timeClose}.
## Последний пункт — гоул. Время UTC переводится в секунды от начала полёта:
## полёт начинается за xctsk.start_lead_s до первого стартового окна.
## QR-формат v2 ("XCTSK:...") не поддерживается.

const SECONDS_PER_DAY := 86400.0


## text — содержимое .xctsk; settings — configs/tasks/settings.json. {} — ошибка разбора.
static func parse(text: String, settings: Dictionary = {}) -> Dictionary:
	var data: Variant = JSON.parse_string(text)
	if not data is Dictionary:
		push_error("XctskImporter: не JSON (QR-формат XCTSK: не поддерживается)")
		return {}
	var src: Dictionary = data
	var tps: Array = src.get("turnpoints", [])
	if tps.is_empty():
		push_error("XctskImporter: нет пунктов")
		return {}
	var x: Dictionary = settings.get("xctsk", {})
	var sss: Dictionary = src.get("sss", {}) if src.get("sss") is Dictionary else {}
	var goal: Dictionary = src.get("goal", {}) if src.get("goal") is Dictionary else {}
	var gates_clock: Array[float] = []
	for g: Variant in sss.get("timeGates", []):
		var s := parse_time(String(g))
		if not is_nan(s):
			gates_clock.append(s)
	gates_clock.sort()
	var lead := float(x.get("start_lead_s", 1200.0))
	var origin := NAN
	if not gates_clock.is_empty():
		origin = gates_clock[0] - lead
	var out := {
		"name": String(src.get("name", "XCTrack")),
		"type": "elapsed" if String(sss.get("type", "RACE")) == "ELAPSED-TIME" else "race",
		"source": "xctsk",
		"clock_origin_s": origin,
		"start_gates_s": _relative(gates_clock, origin, lead),
		"turnpoints": _points(tps, sss, goal),
	}
	if src.has("cylinderTolerance"):
		out["cylinder_tolerance"] = float(src.cylinderTolerance)
	var deadline := parse_time(String(goal.get("deadline", "")))
	if not is_nan(deadline) and not is_nan(origin):
		out["deadline_s"] = fposmod(deadline - origin, SECONDS_PER_DAY)
	return out


## "HH:MM:SSZ" (в XCTrack бывает в лишних кавычках: "\"12:00:00Z\"") → секунды от полуночи.
static func parse_time(s: String) -> float:
	var clean := s.replace('"', "").strip_edges().trim_suffix("Z")
	var parts := clean.split(":")
	if parts.size() < 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return NAN
	var sec := float(parts[2]) if parts.size() > 2 and parts[2].is_valid_float() else 0.0
	return float(parts[0]) * 3600.0 + float(parts[1]) * 60.0 + sec


static func _relative(gates_clock: Array[float], origin: float, lead: float) -> Array:
	if gates_clock.is_empty():
		return [lead]
	var out := []
	for g in gates_clock:
		out.append(fposmod(g - origin, SECONDS_PER_DAY))
	return out


static func _points(tps: Array, sss: Dictionary, goal: Dictionary) -> Array:
	var out := []
	for i in tps.size():
		var tp: Dictionary = tps[i]
		var wp: Dictionary = tp.get("waypoint", {})
		var kind := "turnpoint"
		match String(tp.get("type", "")):
			"TAKEOFF":
				kind = "takeoff"
			"SSS":
				kind = "sss"
			"ESS":
				kind = "ess"
		if i == tps.size() - 1:
			kind = "goal"
		var p := {
			"name": String(wp.get("name", "TP%d" % i)),
			"type": kind,
			"lat": float(wp.get("lat", 0.0)),
			"lon": float(wp.get("lon", 0.0)),
			"radius_m": float(tp.get("radius", 400.0)),
		}
		if wp.has("altSmoothed"):
			p["alt_m"] = float(wp.altSmoothed)
		if kind == "sss":
			p["direction"] = String(sss.get("direction", "EXIT")).to_lower()
		if kind == "goal" and String(goal.get("type", "CYLINDER")) == "LINE":
			p["goal_type"] = "line"
			# в XCTrack длина линии = 2 × радиус пункта
			p["line_length_m"] = 2.0 * float(tp.get("radius", 200.0))
		out.append(p)
	return out
