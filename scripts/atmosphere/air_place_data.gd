class_name AirPlaceData
extends RefCounted
## Место для воздуха (rust-wind W5 v2): растры, которые реализация получает один раз при
## Atmosphere.load_place. Всё производное (уклоны, тень, источники термиков, нагрев) считает
## реализация из этих растров.
##
## header — json-совместимый словарь: {version: 1, loc: {id, center_lat, center_lon, utc_offset_h,
## month, day}, grid: {origin_x, origin_z, spacing, width, height} (сетка W1: узлы, строка j к +Z,
## индекс j * width + i), surface_classes: {имя: код}, start_sites: [{x, z, h_msl}]}.
## heights — м MSL по узлам (NaN недопустим); water — 0/1; surface_cls — код класса поверхности
## (SurfaceLayer.CLASS_NAMES); surface_moist — 0..1; все четыре массива — на одной сетке.
##
## Переходное (только реализация gd, до RW-13): terrain — рельеф игры, если место собрано из него
## (from_terrain): тогда height_fn/sun_fn/surface_fn остаются прежними (terrain.height_at,
## thermal_source_strength_at, surface_at) и физика не меняется; без terrain высота — билинейно
## по растру, сила источника — по нормали растра и влажности (как AtmoFingerprint.source_static).

const VERSION := 1
## Направление «на солнце» для силы источника без времени (как AtmoFingerprint.source_static).
const SUN_FOR_SOURCE := Vector3(0.3, 0.8, 0.5)

var header: Dictionary = {}
var heights := PackedFloat32Array()
var water := PackedByteArray()
var surface_cls := PackedByteArray()
var surface_moist := PackedFloat32Array()
## Рельеф игры (gd, переходное); null — место задано одними растрами.
var terrain: Node = null

var _sun_n := SUN_FOR_SOURCE.normalized()


## Коды классов поверхности: имя → код (как AirPlace.Surface / SurfaceLayer.CLASS_NAMES).
static func surface_classes() -> Dictionary:
	var out := {}
	for i in SurfaceLayer.CLASS_NAMES.size():
		out[SurfaceLayer.CLASS_NAMES[i]] = i
	return out


## Заготовка заголовка W5.
static func make_header(
	loc: Dictionary, grid: Dictionary, start_sites: Array = []
) -> Dictionary:
	return {
		"version": VERSION,
		"loc": loc,
		"grid": grid,
		"surface_classes": surface_classes(),
		"start_sites": start_sites,
	}


## Место из растров. Длины не проверяются здесь — validate().
static func from_arrays(
	p_header: Dictionary,
	p_heights: PackedFloat32Array,
	p_water: PackedByteArray,
	p_cls: PackedByteArray,
	p_moist: PackedFloat32Array
) -> AirPlaceData:
	var p := AirPlaceData.new()
	p.header = p_header
	p.heights = p_heights
	p.water = p_water
	p.surface_cls = p_cls
	p.surface_moist = p_moist
	return p


## Место из рельефа игры (AirRuntime.place_of, слой detail 25 м): сборка полей W5 так же, как у
## генератора эталонов (tools/wind_fixtures/gen_fixtures.gd). Блокирует до готовности снимка
## поверхности. null — сетки не совпали или рельефа нет (причина — в push_error).
static func from_terrain(
	p_terrain: Node, utc_offset_h: float, month: int, day: int
) -> AirPlaceData:
	var place := AirRuntime.place_of(p_terrain, utc_offset_h, month, day)
	var detail: HeightLayer = place.detail
	var sf: AirPlace.Surface = place.surface
	if detail == null or sf == null:
		push_error("AirPlaceData.from_terrain: нет слоя detail или снимка поверхности")
		return null
	sf.wait()
	if (
		sf.width != detail.width
		or sf.height != detail.height
		or sf.origin_x != detail.origin_x
		or sf.origin_z != detail.origin_z
	):
		push_error("AirPlaceData.from_terrain: сетка поверхности не совпала со слоем detail")
		return null
	var sites: Array = []
	for st: Dictionary in place.start_sites:
		var sp: Vector3 = st.position
		sites.append({"id": String(st.id), "x": sp.x, "z": sp.z, "h_msl": sp.y})
	var loc: Dictionary = (place.loc as Dictionary).duplicate()
	loc.month = month
	loc.day = day
	var grid := {
		"origin_x": detail.origin_x,
		"origin_z": detail.origin_z,
		"spacing": detail.spacing,
		"width": detail.width,
		"height": detail.height,
	}
	var p := from_arrays(
		make_header(loc, grid, sites),
		detail.heights,
		_water_nodes(place.water, detail),
		sf.cls,
		sf.moist
	)
	p.terrain = p_terrain
	p.fill_climate()
	return p


