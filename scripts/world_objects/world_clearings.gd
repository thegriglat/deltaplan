class_name WorldClearings
extends RefCounted
## Просеки для расстановки деревьев рельефа: где деревьев быть не должно —
## дороги (ширина + обочина), коридоры ЛЭП, здания с отступом, поля посадок.
## Маска-картинка L8 (255 — расчищено) в координатах мира; строится из data/osm/<id>.json,
## configs/locations/<id>.json (центр, landing_sites) и
## configs/world_objects.json (посадки, параметры — раздел clearings).
## Без нод, можно звать из terrain.
##   var c := WorldClearings.build_for("altai")
##   c.is_clear_at(x, z)  /  c.image, c.origin (x, z угла пикселя 0,0), c.cell_m

const CLEAR := 255

var image: Image
## Мир (x, z) левого верхнего угла пикселя (0, 0): x растёт вправо (восток), z — вниз (юг).
var origin: Vector2 = Vector2.ZERO
var cell_m: float = 10.0
var build_time_s: float = 0.0


## Маска для локации. null — нет конфига локации.
static func build_for(location_id: String) -> WorldClearings:
	var loc: Dictionary = Config.get_config("locations/" + location_id)
	if loc.is_empty():
		return null
	var cfg := WorldObjects.load_config()
	var lat0 := float(loc.center_lat)
	var lon0 := float(loc.center_lon)
	var half := float(cfg.osm.half_size_m)
	var layers: Array = loc.get("dem", {}).get("layers", [])
	if not layers.is_empty():
		half = float(layers[0].size_km) * 500.0
	var path := String(cfg.osm.data_path).replace("{id}", location_id)
	var osm := OsmData.load_file(path, lat0, lon0)
	var landings: Array = []
	for spec in WorldObjects.landing_specs(cfg.landing, location_id, loc.get("landing_sites", [])):
		var p := TerrainGeo.latlon_to_local(float(spec.lat), float(spec.lon), lat0, lon0)
		landings.append(spec.merged({"x": p.x, "z": p.y}, true))
	var tracks: Array = []
	if bool(cfg.start_tracks.get("enabled", true)):
		var starts: Array = []
		for s in loc.get("start_sites", []):
			var p := TerrainGeo.latlon_to_local(float(s.lat), float(s.lon), lat0, lon0)
			starts.append({"position": Vector3(p.x, 0.0, p.y)})
		var dem_dir := String(loc.get("data_dir", "res://data/terrain/" + location_id))
		var height_fn := _load_height_fn(dem_dir)
		if height_fn.is_valid():
			tracks = StartTracks.plan(starts, osm, cfg.start_tracks, height_fn)
	var c := WorldClearings.new()
	c.build(osm, landings, cfg, half, tracks)
	return c


## Высота по данным рельефа локации (<data_dir>/meta.json), как Terrain.height_at, но без
## живой ноды Terrain — только для процедурных троп (StartTracks). Невалидный Callable — нет данных.
static func _load_height_fn(dir: String) -> Callable:
	var meta_text := FileAccess.get_file_as_string(dir.path_join("meta.json"))
	var meta: Variant = JSON.parse_string(meta_text)
	if not meta is Dictionary or not (meta as Dictionary).has("layers"):
		return Callable()
	var layers: Array[HeightLayer] = []
	for info in meta.layers:
		var l := HeightLayer.load_from_file(dir.path_join(String(info.file)), info)
		if l != null:
			layers.append(l)
	if layers.is_empty():
		return Callable()
	return func(x: float, z: float) -> float:
		for l in layers:
			if l.contains(x, z):
				return l.sample(x, z)
		return layers[layers.size() - 1].sample(x, z)


## osm может быть null (только посадки). landings — спецификации посадок с x, z (мир).
## tracks — тропы к стартам (StartTracks.plan), мир (x, z) — не растут деревья.
func build(
	osm: OsmData, landings: Array, cfg: Dictionary, half_size_m: float, tracks: Array = []
) -> void:
	var t0 := Time.get_ticks_usec()
	var cc: Dictionary = cfg.clearings
	cell_m = float(cc.cell_m)
	var n := ceili(2.0 * half_size_m / cell_m)
	origin = Vector2(-half_size_m, -half_size_m)
	image = Image.create_empty(n, n, false, Image.FORMAT_L8)
	if osm != null:
		_roads(osm.roads, cfg.roads.classes, float(cc.road_margin_m))
		_power(osm.power, cfg.power, cc)
		_buildings(osm.buildings, float(cc.building_margin_m))
	for l in landings:
		_landing(l, float(cc.landing_margin_m))
	var track_half := float(cfg.start_tracks.width_m) * 0.5 + float(cc.start_track_margin_m)
	for pts in tracks:
		if (pts as PackedVector2Array).size() >= 2:
			stamp_line(pts, track_half)
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


func _roads(roads: Array, classes: Dictionary, margin: float) -> void:
	for r in roads:
		if classes.has(r.t):
			stamp_line(OsmData.points(r.p), float(classes[r.t][0]) * 0.5 + margin)


func _power(lines: Array, pcfg: Dictionary, cc: Dictionary) -> void:
	for l in lines:
		var high := (
			String(l.get("k", "line")) == "line"
			and (float(l.get("v", 0.0)) <= 0.0 or float(l.v) >= float(pcfg.high_voltage_kv))
		)
		var w := float(cc.power_corridor_high_m if high else cc.power_corridor_low_m)
		stamp_line(OsmData.points(l.p), w * 0.5)


func _buildings(buildings: Array, margin: float) -> void:
	for b in buildings:
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
