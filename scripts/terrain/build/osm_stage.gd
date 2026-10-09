class_name OsmStage
extends RefCounted
## Стадия OSM сборки места (OA-К3, OA-4): запрос Overpass на квадрат ±половина detail → osm.json (OA-К2),
## канал воды A в detail_detail10.png и water_fraction в surface.json.
## Порт tools/osm/fetch_osm.py (упаковщики) и tools/terrain/osm_water.py (вода 10 м) — результат
## должен совпадать с Python на тех же ответах Overpass (проверка: tools/terrain/parity/osm_parity.gd).

const EARTH_R_M := 6371008.8  # как scripts/terrain/geo.gd
const ATTRIBUTION := "© OpenStreetMap contributors, ODbL 1.0 (https://www.openstreetmap.org/copyright)"
const WIDTH_M := {"river": 25.0, "canal": 6.0, "stream": 4.0}
const DEFAULT_WIDTH_M := 4.0
const LAKE_SUPERSAMPLE := 4
const STAGE := "osm"

static var _cfg: Dictionary = {}

## Шов для тестов: клиент Overpass (по умолчанию новый).
var client: OverpassClient = OverpassClient.new()


# ---------------------------------------------------------------- стадия

func run(ctx: LocationBuildContext) -> Error:
	if ctx.offline:
		ctx.log_line("osm: сеть запрещена (offline)")
		return ERR_UNAVAILABLE
	if ctx.cancelled:
		return ERR_SKIP
	var sj_path := ctx.dir.path_join("surface.json")
	var png_path := ctx.dir.path_join("detail_detail10.png")
	if not FileAccess.file_exists(sj_path) or not FileAccess.file_exists(png_path):
		ctx.log_line("osm: нет surface.json / detail_detail10.png (стадия покрова не выполнена)")
		return ERR_FILE_NOT_FOUND
	var cfg := _osm_cfg()
	var half := 20000.0
	var layers: Array = ctx.spec.get("dem", {}).get("layers", [])
	if not layers.is_empty():
		half = float(layers[0].get("size_km", 40.0)) * 500.0
	var bbox := bbox_for(ctx.center_lat, ctx.center_lon, half)
	var world := _read_json("res://configs/world.json")
	var ua := String(world.get("runtime_terrain", {}).get("user_agent", "deltaplan-sim"))
	var timeout_s := int(cfg.get("timeout_s", 180))
	ctx.report(STAGE, 0.02)
	var bodies := await client.fetch_all(ctx, cfg.get("overpass_urls", []), bbox, timeout_s, ua)
	if bodies.is_empty():
		ctx.log_line("osm: Overpass недоступен (%s)" % client.last_error)
		return ERR_CANT_CONNECT if not ctx.cancelled else ERR_SKIP
	ctx.report(STAGE, 0.4)
	var result := {"err": OK}
	var job := func() -> void: result.merge(_process(bodies, ctx.key, ctx.center_lat, ctx.center_lon, half, ctx.dir), true)
	await run_threaded(ctx.host, job)
	for l: String in result.get("log", []):
		ctx.log_line(l)
	ctx.report(STAGE, 1.0)
	return int(result.get("err", OK))


## Тяжёлая часть вне главного потока: разбор JSON, упаковка, вода, запись файлов.
static func _process(bodies: Array, key: String, lat: float, lon: float, half: float, dir: String) -> Dictionary:
	var log: Array = []
	var elements: Array = []
	for body: PackedByteArray in bodies:
		var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
		if not parsed is Dictionary or not (parsed as Dictionary).has("elements"):
			return {"err": ERR_PARSE_ERROR, "log": ["osm: ответ Overpass не разобран"]}
		elements.append_array(parsed.elements)
	var osm := pack(elements, lat, lon, half)
	osm.location = key
	var f := FileAccess.open(dir.path_join("osm.json"), FileAccess.WRITE)
	if f == null:
		return {"err": FileAccess.get_open_error(), "log": ["osm: не открыть osm.json на запись"]}
	f.store_string(JSON.stringify(osm))
	f.close()
	var err := apply_water(dir, osm, log)
	return {"err": err, "log": log}


