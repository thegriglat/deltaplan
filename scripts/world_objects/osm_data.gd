class_name OsmData
extends RefCounted
## Данные OpenStreetMap места из наших тайлов (контракт O9, docs/contracts/osm-tiles.md): разобранные тайлы
## 3x3 (OsmTileReader) переводятся из координат тайла (O1) в мир места (x восток, z юг, м; центр — центр
## места, проекция TerrainGeo). Объекты вне ±(half_m + запас) отбрасываются, линии клипуются.
## © OpenStreetMap contributors, ODbL.

const ATTRIBUTION := "© OpenStreetMap contributors"

const ROAD_CLASSES := [
	"motorway", "trunk", "primary", "secondary", "tertiary", "motorway_link", "trunk_link",
	"primary_link", "secondary_link", "tertiary_link", "unclassified", "residential", "living_street", "road"
]
const AERIALWAY_CLASSES := [
	"cable_car", "gondola", "chair_lift", "mixed_lift", "drag_lift", "t-bar", "j-bar", "platter",
	"rope_tow", "magic_carpet", "zip_line", "goods", "other"
]
const AEROWAY_CLASSES := ["aerodrome", "airstrip", "helipad", "runway", "aerodrome", "airstrip", "helipad"]
const VERTICAL_CLASSES := ["mast", "tower", "chimney", "wind"]
const RAIL_CLASSES := ["rail", "narrow_gauge"]

## [{t, p: PackedVector2Array (x, z), w: float (м, 0 — нет), lanes, tunnel, bridge, grade}]
var roads: Array = []
## [{t: "river"|"canal", named, p}]
var rivers: Array = []
## [{t, tunnel, bridge, p}]
var rail: Array = []
## [[x, z, w, l, угол_град, высота_стен_м, крыша 0|1]] — формат BuildingPlacer (w — вдоль направления угла).
var buildings: Array = []
## [{minor, p}]
var power: Array = []
var towers: PackedVector2Array = PackedVector2Array()
## [{t, p}]
var aerialways: Array = []
## [{t, kind: "point"|"line"|"area", p}]
var aeroways: Array = []
## [{t, comm, x, z, h}]
var verticals: Array = []
## [{x, z, ele (NAN — нет), name ("" — нет)}]
var peaks: Array = []
var passes: Array = []
var attribution: String = ""
## Тайлов с данными (включая пустые «none») и недостающих.
var tiles_ok: int = 0
var tiles_missing: int = 0
var load_time_s: float = 0.0


func is_empty() -> bool:
	return (
		roads.is_empty() and rivers.is_empty() and rail.is_empty() and buildings.is_empty()
		and power.is_empty() and towers.is_empty() and aerialways.is_empty() and aeroways.is_empty()
		and verticals.is_empty() and peaks.is_empty() and passes.is_empty()
	)


## Данные места из его папки: osm_tiles.json (стадия OsmTilesStage) и кеш тайлов. Нет файла/тайлов —
## пустой OsmData (не null). Разбор тайлов — на рабочих потоках.
static func load_for(place_dir: String, center_lat: float, center_lon: float, half_m: float,
		cache_dir: String = "") -> OsmData:
	var t0 := Time.get_ticks_usec()
	var d: OsmData
	var path := place_dir.path_join("osm_tiles.json")
	var listing: Variant = null
	if FileAccess.file_exists(path):
		listing = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not listing is Dictionary:
		d = OsmData.new()
		d.load_time_s = (Time.get_ticks_usec() - t0) / 1.0e6
		return d
	var root := cache_dir if cache_dir != "" else OsmTilesStage.cache_root()
	var jobs: Array = []
	var missing := 0
	var empty := 0
	for e: Variant in (listing as Dictionary).get("tiles", []):
		if not e is Array or (e as Array).size() < 3:
			continue
		var state := String(e[2])
		if state == "ok":
			jobs.append(root.path_join("%d/%d.dpt" % [int(e[0]), int(e[1])]))
		elif state == "none":
			empty += 1
		else:
			missing += 1
	var results: Array = decode_files(jobs)
	var tiles: Array = []
	for r: Variant in results:
		if r is Dictionary and not (r as Dictionary).is_empty():
			tiles.append(r)
		else:
			missing += 1
	d = from_tiles_parallel(tiles, center_lat, center_lon, half_m)
	d.tiles_ok = tiles.size() + empty
	d.tiles_missing = missing
	d.load_time_s = (Time.get_ticks_usec() - t0) / 1.0e6
	return d


