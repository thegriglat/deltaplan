extends SceneTree
# Проверка GDScript в контексте проекта (автозагрузки видны, в отличие от --check-only):
# грузит каждый скрипт из аргументов. Ошибки разбора/компиляции Godot печатает сам — их разбирает dp check gd.
# godot --headless --path . -s res://tools/check/gd_check.gd -- res://a.gd res://b.gd


func _initialize() -> void:
	for p in OS.get_cmdline_user_args():
		ResourceLoader.load(p, "", ResourceLoader.CACHE_MODE_IGNORE)
	quit()