## Читает surface.json и detail_detail10.png, пишет A (вода) и water_fraction.
static func apply_water(dir: String, osm: Dictionary, log: Array = []) -> Error:
	var sj_path := dir.path_join("surface.json")
	var meta: Variant = JSON.parse_string(FileAccess.get_file_as_string(sj_path))
	if not meta is Dictionary:
		log.append("osm: surface.json не разобран")
		return ERR_PARSE_ERROR
	var entry: Dictionary = {}
	for l: Dictionary in meta.get("layers", []):
		if l.has("detail10"):
			entry = l
			break
	if entry.is_empty():
		log.append("osm: в surface.json нет detail10")
		return ERR_FILE_NOT_FOUND
	var d10: Dictionary = entry.detail10
	var img := Image.load_from_file(dir.path_join(String(d10.file)))
	if img == null or img.is_empty():
		log.append("osm: не прочитать " + String(d10.file))
		return ERR_FILE_CANT_READ
	img.convert(Image.FORMAT_LA8)
	var alpha := water_alpha(osm, d10)
	if alpha.get_width() != img.get_width() or alpha.get_height() != img.get_height():
		log.append("osm: размер канала воды не совпал с detail10")
		return ERR_INVALID_DATA
	var px := img.get_data()
	var a := alpha.get_data()
	var n := a.size()
	var wet := 0
	for i in n:
		px[i * 2 + 1] = a[i]
		if a[i] >= 128:
			wet += 1
	var out := Image.create_from_data(img.get_width(), img.get_height(), false, Image.FORMAT_LA8, px)
	var e := out.save_png(dir.path_join(String(d10.file)))
	if e != OK:
		return e
	d10["channels"] = "L — доля леса (0..255), A — доля воды (0..255: реки/ручьи/каналы/озёра OSM)"
	d10["water_fraction"] = snappedf(float(wet) / float(n), 0.0001)
	var f := FileAccess.open(sj_path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(meta, "  ") + "\n")
	f.close()
	return OK


## Выполнить callable в рабочем потоке; пока он идёт, кадры главного потока свободны.
static func run_threaded(host: Node, job: Callable) -> void:
	var tree: SceneTree = host.get_tree() if host != null and host.is_inside_tree() else null
	var tid := WorkerThreadPool.add_task(job, false, "osm_stage")
	if tree == null:
		WorkerThreadPool.wait_for_task_completion(tid)
		return
	while not WorkerThreadPool.is_task_completed(tid):
		await tree.process_frame
	WorkerThreadPool.wait_for_task_completion(tid)


# ---------------------------------------------------------------- конфиг, проекция

static func _read_json(path: String) -> Dictionary:
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return d if d is Dictionary else {}


static func _osm_cfg() -> Dictionary:
	if _cfg.is_empty():
		_cfg = _read_json("res://configs/world_objects.json").get("osm", {})
	return _cfg


static func _m_lat() -> float:
	return EARTH_R_M * PI / 180.0


## [юг, запад, север, восток] — квадрат ±half_m.
static func bbox_for(lat0: float, lon0: float, half_m: float) -> Array:
	var m_lat := _m_lat()
	var m_lon := m_lat * cos(deg_to_rad(lat0))
	var dlat := half_m / m_lat
	var dlon := half_m / m_lon
	return [lat0 - dlat, lon0 - dlon, lat0 + dlat, lon0 + dlon]


static func r1(v: float) -> float:
	return roundf_d(v, 10.0)


static func roundf_d(v: float, k: float) -> float:
	return round(v * k) / k


# ---------------------------------------------------------------- упаковка

class Proj:
	var lat0: float
	var lon0: float
	var m_lat: float
	var m_lon: float

	func _init(lat: float, lon: float) -> void:
		lat0 = lat
		lon0 = lon
		m_lat = OsmStage.EARTH_R_M * PI / 180.0
		m_lon = m_lat * cos(deg_to_rad(lat))

	func x(lon: float) -> float:
		return (lon - lon0) * m_lon

	func z(lat: float) -> float:
		return -(lat - lat0) * m_lat


static func _way_pts(proj: Proj, el: Dictionary) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	for g: Variant in el.get("geometry", []):
		if g is Dictionary and not (g as Dictionary).is_empty():
			out.append(proj.x(float(g.lon)))
			out.append(proj.z(float(g.lat)))
	return out


static func _flat(pts: PackedFloat64Array) -> Array:
	var out: Array = []
	out.resize(pts.size())
	for i in pts.size():
		out[i] = r1(pts[i])
	return out


