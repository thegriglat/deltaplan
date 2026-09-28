extends Node
## Настройки в сетевой зоне (NET-40/К3): время суток всегда ×1 (game.gd) — строка «Скорость
## времени» скрыта, save() сохранённое значение не трогает. Вне сети — как раньше.

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _panel() -> SettingsPanel:
	var sp: SettingsPanel = (
		(load("res://scenes/ui/settings_panel.tscn") as PackedScene).instantiate()
	)
	add_child(sp)
	return sp


func test_net_mode_hides_time_speed_row_and_keeps_stored_speed_on_save() -> void:
	var path := UserSettings.DEFAULT_DIR.path_join("world.json")
	var backup := FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""

	UserSettings.save_patch("world", {"time": {"speed": 10.0}})
	Config.reload()

	var sp := _panel()
	var row: HBoxContainer = sp.get("_time_speed_row")
	check(row != null, "строка «Скорость времени» есть")
	check(row.visible, "вне сети строка видна по умолчанию")

	sp.set_net_mode(true)
	check(not row.visible, "в сети строка скрыта")
	# Сменить выбор в UI (как если бы пилот успел покрутить, будь строка видна) — save()
	# сохранённое значение всё равно не трогает.
	var opt: OptionButton = sp.get("_time_speed")
	opt.select(0)
	check(sp.save(), "сохранилось")
	check(float(Config.value("world", "time.speed", -1.0)) == 10.0, "скорость времени не тронута")

	sp.set_net_mode(false)
	check(row.visible, "вне сети снова видна")

	sp.queue_free()
	if backup == "":
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	else:
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(backup)
		f.close()
	Config.reload()
