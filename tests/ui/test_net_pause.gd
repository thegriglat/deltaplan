extends Node
## NET-52: данные зоны для паузы/загрузки (NetPauseInfo — тонкий слой над NetZone/NetPilots)
## и их показ в PauseMenu/LoadingScreen на подготовленном состоянии (без сети).

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


## Подставная NetZone: только поля, которые читает NetPauseInfo.build.
class FakeZone:
	extends RefCounted
	var in_zone := true
	var code := "4721"
	var peers: Dictionary = {}
	var leader_id := ""
	var my_id := ""


## Подставная NetPilots: высота чужого пилота — Y его последнего состояния (sample).
class FakePilots:
	extends RefCounted
	var states: Dictionary = {}  ## id -> {pos: Vector3}

	func has_pilot(id: String) -> bool:
		return states.has(id)

	func sample(id: String) -> Dictionary:
		return states.get(id, {})


func _make_zone() -> FakeZone:
	var z := FakeZone.new()
	z.my_id = "9"
	z.leader_id = "3"
	z.peers = {
		"3": {"id": "3", "name": "Папа", "joinOrder": 1},
		"7": {"id": "7", "name": "Alex", "joinOrder": 2},
		"9": {"id": "9", "name": "Я", "joinOrder": 3},
	}
	return z


func test_build_returns_empty_outside_zone() -> void:
	var z := _make_zone()
	z.in_zone = false
	check(NetPauseInfo.build(z, null).is_empty(), "вне зоны — пусто")


func test_build_orders_rows_marks_leader_me_and_unknown_altitude() -> void:
	var z := _make_zone()
	var pilots := FakePilots.new()
	pilots.states["3"] = {"pos": Vector3(0.0, 1234.0, 0.0)}
	# "7" (Alex) без состояния — высота неизвестна.
	var info := NetPauseInfo.build(z, pilots, 500.0)
	check(info.code == "4721", "код зоны")
	var rows: Array = info.pilots
	check(rows.size() == 3, "3 пилота")
	check(
		rows[0].name == "Папа" and rows[1].name == "Alex" and rows[2].name == "Я",
		"порядок подключения"
	)
	check(rows[0].is_leader and not rows[1].is_leader and not rows[2].is_leader, "ведущий — Папа")
	check(rows[2].is_me and not rows[0].is_me and not rows[1].is_me, "я — «Я»")
	check(rows[0].alt_m == 1234.0, "высота ведущего из sample()")
	check(rows[1].alt_m == null, "высота Alex неизвестна")
	check(rows[2].alt_m == 500.0, "своя высота — own_alt_m")


func _pause_menu() -> PauseMenu:
	var p: PauseMenu = (load("res://scenes/ui/pause_menu.tscn") as PackedScene).instantiate()
	add_child(p)
	return p


func test_pause_menu_shows_zone_block_with_leader_and_me() -> void:
	var z := _make_zone()
	var pilots := FakePilots.new()
	pilots.states["3"] = {"pos": Vector3(0.0, 1234.0, 0.0)}
	var info := NetPauseInfo.build(z, pilots, 500.0)
	var p := _pause_menu()
	check(not p.net_block_visible(), "вне зоны блок скрыт (по умолчанию)")
	p.set_net_info(info)
	check(p.net_block_visible(), "в зоне блок показан")
	check(p.net_code_text() == "4721", "код зоны показан")
	var lines := p.net_peer_lines()
	check(lines.size() == 3, "3 строки")
	check(lines[0].contains("Папа") and lines[0].contains(tr("net_leader")), "ведущий отмечен")
	check(lines[1].contains("Alex") and lines[1].contains("—"), "неизвестная высота — тире")
	check(lines[2].contains("Я") and lines[2].contains(tr("net_you")), "своя строка отмечена")
	p.set_net_info({})
	check(not p.net_block_visible(), "вышли из зоны — блок снова скрыт")
	p.queue_free()


func test_pause_menu_unchanged_outside_zone() -> void:
	var p := _pause_menu()
	check(not p.net_block_visible(), "нет зоны — блок скрыт")
	check(p.net_code_text() == "", "нет кода")
	check(p.net_peer_lines().is_empty(), "нет строк")
	p.queue_free()


func test_leave_zone_button_emits_signal() -> void:
	var z := _make_zone()
	var info := NetPauseInfo.build(z, null)
	var p := _pause_menu()
	p.set_net_info(info)
	var got := [false]
	p.leave_zone_requested.connect(func() -> void: got[0] = true)
	var btn: Button = p.get("_net_leave_btn")
	check(btn != null and btn.visible, "кнопка «Выйти из зоны» видна")
	btn.pressed.emit()
	check(got[0], "нажатие эмитит leave_zone_requested")
	p.queue_free()


func test_loading_screen_shows_zone_code_and_names() -> void:
	var z := _make_zone()
	var info := NetPauseInfo.build(z, null)
	var l: LoadingScreen = (load("res://scenes/ui/loading_screen.tscn") as PackedScene).instantiate()
	add_child(l)
	check(l.net_line_text() == "", "по умолчанию строки нет")
	l.set_net_info(info)
	var text := l.net_line_text()
	check(text.contains("4721"), "код зоны в строке")
	check(text.contains("Папа") and text.contains("Alex") and text.contains("Я"), "имена в строке")
	l.set_net_info({})
	check(l.net_line_text() == "", "снова скрыта вне зоны")
	l.queue_free()