static func _parse_float(v: Variant, default: float) -> float:
	if v == null:
		return default
	var s := str(v).split(";")[0].replace(",", ".").replace("m", "").strip_edges()
	if s.is_valid_float():
		return s.to_float()
	return default


## Минимальный описанный прямоугольник по рёбрам: [cx, cz, w, l, угол_рад].
static func _min_area_rect(pts: PackedFloat64Array) -> Array:
	var n := pts.size() / 2
	var best_area := INF
	var best_a := 0.0
	var b_u0 := 0.0
	var b_u1 := 0.0
	var b_v0 := 0.0
	var b_v1 := 0.0
	for i in n:
		var x0 := pts[i * 2]
		var z0 := pts[i * 2 + 1]
		var j := (i + 1) % n
		var a := atan2(pts[j * 2 + 1] - z0, pts[j * 2] - x0)
		var c := cos(a)
		var s := sin(a)
		var u0 := INF
		var u1 := -INF
		var v0 := INF
		var v1 := -INF
		for k in n:
			var x := pts[k * 2]
			var z := pts[k * 2 + 1]
			var u := x * c + z * s
			var v := -x * s + z * c
			u0 = minf(u0, u)
			u1 = maxf(u1, u)
			v0 = minf(v0, v)
			v1 = maxf(v1, v)
		var area := (u1 - u0) * (v1 - v0)
		if area < best_area:
			best_area = area
			best_a = a
			b_u0 = u0
			b_u1 = u1
			b_v0 = v0
			b_v1 = v1
	var c2 := cos(best_a)
	var s2 := sin(best_a)
	var cu := (b_u0 + b_u1) / 2.0
	var cv := (b_v0 + b_v1) / 2.0
	return [cu * c2 - cv * s2, cu * s2 + cv * c2, b_u1 - b_u0, b_v1 - b_v0, best_a]


## Элементы ответа Overpass → словарь OA-К2. Дубли по type/id — один раз; слой элемента определяется
## теми же условиями, что запросы (QUERIES в fetch_osm.py), порядок — как в ответе.
static func pack(elements: Array, center_lat: float, center_lon: float, half_m: float) -> Dictionary:
	var cfg := _osm_cfg()
	var proj := Proj.new(center_lat, center_lon)
	var classes: Array = cfg.get("road_classes", [])
	var roads: Array = []
	var buildings: Array = []
	var power: Array = []
	var supports := {}  # id узла → тег power
	var rivers: Array = []
	var lakes: Array = []
	var places: Array = []
	var fields: Array = []
	var fences: Array = []
	var seen := {"node": {}, "way": {}, "relation": {}}
	var power_ways: Array = []
	var re_place := ["city", "town", "village", "hamlet", "suburb", "isolated_dwelling"]
	for el_v: Variant in elements:
		if not el_v is Dictionary:
			continue
		var el: Dictionary = el_v
		var type := String(el.get("type", ""))
		if not seen.has(type):
			continue
		var id: Variant = el.get("id", null)
		if seen[type].has(id):
			continue
		seen[type][id] = true
		var tags: Dictionary = el.get("tags", {})
		if type == "node":
			var pw := String(tags.get("power", ""))
			if pw == "tower" or pw == "pole":
				supports[int(id)] = pw
			if tags.has("place") and String(tags.place) in re_place:
				var x := proj.x(float(el.lon))
				var z := proj.z(float(el.lat))
				places.append({"n": tags.get("name:ru", tags.get("name", "")), "t": tags.place,
					"x": r1(x), "z": r1(z), "pop": int(_parse_float(tags.get("population"), 0.0))})
		elif type == "way":
			if tags.has("highway"):
				var t := String(tags.highway)
				if t in classes:
					var pts := _way_pts(proj, el)
					if pts.size() >= 4:
						roads.append({"t": t, "p": _flat(pts)})
			if tags.has("building"):
				_pack_building(proj, el, tags, cfg, buildings)
			if String(tags.get("power", "")) in ["line", "minor_line"]:
				power_ways.append(el)
			var is_waterway := String(tags.get("waterway", "")) in ["river", "stream", "canal"]
			var is_water := String(tags.get("natural", "")) == "water"
			if is_waterway or is_water:
				if tags.has("waterway"):
					rivers.append({"t": tags.waterway, "n": tags.get("name", ""), "p": _flat(_way_pts(proj, el))})
				else:
					lakes.append({"n": tags.get("name", ""), "p": _flat(_way_pts(proj, el))})
			var is_fence := String(tags.get("barrier", "")) in ["fence", "wall"]
			var is_field := String(tags.get("landuse", "")) in ["meadow", "grass", "farmland"]
			if is_fence or is_field:
				if tags.has("barrier"):
					fences.append({"t": tags.barrier, "p": _flat(_way_pts(proj, el))})
				else:
					fields.append({"t": tags.get("landuse"), "p": _flat(_way_pts(proj, el))})
		elif type == "relation":
			if String(tags.get("natural", "")) == "water":
				_pack_water_relation(proj, el, tags, lakes)
	for el: Dictionary in power_ways:
		var tags: Dictionary = el.tags
		var pts := _way_pts(proj, el)
		if pts.size() < 4:
			continue
		var kv := _parse_float(tags.get("voltage"), 0.0) / 1000.0
		var cables := int(_parse_float(tags.get("cables"), 0.0))
		var nodes: Array = el.get("nodes", [])
		var flags: Array = []
		for nid: Variant in nodes:
			flags.append(1 if supports.get(int(nid), "") in ["tower", "pole"] else 0)
		if flags.size() != pts.size() / 2:
			flags = []
			flags.resize(pts.size() / 2)
			flags.fill(1)
		power.append({"k": tags.power, "v": r1(kv), "c": cables, "p": _flat(pts), "s": flags})
	var bb := bbox_for(center_lat, center_lon, half_m)
	var bbox_out: Array = []
	for v: float in bb:
		bbox_out.append(roundf_d(v, 100000.0))
	return {
		"attribution": ATTRIBUTION,
		"location": "",
		"center_lat": center_lat,
		"center_lon": center_lon,
		"bbox_latlon": bbox_out,
		"roads": roads,
		"buildings": buildings,
		"power": power,
		"water": {"rivers": rivers, "lakes": lakes},
		"places": places,
		"landuse": {"fields": fields, "fences": fences},
	}


