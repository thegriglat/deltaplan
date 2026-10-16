extends SceneTree
## Пишет data/air_model_hash.txt — хеш кода модели воздуха (AirBakedField.code_hash_of_sources) для
## сборки: в экспорте исходники не читаются, игра берёт хеш из этого файла. Зовёт tools/build.sh.
## Запуск: godot --headless --path . --script res://tools/terrain/air_model_hash.gd
## AirBakedField грузится после запуска дерева: он ссылается на автозагрузку Config, которой при
## компиляции этого скрипта ещё нет.


func _initialize() -> void:
	var cls: GDScript = load("res://scripts/atmosphere/air_model/air_baked_field.gd")
	var h: String = cls.call("code_hash_of_sources")
	var path: String = cls.get("CODE_HASH_FILE")
	if h == "":
		printerr("air_model_hash: исходники модели не читаются")
		quit(1)
		return
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		printerr("air_model_hash: не записать %s" % path)
		quit(1)
		return
	f.store_string(h + "\n")
	f.close()
	print("air_model_hash: %s" % h)
	quit(0)
