extends Node
## Счёт деревьев города над Алматы (CityTreePlan): время подготовки и число деревьев по видам в радиусе от точки.
##   XDG_DATA_HOME=$(mktemp -d) godot --headless --path . res://tools/shots/city_trees_count.tscn -- [--r=1100] [--x=0 --z=0]
## Без --x/--z — центр места; --all — все тайлы с данными (число над всем городом).


func _ready() -> void:
	var base := "/home/greg/deltaplan_data/osm_tiles/OT-6/out_a/v1"
	var lat := 43.238
	var lon := 76.945
	var r := 1100.0
	var cx := 0.0
	var cz := 0.0
	var all := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--r="):
			r = float(a.substr(4))
		elif a.begins_with("--x="):
			cx = float(a.substr(4))
		elif a.begins_with("--z="):
			cz = float(a.substr(4))
		elif a == "--all":
			all = true
	var paths: Array = []
	for t in OsmGrid.neighbors(lat, lon):
		var p := "%s/%d/%d.dpt" % [base, t.x, t.y]
		if FileAccess.file_exists(p):
			paths.append(p)
	var d := OsmData.from_tiles_parallel(OsmData.decode_files(paths), lat, lon, 12000.0)
	var cfg := WorldObjects.load_config()
	BuildingStyle.release()
	var tc: Dictionary = cfg.city_trees
	var plan := CityTreePlan.new()
	plan.setup(tc, d.roads, d.rivers, d.buildings, [], cfg.roads, cfg.city_ground, 200.0, func(_x: float, _z: float) -> float: return 0.0)
	plan.model_height.fill(14.0)
	var t0 := Time.get_ticks_usec()
	plan.prepare()
	print("prepare %.2f с, %s; дорог %d домов %d" % [(Time.get_ticks_usec() - t0) / 1.0e6, plan.stats, d.roads.size(), d.buildings.size()])
	var tile := float(tc.tile_m)
	var n := {"street": 0, "yard": 0, "garden": 0}
	var tiles := 0
	var t1 := Time.get_ticks_usec()
	var rr := 12000.0 if all else r
	for tz in range(floori((cz - rr) / tile), floori((cz + rr) / tile) + 1):
		for tx in range(floori((cx - rr) / tile), floori((cx + rr) / tile) + 1):
			var t := plan.build_tile(tx, tz)
			tiles += 1
			for k in n:
				n[k] += int(t[k])
	var el := (Time.get_ticks_usec() - t1) / 1.0e6
	print("тайлов %d за %.2f с (%.1f мс/тайл), деревьев %s, всего %d" % [tiles, el, el * 1000.0 / tiles, n, n.street + n.yard + n.garden])
	get_tree().quit(0)