static func _pack_building(proj: Proj, el: Dictionary, tags: Dictionary, cfg: Dictionary, out: Array) -> void:
	var pts := _way_pts(proj, el)
	var n := pts.size() / 2
	if n < 4:
		return
	if pts[0] == pts[pts.size() - 2] and pts[1] == pts[pts.size() - 1]:
		pts.resize(pts.size() - 2)
	var rect := _min_area_rect(pts)
	var min_size := float(cfg.get("min_building_size_m", 2.0))
	if rect[2] < min_size or rect[3] < min_size:
		return
	var kind := String(tags.get("building", "yes"))
	var levels := _parse_float(tags.get("building:levels"), 0.0)
	var height := _parse_float(tags.get("height"), 0.0)
	if height <= 0.0:
		if levels <= 0.0:
			var dl: Dictionary = cfg.get("default_levels", {})
			levels = float(dl.get(kind, dl.get("_other", 1)))
		height = levels * float(cfg.get("level_height_m", 3.0))
	var roof := String(tags.get("roof:shape", ""))
	var flat_roof: bool = roof == "flat" or (roof == "" and (
		levels >= float(cfg.get("flat_roof_min_levels", 3)) or kind in cfg.get("flat_roof_kinds", [])))
	out.append([r1(rect[0]), r1(rect[1]), r1(rect[2]), r1(rect[3]), roundf_d(rad_to_deg(rect[4]), 10.0),
		r1(height), 1 if flat_roof else 0])


static func _pack_water_relation(proj: Proj, el: Dictionary, tags: Dictionary, lakes: Array) -> void:
	var outer_parts: Array = []
	var inner_parts: Array = []
	for m: Dictionary in el.get("members", []):
		var role := String(m.get("role", ""))
		if (role == "outer" or role == "inner") and m.get("geometry"):
			var geom: Array = []
			for g: Variant in m.geometry:
				if g is Dictionary and not (g as Dictionary).is_empty():
					geom.append([float(g.lat), float(g.lon)])
			(outer_parts if role == "outer" else inner_parts).append(geom)
	var outers: Array = []
	for r: Array in _join_rings(outer_parts):
		outers.append(_ring_xz(proj, r))
	var inners: Array = []
	for r: Array in _join_rings(inner_parts):
		inners.append(_ring_xz(proj, r))
	var holes: Array = []
	for _o in outers:
		holes.append([])
	for inner: PackedFloat64Array in inners:
		for k in outers.size():
			if _point_in_ring(inner[0], inner[1], outers[k]):
				holes[k].append(_flat(inner))
				break
	for k in outers.size():
		var lake := {"n": tags.get("name", ""), "p": _flat(outers[k])}
		if not (holes[k] as Array).is_empty():
			lake["h"] = holes[k]
		lakes.append(lake)


