extends Node
## NET-23. LanDiscovery: объявления зон по UDP и список «Рядом».
## В одном процессе: слушатель видит зону ≤ 2 с, после остановки объявлений — пропадает
## ≤ 4 с, зона другой версии помечена same_version = false, смена числа пилотов → zones_changed.
## Два процесса: второй godot (tests/net/lan_announce_helper.gd) объявляет зону, этот слушает.
## Адрес назначения — 127.0.0.1 (broadcast в песочнице может быть закрыт), порт — случайный.

const LAN_DISCOVERY := preload("res://scripts/net/lan_discovery.gd")
const HELPER := "res://tests/net/lan_announce_helper.gd"
## Сколько ждать, проверяя, что зона не пропадает при идущих объявлениях (> EXPIRE_S).
const EXPIRE_WAIT_S := 3.5

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_announce_listen_expire() -> void:
	var port := 47000 + randi() % 900
	var listener := _lan(port)
	var announcer := _lan(port)
	check(listener.start_listening(), "слушатель открыл порт %d" % port)
	var changes := [0]
	listener.zones_changed.connect(func() -> void: changes[0] += 1)
	var infos := [
		{"code": "4721", "host_name": "Коля", "port": 8080, "pilots_count": 1},
		{"code": "1234", "host_name": "Старый", "port": 8080, "game_version": "0.6.0"},
	]
	var t0 := Time.get_ticks_msec()
	announcer.start_announcing(func() -> Array: return infos)
	await _wait(func() -> bool: return listener.zones.size() == 2, 3.0)
	var seen_s := (Time.get_ticks_msec() - t0) / 1000.0
	check(listener.zones.size() == 2, "две зоны: %s" % [listener.zones])
	check(seen_s <= 2.0, "зоны видны за %.2f с (≤ 2)" % seen_s)
	var z := _find(listener, "4721")
	check(not z.is_empty(), "зона 4721 в списке")
	if not z.is_empty():
		check(z.host_name == "Коля" and z.port == 8080 and z.pilots_count == 1, "поля: %s" % [z])
		check(z.address == "127.0.0.1", "адрес — отправитель датаграммы: %s" % z.address)
		check(z.same_version and z.game_version == listener.game_version, "своя версия")
		check(z.last_seen_s is float, "last_seen_s")
	var old := _find(listener, "1234")
	check(not old.is_empty() and old.same_version == false, "другая версия помечена: %s" % [old])

	# объявления идут раз в секунду: зона не пропадает, смена пилотов → zones_changed
	var before: int = changes[0]
	infos[0]["pilots_count"] = 3
	await _wait(func() -> bool: return _find(listener, "4721").get("pilots_count") == 3, 2.0)
	check(_find(listener, "4721").get("pilots_count") == 3, "число пилотов обновилось")
	check(changes[0] > before, "zones_changed при смене числа пилотов")
	await _wait(func() -> bool: return false, EXPIRE_WAIT_S)
	check(listener.zones.size() == 2, "зоны держатся, пока идут объявления")

	# остановка → пропадает за ≤ 4 с
	announcer.stop_announcing()
	var t1 := Time.get_ticks_msec()
	await _wait(func() -> bool: return listener.zones.is_empty(), 6.0)
	var gone_s := (Time.get_ticks_msec() - t1) / 1000.0
	check(listener.zones.is_empty(), "после остановки зоны пропали")
	check(gone_s <= 4.0, "пропали за %.2f с (≤ 4)" % gone_s)

	# второй слушатель на том же порту в этой же машине — false, без падения
	var third := _lan(port)
	var ok2: bool = third.start_listening()
	print("    второй слушатель на том же порту: ", ok2)
	listener.stop_listening()
	third.stop_listening()


## Второй процесс godot объявляет зону — этот её видит; после kill — пропадает.
func test_two_processes() -> void:
	var port := 47000 + randi() % 900 + 950
	var listener := _lan(port)
	check(listener.start_listening(), "слушатель открыл порт %d" % port)
	var args := [
		"--headless",
		"--path",
		ProjectSettings.globalize_path("res://"),
		"--script",
		HELPER,
		"--",
		"--port=%d" % port,
		"--dest=127.0.0.1",
		"--code=5555",
		"--version=0.0.1-другая",
		"--seconds=30",
	]
	var t_spawn := Time.get_ticks_msec()
	var pid := OS.create_process(OS.get_executable_path(), args)
	check(pid > 0, "второй процесс запущен")
	if pid <= 0:
		return
	# запуск godot занимает секунды — ждём появления с запасом, а «≤ 2 с» считаем от
	# интервала между объявлениями (новый слушатель видит зону не позже следующего)
	await _wait(func() -> bool: return not _find(listener, "5555").is_empty(), 20.0)
	var z := _find(listener, "5555")
	check(not z.is_empty(), "зона второго процесса видна")
	print("    второй процесс: зона видна через %.2f с после запуска" % [
		(Time.get_ticks_msec() - t_spawn) / 1000.0])
	if not z.is_empty():
		check(z.host_name == "Помощник" and z.pilots_count == 2, "поля: %s" % [z])
		check(z.same_version == false, "другая версия помечена")
		# интервал между объявлениями ≤ 2 с (ждём следующего)
		var last: float = z.last_seen_s
		await _wait(func() -> bool: return _find(listener, "5555").get("last_seen_s", last) > last, 3.0)
		var gap: float = float(_find(listener, "5555").get("last_seen_s", 1e9)) - last
		check(gap <= 2.0, "объявления каждые %.2f с (≤ 2)" % gap)
	OS.kill(pid)
	var t1 := Time.get_ticks_msec()
	await _wait(func() -> bool: return _find(listener, "5555").is_empty(), 6.0)
	var gone_s := (Time.get_ticks_msec() - t1) / 1000.0
	check(_find(listener, "5555").is_empty(), "после остановки второго процесса зона пропала")
	check(gone_s <= 4.0, "пропала за %.2f с (≤ 4)" % gone_s)
	listener.stop_listening()


func _lan(port: int) -> Node:
	var lan: Node = LAN_DISCOVERY.new()
	lan.port = port
	lan.broadcast_address = "127.0.0.1"
	add_child(lan)
	return lan


func _find(lan: Node, code: String) -> Dictionary:
	for z: Dictionary in lan.zones:
		if z.code == code:
			return z
	return {}


func _wait(cond: Callable, timeout_s: float) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
