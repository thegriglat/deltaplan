extends SceneTree
## Запуск отпечатка мира из собранной игры (в сборке нельзя указать сцену, а скрипт — можно):
##   deltaplan.exe --headless -s res://scripts/atmosphere/atmo_fingerprint_main.gd -- --out=<файл>
## Параметры — как у scenes/atmosphere/atmo_fingerprint.tscn (atmo_fingerprint_cli.gd). Скрипт
## ничего не импортирует сам: сцена грузится после автозагрузок (Config).


func _initialize() -> void:
	change_scene_to_file.call_deferred("res://scenes/atmosphere/atmo_fingerprint.tscn")
