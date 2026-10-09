extends Control
## Проверка MapPicker: godot --path . res://scenes/terrain/map_picker_preview.tscn [-- --shot=<png>]

var _frames := 0
var _shot := ""


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot="):
			_shot = a.substr(7)
	var mp := MapPicker.new()
	mp.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(mp)
	mp.point_picked.connect(
		func(lat: float, lon: float) -> void: print("Выбрано: %.5f, %.5f" % [lat, lon])
	)
	var loc: Dictionary = Locations.config("altai")
	mp.center_on(float(loc.center_lat), float(loc.center_lon))
	mp.pick(float(loc.center_lat), float(loc.center_lon))


func _process(_d: float) -> void:
	_frames += 1
	if _shot != "" and _frames == 240:
		get_viewport().get_texture().get_image().save_png(_shot)
		get_tree().quit()
