extends Node
## QL-13: «Настройки» и «Полёт…» — содержимое в прокрутке, кнопки внизу вне прокрутки и всегда
## видны при окне 1280×720 и 1024×600 (30+ своих мест на «Полёт…»).

const TMP_PATH := "user://test_menu_scroll_tmp.json"

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _find_scroll(n: Node) -> ScrollContainer:
	if n is ScrollContainer:
		return n
	for c in n.get_children():
		var r := _find_scroll(c)
		if r != null:
			return r
	return null


func _buttons(n: Node, out: Array[Button]) -> void:
	if n is Button and not (n.get_parent() is OptionButton):
		out.append(n)
	for c in n.get_children():
		_buttons(c, out)


func _check_screen(screen: Control, size: Vector2i, name: String) -> void:
	var vp := SubViewport.new()
	vp.size = size
	vp.disable_3d = true
	add_child(vp)
	vp.add_child(screen)
	for i in 4:
		await get_tree().process_frame
	var sc := _find_scroll(screen)
	check(sc != null, "%s %s: есть ScrollContainer" % [name, size])
	if sc != null:
		var content: Control = sc.get_child(0)
		var rect := Rect2(Vector2.ZERO, Vector2(size))
		check(
			rect.encloses(sc.get_global_rect().grow(-1.0)),
			"%s %s: прокрутка в экране: %s" % [name, size, sc.get_global_rect()]
		)
		check(
			sc.size.y < content.size.y or sc.size.y >= content.get_combined_minimum_size().y - 1.0,
			"%s %s: высота согласована" % [name, size]
		)
		# колесом прокручивается до конца
		sc.scroll_vertical = 100000
		await get_tree().process_frame
		check(
			sc.scroll_vertical + sc.size.y >= content.size.y - 2.0,
			"%s %s: содержимое доступно прокруткой" % [name, size]
		)
	var btns: Array[Button] = []
	_buttons(screen, btns)
	var found := 0
	for b in btns:
		if sc != null and sc.is_ancestor_of(b):
			continue
		if b.text == "":
			continue
		found += 1
		check(
			Rect2(Vector2.ZERO, Vector2(size)).encloses(b.get_global_rect()),
			"%s %s: кнопка «%s» видна: %s" % [name, size, b.text, b.get_global_rect()]
		)
	check(found >= 2, "%s %s: кнопки вне прокрутки (%d)" % [name, size, found])
	vp.queue_free()


func test_scroll_screens() -> void:
	if FileAccess.file_exists(TMP_PATH):
		DirAccess.remove_absolute(TMP_PATH)
	for i in 34:
		RecentPlaces.add(50.0 + i * 0.1, 80.0 + i * 0.1, "", TMP_PATH)
	for size in [Vector2i(1280, 720), Vector2i(1024, 600)]:
		var sp: SettingsPanel = (
			(load("res://scenes/ui/settings_panel.tscn") as PackedScene).instantiate()
		)
		await _check_screen(sp, size, "settings")
		var fs: FlightSetupScreen = (
			(load("res://scenes/ui/flight_setup_screen.tscn") as PackedScene).instantiate()
		)
		fs.recent_places_path = TMP_PATH
		await _check_screen(fs, size, "flight_setup")
	if FileAccess.file_exists(TMP_PATH):
		DirAccess.remove_absolute(TMP_PATH)
