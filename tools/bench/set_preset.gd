extends Node
## Разовая правка user://configs: выставить пресет графики (по умолчанию medium) перед замерами
## (карточка 03-zamery-fps-zagruzka). Headless, сам выходит.
##   godot --headless --path . res://tools/bench/set_preset.tscn -- --preset=medium


func _ready() -> void:
	var preset := "medium"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--preset="):
			preset = a.substr(9)
	var ok := GraphicsPresets.select(preset)
	print("set_preset: %s -> %s" % [preset, "ok" if ok else "ОШИБКА"])
	get_tree().quit(0 if ok else 1)
