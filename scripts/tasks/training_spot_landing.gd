class_name TrainingSpotLanding
extends TrainingMode
## Точность приземления: сесть как можно ближе к центру круга-мишени.
## Очки — по кольцам (rings: [{radius_m, points}], от меньшего к большему), умножаются на
## коэффициент оценки посадки LandingJudge (grade_factor: soft / hard / crash).
## Мишень: config.targets[<локация>] {lat, lon} (через latlon_fn) или {x_m, z_m}; или set_target().

var target := Vector3.ZERO
var has_target := false
var rings: Array = []
var grade_factor: Dictionary = {}
var time_limit_s: float = 1800.0
var location: String = ""

## Последняя телеметрия в воздухе — для оценки посадки, если результат не пришёл сигналом.
var _last_velocity := Vector3.ZERO
var _last_bank_deg := 0.0


func get_mode_id() -> String:
	return "spot_landing"


func set_target(pos: Vector3) -> void:
	target = pos
	has_target = true


func _setup_mode() -> void:
	rings = config.get("rings", [])
	rings.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool: return float(a.radius_m) < float(b.radius_m)
	)
	grade_factor = config.get("grade_factor", {"soft": 1.0, "hard": 0.5, "crash": 0.0})
	time_limit_s = float(config.get("time_limit_s", time_limit_s))
	location = String(config.get("location", location))
	var targets: Dictionary = config.get("targets", {})
	var tg: Dictionary = targets.get(location, {})
	if tg.has("lat") and latlon_fn.is_valid():
		var xz: Vector2 = latlon_fn.call(float(tg.lat), float(tg.lon))
		set_target(Vector3(xz.x, 0.0, xz.y))
	elif tg.has("x_m"):
		set_target(Vector3(float(tg.x_m), 0.0, float(tg.get("z_m", 0.0))))


## Расстояние от точки до центра мишени по горизонтали, м.
func distance_to_target(p: Vector3) -> float:
	return Vector2(p.x - target.x, p.z - target.z).length()


## Очки за расстояние (без учёта оценки посадки).
func ring_points(distance_m: float) -> float:
	for r: Dictionary in rings:
		if distance_m <= float(r.radius_m):
			return float(r.points)
	return 0.0


func _step(t: Telemetry, _dt: float) -> void:
	if t.phase == "flying":
		_last_velocity = t.velocity
		_last_bank_deg = t.bank_deg
	if elapsed_s >= time_limit_s:
		_finish(false, 0.0, "time", {})


func _on_ground(t: Telemetry, landing: Dictionary) -> void:
	var lr := landing
	if lr.is_empty():
		var cfg: Dictionary = Config.get_config("flight").get("landing", {})
		lr = LandingJudge.evaluate(_last_velocity, Vector3.UP, _last_bank_deg, cfg)
	var grade := String(lr.get("grade", "soft"))
	var d := distance_to_target(t.position)
	var pts := ring_points(d)
	var score := pts * float(grade_factor.get(grade, 0.0))
	_finish(
		has_target and score > 0.0,
		score,
		"landed",
		{"distance_m": d, "ring_points": pts, "grade": grade, "has_target": has_target}
	)
