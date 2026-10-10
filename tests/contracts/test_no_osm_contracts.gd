extends TestCase
## Контрактные тесты модуля no-osm (docs/contracts/no-osm.md: N1–N4) и К8 v4 (docs/contracts/easter-eggs.md).
## Правка контракта (версия +1) — вместе с этим файлом. Поведение — тесты задач (terrain, world_objects).

const DOC := "res://docs/contracts/no-osm.md"
const EGGS_DOC := "res://docs/contracts/easter-eggs.md"
const VERSIONS := {"N1": 1, "N2": 2, "N3": 1, "N4": 3, "N5": 1}
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


func test_versions_in_doc() -> void:
	for id in VERSIONS:
		check(
			_doc_line(DOC, "## %s." % id).contains("(v%d," % VERSIONS[id]),
			"%s v%d в docs/contracts/no-osm.md" % [id, VERSIONS[id]]
		)
	check(_doc_line(EGGS_DOC, "## К8.").contains("(v4,"), "К8 v4 в easter-eggs.md")