## Вода по узлам слоя: ближайший к узлу пиксель маски (> 127), как у генератора эталонов.
static func _water_nodes(img: Image, layer: HeightLayer) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(layer.width * layer.height)
	if img == null:
		return out
	if img.is_compressed() or img.get_format() != Image.FORMAT_L8:
		img = img.duplicate()
		if img.is_compressed():
			img.decompress()
		img.convert(Image.FORMAT_L8)
	var px := img.get_data()
	var iw := img.get_width()
	var ih := img.get_height()
	for j in layer.height:
		var row := (ih - 1 - int((layer.height - 1 - j) * ih / layer.height)) * iw
		for i in layer.width:
			var col := int(i * iw / layer.width)
			out[j * layer.width + i] = 1 if px[row + col] > 127 else 0
	return out


## Пустая строка — место годится; иначе причина (BAD_INPUT в load_place).
func validate() -> String:
	if int(header.get("version", 0)) != VERSION:
		return "header.version ≠ %d" % VERSION
	for k in ["loc", "grid", "surface_classes", "start_sites"]:
		if not header.has(k):
			return "header.%s отсутствует" % k
	var g: Variant = header.grid
	if not g is Dictionary:
		return "header.grid не словарь"
	for k in ["origin_x", "origin_z", "spacing", "width", "height"]:
		if not (g as Dictionary).has(k) or not is_finite(float(g[k])):
			return "header.grid.%s отсутствует или не число" % k
	var w := int(g.width)
	var h := int(g.height)
	if w < 2 or h < 2 or float(g.spacing) <= 0.0:
		return "header.grid: width, height ≥ 2 и spacing > 0"
	var n := w * h
	if heights.size() != n:
		return "heights: %d значений, нужно %d" % [heights.size(), n]
	if water.size() != n or surface_cls.size() != n or surface_moist.size() != n:
		return "water/surface_cls/surface_moist: длина ≠ %d" % n
	for hv in heights:
		if not is_finite(hv):
			return "heights: NaN или inf"
	return ""


## Климат центра места (W5 v3, v7): loc.climate на дату loc.month/day и loc.climate_lag на дату
## month/day − round(water.lag_days) (с переходом через год, как SurfaceHeat.water_temp_c) — для
## температуры воды. Оба = {tx_c, dtr_k, z_cell_m, has_hh1, has_hh5} — ClimateGrid.place так,
## как строит ctx weather_model.gd (высота долины из рельефа места). Нет сетки — has_* = false
## и запасные значения ClimateGrid. Возвращает climate.
func fill_climate() -> Dictionary:
	var loc: Dictionary = header.loc
	var g: Dictionary = Config.get_config("atmosphere").ground
	var ctx := WeatherModel.ground_context(
		Callable(self, "height_at"),
		float(g.reference_radius_m),
		int(g.reference_samples),
		float(WeatherModel.config().valley_percentile)
	)
	var month := int(loc.get("month", 7))
	var day := int(loc.get("day", 15))
	ctx.merge(
		{
			"month": month,
			"day": day,
			"lat": float(loc.get("center_lat", 52.0)),
			"lon": float(loc.get("center_lon", 0.0)),
		}
	)
	var climate := _climate_cell(ctx)
	# Дата воды: SurfaceHeat.water_temp_c (surface_heat.gd:93-98).
	var lag := int(round(float(SurfaceHeat.config().get("water", {}).get("lag_days", 30.0))))
	var doy := SunClock.day_of_year(month, day) - lag
	if doy < 1:
		doy += 365
	var md := SurfaceHeat._month_day(doy)
	var ctx_lag := ctx.duplicate()
	ctx_lag["month"] = md.x
	ctx_lag["day"] = md.y
	loc.climate = climate
	loc.climate_lag = _climate_cell(ctx_lag)
	header.loc = loc
	return climate


