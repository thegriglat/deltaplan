extends TestCase
## Контракт TA-К1 (docs/contracts/trike-anywhere.md): окно выбора старта по «Лететь».

const DOC := "res://docs/contracts/trike-anywhere.md"
const VERSION := 1


func _site(loc: String, id: String) -> Dictionary:
	for st: Dictionary in Locations.config(loc).get("start_sites", []):
		if String(st.get("id", "")) == id:
			return st
	return {}


func _under_runner(n: Node) -> void:
	# в дерево — под узел раннера (окно root занято, пока раннер в _ready); допущение: раннер — последний узел root
	var root := (Engine.get_main_loop() as SceneTree).root
	root.get_child(root.get_child_count() - 1).add_child(n)


func _menu() -> StartMenu:
	var m: StartMenu = (load("res://scenes/ui/start_menu.tscn") as PackedScene).instantiate()
	_under_runner(m)
	return m


func _items(d: StartChoiceDialog) -> PackedStringArray:
	return d.tow_ids()


func test_doc_heading() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	if text.is_empty():
		text = FileAccess.get_file_as_string(ProjectSettings.globalize_path(DOC))
	check(not text.is_empty(), "контракт читается")
	var re := RegEx.create_from_string("(?m)^## (TA-К\\d) v(\\d+)\\.")
	var found := {}
	for m in re.search_all(text):
		found[m.get_string(1)] = int(m.get_string(2))
	check(found.get("TA-К1", 0) == VERSION, "TA-К1 (v%d) в заголовках: %s" % [VERSION, found])


func test_trike_allowed() -> void:
	check(FlightSettings.trike_allowed(false), "без сети — можно")
	check(not FlightSettings.trike_allowed(true), "в сети — нельзя")


func test_dialog_items() -> void:
	var d := StartChoiceDialog.new()
	_under_runner(d)
	var tow_site := _site("wilotree_park", "runway_36")
	var plain := _site("altai", "sinyukha_west")
	check(not tow_site.is_empty() and not plain.is_empty(), "места из configs/locations/ читаются")
	var s := FlightSettings.defaults()
	d.open(s, tow_site)
	var want: Array = ([""] as Array) + FlightSetupScreen.tow_kinds_for_site(tow_site)
	check(Array(_items(d)) == want, "место с tow: «Нет» + tow.kinds: %s" % [_items(d)])
	check(d.tow_opt.item_count == want.size(), "пунктов столько же")
	d.open(s, plain)
	check(Array(_items(d)) == [""] + FlightSettings.TOW_KINDS, "место без tow: «Нет» + оба вида")
	d.open(s, {})
	check(Array(_items(d)) == [""] + FlightSettings.TOW_KINDS, "точка с картой: «Нет» + оба вида")
	d.queue_free()


func test_dialog_default() -> void:
	var d := StartChoiceDialog.new()
	_under_runner(d)
	var s := FlightSettings.defaults()
	s.tow_kind = "aerotow"
	d.open(s, {})
	check(_items(d)[d.tow_opt.selected] == "aerotow", "умолчание — settings.tow_kind из списка")
	s.tow_kind = ""
	var tow_site := _site("wilotree_park", "runway_36")
	d.open(s, tow_site)
	check(_items(d)[d.tow_opt.selected] == FlightSetupScreen.default_tow_kind(tow_site), "иначе default_tow_kind")
	d.queue_free()


func test_menu_trike() -> void:
	var m := _menu()
	var got: Array = []
	m.fly_requested.connect(func(s: FlightSettings) -> void: got.append(s))
	m.call("_on_fly")
	check(m.choice_dialog.visible and got.is_empty(), "«Лететь» → окно, fly_requested нет")
	m.choice_dialog.trike_btn.pressed.emit()
	check(got.size() == 1 and got[0].vehicle == "trike" and got[0].tow_kind == "", "«Дельталёт»")
	check(not m.choice_dialog.visible, "окно скрыто")
	m.queue_free()


func test_menu_glider_winch() -> void:
	var m := _menu()
	var got: Array = []
	m.fly_requested.connect(func(s: FlightSettings) -> void: got.append(s))
	m.call("_on_fly")
	var d := m.choice_dialog
	d.tow_opt.select(_items(d).find("winch_static"))
	d.glider_btn.pressed.emit()
	check(got.size() == 1 and got[0].vehicle == "glider" and got[0].tow_kind == "winch_static", "«Дельтаплан» + лебёдка")
	m.queue_free()


func test_menu_cancel() -> void:
	var m := _menu()
	var got: Array = []
	m.fly_requested.connect(func(s: FlightSettings) -> void: got.append(s))
	m.call("_on_fly")
	m.choice_dialog.cancel_btn.pressed.emit()
	check(got.is_empty(), "«Отмена» — сигнала нет")
	check(not m.choice_dialog.visible, "окно скрыто")
	m.queue_free()


func test_menu_net() -> void:
	var zone: Node = (Engine.get_main_loop() as SceneTree).root.get_node_or_null("NetZone")
	check(zone != null, "автозагрузка NetZone есть")
	if zone == null:
		return
	var was: bool = zone.get("in_zone")
	zone.set("in_zone", true)
	var m := _menu()
	var s := FlightSettings.defaults()
	s.vehicle = "trike"
	s.tow_kind = "winch_static"
	m.set_settings(s)
	var got: Array = []
	m.fly_requested.connect(func(fs: FlightSettings) -> void: got.append(fs))
	m.call("_on_fly")
	zone.set("in_zone", was)
	check(got.size() == 1 and got[0].vehicle == "glider" and got[0].tow_kind == "", "в сети: сразу, glider, без буксировки")
	check(m.choice_dialog == null, "в сети окна нет")
	m.queue_free()


func test_setup_screen_keeps_vehicle() -> void:
	var m: FlightSetupScreen = (load("res://scenes/ui/flight_setup_screen.tscn") as PackedScene).instantiate()
	_under_runner(m)
	check(m.get("_tow_opt") == null, "у экрана нет _tow_opt")
	var s := FlightSettings.defaults()
	s.vehicle = "trike"
	s.tow_kind = "aerotow"
	m.set_settings(s)
	var got: Array = []
	m.done.connect(func(r: FlightSettings) -> void: got.append(r))
	m.call("_on_done")
	check(got.size() == 1 and got[0].vehicle == "trike", "vehicle trike проходит")
	m.queue_free()
