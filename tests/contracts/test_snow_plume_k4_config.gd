extends TestCase
## Контракт SNW-К4 v2 (docs/contracts/snow-plume.md): configs/snow_plume.json — ключи, описания, числа SNW-1.

const PATH := "res://configs/snow_plume.json"
const MODEL_KEYS := [
	"radius_m", "max_emitters", "update_s", "max_wind_samples", "scan_step_m", "scan_points_per_frame",
	"rescan_m", "rescan_dir_deg", "dir_tolerance_k", "fetch_m", "lee_slope_deg", "spacing_m", "snow_min",
	"start_agl_m", "min_agl_m", "path_points", "path_dt_s", "span_ms", "threshold",
]
const THRESHOLD_KEYS := ["a", "b", "c", "wet_t_c", "wet_u10_ms"]
const RENDER_KEYS := ["max_emitters", "particles_per_emitter", "settle_ms", "spread_ms", "size_m", "alpha", "visibility_m"]


func _cfg() -> Dictionary:
	if not FileAccess.file_exists(PATH):
		return {}
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	return d if d is Dictionary else {}


func _keys(sec: Dictionary, keys: Array, name: String) -> void:
	for k: String in keys:
		check(sec.has(k), "%s.%s есть" % [name, k])
		check(sec.has(k + "_doc"), "%s.%s_doc есть" % [name, k])


func test_keys_and_docs() -> void:
	var c := _cfg()
	check(not c.is_empty(), "нет или не JSON: " + PATH)
	if c.is_empty():
		return
	check(c.has("enabled") and c.has("enabled_doc"), "enabled и enabled_doc")
	var m: Dictionary = c.get("model", {})
	var r: Dictionary = c.get("render", {})
	_keys(m, MODEL_KEYS, "model")
	_keys(m.get("threshold", {}), THRESHOLD_KEYS, "model.threshold")
	_keys(r, RENDER_KEYS, "render")


func test_values() -> void:
	var c := _cfg()
	if c.is_empty():
		check(false, "нет " + PATH)
		return
	var m: Dictionary = c.get("model", {})
	var r: Dictionary = c.get("render", {})
	var th: Dictionary = m.get("threshold", {})
	# Li & Pomeroy 1997 — docs/research/snow_plume.md (SNW-1), решение координатора 2026-10-23.
	approx(float(th.get("a", 0.0)), 9.43, 1e-6, "threshold.a")
	approx(float(th.get("b", 0.0)), 0.18, 1e-6, "threshold.b")
	approx(float(th.get("c", 0.0)), 0.0033, 1e-7, "threshold.c")
	check(float(m.get("start_agl_m", 0.0)) >= float(m.get("min_agl_m", 1.0)), "start_agl_m ≥ min_agl_m")
	check(int(m.get("path_points", 99)) >= 2 and int(m.get("path_points", 99)) <= 8, "path_points 2…8")
	check(int(r.get("max_emitters", -1)) == int(m.get("max_emitters", -2)), "render.max_emitters = model.max_emitters")
	var per_emitter := 1 + int(m.get("path_points", 0))
	check(int(m.get("max_wind_samples", 0)) >= per_emitter, "max_wind_samples хватает хотя бы на один источник")
