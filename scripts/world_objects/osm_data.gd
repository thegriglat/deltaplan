class_name OsmData
extends RefCounted
## Данные OpenStreetMap локации (osm.json в папке места, Locations.osm_path; необязательный файл места: встроенные места; дороги и вода читаются, ЛЭП, заборы и поля — нет).
## © OpenStreetMap contributors, ODbL. Координаты в файле — мир игры относительно центра файла;
## если центр рельефа другой, точки пересчитываются через широту/долготу (TerrainGeo).
## Формат — docs/guide/world-objects.md.

var attribution: String = ""
var roads: Array = []
var buildings: Array = []
var rivers: Array = []
var lakes: Array = []
var places: Array = []
var load_time_s: float = 0.0


## Загрузить файл; center_lat/lon — центр рельефа (NAN — оставить как в файле). null — нет файла.
static func load_file(path: String, center_lat: float = NAN, center_lon: float = NAN) -> OsmData:
	if not FileAccess.file_exists(path):
		push_warning("OsmData: нет %s" % path)
		return null
	var t0 := Time.get_ticks_usec()
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not d is Dictionary:
		push_error("OsmData: ошибка разбора " + path)
		return null
	var o := OsmData.new()
	o.attribution = String(d.get("attribution", ""))
	o.roads = d.get("roads", [])
	o.buildings = d.get("buildings", [])
	o.rivers = d.get("water", {}).get("rivers", [])
	o.lakes = d.get("water", {}).get("lakes", [])
	o.places = d.get("places", [])
	var lat0 := float(d.get("center_lat", 0.0))
	var lon0 := float(d.get("center_lon", 0.0))
	if (
		not is_nan(center_lat)
		and (absf(lat0 - center_lat) > 1.0e-7 or absf(lon0 - center_lon) > 1.0e-7)
	):
		o._reproject(lat0, lon0, center_lat, center_lon)
	o.load_time_s = (Time.get_ticks_usec() - t0) / 1.0e6
	return o


## Плоский массив [x, z, x, z…] → точки.
static func points(flat: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(flat.size() / 2)
	for i in out.size():
		out[i] = Vector2(float(flat[2 * i]), float(flat[2 * i + 1]))
	return out


func _reproject(lat0: float, lon0: float, lat1: float, lon1: float) -> void:
	var f := func(x: float, z: float) -> Vector2:
		var ll := TerrainGeo.local_to_latlon(x, z, lat0, lon0)
		return TerrainGeo.latlon_to_local(ll.x, ll.y, lat1, lon1)
	for arr in [roads, rivers, lakes]:
		for item: Dictionary in arr:
			# у водоёмов ещё острова-дыры h: [[x, z…]…] (мультиполигоны OSM)
			var rings: Array = [item.p]
			rings.append_array(item.get("h", []))
			for p: Array in rings:
				for i in range(0, p.size() - 1, 2):
					var v: Vector2 = f.call(float(p[i]), float(p[i + 1]))
					p[i] = v.x
					p[i + 1] = v.y
	for b in buildings:
		var v: Vector2 = f.call(float(b[0]), float(b[1]))
		b[0] = v.x
		b[1] = v.y
	for pl in places:
		var v: Vector2 = f.call(float(pl.x), float(pl.z))
		pl.x = v.x
		pl.z = v.y
