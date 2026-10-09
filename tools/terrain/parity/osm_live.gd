extends SceneTree
## Живая проверка стадии OSM (OA-9): один прогон по живому Overpass, вручную (не из dp accept):
##   godot --headless --path . -s res://tools/terrain/parity/osm_live.gd
## OsmStage.run на точке в Альпах (47.05, 11.0) и на центре askarovo; пишет build/osm_live.txt.
## Для askarovo — число объектов по слоям против data/terrain/askarovo/osm.json (OSM мог обновиться).

const POINTS := [["alps", 47.05, 11.0], ["askarovo", 53.26, 58.54]]
const OUT := "res://build/osm_live.txt"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var lines: PackedStringArray = []
	for p: Array in POINTS:
		var name: String = p[0]
		var d := "user://osm_live_" + name
		DirAccess.make_dir_recursive_absolute(d)
		var w := 4001
		var px := PackedByteArray()
		px.resize(w * w * 2)
		Image.create_from_data(w, w, false, Image.FORMAT_LA8, px).save_png(d.path_join("detail_detail10.png"))
		var sj := {"layers": [{"id": "detail", "detail10": {"file": "detail_detail10.png", "width": w, "height": w,
			"spacing_m": 10.0, "origin_x_m": -20000.0, "origin_z_m": -20000.0}}]}
		var f := FileAccess.open(d.path_join("surface.json"), FileAccess.WRITE)
		f.store_string(JSON.stringify(sj))
		f.close()
		var ctx := LocationBuildContext.new()
		ctx.key = "live_" + name
		ctx.center_lat = p[1]
		ctx.center_lon = p[2]
		ctx.dir = d
		ctx.spec = {"dem": {"layers": [{"size_km": 40}]}}
		ctx.host = root
		var st := OsmStage.new()
		var t0 := Time.get_ticks_msec()
		var err: Error = await st.run(ctx)
		var sec := (Time.get_ticks_msec() - t0) / 1000.0
		lines.append("%s_err=%d" % [name, err])
		lines.append("live_%s_seconds=%.1f" % [name, sec])
		lines.append("live_%s_requests=%d" % [name, ctx.net_requests])
		for s: Dictionary in st.client.stats:
			lines.append("%s_layer_%s: %.2f МБ, %.1f с, запросов %d, тайлов %d" % [
				name, s.layer, float(s.bytes) / 1.0e6, s.seconds, s.requests, s.tiles])
		for l in ctx.log_lines:
			lines.append("%s_log: %s" % [name, l])
		var osm: Variant = null
		if FileAccess.file_exists(d.path_join("osm.json")):
			osm = JSON.parse_string(FileAccess.get_file_as_string(d.path_join("osm.json")))
		if osm is Dictionary:
			var c := _counts(osm)
			lines.append("live_%s_roads=%d" % [name, c.roads])
			lines.append("%s_counts=%s" % [name, str(c)])
			if name == "askarovo":
				var ref: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/terrain/askarovo/osm.json"))
				lines.append("askarovo_ref_counts=%s" % str(_counts(ref)))
		else:
			lines.append("live_%s_roads=0" % name)
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://build"))
		var o := FileAccess.open(OUT, FileAccess.WRITE)
		o.store_string("\n".join(lines) + "\n")
		o.close()
	print("\n".join(lines))
	quit()


func _counts(o: Dictionary) -> Dictionary:
	return {"roads": o.roads.size(), "buildings": o.buildings.size(), "power": o.power.size(),
		"rivers": o.water.rivers.size(), "lakes": o.water.lakes.size(), "places": o.places.size(),
		"fields": o.landuse.fields.size(), "fences": o.landuse.fences.size()}