static func _ring_xz(proj: Proj, ring: Array) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	for g: Array in ring:
		out.append(proj.x(g[1]))
		out.append(proj.z(g[0]))
	return out


static func _same(a: Array, b: Array) -> bool:
	return a[0] == b[0] and a[1] == b[1]


## Замкнутые кольца мультиполигона из линий-участников (по совпадающим концам); не замкнувшееся
## стыковкой кольцо замыкается хордой при заливке (как в fetch_osm.py join_rings).
static func _join_rings(parts: Array) -> Array:
	var left: Array = []
	for p: Array in parts:
		if p.size() >= 2:
			left.append(p.duplicate())
	var rings: Array = []
	while not left.is_empty():
		var ring: Array = left.pop_front()
		while not _same(ring[0], ring[ring.size() - 1]):
			var found := false
			for k in left.size():
				var p: Array = left[k]
				var pl: Array = p[p.size() - 1]
				var rl: Array = ring[ring.size() - 1]
				if _same(p[0], rl):
					ring.append_array(p.slice(1))
				elif _same(pl, rl):
					var tail := p.slice(0, p.size() - 1)
					tail.reverse()
					ring.append_array(tail)
				elif _same(pl, ring[0]):
					ring = p.slice(0, p.size() - 1) + ring
				elif _same(p[0], ring[0]):
					var head := p.slice(1)
					head.reverse()
					ring = head + ring
				else:
					continue
				left.remove_at(k)
				found = true
				break
			if not found:
				break
		if ring.size() >= 3:
			rings.append(ring)
	return rings


static func _point_in_ring(x: float, z: float, ring: PackedFloat64Array) -> bool:
	var inside := false
	var n := ring.size() / 2
	for i in n:
		var j := (i + 1) % n
		var x0 := ring[i * 2]
		var z0 := ring[i * 2 + 1]
		var x1 := ring[j * 2]
		var z1 := ring[j * 2 + 1]
		if (z0 > z) != (z1 > z) and x < (x1 - x0) * (z - z0) / (z1 - z0) + x0:
			inside = not inside
	return inside


# ---------------------------------------------------------------- вода 10 м

## Канал воды: L8 на сетке detail10 (width, height, spacing_m, origin_x_m, origin_z_m), 0..255.
## Реки — полосы по классу ширины (антиалиас ~1 клетка), озёра — полигоны с супервыборкой 4×4 и дырами-островами.
static func water_alpha(osm: Dictionary, info10: Dictionary) -> Image:
	var w := int(info10.width)
	var h := int(info10.height)
	var s := float(info10.spacing_m)
	var ox := float(info10.origin_x_m)
	var oz := float(info10.origin_z_m)
	var mask := PackedFloat32Array()
	mask.resize(w * h)
	var water: Dictionary = osm.get("water", {})
	_river_coverage(mask, w, h, s, ox, oz, water.get("rivers", []))
	_lake_coverage(mask, w, h, s, ox, oz, water.get("lakes", []))
	var bytes := PackedByteArray()
	bytes.resize(w * h)
	for i in mask.size():
		bytes[i] = int(round(mask[i] * 255.0))
	return Image.create_from_data(w, h, false, Image.FORMAT_L8, bytes)


static func _river_coverage(mask: PackedFloat32Array, w: int, h: int, s: float, ox: float, oz: float, rivers: Array) -> void:
	for river: Dictionary in rivers:
		var p: Array = river.p
		var width: float = WIDTH_M.get(river.get("t"), DEFAULT_WIDTH_M)
		var r := width / 2.0
		var gain := minf(1.0, width / s)
		for k in range(0, p.size() - 3, 2):
			var x0: float = p[k]
			var z0: float = p[k + 1]
			var x1: float = p[k + 2]
			var z1: float = p[k + 3]
			var i0 := maxi(int(floor((minf(x0, x1) - r - s - ox) / s)), 0)
			var i1 := mini(int(ceil((maxf(x0, x1) + r + s - ox) / s)), w - 1)
			var j0 := maxi(int(floor((minf(z0, z1) - r - s - oz) / s)), 0)
			var j1 := mini(int(ceil((maxf(z0, z1) + r + s - oz) / s)), h - 1)
			if i0 > i1 or j0 > j1:
				continue
			var dx := x1 - x0
			var dz := z1 - z0
			var len2 := dx * dx + dz * dz
			for j in range(j0, j1 + 1):
				var gz := oz + j * s
				var row := j * w
				for i in range(i0, i1 + 1):
					var gx := ox + i * s
					var t := 0.0
					if len2 > 0.0:
						t = clampf(((gx - x0) * dx + (gz - z0) * dz) / len2, 0.0, 1.0)
					var d := sqrt((gx - (x0 + t * dx)) ** 2 + (gz - (z0 + t * dz)) ** 2)
					var cov := clampf((r - d) / s + 0.5, 0.0, 1.0) * gain
					if cov > mask[row + i]:
						mask[row + i] = cov