## Прочитать и разобрать файлы тайлов на рабочих потоках (по задаче на файл); результат — по порядку
## путей, пустой словарь — файл не читается/битый.
static func decode_files(paths: Array) -> Array:
	var out: Array = []
	out.resize(paths.size())
	if paths.is_empty():
		return out
	var task := func(k: int) -> void:
		var bytes := FileAccess.get_file_as_bytes(paths[k])
		out[k] = OsmTileReader.read(bytes) if not bytes.is_empty() else {}
	var gid := WorkerThreadPool.add_group_task(task, paths.size(), -1, true, "osm tiles decode")
	WorkerThreadPool.wait_for_group_task_completion(gid)
	return out


## То же, что from_tiles, но тайлы переводятся в мир на рабочих потоках (по задаче на тайл), результаты
## склеиваются в порядке тайлов. Конфиг читается здесь, на вызывающем потоке.
static func from_tiles_parallel(tile_dicts: Array, center_lat: float, center_lon: float, half_m: float) -> OsmData:
	var cfg: Dictionary = Config.get_config("osm_tiles")
	if tile_dicts.size() < 2:
		return from_tiles(tile_dicts, center_lat, center_lon, half_m, cfg)
	var parts: Array = []
	parts.resize(tile_dicts.size())
	var task := func(k: int) -> void:
		parts[k] = from_tiles([tile_dicts[k]], center_lat, center_lon, half_m, cfg)
	var gid := WorkerThreadPool.add_group_task(task, tile_dicts.size(), -1, true, "osm tiles to world")
	WorkerThreadPool.wait_for_group_task_completion(gid)
	var o := OsmData.new()
	for p: OsmData in parts:
		o.roads.append_array(p.roads)
		o.rivers.append_array(p.rivers)
		o.rail.append_array(p.rail)
		o.buildings.append_array(p.buildings)
		o.power.append_array(p.power)
		o.towers.append_array(p.towers)
		o.aerialways.append_array(p.aerialways)
		o.aeroways.append_array(p.aeroways)
		o.verticals.append_array(p.verticals)
		o.peaks.append_array(p.peaks)
		o.passes.append_array(p.passes)
	o.tiles_ok = tile_dicts.size()
	if not o.is_empty():
		o.attribution = ATTRIBUTION
	return o


