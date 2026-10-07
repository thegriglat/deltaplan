extends TestCase
## Контрактные тесты модуля steam-assets (docs/contracts/steam-assets.md). Без сети и GPU.
## Правка контракта (версия +1) — вместе с этим файлом. Проверки задач — в отдельных файлах
## tests/contracts/test_steam_assets_contracts_<задача>.gd.

const DOC := "res://docs/contracts/steam-assets.md"
const ASSETS := "res://ASSETS.md"
const VERSIONS := {"SA-К1": 3, "SA-К2": 5, "SA-К3": 4, "SA-К4": 3}
const HEADERS := ["Файл", "Что", "Источник", "Лицензия", "Где используется"]
const FORBIDDEN := ["nc", "некоммерч", "non-commercial", "personal", "личн"]


func test_versions_in_doc() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	check(not text.is_empty(), "нет " + DOC)
	for id in VERSIONS:
		var at := text.find("## %s." % id)
		var line := text.substr(at, text.find("\n", at) - at) if at >= 0 else ""
		check(line.contains("(v%d)" % VERSIONS[id]), "%s v%d в документе: %s" % [id, VERSIONS[id], line])


static func _in_build(title: String) -> bool:
	return not title.to_lower().contains("не вход")


func test_k3_assets_md_tables() -> void:
	var md := FileAccess.get_file_as_string(ASSETS)
	check(not md.is_empty(), "нет " + ASSETS)
	var tables := AssetsCredits.parse_tables(md)
	check(tables.size() >= 5, "таблиц в ASSETS.md: %d" % tables.size())
	var in_build := 0
	for t in tables:
		if not _in_build(String(t.title)):
			continue
		in_build += 1
		var hdr: Array = t.headers
		check(hdr == HEADERS, "%s: заголовки %s" % [t.title, hdr])
		for row in t.rows:
			check(row.size() == 5, "%s: 5 колонок: %s" % [t.title, row])
			if row.size() < 4:
				continue
			var lic := String(row[3]).strip_edges()
			check(lic != "", "%s: пустая лицензия: %s" % [t.title, row[0]])
			var low := lic.to_lower()
			for w in FORBIDDEN:
				var hit := RegEx.create_from_string("\\bnc\\b").search(low) != null if w == "nc" else low.contains(w)
				check(not hit, "%s: запрещённая лицензия в сборке (%s): %s" % [t.title, w, row[0]])
	check(in_build >= 4, "разделов, входящих в сборку: %d" % in_build)
