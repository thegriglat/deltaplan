extends TestCase
## Контракт SNW-К1/К3 v3 (docs/contracts/snow-plume.md): модель снежных флагов → список источников.
## Рельеф — синтетический гребень вдоль Z (x = 0, склоны ≈39°), ветер поперёк (+X). Числа порога — тестовые,
## не из литературы (настоящие — SNW-1 → configs/snow_plume.json).

const MODEL_PATH := "res://scripts/world/snow_plume/snow_plume_model.gd"
const KEYS := {
	"id": TYPE_INT, "pos": TYPE_VECTOR3, "dir": TYPE_VECTOR3, "u10": TYPE_FLOAT, "u_t": TYPE_FLOAT,
	"intensity": TYPE_FLOAT, "snow": TYPE_FLOAT, "width_m": TYPE_FLOAT,
	"path": TYPE_PACKED_VECTOR3_ARRAY, "vel": TYPE_PACKED_VECTOR3_ARRAY, "path_dt": TYPE_FLOAT,
	"surf": TYPE_PACKED_VECTOR3_ARRAY,
}
const CAM := Vector3(-1500.0, 3600.0, 0.0)


func _cfg() -> Dictionary:
	return {
		"radius_m": 3000.0, "max_emitters": 6, "update_s": 0.5, "max_wind_samples": 80,
		"scan_step_m": 50.0, "scan_points_per_frame": 4000, "rescan_m": 1000.0, "rescan_dir_deg": 10.0,
		"fetch_m": 200.0, "lee_slope_deg": 15.0, "spacing_m": 150.0, "snow_min": 0.5,
		"start_agl_m": 3.0, "min_agl_m": 3.0, "surf_upwind_m": 30.0, "path_points": 6, "path_dt_s": 8.0, "span_ms": 8.0,
		"threshold": {"a": 9.0, "b": 0.0, "c": 0.0, "wet_t_c": 0.0, "wet_u10_ms": 12.0},
	}


func _h(x: float, _z: float) -> float:
	return 3000.0 + maxf(0.0, 500.0 - absf(x) * 0.8)


func _model(snow: float, wind_ms: float, cfg: Dictionary = {}) -> Object:
	var script: GDScript = load(MODEL_PATH)
	if script == null:
		return null
	var c := _cfg() if cfg.is_empty() else cfg
	return script.new(
		c, _h, func(_x: float, _z: float) -> float: return snow,
		func(_p: Vector3) -> Vector3: return Vector3(wind_ms, 0.0, 0.0),
		func(_z_m: float) -> float: return -10.0)


func _run(m: Object, frames: int = 600) -> Array:
	var out: Array = []
	for i in frames:
		out = m.update(CAM, 1.0 / 60.0)
	return out


func test_threshold_and_intensity() -> void:
	var script: GDScript = load(MODEL_PATH)
	check(script != null, "нет " + MODEL_PATH)
	if script == null:
		return
	var cfg := {"span_ms": 8.0, "threshold": {"a": 9.0, "b": 0.2, "c": 0.01, "wet_t_c": 0.0, "wet_u10_ms": 12.0}}
	approx(script.threshold_u10(-10.0, cfg), 9.0 - 2.0 + 1.0, 1e-4, "a + b·t + c·t² при t ≤ wet_t_c")
	approx(script.threshold_u10(2.0, cfg), 12.0, 1e-4, "мокрый снег — wet_u10_ms")
	approx(script.intensity(5.0, 9.0, cfg), 0.0, 1e-6, "ниже порога — 0")
	approx(script.intensity(13.0, 9.0, cfg), 0.5, 1e-6, "(u − u_t)/span")
	approx(script.intensity(30.0, 9.0, cfg), 1.0, 1e-6, "не больше 1")


func test_strong_wind_emitters() -> void:
	var m := _model(1.0, 15.0)
	check(m != null, "нет " + MODEL_PATH)
	if m == null:
		return
	var list := _run(m)
	var cfg := _cfg()
	check(not list.is_empty(), "сильный ветер поперёк заснеженного гребня — есть источники")
	check(list.size() <= int(cfg.max_emitters), "не больше max_emitters")
	check(m.wind_calls_last() <= int(cfg.max_wind_samples), "вызовов ветра не больше max_wind_samples")
	var prev_d := -1.0
	for e: Dictionary in list:
		for k: String in KEYS:
			check(e.has(k) and typeof(e[k]) == KEYS[k], "ключ %s типа %d" % [k, KEYS[k]])
		if not (e.has("pos") and e.has("path") and e.has("vel")):
			continue
		var p: Vector3 = e.pos
		var d := Vector2(p.x - CAM.x, p.z - CAM.z).length()
		check(d >= prev_d - 1e-3, "по возрастанию расстояния до камеры")
		prev_d = d
		check(d <= float(cfg.radius_m) + 1e-3, "в пределах radius_m")
		check(absf(p.x) <= 1.5 * float(cfg.scan_step_m), "точка на гребне (x≈0), x=%.0f" % p.x)
		approx(p.y, _h(p.x, p.z), 1.0, "pos.y = высота рельефа")
		check(float(e.intensity) > 0.0 and float(e.intensity) <= 1.0, "intensity в (0, 1]")
		check(float(e.u10) > float(e.u_t), "u10 > u_t")
		check(float(e.snow) >= float(cfg.snow_min), "snow ≥ snow_min")
		var path: PackedVector3Array = e.path
		var vel: PackedVector3Array = e.vel
		check(path.size() == int(cfg.path_points) and vel.size() == path.size(), "path_points точек")
		for q in path:
			check(q.y >= _h(q.x, q.z) + float(cfg.min_agl_m) - 0.01, "линия тока не ниже рельефа + min_agl_m")
		if e.has("surf"):
			var surf: PackedVector3Array = e.surf
			check(surf.size() >= 2 and surf.size() <= 8, "surf: 2…8 точек")
			var lim := 0.5 * float(e.width_m) + float(cfg.surf_upwind_m) + 1e-3
			for s in surf:
				approx(s.y, _h(s.x, s.z), 0.01, "surf на рельефе")
				check(Vector2(s.x - p.x, s.z - p.z).length() <= lim, "surf у гребня")
		if path.size() >= 2:
			check(path[path.size() - 1].x > path[0].x, "шлейф уходит по ветру (+X) на подветренную сторону")


func test_stable_ids() -> void:
	var m := _model(1.0, 15.0)
	if m == null:
		check(false, "нет " + MODEL_PATH)
		return
	var a := _run(m)
	var ids_a := {}
	for e: Dictionary in a:
		ids_a[e.get("id", -1)] = true
	var b := _run(m, 60)
	var same := 0
	for e: Dictionary in b:
		if ids_a.has(e.get("id", -2)):
			same += 1
	check(not b.is_empty() and same == b.size(), "та же клетка гребня — тот же id")


func test_no_emitters_weak_wind_or_no_snow() -> void:
	var weak := _model(1.0, 3.0)
	var bare := _model(0.0, 15.0)
	if weak == null or bare == null:
		check(false, "нет " + MODEL_PATH)
		return
	check(_run(weak).is_empty(), "ветер ниже порога — нет источников")
	check(_run(bare).is_empty(), "нет снега — нет источников")
