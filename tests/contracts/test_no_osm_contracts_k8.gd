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


## К8 v4: EggPlace без дорог OSM, с places().
func test_k8_v4_interface() -> void:
	var m := _methods("res://scripts/world_objects/egg_place.gd")
	for f in ["places", "nearest_place", "near_water_m", "find_point"]:
		check(m.has(f), "EggPlace.%s" % f)
	for f in ["roads", "road_maybe_near", "nearest_road_m"]:
		check(not m.has(f), "EggPlace.%s удалён (К8 v4)" % f)
