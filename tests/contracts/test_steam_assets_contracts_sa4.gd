extends TestCase
## SA-4: SA-К2 v3 (docs/contracts/steam-assets.md): набор licenses/*.txt,
## генератор THIRD_PARTY_NOTICES.txt, строки с атрибуцией есть в файле и в тексте «Об игре».
## Без сети и GPU; нужен python3 (как у build_inventory).

const SET := [
	"MIT-deltaplan", "MIT-godot", "godot-COPYRIGHT", "MIT-godot-cpp", "onnxruntime-LICENSE",
	"onnxruntime-ThirdPartyNotices", "MIT-debug_draw_3d", "MIT-debug_menu", "MIT-godotsteam",
	"OFL-1.1", "CC-BY-4.0", "CC0-1.0",
	"ODbL-1.0", "copernicus-dem", "msvc-runtime",
]
const ODBL := (
	"Derived OpenStreetMap data (data/osm/, data/places/) is available under the ODbL 1.0 "
	+ "in the project repository: https://github.com/thegriglat/deltaplan"
)
const ATTR := "cc[- ]?by|odbl|\\bofl\\b|\\bmit\\b|bsd|apache|copernicus|атрибуц"


func _root() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/")


func test_licenses_set() -> void:
	check(FileAccess.file_exists("res://licenses/.gdignore"), "licenses/.gdignore")
	var name_re := RegEx.create_from_string("^[A-Za-z0-9._-]+$")
	for n: String in SET:
		check(name_re.search(n) != null, "имя " + n)
		var p := "res://licenses/%s.txt" % n
		var ok := FileAccess.file_exists(p) and FileAccess.get_file_as_string(p).length() > 100
		check(ok, "licenses/%s.txt не пуст" % n)
	var d := DirAccess.open("res://licenses")
	for f in d.get_files():
		if f.ends_with(".txt"):
			check(f.trim_suffix(".txt") in SET, "лишний файл licenses/" + f)


func test_assets_md_license_refs_exist() -> void:
	var md := FileAccess.get_file_as_string("res://ASSETS.md")
	var re := RegEx.create_from_string("licenses/([A-Za-z0-9._-]+)\\.txt")
	for m in re.search_all(md):
		var lic := m.get_string(1)
		check(FileAccess.file_exists("res://licenses/%s.txt" % lic), "ссылка на licenses/%s.txt" % lic)


func _run_generator(preset: String) -> String:
	var out := OS.get_user_data_dir().path_join("sa4_notices_" + preset)
	DirAccess.make_dir_recursive_absolute(out)
	var output := []
	var script := _root().path_join("tools/release/third_party_notices.py")
	var rc := OS.execute("python3", [script, "--out", out, "--preset", preset], output, true)
	check(rc == 0, "third_party_notices.py --preset %s: rc=%d %s" % [preset, rc, output])
	return out


func test_generator_output() -> void:
	var out := _run_generator("Linux")
	var txt := FileAccess.get_file_as_string(out.path_join("THIRD_PARTY_NOTICES.txt"))
	check(txt.contains(ODBL), "фраза ODbL в THIRD_PARTY_NOTICES.txt")
	check(not txt.contains("\r"), "LF")
	for n in ["ODbL-1.0", "MIT-deltaplan", "MIT-godot", "godot-COPYRIGHT"]:
		check(FileAccess.file_exists(out.path_join("licenses/%s.txt" % n)), "licenses/%s.txt рядом" % n)
	var win := _run_generator("Windows")
	var msvc := win.path_join("licenses/msvc-runtime.txt")
	check(FileAccess.file_exists(msvc), "msvc-runtime для Windows")
	# Каждая упомянутая в файле лицензия лежит рядом.
	var re := RegEx.create_from_string("([A-Za-z0-9._-]+)\\.txt")
	for line in txt.split("\n"):
		if line.begins_with("Full license texts"):
			for m in re.search_all(line):
				var lp := out.path_join("licenses/%s.txt" % m.get_string(1))
				check(FileAccess.file_exists(lp), "упомянут, но нет: " + m.get_string(1))


func test_attributed_rows_in_notices_and_about() -> void:
	var out := _run_generator("Linux")
	var notices := FileAccess.get_file_as_string(out.path_join("THIRD_PARTY_NOTICES.txt"))
	var about := AssetsCredits.build_text(["res://ASSETS.md"], [])
	var attr := RegEx.create_from_string("(?i)" + ATTR)
	var n := 0
	for t in AssetsCredits.parse_tables(FileAccess.get_file_as_string("res://ASSETS.md")):
		if not AssetsCredits.in_build(String(t.title)):
			continue
		for row: Array in t.rows:
			if row.size() < 5 or String(row[4]).to_lower().contains("только steam"):
				continue
			var lic := AssetsCredits.plain(String(row[3]))
			if lic == "—" or attr.search(lic) == null:
				continue
			var what := AssetsCredits.plain(String(row[1]))
			if what == "" or what == "—":
				what = AssetsCredits.plain(String(row[0]))
			n += 1
			check(notices.contains(what), "нет в THIRD_PARTY_NOTICES.txt: " + what)
			check(about.contains(what.replace("[", "[lb]")), "нет в «Об игре»: " + what)
	check(n > 10, "строк с атрибуцией: %d" % n)


func test_about_skips_sections_outside_build() -> void:
	var hdr := ["Файл", "Что", "Источник", "Лицензия", "Где"]
	var tables: Array[Dictionary] = [
		{"title": "Игра", "headers": hdr, "rows": [["a", "вошло", "s", "MIT", "w"]]},
		{
			"title": "Сайт (не входит в игру)",
			"headers": hdr,
			"rows": [["b", "не вошло", "s", "MIT", "w"]]
		},
	]
	var text := AssetsCredits.to_bbcode(tables, {})
	check(text.contains("вошло") and not text.contains("не вошло"), "разделы «не входит» скрыты")
