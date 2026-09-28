class_name UserDirMigration
extends RefCounted
## Своя папка профиля (config/use_custom_user_dir → «Deltaplan»: ~/.local/share/Deltaplan,
## %APPDATA%\Deltaplan). Раньше профиль лежал в godot/app_userdata/Дельтаплан — при первом
## запуске копируем оттуда всё (настройки, последний полёт, места, рекорды, кеш рельефа), кроме
## кешей движка. Старую папку не трогаем. Один раз: после копии кладём метку.

const MARK := ".migrated_from_app_userdata"
## Кеши и логи движка — пересоздаются сами, копировать незачем.
const SKIP := ["logs", "shader_cache", "vulkan", "d3d12"]
## Имя проекта, под которым жил старый профиль (до 0.8 config/name был «Дельтаплан»).
const LEGACY_APP_NAME := "Дельтаплан"


## Старая папка профиля: <данные ОС>/godot|Godot/app_userdata/Дельтаплан.
static func legacy_dir() -> String:
	var godot_dir := "Godot" if OS.get_name() in ["Windows", "macOS"] else "godot"
	return OS.get_data_dir().path_join(godot_dir).path_join("app_userdata").path_join(LEGACY_APP_NAME)


## Скопировать old_dir → new_dir, если в new_dir ещё нет настроек пилота и не было переноса.
## Возвращает true, если копировали.
static func run(old_dir: String, new_dir: String) -> bool:
	if old_dir == "" or old_dir.simplify_path() == new_dir.simplify_path():
		return false
	if not DirAccess.dir_exists_absolute(old_dir):
		return false
	if FileAccess.file_exists(new_dir.path_join(MARK)):
		return false
	var has_settings := (
		DirAccess.dir_exists_absolute(new_dir.path_join("configs"))
		or FileAccess.file_exists(new_dir.path_join("last_flight.json"))
	)
	if not has_settings:
		_copy_dir(old_dir, new_dir, true)
		print("Профиль перенесён: %s → %s" % [old_dir, new_dir])
	var f := FileAccess.open(new_dir.path_join(MARK), FileAccess.WRITE)
	if f != null:
		f.store_string(old_dir)
	return not has_settings


## Рекурсивная копия; существующие файлы не перезаписываем.
static func _copy_dir(src: String, dst: String, top: bool) -> void:
	var d := DirAccess.open(src)
	if d == null or DirAccess.make_dir_recursive_absolute(dst) != OK:
		return
	for sub in d.get_directories():
		if top and sub in SKIP:
			continue
		_copy_dir(src.path_join(sub), dst.path_join(sub), false)
	for f in d.get_files():
		var to := dst.path_join(f)
		if not FileAccess.file_exists(to):
			DirAccess.copy_absolute(src.path_join(f), to)
