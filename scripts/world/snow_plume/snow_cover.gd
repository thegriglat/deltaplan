class_name SnowCover
extends RefCounted
## Снег на CPU (SNW-К2 v1, docs/contracts/snow-plume.md): CPU-зеркало шейдера рельефа без шума.
## Только чтение. Сдувание с гребня (snow_ridge_blow) не учитывается: это следствие переноса,
## источник шлейфа — снег наветренного склона.

## Кэш на экземпляр Terrain: scene_look_params() собирает раздел конфига и небо — слишком дорого
## для вызова на каждую точку. Меняется дата или широта — пересчитывается.
static var _cache: Dictionary = {}


static func _ss(e0: float, e1: float, x: float) -> float:
	var u := clampf((x - e0) / (e1 - e0), 0.0, 1.0)
	return u * u * (3.0 - 2.0 * u)


static func _pair(v: Variant, d0: float, d1: float) -> Vector2:
	if v is Array and (v as Array).size() >= 2:
		return Vector2(float((v as Array)[0]), float((v as Array)[1]))
	return Vector2(d0, d1)


## Доля снега 0..1 в точке: max(A, C). A — снег класса рельефа (и голый грунт выше снеговой линии
## ложбин, как в шейдере: слияние с гладкой кромкой ±150 м) × множитель крутизны; C — свежий
## снег SeasonLook выше сезонной снеговой линии × множитель крутизны. Вне рельефа — 0.
static func snow_fraction(terrain: Terrain, x: float, z: float) -> float:
	if terrain == null:
		return 0.0
	var look: Dictionary = terrain._look
	var key := terrain.get_instance_id()
	var c: Dictionary = _cache.get(key, {})
	if c.is_empty() or c.doy != terrain.flight_doy or c.lat != terrain.center_lat:
		var sl: Dictionary = terrain.scene_look_params()
		c = {
			"doy": terrain.flight_doy, "lat": terrain.center_lat, "sl": sl,
			"line": SeasonLook.snow_line(terrain.flight_doy, terrain.center_lat, sl),
			"enabled": bool(sl.get("snow_enabled", true)),
			"band": float(sl.get("snow_fresh_band_m", 300.0)),
			"fresh_slope": _pair(sl.get("snow_fresh_slope"), 38.0, 55.0),
		}
		_cache[key] = c
	var cls := terrain.surface_at(x, z)
	var h := terrain.height_at(x, z)
	var slope := rad_to_deg(acos(clampf(terrain.normal_at(x, z).y, -1.0, 1.0)))
	var a := 0.0
	var pool := 0.0
	if cls == SurfaceLayer.SNOW:
		pool = 1.0
	elif cls == SurfaceLayer.BARE:
		var line := float(look.get("gully_snow_line_m", 2500.0))
		pool = float(look.get("snow_bare_merge", 1.0)) * _ss(line - 150.0, line + 150.0, h)
	if pool > 0.0:
		var sn := _pair(look.get("snow_slope_deg"), 35.0, 45.0)
		a = pool * (1.0 - _ss(sn.x, sn.y, slope))
	var f := 0.0
	if c.enabled:
		var line_f: float = c.line
		var fs: Vector2 = c.fresh_slope
		f = _ss(line_f, line_f + float(c.band), h) * (1.0 - _ss(fs.x, fs.y, slope))
	return clampf(maxf(a, f), 0.0, 1.0)
