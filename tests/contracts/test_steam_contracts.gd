extends TestCase
## Контрактные тесты модуля steam (docs/contracts/steam.md). Версии стыков в документе и S1.1:
## никто, кроме scripts/steam/steam_service.gd, не трогает глобальный идентификатор Steam
## (игра обязана разбираться без расширения GodotSteam). Задачи-владельцы дописывают сюда
## проверки формы своих стыков (S2…S6). Правка контракта (версия +1) — вместе с этим файлом.

const DOC := "res://docs/contracts/steam.md"
const VERSIONS := {"S1": 1, "S2": 3, "S3": 2, "S4": 2, "S5": 1, "S6": 2, "S7": 1}
const SCAN_DIRS := ["res://scripts", "res://scenes", "res://tests"]


func test_versions_in_doc() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	check(not text.is_empty(), "нет " + DOC)
	for id in VERSIONS:
		var at := text.find("## %s." % id)
		var line := text.substr(at, text.find("\n", at) - at) if at >= 0 else ""
		check(line.contains("(версия %d)" % VERSIONS[id]), "%s версия %d в документе: '%s'" % [id, VERSIONS[id], line])


func test_s1_no_direct_steam_identifier() -> void:
	var strings := RegEx.create_from_string("\"(?:[^\"\\\\\\n]|\\\\.)*\"|'(?:[^'\\\\\\n]|\\\\.)*'")
	var comment := RegEx.create_from_string("#.*$")
	var ident := RegEx.create_from_string("(?<![A-Za-z0-9_.])Steam\\s*\\.")
	var bad: PackedStringArray = []
	for path in _gd_files():
		var lines := FileAccess.get_file_as_string(path).split("\n")
		for i in lines.size():
			var code := comment.sub(strings.sub(lines[i], "\"\"", true), "")
			if ident.search(code) != null:
				bad.append("%s:%d" % [path, i + 1])
	check(bad.is_empty(), "прямое обращение к Steam (S1.1): %s" % ", ".join(bad))


func _gd_files() -> PackedStringArray:
	var out: PackedStringArray = []
	var stack: Array = SCAN_DIRS.duplicate()
	while not stack.is_empty():
		var dir: String = stack.pop_back()
		var d := DirAccess.open(dir)
		if d == null:
			continue
		for sub in d.get_directories():
			if not sub.begins_with("."):
				stack.append(dir.path_join(sub))
		for f in d.get_files():
			if f.ends_with(".gd"):
				out.append(dir.path_join(f))
	return out
