class_name WorldClearings
extends RefCounted
## Просеки для расстановки деревьев рельефа: где деревьев быть не должно —
## поля посадок, тропы к стартам, дома посёлков.
## Маска-картинка L8 (255 — расчищено) в координатах мира; строится из
## configs/locations/<id>.json (центр, landing_sites) и
## configs/world_objects.json (посадки, параметры — раздел clearings).
## Без нод, можно звать из terrain.
##   var c := WorldClearings.build_for("altai")
##   c.is_clear_at(x, z)  /  c.image, c.origin (x, z угла пикселя 0,0), c.cell_m

const CLEAR := 255
## Половина стороны маски, если у места нет слоёв рельефа, м.
const DEFAULT_HALF_SIZE_M := 20000.0

var image: Image
## Мир (x, z) левого верхнего угла пикселя (0, 0): x растёт вправо (восток), z — вниз (юг).
var origin: Vector2 = Vector2.ZERO
var cell_m: float = 10.0
var build_time_s: float = 0.0


## Маска для локации без живого рельефа (превью, инструменты): PlaceData из файлов. null — нет конфига.
static func build_for(location_id: String) -> WorldClearings:
	return build_from(PlaceData.from_files(location_id))


## Маска по общим данным места (FL-К2): рельеф, OSM и план домов — из PlaceData, без чтения файлов.
## Расчищено только там, где объекты стоят: дома плана (тот же, что расставляет WorldObjects), дворы,
## дороги и ж/д OSM, тропы к стартам, посадки. null — нет данных или конфига места.
static func build_from(pd: PlaceData) -> WorldClearings:
	if pd == null:
		return null
	var location_id := pd.location_id
	var loc: Dictionary = Locations.config(location_id)
	if loc.is_empty():
		return null
	var cfg := WorldObjects.load_config()
	var lat0 := float(loc.center_lat)
	var lon0 := float(loc.center_lon)
	var half := DEFAULT_HALF_SIZE_M
	var layers: Array = loc.get("dem", {}).get("layers", [])
	if not layers.is_empty():
		half = float(layers[0].size_km) * 500.0
	var landings: Array = []
	for spec in WorldObjects.landing_specs(cfg.landing, location_id, loc.get("landing_sites", [])):
		var p := TerrainGeo.latlon_to_local(float(spec.lat), float(spec.lon), lat0, lon0)
		landings.append(spec.merged({"x": p.x, "z": p.y}, true))
	var tracks: Array = []
	if bool(cfg.start_tracks.get("enabled", true)) and not pd.layers.is_empty():
		var starts: Array = []
		for s in loc.get("start_sites", []):
			var p := TerrainGeo.latlon_to_local(float(s.lat), float(s.lon), lat0, lon0)
			starts.append({"position": Vector3(p.x, 0.0, p.y)})
		tracks = StartTracks.plan(starts, cfg.start_tracks, pd.height_at)
	var c := WorldClearings.new()
	c.build(landings, cfg, half, tracks, pd.house_plan, pd.osm)
	return c


## Пятна застройки места по id (без ноды Terrain); пустые, если места или файлов нет.
static func patches_for_location(location_id: String) -> BuiltPatches:
	var loc: Dictionary = Locations.config(location_id)
	if loc.is_empty():
		return BuiltPatches.new()
	return VillagePlacer.patches_for_dir(
		Locations.data_dir(location_id)
	)


## landings — спецификации посадок с x, z (мир).
## tracks — тропы к стартам (StartTracks.plan), мир (x, z) — не растут деревья.
## osm — данные OSM места: просека вдоль дорог (ширина класса + обочина), без тоннелей.
func build(
	landings: Array,
	cfg: Dictionary,
	half_size_m: float,
	tracks: Array = [],
	houses: Array = [],
	osm: OsmData = null
) -> void:
	var t0 := Time.get_ticks_usec()
	var cc: Dictionary = cfg.clearings
	cell_m = float(cc.cell_m)
	var n := ceili(2.0 * half_size_m / cell_m)
	origin = Vector2(-half_size_m, -half_size_m)
	image = Image.create_empty(n, n, false, Image.FORMAT_L8)
	# линии (дороги, ж/д, тропы) — основная работа маски
	var lines: Array = []
	var track_half := float(cfg.start_tracks.width_m) * 0.5 + float(cc.start_track_margin_m)
	for pts in tracks:
		if (pts as PackedVector2Array).size() >= 2:
			lines.append([pts, track_half])
	if osm != null:
		var rm := float(cc.get("road_margin_m", 3.0))
		_line_list(lines, osm.roads, cfg.get("roads", {}).get("classes", {}), rm)
		_line_list(lines, osm.rail, cfg.get("rail", {}).get("classes", {}), rm)
	stamp_lines(lines)
	if osm != null:
		_buildings(osm.buildings, float(cc.get("building_margin_m", 4.0)))
	for l in landings:
		_landing(l, float(cc.landing_margin_m))
	var margin := float(cc.get("house_margin_m", 3.0))
	for b: Array in houses:
		stamp(float(b[0]), float(b[1]), maxf(float(b[2]), float(b[3])) * 0.5 + margin)
	build_time_s = (Time.get_ticks_usec() - t0) / 1.0e6