## Тайлы (словари OsmTileReader.read) → данные места. half_m — полуразмер квадрата места, м.
static func from_tiles(tile_dicts: Array, center_lat: float, center_lon: float, half_m: float,
		cfg: Dictionary = {}) -> OsmData:
	if cfg.is_empty():
		cfg = Config.get_config("osm_tiles")
	var o := OsmData.new()
	var lim := half_m + float(cfg.get("margin_m", 200.0))
	var rule: Dictionary = cfg.get("height_rule", {})
	var type_rule := _type_rule_table(rule)
	var level_m := float(rule.get("level_m", 3.0))
	var m := OsmGrid.m_per_deg()
	var mlon_c := m * cos(deg_to_rad(center_lat))
	for t: Dictionary in tile_dicts:
		if t.is_empty():
			continue
		var j := int(t.j)
		var org := OsmGrid.origin_d(j, int(t.i))
		var sx := mlon_c / OsmGrid.kx(j)
		var ox := (org[1] - center_lon) * mlon_c
		var oz := -(org[0] - center_lat) * m
		var tf := Transform2D(Vector2(sx, 0.0), Vector2(0.0, -1.0), Vector2(ox, oz))
		var st: Dictionary = t.streams
		for name: String in ["roads", "track"]:
			for r: Dictionary in st.get(name, []):
				for seg in _clip(_xf(r.pts, tf), lim):
					var item := {"t": "track" if name == "track" else ROAD_CLASSES[clampi(int(r.cls), 0, 13)],
						"p": seg, "w": 0.1 * float(r.width_dm) if r.width_dm != null else 0.0,
						"lanes": int(r.lanes) if r.lanes != null else 0,
						"tunnel": r.tunnel, "bridge": r.bridge, "grade": int(r.cls) if name == "track" else 0}
					o.roads.append(item)
		for name: String in ["river", "canal"]:
			for r: Dictionary in st.get(name, []):
				for seg in _clip(_xf(r.pts, tf), lim):
					o.rivers.append({"t": name, "named": (int(r.flags) & 1) != 0, "p": seg})
		for r: Dictionary in st.get("rail", []):
			for seg in _clip(_xf(r.pts, tf), lim):
				o.rail.append({"t": RAIL_CLASSES[clampi(int(r.cls), 0, 1)], "tunnel": (int(r.flags) & 8) != 0,
					"bridge": (int(r.flags) & 16) != 0, "p": seg})
		for r: Dictionary in st.get("powerline", []):
			for seg in _clip(_xf(r.pts, tf), lim):
				o.power.append({"minor": (int(r.flags) & 1) != 0, "p": seg})
		for r: Dictionary in st.get("power_tower", []):
			for q in _xf(r.pts, tf):
				if absf(q.x) <= lim and absf(q.y) <= lim:
					o.towers.append(q)
		for r: Dictionary in st.get("aerialway", []):
			for seg in _clip(_xf(r.pts, tf), lim):
				o.aerialways.append({"t": AERIALWAY_CLASSES[clampi(int(r.cls), 0, 12)], "p": seg})
		for r: Dictionary in st.get("aeroway", []):
			var cls := clampi(int(r.cls), 0, 6)
			var kind := "point" if cls <= 2 else ("line" if cls == 3 else "area")
			var pts := _xf(r.pts, tf)
			if kind == "line":
				for seg in _clip(pts, lim):
					o.aeroways.append({"t": AEROWAY_CLASSES[cls], "kind": kind, "p": seg})
			elif _any_inside(pts, lim):  # точка и площадь — тайл центроида, без клипа
				o.aeroways.append({"t": AEROWAY_CLASSES[cls], "kind": kind, "p": pts})
		for r: Dictionary in st.get("vertical", []):
			var q: Vector2 = _xf(r.pts, tf)[0] if not (r.pts as PackedVector2Array).is_empty() else Vector2(INF, INF)
			if absf(q.x) <= lim and absf(q.y) <= lim:
				o.verticals.append({"t": VERTICAL_CLASSES[clampi(int(r.cls), 0, 3)], "comm": (int(r.flags) & 1) != 0,
					"x": q.x, "z": q.y, "h": float(r.h)})
		# имена: сначала вершины с флагом, затем перевалы с флагом (O3.NAMES)
		var names: Array = st.get("names", [])
		var ni := 0
		for pair: Array in [["peak", o.peaks], ["pass", o.passes]]:
			for r: Dictionary in st.get(pair[0], []):
				var nm := ""
				if (int(r.flags) & 1) != 0:
					if ni < names.size():
						nm = String(names[ni])
					ni += 1
				var pts := _xf(r.pts, tf)
				if pts.is_empty() or absf(pts[0].x) > lim or absf(pts[0].y) > lim:
					continue
				(pair[1] as Array).append({"x": pts[0].x, "z": pts[0].y,
					"ele": float(r.h) if int(r.h) > 0 else NAN, "name": nm})
		for b: Dictionary in st.get("buildings", []):
			var c := tf * Vector2(float(b.x), float(b.y))
			if absf(c.x) > lim or absf(c.y) > lim:
				continue
			var w := 0.5 * float(b.l2)  # вдоль длинной стороны (направление угла)
			var l := 0.5 * float(b.w2)
			var rr := _house_rule(type_rule, int(b.type), w * l)
			var hq := int(b.hq)
			var wall_h := 0.5 * float(hq) if hq > 0 else float(rr.height_m) if rr.height_m > 0.0 else float(rr.levels) * level_m
			# O3: угол от востока против часовой (север вверх) → мир (z на юг): минус
			o.buildings.append([c.x, c.y, w, l, fposmod(-float(b.angle), 180.0), wall_h, int(rr.roof)])
	o.tiles_ok = tile_dicts.size()
	if not o.is_empty():
		o.attribution = ATTRIBUTION
	return o