static func _climate_cell(ctx: Dictionary) -> Dictionary:
	var cp := ClimateGrid.place(ctx)
	var src: Dictionary = cp.src
	return {
		"tx_c": float(cp.tx_c),
		"dtr_k": float(cp.dtr_k),
		"z_cell_m": float(cp.z_cell_m),
		"has_hh1": String(src.hh1) != "none",
		"has_hh5": String(src.hh5) != "none",
	}


func grid_width() -> int:
	return int(header.grid.width)


func grid_height() -> int:
	return int(header.grid.height)


## Высота, м MSL: рельеф игры, если место из него (путь прежний), иначе билинейно по растру;
## вне сетки — ближайший край.
func height_at(x: float, z: float) -> float:
	if terrain != null and is_instance_valid(terrain):
		return float(terrain.call("height_at", x, z))
	return raster_height(x, z)


func raster_height(x: float, z: float) -> float:
	var g: Dictionary = header.grid
	var w := int(g.width)
	var h := int(g.height)
	var inv := 1.0 / float(g.spacing)
	var u := clampf((x - float(g.origin_x)) * inv, 0.0, float(w - 1))
	var v := clampf((z - float(g.origin_z)) * inv, 0.0, float(h - 1))
	var i0 := mini(int(u), w - 2)
	var j0 := mini(int(v), h - 2)
	var fx := u - i0
	var fz := v - j0
	var k := j0 * w + i0
	var top := heights[k] + (heights[k + 1] - heights[k]) * fx
	var bot := heights[k + w] + (heights[k + w + 1] - heights[k + w]) * fx
	return top + (bot - top) * fz


## Сила источника термиков 0..1 без времени: рельеф игры или растр (нормаль × влажность).
func source_at(x: float, z: float) -> float:
	if terrain != null and is_instance_valid(terrain):
		if terrain.has_method("thermal_source_strength_at"):
			return float(terrain.call("thermal_source_strength_at", x, z))
		return float(terrain.call("sun_exposure_at", x, z))
	var e := maxf(float(header.grid.spacing), 1.0)
	var dx := (raster_height(x + e, z) - raster_height(x - e, z)) / (2.0 * e)
	var dz := (raster_height(x, z + e) - raster_height(x, z - e)) / (2.0 * e)
	var n := Vector3(-dx, 1.0, -dz).normalized()
	return clampf(raster_moist(x, z) * (0.35 + 0.8 * n.dot(_sun_n)), 0.0, 1.0)


## Влажность поверхности в ближайшем узле.
func raster_moist(x: float, z: float) -> float:
	return surface_moist[_nearest(x, z)]


## Класс поверхности в точке: terrain.surface_at или ближайший узел растра.
func surface_at(x: float, z: float) -> int:
	if terrain != null and is_instance_valid(terrain):
		return int(terrain.call("surface_at", x, z))
	return surface_cls[_nearest(x, z)]


func _nearest(x: float, z: float) -> int:
	var g: Dictionary = header.grid
	var w := int(g.width)
	var h := int(g.height)
	var inv := 1.0 / float(g.spacing)
	var i := clampi(roundi((x - float(g.origin_x)) * inv), 0, w - 1)
	var j := clampi(roundi((z - float(g.origin_z)) * inv), 0, h - 1)
	return j * w + i
