extends TestCase
## Контрактные тесты feedback-1012 (docs/contracts/feedback-1012.md): FB-К1 — смещение пилота в телеметрии.
## Проверки формы и инвариантов FB-К1 дописывает владелец (FB-1). Правка контракта (версия +1) — вместе с этим файлом.

const DOC := "res://docs/contracts/feedback-1012.md"
const VERSIONS := {"FB-К1": 1}


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
