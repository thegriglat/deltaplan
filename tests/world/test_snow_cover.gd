extends TestCase
## SNW-К2: SnowCover.snow_fraction на заглушке Terrain (без загрузки места).

class StubTerrain:
	extends Terrain
	var h := 3000.0
	var slope_deg := 0.0
	var cls := SurfaceLayer.SNOW
	var sl := {}
	var bounds := Rect2(-1000.0, -1000.0, 2000.0, 2000.0)

	func height_at(_x: float, _z: float) -> float:
		return h

	func normal_at(_x: float, _z: float) -> Vector3:
		var a := deg_to_rad(slope_deg)
		return Vector3(sin(a), cos(a), 0.0)

	func surface_at(_x: float, _z: float) -> int:
		return cls

	func scene_look_params() -> Dictionary:
		return sl

	func detail_bounds() -> Rect2:
		return bounds


func _stub() -> StubTerrain:
	var t := StubTerrain.new()
	t._look = {"gully_snow_line_m": 2500.0, "snow_slope_deg": [35.0, 45.0], "snow_bare_merge": 1.0}
	t.flight_doy = 196.0
	t.center_lat = 46.0
	t.sl = {"snow_enabled": false}
	return t


func test_class_snow_and_slope() -> void:
	var t := _stub()
	approx(SnowCover.snow_fraction(t, 0.0, 0.0), 1.0, 1e-5, "снег класса 8 на пологом — 1")
	t.slope_deg = 40.0
	approx(SnowCover.snow_fraction(t, 0.0, 0.0), 0.5, 1e-3, "середина 35..45 — smoothstep 0,5")
	t.slope_deg = 50.0
	approx(SnowCover.snow_fraction(t, 0.0, 0.0), 0.0, 1e-5, "круче 45 — нет снега")
	t.free()


func test_bare_above_line() -> void:
	var t := _stub()
	t.cls = SurfaceLayer.BARE
	t.h = 3000.0
	approx(SnowCover.snow_fraction(t, 0.0, 0.0), 1.0, 1e-5, "голый грунт выше линии ложбин (+150 м) — снег")
	t.h = 2300.0
	approx(SnowCover.snow_fraction(t, 0.0, 0.0), 0.0, 1e-5, "голый грунт ниже линии (−150 м) — нет")
	t.h = 3000.0
	t._look["snow_bare_merge"] = 0.0
	approx(SnowCover.snow_fraction(t, 0.0, 0.0), 0.0, 1e-5, "snow_bare_merge = 0 — как класс")
	t.cls = SurfaceLayer.FOREST
	t._look["snow_bare_merge"] = 1.0
	approx(SnowCover.snow_fraction(t, 0.0, 0.0), 0.0, 1e-5, "лес — нет")
	t.free()


func test_fresh_snow_and_max() -> void:
	var t := _stub()
	t.cls = SurfaceLayer.GRASS
	t.sl = {"snow_enabled": true}
	var line := SeasonLook.snow_line(t.flight_doy, t.center_lat, t.sl)
	t.h = line + 1000.0
	approx(SnowCover.snow_fraction(t, 0.0, 0.0), 1.0, 1e-5, "свежий снег высоко над линией")
	t.h = line - 10.0
	approx(SnowCover.snow_fraction(t, 0.0, 0.0), 0.0, 1e-5, "ниже сезонной линии — нет")
	t.h = line + 150.0
	approx(SnowCover.snow_fraction(t, 0.0, 0.0), 0.5, 1e-3, "середина полосы snow_fresh_band_m (300)")
	t.slope_deg = 46.5
	approx(SnowCover.snow_fraction(t, 0.0, 0.0), 0.5 * (1.0 - _smooth(38.0, 55.0, 46.5)), 1e-3, "свежий × крутизна 38..55")
	# max(A, C): класс снега даёт 1, свежий — меньше
	t.cls = SurfaceLayer.SNOW
	t.slope_deg = 0.0
	t.h = line + 150.0
	approx(SnowCover.snow_fraction(t, 0.0, 0.0), 1.0, 1e-5, "max(A, C)")
	t.free()


func test_snow_disabled() -> void:
	var t := _stub()
	t.cls = SurfaceLayer.GRASS
	t.h = 6000.0
	t.sl = {"snow_enabled": false}
	approx(SnowCover.snow_fraction(t, 0.0, 0.0), 0.0, 1e-5, "snow_enabled=false — свежего снега нет")
	t.sl = {"snow_enabled": true}
	t.flight_doy = 200.0  # смена даты — кэш пересчитывается
	check(SnowCover.snow_fraction(t, 0.0, 0.0) > 0.99, "включили и сменили дату — снег есть")
	t.free()


func test_outside_detail_bounds() -> void:
	var t := _stub()
	approx(SnowCover.snow_fraction(t, 0.0, 0.0), 1.0, 1e-5, "внутри слоя — снег")
	approx(SnowCover.snow_fraction(t, 5000.0, 0.0), 0.0, 1e-5, "вне detail_bounds — 0")
	t.free()


func test_cache_reset_on_look_and_snow_enabled() -> void:
	var t := _stub()
	t.cls = SurfaceLayer.BARE
	t.h = 3000.0
	SnowCover.frame_override = 10
	approx(SnowCover.snow_fraction(t, 0.0, 0.0), 1.0, 1e-5, "голый выше линии — снег")
	t._look["snow_bare_merge"] = 0.0  # тот же словарь, тот же кадр
	approx(SnowCover.snow_fraction(t, 0.0, 0.0), 0.0, 1e-5, "смена _look сбрасывает кэш")
	t.cls = SurfaceLayer.GRASS
	t.h = 6000.0
	t.sl = {"snow_enabled": true}
	SnowCover.frame_override = 11
	check(SnowCover.snow_fraction(t, 0.0, 0.0) > 0.99, "snow_enabled включили — свежий снег в следующем кадре")
	t.sl = {"snow_enabled": false}
	SnowCover.frame_override = 12
	approx(SnowCover.snow_fraction(t, 0.0, 0.0), 0.0, 1e-5, "snow_enabled выключили")
	SnowCover.frame_override = -1
	t.free()


static func _smooth(e0: float, e1: float, x: float) -> float:
	var u := clampf((x - e0) / (e1 - e0), 0.0, 1.0)
	return u * u * (3.0 - 2.0 * u)
