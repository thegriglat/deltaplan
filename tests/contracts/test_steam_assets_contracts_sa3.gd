extends TestCase
## SA-К3 v4 (docs/contracts/steam-assets.md): явные лицензии в разделах сборки и раздел
## «Движок и библиотеки». Владелец файла — координатор steam-assets.

const ASSETS := "res://ASSETS.md"
const VAGUE := ["как у", "то же", "как выше"]
const ENGINE_ROWS := ["engine", "debug_menu"]
const GONE_ROWS := ["debug_draw_3d", "libdd3d"]  ## SA-К3 v4: аддон удалён


func _tables() -> Array[Dictionary]:
	return AssetsCredits.parse_tables(FileAccess.get_file_as_string(ASSETS))


func test_no_vague_licenses() -> void:
	for t in _tables():
		if String(t.title).to_lower().contains("не вход"):
			continue
		for row in t.rows:
			if row.size() < 4:
				continue
			var lic := String(row[3]).to_lower().strip_edges()
			for w in VAGUE:
				check(not lic.contains(w), "%s: «%s» в лицензии: %s" % [t.title, w, row[0]])
			check(lic != "открытые данные", "%s: лицензия «открытые данные»: %s" % [t.title, row[0]])


func test_engine_section() -> void:
	var sec: Dictionary = {}
	for t in _tables():
		if String(t.title).begins_with("Движок и библиотеки"):
			sec = t
	check(not sec.is_empty(), "раздел «Движок и библиотеки»")
	if sec.is_empty():
		return
	var files := ""
	for row in sec.rows:
		files += String(row[0]).to_lower() + " "
	for k in ENGINE_ROWS:
		check(files.contains(k), "в «Движок и библиотеки» есть %s" % k)
	for k in GONE_ROWS:
		check(not files.contains(k), "в «Движок и библиотеки» нет %s" % k)


func test_no_noncommercial_rule() -> void:
	var md := FileAccess.get_file_as_string(ASSETS).to_lower()
	check(not md.contains("некоммерческ"), "в ASSETS.md нет «некоммерческ»")
	check(not md.contains("⚠ nc"), "в ASSETS.md нет «⚠ NC»")


func test_no_debug_draw_3d() -> void:
	## Решение пользователя 07.10.2026: аддон Debug Draw 3D удалён из проекта целиком.
	check(not DirAccess.dir_exists_absolute("res://addons/debug_draw_3d"), "нет addons/debug_draw_3d")
	check(not Engine.has_singleton("DebugDraw3D"), "нет синглтона DebugDraw3D")
