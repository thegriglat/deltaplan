extends Node
## QL-14: «Настройки», «Полёт…» (34 своих места) и главное меню (8 избранных) в НАСТОЯЩЕМ окне
## заданного размера — без масштабирования кадра; прокрутка — настоящим событием колеса мыши.
## Запуск (нужен дисплей):
##   XDG_DATA_HOME=$(mktemp -d) godot --path . --audio-driver Dummy --resolution 1024x600 \
##     res://tools/shots/scroll_shot.tscn -- --out=<каталог>
## Пишет <out>/<экран>_<ширина>x<высота>_{верх,низ}.png и печатает проверки (код выхода 0/1).

var _out := "/tmp"
var _fails := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
	DirAccess.make_dir_recursive_absolute(_out)
	await get_tree().process_frame
	var win := get_window()
	print("окно: ", win.size, " экран: ", DisplayServer.window_get_size())
	var rp := "user://scroll_shot_places.json"
	var fp := "user://scroll_shot_fav.json"
	for p in [rp, fp]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
	for i in 34:
		RecentPlaces.add(50.0 + i * 0.1, 80.0 + i * 0.1, "", rp)
	var s := FlightSettings.defaults()
	for i in 8:
		s.start_hour = 8.0 + i
		s.wind_speed_kmh = 5.0 + i * 2.0
		Favorites.add(s, fp, float(i + 1))
	var tag := "%dx%d" % [win.size.x, win.size.y]
	var st: SettingsPanel = (load("res://scenes/ui/settings_panel.tscn") as PackedScene).instantiate()
	await _screen(st, "Настройки", tag, true)
	var fs: FlightSetupScreen = (
		(load("res://scenes/ui/flight_setup_screen.tscn") as PackedScene).instantiate()
	)
	fs.recent_places_path = rp
	fs.favorites_path = fp
	await _screen(fs, "Полёт", tag, true)
	var m: StartMenu = (load("res://scenes/ui/start_menu.tscn") as PackedScene).instantiate()
	m.favorites_path = fp
	await _screen(m, "Главное_меню", tag, true)
	for p in [rp, fp]:
		DirAccess.remove_absolute(p)
	print("scroll_shot: ", "FAIL" if _fails > 0 else "OK")
	get_tree().quit(1 if _fails > 0 else 0)


func _find_scroll(n: Node) -> ScrollContainer:
	if n is ScrollContainer:
		return n
	for c in n.get_children():
		var r := _find_scroll(c)
		if r != null:
			return r
	return null


func _buttons(n: Node, out: Array[Button]) -> void:
	if n is Button and not (n.get_parent() is OptionButton) and n.is_visible_in_tree():
		out.append(n)
	for c in n.get_children():
		_buttons(c, out)


func _check(c: bool, msg: String) -> void:
	print(("ok   " if c else "FAIL ") + msg)
	if not c:
		_fails += 1


func _save(name: String, tag: String, suffix: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	print("  кадр ", name, " ", img.get_size())
	img.save_png(_out.path_join("%s_%s_%s.png" % [name, tag, suffix]))


func _screen(screen: Control, name: String, tag: String, scrolls: bool) -> void:
	get_tree().root.add_child(screen)
	for i in 8:
		await get_tree().process_frame
	var win := Rect2(Vector2.ZERO, Vector2(get_window().size))
	var btns: Array[Button] = []
	_buttons(screen, btns)
	var sc := _find_scroll(screen)
	var outside := 0
	for b in btns:
		if sc != null and sc.is_ancestor_of(b):
			continue
		if b.text == "":
			continue
		outside += 1
		_check(win.encloses(b.get_global_rect()), "%s %s: «%s» в окне %s" % [name, tag, b.text, b.get_global_rect()])
	if not scrolls:
		_check(outside > 0, "%s %s: кнопок %d" % [name, tag, outside])
		await _save(name, tag, "верх")
		screen.queue_free()
		await get_tree().process_frame
		return
	_check(sc != null, "%s %s: есть прокрутка" % [name, tag])
	await _save(name, tag, "верх")
	_check(win.encloses(sc.get_global_rect()), "%s %s: прокрутка в окне %s" % [name, tag, sc.get_global_rect()])
	# настоящее колесо мыши над прокруткой
	var pos := sc.get_global_rect().get_center()
	Input.warp_mouse(pos)
	await get_tree().process_frame
	var content: Control = sc.get_child(0)
	var overflow := content.size.y > sc.size.y + 1.0
	print("  содержимое %.0f, окно прокрутки %.0f" % [content.size.y, sc.size.y])
	for i in 80:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_WHEEL_DOWN
		ev.pressed = true
		ev.position = pos
		ev.global_position = pos
		Input.parse_input_event(ev)
		await get_tree().process_frame
	await get_tree().process_frame
	_check(
		sc.scroll_vertical + sc.size.y >= content.size.y - 2.0,
		"%s %s: колесо довело до конца (scroll %d)" % [name, tag, sc.scroll_vertical]
	)
	_check(not overflow or sc.scroll_vertical > 0, "%s %s: колесо сдвинуло" % [name, tag])
	await _save(name, tag, "низ")
	screen.queue_free()
	await get_tree().process_frame
