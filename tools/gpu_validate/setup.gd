extends Node
## tools/gpu_validate.sh: настройки профиля перед прогоном — пресет графики и режим ветра
## (user://configs, как из меню). Headless, сам выходит.
##   godot --headless --path . res://tools/gpu_validate/setup.tscn -- --preset=low --wind=auto|off


func _ready() -> void:
	var preset := "low"
	var wind := "auto"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--preset="):
			preset = a.substr(9)
		elif a.begins_with("--wind="):
			wind = a.substr(7)
	var ok := GraphicsPresets.select(preset)
	ok = UserSettings.save_patch("atmosphere", {"air_model": {"enabled": wind}}) and ok
	print("gpu_validate setup: preset=%s wind=%s -> %s" % [preset, wind, "ok" if ok else "ОШИБКА"])
	get_tree().quit(0 if ok else 1)
