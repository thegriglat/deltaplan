extends TestCase
## Контракт TK-K1 (docs/contracts/trike-model.md): версия в заголовке. Владелец стыка дописывает проверку интерфейса.

const DOC := "res://docs/contracts/trike-model.md"
const VERSION := 1


func test_doc_heading() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	if text.is_empty():
		text = FileAccess.get_file_as_string(ProjectSettings.globalize_path(DOC))
	check(not text.is_empty(), "контракт читается")
	var re := RegEx.create_from_string("(?m)^## (TK-K\\d)\\. .* \\(v(\\d+)\\)\\s*$")
	var found := {}
	for m in re.search_all(text):
		found[m.get_string(1)] = int(m.get_string(2))
	check(found.get("TK-K1", 0) == VERSION, "TK-K1 (v%d) в заголовках: %s" % [VERSION, found])
