extends TestCase
## Контрактный тест N5 (docs/contracts/no-osm.md): файлы места в WebP, версия формата кеша.
## Правка контракта (версия +1) — вместе с этим файлом.

const PLACES := ["askarovo", "altai", "aushkul", "ongudai"]


func test_n5_format_version() -> void:
	var scr: Script = load("res://scripts/terrain/build/locations.gd")
	var c := scr.get_script_constant_map()
	check(c.has("FORMAT_VERSION") and typeof(c.FORMAT_VERSION) == TYPE_INT, "Locations.FORMAT_VERSION (int)")


## Встроенные места (пока они в пакете, до NO-8): высоты и растры — WebP, старых PNG/zst нет.
func test_n5_place_files() -> void:
	for id in PLACES:
		var dir := Locations.data_dir(id) + "/"
		if not DirAccess.dir_exists_absolute(dir):
			continue
		for f in DirAccess.get_files_at(dir):
			check(not f.ends_with(".f32.zst") and not f.ends_with(".png"), "%s: старый формат %s" % [id, f])
		check(FileAccess.file_exists(dir + "detail.webp"), "%s: detail.webp" % id)
		var img := Image.load_from_file(dir + "detail.webp")
		check(img != null and img.get_width() > 0, "%s: detail.webp читается" % id)
