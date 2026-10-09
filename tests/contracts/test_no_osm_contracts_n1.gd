extends TestCase
## Контрактные тесты модуля no-osm (docs/contracts/no-osm.md: N1–N4) и К8 v4 (docs/contracts/easter-eggs.md).
## Правка контракта (версия +1) — вместе с этим файлом. Поведение — тесты задач (terrain, world_objects).

const DOC := "res://docs/contracts/no-osm.md"
const EGGS_DOC := "res://docs/contracts/easter-eggs.md"
const VERSIONS := {"N1": 1, "N2": 1, "N3": 1, "N4": 1}
const PLACES := ["askarovo", "altai", "aushkul", "ongudai"]


func _doc_line(path: String, head: String) -> String:
	var text := FileAccess.get_file_as_string(path)
	var at := text.find(head)
	return text.substr(at, text.find("\n", at) - at) if at >= 0 else ""


func _methods(path: String) -> Array:
	if not ResourceLoader.exists(path):
		return []
	var scr: Script = load(path)
	return scr.get_script_method_list().map(func(m: Dictionary) -> String: return m.name)


## N1: файлы застройки у встроенных мест, та же сетка, что detail10.
func test_n1_files() -> void:
	for id in PLACES:
		var dir := "res://data/terrain/%s/" % id
		var surf: Variant = JSON.parse_string(FileAccess.get_file_as_string(dir + "surface.json"))
		check(surf is Dictionary, "%s: surface.json" % id)
		if not surf is Dictionary:
			continue
		var det: Dictionary = {}
		for l in surf.get("layers", []):
			if String(l.get("id", "")) == "detail":
				det = l
		var b10: Dictionary = det.get("built10", {})
		check(not b10.is_empty(), "%s: surface.json → layers[detail].built10" % id)
		for k in ["file", "patches_file", "built_fraction", "patches"]:
			check(b10.has(k), "%s: built10.%s" % [id, k])
		var img := Image.load_from_file(dir + "detail_built10.png")
		check(img != null, "%s: detail_built10.png читается" % id)
		if img != null:
			check(img.get_format() == Image.FORMAT_L8, "%s: built10 — L8" % id)
			var d10: Dictionary = det.get("detail10", {})
			check(
				img.get_width() == int(d10.get("width", -1)) and img.get_height() == int(d10.get("height", -1)),
				"%s: built10 той же сетки, что detail10" % id
			)
		var pj: Variant = JSON.parse_string(FileAccess.get_file_as_string(dir + "built_patches.json"))
		check(pj is Dictionary, "%s: built_patches.json" % id)
		if not pj is Dictionary:
			continue
		check(int(pj.get("version", 0)) == 1, "%s: built_patches.version 1" % id)
		for k in ["source", "cell_m", "threshold", "min_area_m2", "patches"]:
			check(pj.has(k), "%s: built_patches.%s" % [id, k])
		var i := 0
		for p in pj.get("patches", []):
			check(int(p.get("id", -1)) == i, "%s: id пятен 0..N−1 по порядку" % id)
			for k in ["x", "z", "area_m2", "share", "bbox"]:
				check(p.has(k), "%s: пятно.%s" % [id, k])
			check(float(p.get("area_m2", 0.0)) >= float(pj.get("min_area_m2", 0.0)), "%s: area ≥ min" % id)
			check(p.get("bbox", []).size() == 4, "%s: bbox из 4 чисел" % id)
			i += 1
	# хотя бы у одного равнинного места с посёлками пятна есть
	var ask: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/terrain/askarovo/built_patches.json"))
	check(ask is Dictionary and ask.get("patches", []).size() > 0, "askarovo: пятна застройки есть")


## N2: интерфейс BuiltPatches; без места — пустой, без ошибок.
func test_n2_interface() -> void:
	var path := "res://scripts/terrain/built_patches.gd"
	var m := _methods(path)
	for f in ["for_terrain", "patches", "nearest", "share_at"]:
		check(m.has(f), "BuiltPatches.%s" % f)
	if not ResourceLoader.exists(path):
		return
	var cls: Script = load(path)
	var empty: Object = cls.call("for_terrain", null)
	check(empty != null and String(empty.get("source")) == "none", "for_terrain(null) → source none")
	if empty != null:
		check((empty.call("patches") as Array).is_empty(), "пустой: patches() = []")
		check((empty.call("nearest", 0.0, 0.0) as Dictionary).is_empty(), "пустой: nearest = {}")
		check(is_zero_approx(float(empty.call("share_at", 0.0, 0.0))), "пустой: share_at = 0")
