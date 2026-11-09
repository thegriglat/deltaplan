extends Node
## LT-4: место W5 (json + bin) из рельефа игры для точки (Perdigão, Askervein) и станции в его кадре.
## Путь игры: Terrain.load_point (кеш/сборка user://locations/<ключ>: Copernicus GLO-30 25 м, WorldCover, реки) ->
## AirPlaceData.from_terrain (слой detail 25 м, вода, снимок поверхности) -> запись как у эталонов W8
## (tests/fixtures/wind/README.md): int16 высот со смещением h_offset и шагом h_scale, water, cls, moist (x 255).
##
##   XDG_DATA_HOME=~/.cache/dp-xdg/lee-turb-LT-4 godot --headless --path . \
##     res://tools/research/lee_turb/places/export_place.tscn -- --site=perdigao [--out=~/data/lee_turb/places]
## Выход: <out>/<site>.json, <site>.bin, <site>_stations.csv (site,station,lat,lon,x_game,z_game,
## ground_game_m,ground_asl_m) по станциям stations_in.csv этого места. Сеть нужна на первой сборке.

const SITES := {
	"perdigao": {
		"lat": 39.7098, "lon": -7.7370, "utc": 1.0, "month": 4, "day": 27,
		"start_station": "tse04",
		"note": "Perdigão (Португалия), центр между грядами tse04 и tse13; дата 27.04.2017 (случай NE), пояс WEST UTC+1",
	},
	"askervein": {
		"lat": 57.1908, "lon": -7.3738, "utc": 0.0, "month": 10, "day": 3,
		"start_station": "HT",
		"note": "Askervein Hill (о. Южный Уист), центр — вершина HT; дата 03.10.1983 (TU-03B), пояс UTC",
	},
}


func _ready() -> void:
	var a := {}
	for s in OS.get_cmdline_user_args():
		if s.begins_with("--"):
			var kv := s.substr(2).split("=", true, 1)
			a[kv[0]] = kv[1] if kv.size() > 1 else "1"
	await get_tree().process_frame
	var ok := await _run(a)
	get_tree().quit(0 if ok else 1)


func _run(a: Dictionary) -> bool:
	var site := String(a.get("site", ""))
	if not SITES.has(site):
		push_error("--site=perdigao|askervein")
		return false
	var cfg: Dictionary = SITES[site]
	var out := String(a.get("out", OS.get_environment("HOME") + "/data/lee_turb/places"))
	DirAccess.make_dir_recursive_absolute(out)
	var t0 := Time.get_ticks_msec()
	var terrain := Terrain.new()
	terrain.location_id = ""
	add_child(terrain)
	var failed := [false]
	terrain.load_failed.connect(func(m: String) -> void: failed[0] = true; push_error("load_failed: " + m))
	await terrain.load_point(float(cfg.lat), float(cfg.lon), "", true)
	if failed[0] or terrain.layers.is_empty():
		return false
	print("lee_turb: место %s собрано, %.1f с" % [terrain.location_id, (Time.get_ticks_msec() - t0) / 1000.0])
	var place := AirPlaceData.from_terrain(terrain, float(cfg.utc), int(cfg.month), int(cfg.day))
	if place == null:
		push_error("AirPlaceData.from_terrain: null")
		return false
	var why := place.validate()
	if why != "":
		push_error("место: " + why)
		return false
	var stations := _stations(site, terrain)
	var sites: Array = []
	for st: Dictionary in stations:
		if st.station == cfg.start_station:
			sites.append({"id": site + "_" + String(st.station), "x": st.x_game, "z": st.z_game, "h_msl": st.ground_game_m})
	place.header["start_sites"] = sites
	place.header.loc["id"] = site
	_write_place(place, site, out, String(cfg.note), terrain)
	_write_stations(site, out, stations)
	print("lee_turb: %s: %d станций, сетка %dx%d, всего %.1f с" % [
		site, stations.size(), place.grid_width(), place.grid_height(), (Time.get_ticks_msec() - t0) / 1000.0])
	return true


func _stations(site: String, terrain: Terrain) -> Array:
	var rows: Array = []
	var f := FileAccess.open("res://tools/research/lee_turb/places/stations_in.csv", FileAccess.READ)
	f.get_csv_line()
	while not f.eof_reached():
		var r := f.get_csv_line()
		if r.size() < 6 or r[0] != site:
			continue
		var p := terrain.latlon_to_local(float(r[3]), float(r[4]))
		rows.append({
			"station": r[1], "lat": float(r[3]), "lon": float(r[4]), "x_game": p.x, "z_game": p.y,
			"ground_game_m": terrain.height_at(p.x, p.y), "ground_asl_m": float(r[5]),
		})
	return rows


func _write_stations(site: String, out: String, rows: Array) -> void:
	var f := FileAccess.open("%s/%s_stations.csv" % [out, site], FileAccess.WRITE)
	f.store_line("site,station,lat,lon,x_game,z_game,ground_game_m,ground_asl_m")
	for r: Dictionary in rows:
		f.store_line("%s,%s,%.7f,%.7f,%.2f,%.2f,%.2f,%.2f" % [
			site, r.station, r.lat, r.lon, r.x_game, r.z_game, r.ground_game_m, r.ground_asl_m])


func _write_place(place: AirPlaceData, site: String, out: String, note: String, terrain: Terrain) -> void:
	var n := place.heights.size()
	var lo := INF
	var hi := -INF
	for h in place.heights:
		lo = minf(lo, h)
		hi = maxf(hi, h)
	var scale := 0.03125
	if (hi - lo) / scale > 65000.0:
		scale = (hi - lo) / 65000.0
	var off := snappedf((lo + hi) * 0.5, scale)
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	var maxerr := 0.0
	for i in n:
		var q := clampi(roundi((place.heights[i] - off) / scale), -32768, 32767)
		maxerr = maxf(maxerr, absf(off + q * scale - place.heights[i]))
		bytes.encode_s16(i * 2, q)
	bytes.append_array(place.water)
	bytes.append_array(place.surface_cls)
	var mo := PackedByteArray()
	mo.resize(n)
	for i in n:
		mo[i] = clampi(roundi(place.surface_moist[i] * 255.0), 0, 255)
	bytes.append_array(mo)
	var fb := FileAccess.open("%s/%s.bin" % [out, site], FileAccess.WRITE)
	fb.store_buffer(bytes)
	fb.close()
	var h := place.header.duplicate(true)
	h["h_offset"] = off
	h["h_scale"] = scale
	h["name"] = site
	h["note"] = note + "; слой detail 25 м, AirPlaceData.from_terrain (LT-4)"
	h["bin"] = {
		"bytes": bytes.size(), "h_max_err_m": maxerr,
		"layout": "heights int16 LE, water u8, cls u8, moist u8 (x 1/255); подряд, width*height узлов, строка j к +Z (W1)",
	}
	h["game_key"] = terrain.location_id
	h["game_center"] = {"lat": terrain.center_lat, "lon": terrain.center_lon}
	var fj := FileAccess.open("%s/%s.json" % [out, site], FileAccess.WRITE)
	fj.store_string(JSON.stringify(h, "\t", true) + "\n")
	fj.close()
