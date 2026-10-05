class_name AssetsCredits
extends RefCounted
## Текст экрана «Об игре» (FR-27a): таблицы ассетов из ASSETS.md + тексты лицензий.
## Парсер Markdown — только то, что есть в ASSETS.md: заголовки «## …» и таблицы «| … |».


## Разобрать Markdown: [{title, headers: [..], rows: [[..], ..]}] — по одной записи на таблицу.
static func parse_tables(md: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var title := ""
	var cur: Dictionary = {}
	for raw in md.split("\n"):
		var line := raw.strip_edges()
		if line.begins_with("#"):
			title = line.lstrip("#").strip_edges()
			cur = {}
			continue
		if not line.begins_with("|"):
			cur = {}
			continue
		var cells := _cells(line)
		if cur.is_empty():
			cur = {"title": title, "headers": cells, "rows": []}
			out.append(cur)
		elif _is_rule(cells):
			continue
		else:
			cur.rows.append(cells)
	return out


## Убрать разметку: [текст](url) → «текст (url)», `код` → код, **ж** → ж.
static func plain(s: String) -> String:
	var re := RegEx.create_from_string("\\[([^\\]]*)\\]\\(([^)]*)\\)")
	var t := re.sub(s, "$1 ($2)", true)
	return t.replace("`", "").replace("**", "").replace("<br>", " ").strip_edges()


## Раздел входит в сборку (SA-К3): в названии нет «не вход».
static func in_build(title: String) -> bool:
	return not title.to_lower().contains("не вход")


## BBCode для RichTextLabel: разделы, строки «что — источник — лицензия», тексты лицензий.
static func to_bbcode(tables: Array[Dictionary], licenses: Dictionary) -> String:
	var lines: PackedStringArray = []
	for t in tables:
		if not in_build(String(t.title)):
			continue
		lines.append("[font_size=22][color=#f2c77f]%s[/color][/font_size]" % _esc(t.title))
		var hdr: Array = t.headers
		var i_what := _col(hdr, ["Что"], 1)
		var i_src := _col(hdr, ["Источник"], 2)
		var i_lic := _col(hdr, ["Лицензия"], 3)
		var i_file := _col(hdr, ["Файл"], 0)
		for r: Array in t.rows:
			var what := plain(_at(r, i_what))
			var file := plain(_at(r, i_file))
			if what == "" or what == "—":
				what = file
			var src := plain(_at(r, i_src))
			var lic := plain(_at(r, i_lic))
			var parts := PackedStringArray(["[b]%s[/b]" % _esc(what)])
			if src != "" and src != "—":
				parts.append(_esc(src))
			if lic != "" and lic != "—":
				parts.append("[i]%s[/i]" % _esc(lic))
			lines.append("• " + " — ".join(parts))
		lines.append("")
	for path: String in licenses:
		lines.append("[font_size=22][color=#f2c77f]%s[/color][/font_size]" % path.get_file())
		lines.append("[font_size=14]%s[/font_size]" % _esc(String(licenses[path])))
		lines.append("")
	return "\n".join(lines)


## Собрать из файлов (configs/ui.json → about_sources, license_files).
static func build_text(sources: Array, license_files: Array) -> String:
	var tables: Array[Dictionary] = []
	for p: String in sources:
		if FileAccess.file_exists(p):
			tables.append_array(parse_tables(FileAccess.get_file_as_string(p)))
		else:
			push_warning("AssetsCredits: нет файла %s" % p)
	var lic := {}
	for p: String in license_files:
		if FileAccess.file_exists(p):
			lic[p] = FileAccess.get_file_as_string(p)
		else:
			push_warning("AssetsCredits: нет файла %s" % p)
	return to_bbcode(tables, lic)


static func _cells(line: String) -> Array:
	var s := line.strip_edges().trim_prefix("|").trim_suffix("|")
	var out: Array = []
	for c in s.split("|"):
		out.append(c.strip_edges())
	return out


static func _is_rule(cells: Array) -> bool:
	for c: String in cells:
		if c.replace("-", "").replace(":", "").strip_edges() != "":
			return false
	return true


static func _col(headers: Array, names: Array, fallback: int) -> int:
	for i in headers.size():
		for n: String in names:
			if String(headers[i]).begins_with(n):
				return i
	return fallback if fallback < headers.size() else -1


static func _at(row: Array, i: int) -> String:
	return String(row[i]) if i >= 0 and i < row.size() else ""


static func _esc(s: String) -> String:
	return s.replace("[", "[lb]")
