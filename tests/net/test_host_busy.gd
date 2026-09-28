extends Node
## Ведущий занят загрузкой мира (главный поток стоит ~10 с) — встроенный сервер (свой поток)
## всё равно принимает: второй процесс godot (tests/net/join_helper.gd) подключается и входит
## в зону за время блокировки. После неё ведущий видит нового пилота, а его собственный
## NetClient не отключён (тот же id, в зоне, Ping/Pong снова идут).

const NET_CLIENT := preload("res://scripts/net/net_client.gd")
const NET_ZONE := preload("res://scripts/net/net_zone.gd")
const HELPER := "res://tests/net/join_helper.tscn"
const PORT_MIN := 20000
const PORT_MAX := 40000
## Сколько «грузится мир», мс; кусками, как синхронные шаги загрузки.
const BLOCK_MS := 10000
const BLOCK_CHUNK_MS := 500

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func test_join_while_host_blocked() -> void:
	var c: Node = NET_CLIENT.new()
	c.ping_interval_s = 0.5
	add_child(c)
	var z: Node = NET_ZONE.new()
	z.setup(c)
	add_child(z)
	var log := []
	c.disconnected.connect(func(w: bool) -> void: log.append("disconnected:%s" % w))
	c.error.connect(func(e: String, _t: String) -> void: log.append("error:" + e))
	var port := _free_port()
	z.host_local(FlightSettings.new(), 4711, 0, "Коля", port)
	await _wait(func() -> bool: return z.in_zone, 5.0)
	check(z.in_zone and z.is_hosting(), "ведущий в зоне: %s" % [log])
	if not z.in_zone:
		return
	var my_id: String = c.my_id
	var out := OS.get_temp_dir().path_join("deltaplan_join_%d_%d.txt" % [OS.get_process_id(), port])
	DirAccess.remove_absolute(out)
	var args := [
		"--headless",
		"--path",
		ProjectSettings.globalize_path("res://"),
		HELPER,
		"--",
		"--addr=127.0.0.1:%d" % port,
		"--code=%s" % z.code,
		"--out=%s" % out,
		"--seconds=60",
	]
	var pid := OS.create_process(OS.get_executable_path(), args)
	check(pid > 0, "второй процесс запущен")
	if pid <= 0:
		return
	# «загрузка мира»: главный поток занят, кадров нет
	var t0 := Time.get_unix_time_from_system()
	var blocked := 0
	while blocked < BLOCK_MS:
		OS.delay_msec(BLOCK_CHUNK_MS)
		blocked += BLOCK_CHUNK_MS
	var t_unblock := Time.get_unix_time_from_system()
	var lines := _read_lines(out)
	print("    за %.1f с блокировки второй процесс: %s" % [t_unblock - t0, lines])
	var joined := _find_line(lines, "joined")
	check(joined != "", "вошёл в зону, пока ведущий занят: %s" % [lines])
	if joined != "":
		check(float(joined.get_slice(" ", 1)) < t_unblock, "вход — во время блокировки")
		check(joined.get_slice(" ", 2) == "2", "в зоне двое: %s" % joined)
	# не успел за 10 с (медленный запуск godot) — ждём и после, но вход обязателен
	await _wait(func() -> bool: return _find_line(_read_lines(out), "joined") != "", 20.0)
	check(_find_line(_read_lines(out), "joined") != "", "второй процесс в зоне")
	var errs := _read_lines(out).filter(func(l: String) -> bool: return l.begins_with("error"))
	check(errs.is_empty(), "без ошибок: %s" % [errs])
	# ведущий: новый пилот виден, своё соединение живо
	await _wait(func() -> bool: return z.peers.size() == 2, 5.0)
	check(z.peers.size() == 2, "ведущий видит второго: %s" % [z.peer_ids()])
	check(c.is_online and c.my_id == my_id, "свой клиент не отключался")
	check(z.in_zone and z.is_leader(), "ведущий в зоне")
	check(log.is_empty(), "без обрывов и ошибок: %s" % [log])
	var pongs := [0]
	c.message.connect(
		func(type: String, _d: Dictionary, _f: String) -> void: pongs[0] += int(type == "pong")
	)
	await _wait(func() -> bool: return pongs[0] >= 2, 3.0)
	check(pongs[0] >= 2, "Ping/Pong после блокировки: %d" % pongs[0])
	# Pong на ping, ушедший до блокировки, не испортил замеры
	check(c.latency_ms >= 0.0 and c.latency_ms < 100.0, "RTT: %.1f мс" % c.latency_ms)
	var skew: float = c.server_time() - Time.get_unix_time_from_system()
	check(absf(skew) < 0.2, "часы сервера: расхождение %.3f с" % skew)
	OS.kill(pid)
	await _wait(func() -> bool: return z.peers.size() == 1, 5.0)
	check(z.peers.size() == 1, "второй ушёл (обрыв TCP виден)")
	z.leave_zone()
	check(not z.is_hosting(), "сервер остановлен")
	DirAccess.remove_absolute(out)
	z.queue_free()
	c.queue_free()


func _read_lines(path: String) -> Array:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var out := []
	for l in f.get_as_text().split("\n", false):
		out.append(l)
	return out


func _find_line(lines: Array, prefix: String) -> String:
	for l: String in lines:
		if l.begins_with(prefix + " "):
			return l
	return ""


## Свободный порт на всех адресах (как слушает host_local).
func _free_port() -> int:
	for i in 20:
		var p := randi_range(PORT_MIN, PORT_MAX)
		var probe := TCPServer.new()
		if probe.listen(p) == OK:
			probe.stop()
			return p
	return PORT_MIN


func _wait(cond: Callable, timeout_s: float) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
