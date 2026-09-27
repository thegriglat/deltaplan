extends Node3D
## Главная сцена. Пока заглушка — сборка модулей в этап интеграции.


func _ready() -> void:
	if "--smoke" in OS.get_cmdline_user_args():
		_smoke_test()


## Проверка собранной игры: конфиги читаются из пакета и из папки рядом с exe.
func _smoke_test() -> void:
	var sim := Config.get_config("sim")
	print("smoke: physics_hz=%s dirs=%s" % [sim.get("physics_hz"), Config.search_dirs()])
	print("smoke: wings=%s" % [Config.list_configs("wings")])
	print("smoke: locations=%s" % [Config.list_configs("locations")])
	get_tree().quit(0 if not sim.is_empty() else 1)
