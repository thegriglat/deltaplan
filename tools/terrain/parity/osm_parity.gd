extends SceneTree
## Паритет стадии OSM (OA-4) с Python без сети:
##   godot --headless --path . -s res://tools/terrain/parity/osm_parity.gd
## 1) сырые ответы Overpass ~/.cache/deltaplan_osm/<id>_<слой>.json → OsmStage.pack → сравнение с data/osm/<id>.json
##    (без _doc; числа ±0,1 м; порядок элементов — как в ответе);
## 2) канал воды OsmStage.water_alpha(data/osm/<id>.json) против A в data/terrain/<id>/detail_detail10.png
##    (IoU по порогу 128 = 0,5).
## Печатает osm_mismatch_total, water_iou_min, stage_seconds_max.

const IDS := ["askarovo", "altai"]
const LAYERS := ["roads", "buildings", "power", "water", "places", "landuse"]
const TOL := 0.1001
const THRESHOLD := 128


func _initialize() -> void:
	var mismatch_total := 0
	var iou_min := 1.0
	var sec_max := 0.0
	for id: String in IDS:
		var cache := OS.get_environment("HOME").path_join(".cache/deltaplan_osm/%s_%%s.json" % id)
		var elements: Array = []
		for layer: String in LAYERS:
			var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(cache % layer))
			if not raw is Dictionary:
				print("нет кеша Overpass: ", cache % layer)
				quit(2)
				return
			elements.append_array(raw.elements)
		var loc: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://configs/locations/%s.json" % id))
		var half := float(loc.dem.layers[0].size_km) * 500.0
		var t0 := Time.get_ticks_usec()
		var packed := OsmStage.pack(elements, float(loc.center_lat), float(loc.center_lon), half)
		var t_pack := (Time.get_ticks_usec() - t0) / 1.0e6
		var ref: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/osm/%s.json" % id))
		# round-trip через JSON — как в файле
		var got: Dictionary = JSON.parse_string(JSON.stringify(packed))
		var per := {}
		var total := 0
		for key in ["roads", "buildings", "power", "places"]:
			per[key] = _diff_list(got[key], ref[key])
		per["rivers"] = _diff_list(got.water.rivers, ref.water.rivers)
		per["lakes"] = _diff_list(got.water.lakes, ref.water.lakes)
		per["fields"] = _diff_list(got.landuse.fields, ref.landuse.fields)
		per["fences"] = _diff_list(got.landuse.fences, ref.landuse.fences)
		per["meta"] = 0
		for k in ["center_lat", "center_lon"]:
			if absf(float(got[k]) - float(ref[k])) > 1e-9:
				per["meta"] += 1
		if not _eq(got.bbox_latlon, ref.bbox_latlon, 1e-5 + 1e-9):
			per["meta"] += 1
		if String(got.attribution) != String(ref.attribution):
			per["meta"] += 1
		for k: String in per:
			total += int(per[k])
		mismatch_total += total
		print("%s: расхождений %d  %s; элементов: дорог %d, зданий %d, ЛЭП %d, рек %d, озёр %d, мест %d, полей %d, заборов %d" % [
			id, total, per, got.roads.size(), got.buildings.size(), got.power.size(), got.water.rivers.size(),
			got.water.lakes.size(), got.places.size(), got.landuse.fields.size(), got.landuse.fences.size()])
		# вода из data/osm/<id>.json (эталон Python) против A встроенной маски
		var sj: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/terrain/%s/surface.json" % id))
		var d10: Dictionary = {}
		for l: Dictionary in sj.layers:
			if l.has("detail10"):
				d10 = l.detail10
		t0 = Time.get_ticks_usec()
		var alpha := OsmStage.water_alpha(ref, d10)
		var t_water := (Time.get_ticks_usec() - t0) / 1.0e6
		var img := Image.load_from_file("res://data/terrain/%s/%s" % [id, d10.file])
		img.convert(Image.FORMAT_LA8)
		var iou := _iou(alpha.get_data(), img.get_data())
		iou_min = minf(iou_min, iou)
		sec_max = maxf(sec_max, t_pack + t_water)
		print("%s: water_iou=%.4f pack=%.1f c water_alpha=%.1f c" % [id, iou, t_pack, t_water])
	print("osm_mismatch_total=%d" % mismatch_total)
	print("water_iou_min=%.4f" % iou_min)
	print("stage_seconds_max=%.1f" % sec_max)
	quit()


func _iou(a: PackedByteArray, la: PackedByteArray) -> float:
	var inter := 0
	var uni := 0
	for i in a.size():
		var x := a[i] >= THRESHOLD
		var y := la[i * 2 + 1] >= THRESHOLD
		if x and y:
			inter += 1
		if x or y:
			uni += 1
	return float(inter) / float(maxi(uni, 1))


## Порядок элементов не важен (слои склеены в один запрос): сортировка по ключу из первых чисел.
func _key(e: Variant) -> String:
	var nums: Array = []
	if e is Dictionary:
		for k in ["p", "x", "z"]:
			if e.has(k):
				var v: Variant = e[k]
				nums.append_array(v.slice(0, 2) if v is Array else [v])
		nums.append(String(e.get("t", "")))
		nums.append(String(e.get("n", "")))
		nums.append(str(e.get("p", []).size() if e.get("p") is Array else 0))
	elif e is Array:
		nums = (e as Array).slice(0, 4)
	var out := ""
	for n in nums:
		out += (str(snappedf(float(n), 1.0)) if (n is float or n is int) else str(n)) + "|"
	return out


func _sorted(a: Array) -> Array:
	var keyed: Array = []
	for e in a:
		keyed.append([_key(e), e])
	keyed.sort_custom(func(x: Array, y: Array) -> bool: return x[0] < y[0])
	var out: Array = []
	for k in keyed:
		out.append(k[1])
	return out


func _diff_list(a_in: Array, b_in: Array) -> int:
	var a := _sorted(a_in)
	var b := _sorted(b_in)
	var bad := absi(a.size() - b.size())
	for i in mini(a.size(), b.size()):
		if not _eq(a[i], b[i], TOL):
			if bad == absi(a.size() - b.size()):
				print("  первое расхождение [%d]: игра %s | эталон %s" % [i, str(a[i]).left(200), str(b[i]).left(200)])
			bad += 1
	return bad


func _eq(a: Variant, b: Variant, tol: float) -> bool:
	if a is Dictionary and b is Dictionary:
		if (a as Dictionary).size() != (b as Dictionary).size():
			return false
		for k: Variant in a:
			if not (b as Dictionary).has(k) or not _eq(a[k], b[k], tol):
				return false
		return true
	if a is Array and b is Array:
		if (a as Array).size() != (b as Array).size():
			return false
		for i in (a as Array).size():
			if not _eq(a[i], b[i], tol):
				return false
		return true
	if (a is float or a is int) and (b is float or b is int):
		return absf(float(a) - float(b)) <= tol
	return a == b
