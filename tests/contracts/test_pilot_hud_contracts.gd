extends TestCase
## Контрактные тесты pilot-hud (docs/contracts/pilot-hud.md). Версии — координатор; проверки формы и
## инвариантов дописывают владельцы: PH-К1 — PH-1, PH-К2 — PH-2/PH-7, PH-К3 — PH-3, PH-К4 — PH-5/PH-6,
## PH-К5 — PH-9, PH-К6 — PH-4, PH-К7 — PH-8. Правка контракта (версия +1) — вместе с этим файлом.

const DOC := "res://docs/contracts/pilot-hud.md"
const VERSIONS := {
	"PH-К1": 1, "PH-К2": 1, "PH-К3": 2, "PH-К4": 1, "PH-К5": 1, "PH-К6": 1, "PH-К7": 1,
}


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
