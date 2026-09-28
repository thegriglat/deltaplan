extends TestCase
## Перенос профиля из старой папки (UserDirMigration): копирует всё, кроме кешей движка; не
## перезаписывает и не трогает старую папку; второй раз не копирует; есть свои настройки —
## не копирует.

const ROOT := "user://test_user_dir_migration"


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _rm(dir: String) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	d.include_hidden = true
	for sub in d.get_directories():
		_rm(dir.path_join(sub))
	for f in d.get_files():
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)


func test_copies_once_and_keeps_old() -> void:
	_rm(ROOT)
	var old := ProjectSettings.globalize_path(ROOT.path_join("old"))
	var new := ProjectSettings.globalize_path(ROOT.path_join("new"))
	_write(old.path_join("last_flight.json"), "{\"a\": 1}")
	_write(old.path_join("configs/game.json"), "{\"language\": \"en\"}")
	_write(old.path_join("terrain_cache/10/1/2.png"), "tile")
	_write(old.path_join("logs/godot.log"), "log")
	_write(old.path_join("shader_cache/x"), "sc")
	_write(new.path_join("logs/godot.log"), "new log")  # движок успел создать своё
	check(UserDirMigration.run(old, new), "перенос выполнен")
	var lf := FileAccess.get_file_as_string(new.path_join("last_flight.json"))
	check(lf == "{\"a\": 1}", "last_flight")
	check(FileAccess.file_exists(new.path_join("configs/game.json")), "configs")
	check(FileAccess.file_exists(new.path_join("terrain_cache/10/1/2.png")), "кеш рельефа")
	check(not FileAccess.file_exists(new.path_join("shader_cache/x")), "кеш шейдеров не копируем")
	var lg := FileAccess.get_file_as_string(new.path_join("logs/godot.log"))
	check(lg == "new log", "логи не трогаем")
	check(FileAccess.file_exists(old.path_join("last_flight.json")), "старая папка цела")
	_write(new.path_join("last_flight.json"), "{\"b\": 2}")
	DirAccess.remove_absolute(new.path_join("configs/game.json"))
	check(not UserDirMigration.run(old, new), "второй раз не копирует")
	check(not FileAccess.file_exists(new.path_join("configs/game.json")), "удалённое не вернулось")
	_rm(ROOT)


func test_skips_when_new_has_settings_or_no_old() -> void:
	_rm(ROOT)
	var old := ProjectSettings.globalize_path(ROOT.path_join("old"))
	var new := ProjectSettings.globalize_path(ROOT.path_join("new"))
	check(not UserDirMigration.run(old, new), "нет старой папки — ничего")
	_write(old.path_join("last_flight.json"), "old")
	_write(new.path_join("configs/game.json"), "mine")
	check(not UserDirMigration.run(old, new), "свои настройки — не копируем")
	check(not FileAccess.file_exists(new.path_join("last_flight.json")), "ничего не скопировано")
	_rm(ROOT)
