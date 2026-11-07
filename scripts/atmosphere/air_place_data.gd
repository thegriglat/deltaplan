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
## terrain — рельеф игры, если место собрано из него (from_terrain): height_at/surface_at берутся из
## него; без terrain высота — билинейно по растру, класс — ближайший узел.

const VERSION := 1

var header: Dictionary = {}
var heights := PackedFloat32Array()
var water := PackedByteArray()
var surface_cls := PackedByteArray()
var surface_moist := PackedFloat32Array()
## Рельеф игры; null — место задано одними растрами.
var terrain: Node = null


## Коды классов поверхности: имя → код (как SurfaceSnapshot / SurfaceLayer.CLASS_NAMES).
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


## Снимок рельефа игры для места (слой detail 25 м, маска воды, снимок поверхности — задачей пула,
## FL-9: читать после surface.wait() или surface.is_ready()), координаты, пояс часов (NAN —
## солнечное время), дата полёта, площадки старта. {detail, water, surface, loc, start_sites}.
## Сетки области решателя крейту не нужны (шаги не передаются).
static func terrain_snapshot(
	p_terrain: Node, utc_offset_h: float, month: int = 0, day: int = 0
) -> Dictionary:
	var detail: HeightLayer = null
	for l: HeightLayer in p_terrain.get("layers"):
		if l.id == "detail":
			detail = l
	var water: Image = null
	if detail != null and detail.water_texture != null:
		water = detail.water_texture.get_image()
		if water != null:
			water = water.duplicate()
			if water.is_compressed():
				water.decompress()
	var loc := {
		id = String(p_terrain.get("location_id")),
		center_lat = float(p_terrain.get("center_lat")),
		center_lon = float(p_terrain.get("center_lon")),
		utc_offset_h = utc_offset_h,
	}
	if month > 0 and day > 0:
		loc.month = month
		loc.day = day
	var sites: Array = []
	if p_terrain.has_method("get_start_sites"):
		for st: Dictionary in p_terrain.call("get_start_sites"):
			sites.append({id = String(st.id), position = st.position})
	return {
		detail = detail,
		water = water,
		surface = SurfaceSnapshot.start(p_terrain, detail, water),
		loc = loc,
		start_sites = sites,
	}


## Место из снимка terrain_snapshot (снимок поверхности уже готов). null — нет слоя detail или
## снимка поверхности, сетки не совпали (причина — в push_error).
static func from_snapshot(snap: Dictionary, p_terrain: Node, month: int, day: int) -> AirPlaceData:
	var detail: HeightLayer = snap.detail
	var sf: SurfaceSnapshot = snap.surface
	if detail == null or sf == null:
		push_error("AirPlaceData: нет слоя detail или снимка поверхности")
		return null
	sf.wait()
	if (
		sf.width != detail.width
		or sf.height != detail.height
		or sf.origin_x != detail.origin_x
		or sf.origin_z != detail.origin_z
	):
		push_error("AirPlaceData: сетка поверхности не совпала со слоем detail")
		return null
	var sites: Array = []
	for st: Dictionary in snap.start_sites:
		var sp: Vector3 = st.position
		sites.append({"id": String(st.id), "x": sp.x, "z": sp.z, "h_msl": sp.y})
	var loc: Dictionary = (snap.loc as Dictionary).duplicate()
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
		_water_nodes(snap.water, detail),
		sf.cls,
		sf.moist
	)
	p.terrain = p_terrain
	return p


## Место из рельефа игры, блокирующе (тесты, инструменты, генератор эталонов; игра — корутина
## Atmosphere.place_from_terrain). null — сетки не совпали или рельефа нет.
static func from_terrain(
	p_terrain: Node, utc_offset_h: float, month: int, day: int
) -> AirPlaceData:
	return from_snapshot(terrain_snapshot(p_terrain, utc_offset_h, month, day), p_terrain, month, day)


## Место из функций (превью и эталонный мир без карты): сетка width × height узлов с шагом spacing
## от (origin_x, origin_z); высота — height_fn(x, z), влажность поверхности — moist_fn(x, z) (0..1;
## множитель силы источников), вода нет, класс — луг. loc — {id, center_lat, center_lon,
## utc_offset_h, month, day}.
static func from_functions(
	height_fn: Callable, moist_fn: Callable, loc: Dictionary, origin_x: float, origin_z: float,
	spacing: float, width: int, height: int, start_sites: Array = []
) -> AirPlaceData:
	var n := width * height
	var hs := PackedFloat32Array()
	hs.resize(n)
	var moist := PackedFloat32Array()
	moist.resize(n)
	for j in height:
		var z := origin_z + spacing * j
		for i in width:
			var x := origin_x + spacing * i
			hs[j * width + i] = float(height_fn.call(x, z))
			moist[j * width + i] = clampf(float(moist_fn.call(x, z)), 0.0, 1.0)
	var cls := PackedByteArray()
	cls.resize(n)
	cls.fill(SurfaceLayer.GRASS)
	var grid := {
		"origin_x": origin_x, "origin_z": origin_z, "spacing": spacing, "width": width,
		"height": height,
	}
	var p := from_arrays(make_header(loc, grid, start_sites), hs, PackedByteArray(), cls, moist)
	p.water.resize(n)
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


## Входы крейта, которых нет в растрах (W5 v5, v9): header.model_hash (хеш GD-модели воздуха — нужен
## только ключу кеша полей; пусто — кеша нет). Уже заданное не перезаписывается.
func fill_crate_inputs() -> void:
	if not header.has("model_hash"):
		header["model_hash"] = AirModelHash.model_hash()


## Заголовок для load_place крейта (W5, json): utc_offset_h = NAN (солнечное время часов) крейту
## не передать — подставляется солнечное смещение долготы центра (center_lon / 15 ч).
func header_json() -> String:
	var h := header.duplicate(true)
	var loc: Dictionary = h.loc
	if not is_finite(float(loc.get("utc_offset_h", NAN))):
		loc["utc_offset_h"] = float(loc.get("center_lon", 0.0)) / 15.0
	return JSON.stringify(h)


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
