extends TestCase
## Контрактные тесты start-pick (docs/contracts/start-pick.md): SP-К1 — точный старт в FlightSettings и Game,
## SP-К2 — StartSpot.check, SP-К3 — точный старт в сети, SP-К4 — камни и кусты не на разбеге.
## Проверки формы и инвариантов дописывают владельцы (SP-К1, SP-К2 — SP-1; SP-К3 — SP-3; SP-К4 — SP-4).
## Правка контракта (версия +1) — вместе с этим файлом.

const DOC := "res://docs/contracts/start-pick.md"
const VERSIONS := {"SP-К1": 1, "SP-К2": 1, "SP-К3": 1, "SP-К4": 1}


func _read(path: String) -> String:
	var t := FileAccess.get_file_as_string(path)
	if t.is_empty():
		t = FileAccess.get_file_as_string(ProjectSettings.globalize_path(path))
	return t


func test_versions() -> void:
	var text := _read(DOC)
	var at := text.find("contracts: [")
	check(at >= 0, "frontmatter contracts")
	var line := text.substr(at, text.find("\n", at) - at)
	for id: String in VERSIONS:
		check(
			line.contains('{"id": "%s", "version": %d}' % [id, VERSIONS[id]]),
			"%s v%d в frontmatter: %s" % [id, VERSIONS[id], line]
		)
		check(text.contains("## %s v%d" % [id, VERSIONS[id]]), "%s v%d заголовок" % [id, VERSIONS[id]])
