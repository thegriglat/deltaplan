extends Node
## NET-42: меню «Догнать» (CatchUpMenu) на поддельном источнике — без сети и без мира.

var failures: PackedStringArray = []
var _list: Array[Dictionary] = []
var _own := Vector3.ZERO


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _pilot(id: String, nm: String, is_bot: bool, pos: Vector3, on_ground: bool) -> Dictionary:
	return {"id": id, "name": nm, "is_bot": is_bot, "pos": pos, "on_ground": on_ground}


## Я в (0, 1000, 0); Оля — в воздухе в 3 км, Коля — в воздухе в 500 м, но бот ближе всех,
## Саша — на старте рядом, «я» тоже в списке источника.
func _fill() -> void:
	_own = Vector3(0, 1000, 0)
	_list = [
		_pilot("bot-1", "Бот", true, Vector3(50, 1000, 0), false),
		_pilot("7", "Оля", false, Vector3(3000, 1500, 0), false),
		_pilot("me", "Я", false, _own, false),
		_pilot("5", "Коля", false, Vector3(0, 1200, 500), false),
		_pilot("9", "Саша", false, Vector3(100, 900, 0), true),
	]


func _menu() -> CatchUpMenu:
	_fill()
	InputController.register_actions(Config.get_config("controls"))
	var m: CatchUpMenu = (load("res://scenes/ui/catch_up_menu.tscn") as PackedScene).instantiate()
	add_child(m)
	m.self_id = "me"
	m.set_source(func() -> Array[Dictionary]: return _list, func() -> Vector3: return _own)
	return m


func _ids(m: CatchUpMenu) -> PackedStringArray:
	var out: PackedStringArray = []
	for r in m.rows():
		out.append(String(r.id))
	return out


func _key(action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)
	Input.flush_buffered_events()


func test_self_not_in_list_and_humans_above_bots() -> void:
	var m := _menu()
	m.open()
	var ids := _ids(m)
	check(not ids.has("me"), "себя нет: %s" % str(ids))
	check(ids.size() == 4, "4 пилота: %s" % str(ids))
	check(ids[ids.size() - 1] == "bot-1", "бот последний: %s" % str(ids))
	check(ids[0] == "5" and ids[1] == "7" and ids[2] == "9", "живые по имени: %s" % str(ids))
	var t := m.row_texts()
	check(t[0].contains("Коля") and t[0].contains("1200") and t[0].contains("500"), t[0])
	check(t[2].contains(tr("catch_up_at_launch")), "Саша на старте: " + t[2])
	check(t[0].contains(tr("catch_up_air")), "Коля в воздухе: " + t[0])
	m.queue_free()


func test_default_selection_is_nearest_airborne_human() -> void:
	var m := _menu()
	m.open()
	check(m.is_open(), "открыто")
	check(m.selected_id() == "5", "Коля — ближайший живой в воздухе: " + m.selected_id())
	# Двое в зоне: `=` → Enter.
	_list = [_pilot("7", "Оля", false, Vector3(3000, 1500, 0), false)]
	m.close()
	m.open()
	check(m.selected_id() == "7", "единственный — выделен")
	# Никого живого в воздухе — первая строка.
	_list = [
		_pilot("bot-1", "Бот", true, Vector3(50, 1000, 0), false),
		_pilot("9", "Саша", false, Vector3(100, 900, 0), true),
	]
	m.close()
	m.open()
	check(m.selected_id() == "9", "нет живых в воздухе — первая строка")
	m.queue_free()


func test_up_down_enter_emits_selected_id() -> void:
	var m := _menu()
	var got: Array[String] = []
	var closed := [0]
	m.catch_up_requested.connect(func(id: String) -> void: got.append(id))
	m.closed.connect(func() -> void: closed[0] += 1)
	m.open()
	_key("ui_down")
	check(m.selected_id() == "7", "↓ → Оля: " + m.selected_id())
	_key("ui_down")
	_key("ui_down")
	check(m.selected_id() == "bot-1", "↓↓ → бот")
	_key("ui_down")
	check(m.selected_id() == "5", "по кругу — снова Коля")
	_key("ui_up")
	check(m.selected_id() == "bot-1", "↑ по кругу — бот")
	_key("ui_accept")
	check(got.size() == 1 and got[0] == "bot-1", "Enter — id бота: %s" % str(got))
	check(not m.is_open() and not m.visible, "после Enter закрыто")
	check(closed[0] == 1, "closed после Enter")
	m.queue_free()


