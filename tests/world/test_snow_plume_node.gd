extends TestCase
## SNW-4: узел SnowPlume — headless, модель с SnowCover и configs/snow_plume.json на заглушке Terrain.

class StubTerrain:
	extends Terrain

	func height_at(x: float, _z: float) -> float:
		return 3000.0 + maxf(0.0, 500.0 - absf(x) * 0.8)

	func normal_at(_x: float, _z: float) -> Vector3:
		return Vector3.UP

	func surface_at(_x: float, _z: float) -> int:
		return SurfaceLayer.SNOW

	func scene_look_params() -> Dictionary:
		return {"snow_enabled": false}

	func detail_bounds() -> Rect2:
		return Rect2(-20000.0, -20000.0, 40000.0, 40000.0)


class WindAir:
	extends Node
	var v := Vector3(15.0, 0.0, 0.0)

	func mean_wind_at(_p: Vector3) -> Vector3:
		return v


func _stub() -> StubTerrain:
	var t := StubTerrain.new()
	t._look = {"gully_snow_line_m": 2500.0, "snow_slope_deg": [35.0, 45.0], "snow_bare_merge": 1.0}
	t.flight_doy = 196.0
	t.center_lat = 46.0
	return t


func _emitters(wind: float, temp_c: float) -> Array:
	var t := _stub()
	var air := WindAir.new()
	air.v = Vector3(wind, 0.0, 0.0)
	var cfg: Dictionary = Config.get_config("snow_plume")
	var m := SnowPlume.make_model(t, air, func(_h: float) -> float: return temp_c, cfg.get("model", {}))
	var out: Array = []
	for i in 200:
		out = m.update(Vector3(-800.0, 3600.0, 0.0), 1.0 / 60.0)
	t.free()
	air.free()
	return out


func test_headless_attach_null() -> void:
	var t := _stub()
	var air := WindAir.new()
	var n := SnowPlume.attach(t, air, Callable())
	if DisplayServer.get_name() == "headless":
		check(n == null, "в headless attach возвращает null")
		check(t.get_child_count() == 0, "детей у Terrain нет")
	t.free()
	air.free()


func test_config_loaded() -> void:
	var cfg: Dictionary = Config.get_config("snow_plume")
	check(bool(cfg.get("enabled", false)), "enabled")
	check((cfg.get("model", {}) as Dictionary).has("threshold"), "model.threshold")


func test_strong_wind_emits() -> void:
	var list := _emitters(15.0, -10.0)
	check(not list.is_empty(), "15 м/с, -10 °C — источники на заснеженном гребне")


func test_weak_wind_silent() -> void:
	check(_emitters(5.0, -10.0).is_empty(), "5 м/с — источников нет")


func test_no_temp_fn_uses_fallback() -> void:
	var t := _stub()
	var air := WindAir.new()
	var m := SnowPlume.make_model(t, air, Callable(), Config.get_config("snow_plume").get("model", {}))
	var out: Array = []
	for i in 200:
		out = m.update(Vector3(-800.0, 3600.0, 0.0), 1.0 / 60.0)
	check(not out.is_empty(), "без temp_fn — порог при −10 °C, источники есть")
	t.free()
	air.free()
