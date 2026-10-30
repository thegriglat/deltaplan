extends TestCase
## Контрактные тесты feedback-1013 (docs/contracts/feedback-1013.md). FBW-К2 — время суток и солнце
## для притока тепла и термиков (владелец FBW-1): часы — поясное время места, солнце — SunClock;
## ψ ≤ 0 → K↓ = 0, рождений термиков нет; облачность — один раз. Поток тепла по классам поверхности
## (суша H ≤ 0 после заката, застройка — ночной спад, вода — water_flux) и дата поля — в крейте
## (rust/dp-air/src/field/surface_heat.rs, weather_core.rs); класс Weather — обёртка DpWeather (W12).
## Сценарий пилота через сцену игры — tools/research/fb1013_evening/run.sh.

const Rig := preload("res://tests/atmosphere/air_rig.gd")
const DOC := "res://docs/contracts/feedback-1013.md"
const VERSIONS := {"FBW-К2": 3}
## Места: широта, долгота, пояс (NAN — по долготе, как точка с карты): широты 40–60°, долготы мест игры.
const PLACES := [
	[40.0, 42.5, NAN], [43.3, 42.5, NAN], [45.0, 59.69, NAN], [50.79, 86.13, 7.0],
	[51.87, 85.87, 7.0], [53.26, 58.54, 5.0], [54.72, 59.69, 5.0], [58.0, 60.0, NAN],
	[60.0, 86.13, NAN],
]
const SKIES := ["clear", "partly", "overcast"]


func _read(path: String) -> String:
	var t := FileAccess.get_file_as_string(path)
	if t.is_empty():
		t = FileAccess.get_file_as_string(ProjectSettings.globalize_path(path))
	return t


func test_versions() -> void:
	var text := _read(DOC)
	var at := text.find("contracts: [")
	check(at >= 0, "frontmatter contracts")
	var line := text.substr(at, text.find("\n", at) - at)
	for id: String in VERSIONS:
		check(
			line.contains('{"id": "%s", "version": %d}' % [id, VERSIONS[id]]),
			"%s v%d в frontmatter: %s" % [id, VERSIONS[id], line]
		)
		check(text.contains("## %s v%d" % [id, VERSIONS[id]]), "%s v%d заголовок" % [id, VERSIONS[id]])


static func _utc(p: Array) -> float:
	return float(p[2]) if not is_nan(float(p[2])) else roundf(float(p[1]) / 15.0)


static func _ctx(p: Array, month: int, day: int) -> Dictionary:
	var c := Weather.reference_context()
	c.merge({"month": month, "day": day, "lat": p[0], "lon": p[1], "utc_offset_h": _utc(p)}, true)
	return c


# ---------------------------------------------------------------- FBW-К2 (владелец FBW-1)
## Погода хода дня: ψ ≤ 0 → прогрев 0, доля рождений 0, сила 0 (все небеса).
func test_k2_weather_evening() -> void:
	var fc := {"temperature_c": 7.0, "wind_speed_kmh": 25.2, "wind_from_deg": 180.0}
	for p: Array in PLACES:
		for sky: String in SKIES:
			fc.sky = sky
			var w := Weather.derive(fc, _ctx(p, 10, 15), 20.0)
			var d: Dictionary = w._derived
			check(float(d.sun_elev_deg) < 0.0, "%s %s: ψ погоды < 0" % [str(p), sky])
			check(float(d.heat) == 0.0, "%s %s: прогрев 0 (%.3f)" % [str(p), sky, d.heat])
			check(float(w.thermal_duty) == 0.0, "%s %s: доля рождений 0" % [str(p), sky])
			check(float(w.thermal_strength_ms[1]) == 0.0, "%s %s: сила 0" % [str(p), sky])
		# сразу после заката (в пределах запаздывания луга) прогрева уже нет
		var sunset := Weather.sunset_h(26.0, _ctx(p, 7, 15))
		var w2 := Weather.derive(
			{"temperature_c": 26.0, "wind_speed_kmh": 10.0, "sky": "clear"}, _ctx(p, 7, 15), sunset + 0.05
		)
		check(float(w2._derived.heat) == 0.0, "%s: сразу после заката прогрев 0" % str(p))


## Облачность — один раз: пелена неба прогноза не гасит солнце источникам второй раз, доля
## рождений поля — без duty_k неба (оно уже в K↓ поля).
func test_k2_cloud_once() -> void:
	var p: Array = PLACES[4]
	for sky: String in SKIES:
		var w := Weather.derive(
			{"temperature_c": 26.0, "wind_speed_kmh": 10.0, "sky": sky}, _ctx(p, 7, 15), 13.0
		)
		var sp := Weather.sky_params(sky)
		approx(float(w.sky_cover), float(sp.get("cover", 0.0)), 1e-6, sky + ": sky_cover")
		var sdef: Dictionary = Weather.config().sky.get(sky, {})
		approx(float(w.sky_duty_k), float(sdef.get("duty_k", 1.0)), 1e-6, sky + ": sky_duty_k")


# ---- рождения: атмосфера с ходом дня (погода, солнце, источники по инерции прогрева), ровная земля
static func _flat(_x: float, _z: float) -> float:
	return 1000.0


## Рождения термиков за 10 мин от t = 0 (ядра, которых не было в начале): прогноз в set_conditions
## (ход дня, солнце и источники по инерции прогрева — в крейте, W2 v4), ровная земля, трава.
static func _births(p: Array, month: int, day: int, hour: float, sky: String) -> int:
	var cond := {
		"forecast":
		{
			"temperature_c": Weather.typical_max_c(month, day),
			"wind_speed_kmh": 25.2,
			"wind_from_deg": 180.0,
			"sky": sky
		},
		"start_hour": hour,
		"wind_ref": {"ref_msl": 1000.0, "gain_per_km": 0.6},
	}
	var loc := {
		"id": "fbw_k2",
		"center_lat": float(p[0]),
		"center_lon": float(p[1]),
		"utc_offset_h": _utc(p),
		"month": month,
		"day": day,
	}
	var a := Rig.make(
		{"cond": cond, "loc": loc, "ground": _flat, "focus": Vector3(0, 1000.0, 0), "advance": 0.0}
	)
	var center := Vector3(0, 1000.0, 0)
	var cs := Atmosphere.CORE_STRIDE
	var seen := {}
	var c0 := a.cores(center, 20000.0)
	for j in range(0, c0.size() - cs + 1, cs):
		seen[int(c0[j + Atmosphere.CORE_ID])] = true
	var born := {}
	for i in 120:
		Rig.step(a, 5.0)
		var c := a.cores(center, 20000.0)
		for j in range(0, c.size() - cs + 1, cs):
			var id := int(c[j + Atmosphere.CORE_ID])
			if (int(c[j + Atmosphere.CORE_FLAGS]) & 1) == 0 and not seen.has(id):
				born[id] = true
	a.free()
	return born.size()


## 15.10 20:00 облачно: рождений 0 за 10 мин; 15.07 13:00 ясно: термики рождаются.
func test_k2_births() -> void:
	for i: int in [1, 3, 6, 7]:
		var p: Array = PLACES[i]
		var n := _births(p, 10, 15, 20.0, "overcast")
		check(n == 0, "%s 15.10 20:00: рождений %d" % [str(p), n])
	var nd := _births(PLACES[4], 7, 15, 13.0, "clear")
	check(nd > 0, "15.07 13:00 ясно: рождений %d > 0" % nd)