func test_escape_and_equal_close_without_action() -> void:
	var m := _menu()
	var got: Array[String] = []
	var closed := [0]
	m.catch_up_requested.connect(func(id: String) -> void: got.append(id))
	m.closed.connect(func() -> void: closed[0] += 1)
	m.open()
	_key("ui_cancel")
	check(not m.is_open(), "Esc закрыл")
	m.open()
	_key(CatchUpMenu.ACTION)
	check(not m.is_open(), "`=` закрыл")
	check(got.is_empty(), "без catch_up_requested")
	check(closed[0] == 2, "closed дважды")
	# Закрытое меню клавиши не трогает.
	_key("ui_accept")
	check(got.is_empty(), "закрытое меню Enter не ловит")
	var evs := InputMap.action_get_events(CatchUpMenu.ACTION)
	var has_key := false
	var has_pad := false
	for e in evs:
		has_key = has_key or (e is InputEventKey and e.physical_keycode == KEY_EQUAL)
		has_pad = has_pad or e is InputEventJoypadButton
	check(has_key and has_pad, "catch_up: клавиша `=` и кнопка геймпада")
	m.queue_free()


func test_pilot_leaving_updates_list_and_selection() -> void:
	var m := _menu()
	m.open()
	m.move_selection(1)
	check(m.selected_id() == "7", "выбрана Оля")
	# Оля ушла: строка исчезает, выделение — на той же позиции (Саша).
	_list = _list.filter(func(p: Dictionary) -> bool: return p.id != "7")
	m.refresh()
	check(not _ids(m).has("7"), "Оли нет в списке")
	check(m.selected_id() == "9", "выделение на той же позиции: " + m.selected_id())
	# Ушёл не выбранный — выделение остаётся на своём пилоте.
	_list = _list.filter(func(p: Dictionary) -> bool: return p.id != "5")
	m.refresh()
	check(m.selected_id() == "9", "Саша так и выделен")
	# Ушли все — пусто, Enter ничего не делает.
	_list = []
	m.refresh()
	check(m.rows().is_empty() and m.selected_id() == "", "пусто")
	var got := [false]
	m.catch_up_requested.connect(func(_id: String) -> void: got[0] = true)
	m.accept()
	check(not got[0], "пустой список — Enter без действия")
	m.queue_free()


func test_live_refresh_by_timer() -> void:
	var m := _menu()
	m.open()
	_list.append(_pilot("11", "Аня", false, Vector3(10, 1000, 10), false))
	for i in 20:
		m._process(0.05)
	check(_ids(m).has("11"), "новый пилот появился без ручного refresh")
	m.queue_free()


func test_pick_nearest_airborne_human_and_count() -> void:
	_fill()
	var others := _list.filter(func(p: Dictionary) -> bool: return p.id != "me")
	check(CatchUpMenu.pick_nearest_airborne_human(others, _own) == "5", "ближайший живой в воздухе")
	check(CatchUpMenu.airborne_count(others) == 2, "двое живых в воздухе (бот и Саша — нет)")
	var one := [_pilot("7", "Оля", false, Vector3(3000, 1500, 0), false)]
	check(CatchUpMenu.pick_nearest_airborne_human(one, _own) == "7", "один — он")
	check(CatchUpMenu.airborne_count(one) == 1, "один в воздухе")
	var none := [
		_pilot("bot-1", "Бот", true, Vector3(50, 1000, 0), false),
		_pilot("9", "Саша", false, Vector3(100, 900, 0), true),
	]
	check(CatchUpMenu.pick_nearest_airborne_human(none, _own) == "", "никого — пусто")
	check(CatchUpMenu.airborne_count(none) == 0, "0 в воздухе")
	check(CatchUpMenu.pick_nearest_airborne_human([], _own) == "", "пустой список")


func test_distance_format() -> void:
	var m := _menu()
	check(m.fmt_distance(63.0) == "60 %s" % tr("unit_m"), m.fmt_distance(63.0))
	var km := m.fmt_distance(2340.0)
	check(km.begins_with("2") and km.contains("3 " + tr("unit_km")), km)
	m.queue_free()


func test_remote_pilots_source_adapter() -> void:
	var rp := RemotePilots.new()
	rp.visuals_enabled = false
	add_child(rp)
	(
		rp
		. upsert(
			{
				"pilot_id": "7",
				"name": "Оля",
				"is_bot": false,
				"pos": Vector3(0, 1500, 0),
				"phase": "flying",
			}
		)
	)
	rp.upsert(
		{"pilot_id": "bot-2", "name": "Бот", "is_bot": true, "pos": Vector3.ZERO, "phase": "landed"}
	)
	var list: Array = CatchUpMenu.remote_pilots_source(rp).call()
	check(list.size() == 2, "2 пилота из RemotePilots")
	for p: Dictionary in list:
		if p.id == "7":
			check(not p.on_ground and p.name == "Оля", "Оля в воздухе")
		else:
			check(p.on_ground and p.landed and p.is_bot, "бот сел")
	rp.queue_free()
