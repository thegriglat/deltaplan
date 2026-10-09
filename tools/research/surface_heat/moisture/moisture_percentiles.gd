extends Node
## Перцентили поля влажности рельефа TerrainRelief.moisture по суше слоя detail (SH-1).
## Запуск: XDG_DATA_HOME=$(mktemp -d) godot --headless --path . res://tools/research/surface_heat/moisture/moisture_percentiles.tscn -- out=<каталог> step=50

const PLACES := ["altai", "askarovo", "aushkul", "ongudai"]
const PCTS := [1, 5, 10, 25, 50, 75, 90, 95, 99]
const WATER := 6


func _pct(a: PackedFloat32Array, p: float) -> float:
	if a.is_empty():
		return NAN
	var i := clampi(roundi(p / 100.0 * (a.size() - 1)), 0, a.size() - 1)
	return a[i]


func _ready() -> void:
	var out_dir := "tools/research/surface_heat/moisture"
	var step := 50.0
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=")
		if kv[0] == "out":
			out_dir = kv[1]
		elif kv[0] == "step":
			step = float(kv[1])
	var result := {}
	var pooled := PackedFloat32Array()
	for place in PLACES:
		var terrain := Terrain.new()
		terrain.location_id = ""
		if not terrain.load_location(place):
			push_error("не загрузилась %s" % place)
			get_tree().quit(1)
			return
		terrain.wait_relief()
		var b := terrain.detail_bounds()
		var all := PackedFloat32Array()
		var by_class := {}
		var n_total := 0
		var x := b.position.x + step * 0.5
		while x < b.end.x:
			var z := b.position.y + step * 0.5
			while z < b.end.y:
				n_total += 1
				var sl: SurfaceLayer = terrain._surface_layer_at(x, z)
				var c := sl.class_at(x, z) if sl != null else 0
				if c != WATER:
					var m := terrain.moisture_at(x, z)
					all.append(m)
					if not by_class.has(c):
						by_class[c] = PackedFloat32Array()
					by_class[c].append(m)
				z += step
			x += step
		all.sort()
		var r := {"n_total": n_total, "n_land": all.size(), "step_m": step, "pct": {}, "by_class": {}}
		for p in PCTS:
			r["pct"][str(p)] = snappedf(_pct(all, p), 0.001)
		var s := 0.0
		for v in all:
			s += v
		r["mean"] = snappedf(s / maxf(all.size(), 1), 0.001)
		for c in by_class:
			var a: PackedFloat32Array = by_class[c]
			a.sort()
			r["by_class"][SurfaceLayer.CLASS_NAMES[c]] = {
				"n": a.size(), "p10": snappedf(_pct(a, 10), 0.001),
				"p50": snappedf(_pct(a, 50), 0.001), "p90": snappedf(_pct(a, 90), 0.001)
			}
		result[place] = r
		pooled.append_array(all)
		terrain.free()
	pooled.sort()
	var pr := {"n_land": pooled.size(), "pct": {}}
	for p in PCTS:
		pr["pct"][str(p)] = snappedf(_pct(pooled, p), 0.001)
	result["pooled"] = pr
	var f := FileAccess.open(out_dir.path_join("moisture_percentiles.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(result, "  "))
	f.close()
	var csv := "place,n_land," + ",".join(PCTS.map(func(p): return "p%d" % p)) + ",mean\n"
	for place in PLACES:
		var r: Dictionary = result[place]
		csv += "%s,%d," % [place, r["n_land"]]
		csv += ",".join(PCTS.map(func(p): return str(r["pct"][str(p)]))) + ",%s\n" % r["mean"]
	csv += "pooled,%d," % pooled.size() + ",".join(PCTS.map(func(p): return str(pr["pct"][str(p)]))) + ",\n"
	var g := FileAccess.open(out_dir.path_join("moisture_percentiles.csv"), FileAccess.WRITE)
	g.store_string(csv)
	g.close()
	print(csv)
	get_tree().quit(0)