# ---------- правило высоты дома (O9) ----------

## Тип O3 → правило группы {levels, height_m, roof, area_levels}.
static func _type_rule_table(rule: Dictionary) -> Dictionary:
	var out := {}
	var groups: Dictionary = rule.get("groups", {})
	for g: Dictionary in groups.values():
		if not g is Dictionary:
			continue
		for ty: Variant in g.get("types", []):
			out[int(ty)] = g
	return out


## {levels, height_m, roof} по типу и площади следа (м²).
static func _house_rule(table: Dictionary, type: int, area: float) -> Dictionary:
	var g: Dictionary = table.get(type, table.get(26, {}))
	if g.is_empty():
		return {"levels": 2, "height_m": 0.0, "roof": 1}
	var roof := int(g.get("flat", 1))
	var levels := int(g.get("levels", 0))
	var hm := float(g.get("height_m", 0.0))
	if g.has("area_levels"):
		for row: Array in g.area_levels:
			if area < float(row[0]):
				levels = int(row[1])
				if row.size() > 2:
					roof = int(row[2])
				break
	return {"levels": levels, "height_m": hm, "roof": roof}


# ---------- геометрия ----------

static func _xf(pts: PackedVector2Array, tf: Transform2D) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(pts.size())
	for k in pts.size():
		out[k] = tf * pts[k]
	return out


static func _any_inside(pts: PackedVector2Array, lim: float) -> bool:
	for q in pts:
		if absf(q.x) <= lim and absf(q.y) <= lim:
			return true
	return false


## Ломаная → куски внутри квадрата [-lim, lim]² (Лианга — Барски по звеньям); куски длиннее одной точки.
static func _clip(pts: PackedVector2Array, lim: float) -> Array:
	var out: Array = []
	var cur := PackedVector2Array()
	for k in pts.size() - 1:
		var a := pts[k]
		var b := pts[k + 1]
		var d := b - a
		var t0 := 0.0
		var t1 := 1.0
		var ok := true
		for ax in 2:
			var p: float
			var q0: float
			var q1: float
			if ax == 0:
				p = d.x
				q0 = a.x
			else:
				p = d.y
				q0 = a.y
			q1 = lim - q0
			var q2 := -lim - q0
			if absf(p) < 1.0e-12:
				if q0 < -lim or q0 > lim:
					ok = false
					break
			else:
				var ta := q2 / p
				var tb := q1 / p
				if ta > tb:
					var tmp := ta
					ta = tb
					tb = tmp
				t0 = maxf(t0, ta)
				t1 = minf(t1, tb)
				if t0 > t1:
					ok = false
					break
		if not ok:
			if cur.size() >= 2:
				out.append(cur)
			cur = PackedVector2Array()
			continue
		var pa := a + d * t0
		var pb := a + d * t1
		if cur.is_empty():
			cur.append(pa)
		elif cur[cur.size() - 1].distance_squared_to(pa) > 1.0e-6:
			if cur.size() >= 2:
				out.append(cur)
			cur = PackedVector2Array([pa])
		cur.append(pb)
		if t1 < 1.0:  # вышли из окна — кусок закончен
			out.append(cur)
			cur = PackedVector2Array()
	if cur.size() >= 2:
		out.append(cur)
	return out