## Расчищено ли место (деревьев здесь быть не должно)? За пределами маски — нет.
func is_clear_at(x: float, z: float) -> bool:
	var i := floori((x - origin.x) / cell_m)
	var j := floori((z - origin.y) / cell_m)
	if i < 0 or j < 0 or i >= image.get_width() or j >= image.get_height():
		return false
	return image.get_pixel(i, j).r > 0.5


## Квадрат со стороной 2r вокруг точки.
func stamp(x: float, z: float, r: float) -> void:
	var i0 := floori((x - r - origin.x) / cell_m)
	var j0 := floori((z - r - origin.y) / cell_m)
	var i1 := floori((x + r - origin.x) / cell_m)
	var j1 := floori((z + r - origin.y) / cell_m)
	var rect := Rect2i(i0, j0, i1 - i0 + 1, j1 - j0 + 1).intersection(
		Rect2i(0, 0, image.get_width(), image.get_height())
	)
	if rect.has_area():
		image.fill_rect(rect, Color(1, 1, 1))


## Полоса полуширины half вдоль ломаной.
func stamp_line(pts: PackedVector2Array, half: float) -> void:
	var step := maxf(minf(half, cell_m), 1.0)
	for i in pts.size() - 1:
		var a := pts[i]
		var b := pts[i + 1]
		var k := maxi(1, ceili(a.distance_to(b) / step))
		for s in k + 1:
			var p := a.lerp(b, float(s) / k)
			stamp(p.x, p.y, half)


## Полосы [[ломаная, полуширина], …] (stamp_line каждой). Подряд на вызывающем потоке: проба по полосам
## картинки на WorkerThreadPool (FL-4) была вдвое медленнее (13,5 тыс. линий точки −27.7, −48.8: 1,3 с против 0,67 с).
func stamp_lines(lines: Array) -> void:
	for ln: Array in lines:
		stamp_line(ln[0], float(ln[1]))


## Дороги / ж/д нужных классов (не тоннели) → [ломаная, полуширина просеки] в lines.
static func _line_list(lines: Array, items: Array, classes: Dictionary, margin: float) -> void:
	for r: Dictionary in items:
		if classes.has(r.t) and not bool(r.get("tunnel", false)) and (r.p as PackedVector2Array).size() >= 2:
			lines.append([r.p, float(classes[r.t][0]) * 0.5 + margin])


func _buildings(buildings: Array, margin: float) -> void:
	for b: Array in buildings:
		stamp(float(b[0]), float(b[1]), Vector2(float(b[2]), float(b[3])).length() * 0.5 + margin)


func _landing(l: Dictionary, margin: float) -> void:
	var c := Vector2(float(l.x), float(l.z))
	if l.get("axis_deg") == null:  # ось считается по рельефу — берём описанный квадрат
		stamp(c.x, c.y, maxf(float(l.length_m), float(l.width_m)) * 0.5 + margin)
		return
	var hd := deg_to_rad(float(l.axis_deg))
	var ax := Vector2(sin(hd), -cos(hd))
	var rt := Vector2(-ax.y, ax.x)
	var ha := float(l.length_m) * 0.5 + margin
	var hb := float(l.width_m) * 0.5 + margin
	var r := Vector2(ha, hb).length()
	for i in range(
		floori((c.x - r - origin.x) / cell_m), floori((c.x + r - origin.x) / cell_m) + 1
	):
		for j in range(
			floori((c.y - r - origin.y) / cell_m), floori((c.y + r - origin.y) / cell_m) + 1
		):
			if i < 0 or j < 0 or i >= image.get_width() or j >= image.get_height():
				continue
			var d := origin + Vector2(i + 0.5, j + 0.5) * cell_m - c
			if absf(d.dot(ax)) <= ha and absf(d.dot(rt)) <= hb:
				image.set_pixel(i, j, Color(1, 1, 1))
