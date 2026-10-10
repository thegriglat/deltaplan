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


## N4: Overpass-клиента нет.
func test_n4_no_overpass() -> void:
	check(not ResourceLoader.exists("res://scripts/terrain/build/overpass_client.gd"), "overpass_client.gd удалён")


## N4 v3: OSM возвращён из своих тайлов (OsmData, OsmLayer, RoadMesher разрешены); Overpass, OsmStage, osm.json у мест
## и Locations.osm_path по-прежнему отсутствуют.
func test_n4_v2_no_osm() -> void:
	check(not ResourceLoader.exists("res://scripts/terrain/build/osm_stage.gd"), "osm_stage.gd удалён")
	var loc: GDScript = Locations
	var names: Array = []
	for m: Dictionary in loc.get_script_method_list():
		names.append(m.name)
	check(not names.has("osm_path"), "Locations.osm_path удалён")
	for id in PLACES:
		check(not FileAccess.file_exists(Locations.data_dir(id) + "/osm.json"), "%s: osm.json удалён" % id)