static func _lake_coverage(mask: PackedFloat32Array, w: int, h: int, s: float, ox: float, oz: float, lakes: Array) -> void:
	var ss := LAKE_SUPERSAMPLE
	var inv := 1.0 / float(ss * ss)
	for lake: Dictionary in lakes:
		var p: Array = lake.p
		if p.size() < 6:
			continue
		var rings: Array = [p]
		for hole: Array in lake.get("h", []):
			if hole.size() >= 6:
				rings.append(hole)
		var xmin := INF
		var xmax := -INF
		var zmin := INF
		var zmax := -INF
		for k in range(0, p.size() - 1, 2):
			xmin = minf(xmin, p[k])
			xmax = maxf(xmax, p[k])
			zmin = minf(zmin, p[k + 1])
			zmax = maxf(zmax, p[k + 1])
		var i0 := maxi(0, int(floor((xmin - ox) / s)) - 1)
		var i1 := mini(w - 1, int(ceil((xmax - ox) / s)) + 1)
		var j0 := maxi(0, int(floor((zmin - oz) / s)) - 1)
		var j1 := mini(h - 1, int(ceil((zmax - oz) / s)) + 1)
		if i0 > i1 or j0 > j1:
			continue
		var lw := i1 - i0 + 1
		var lh := j1 - j0 + 1
		var hw := lw * ss  # ширина в подвыборках
		var nsub := lh * ss
		# пересечения рёбер с центрами подстрок: подстрока sy — линия y = sy + 0.5
		var xs: Array = []
		xs.resize(nsub)
		for sy in nsub:
			xs[sy] = []
		for ring: Array in rings:
			var n := ring.size() / 2
			for e in n:
				var f := (e + 1) % n
				var ax := ((float(ring[e * 2]) - ox) / s - i0) * ss
				var ay := ((float(ring[e * 2 + 1]) - oz) / s - j0) * ss
				var bx := ((float(ring[f * 2]) - ox) / s - i0) * ss
				var by := ((float(ring[f * 2 + 1]) - oz) / s - j0) * ss
				if ay == by:
					continue
				var y_lo := minf(ay, by)
				var y_hi := maxf(ay, by)
				var s0 := maxi(int(ceil(y_lo - 0.5)), 0)
				var s1 := mini(int(ceil(y_hi - 0.5)) - 1, nsub - 1)
				var k := (bx - ax) / (by - ay)
				for sy in range(s0, s1 + 1):
					(xs[sy] as Array).append(ax + (sy + 0.5 - ay) * k)
		var cnt := PackedInt32Array()
		cnt.resize(lw)
		for cj in lh:
			cnt.fill(0)
			var any := false
			for q in ss:
				var cr: Array = xs[cj * ss + q]
				if cr.size() < 2:
					continue
				cr.sort()
				for m in range(0, cr.size() - 1, 2):
					var a := maxi(int(ceil(cr[m] - 0.5)), 0)
					var b := mini(int(ceil(cr[m + 1] - 0.5)) - 1, hw - 1)
					if a > b:
						continue
					any = true
					var ca := a / ss
					var cb := b / ss
					if ca == cb:
						cnt[ca] += b - a + 1
					else:
						cnt[ca] += (ca + 1) * ss - a
						cnt[cb] += b - cb * ss + 1
						for c in range(ca + 1, cb):
							cnt[c] += ss
			if not any:
				continue
			var row := (j0 + cj) * w + i0
			for c in lw:
				var cov := float(cnt[c]) * inv
				if cov > mask[row + c]:
					mask[row + c] = cov
