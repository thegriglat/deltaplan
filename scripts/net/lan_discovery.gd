extends Node
## NET-23. Поиск зон в локальной сети (автозагрузка LanDiscovery).
##
## Контракт — LanAnnounce в server/proto/deltaplan/v1/net.proto, описание и пример —
## docs/guide/net-protocol.md, «Поиск зон в локальной сети».
##
## Объявление (игра со встроенным сервером, NET-22): start_announcing(info_provider) — раз в
## секунду (первое — сразу) для каждой зоны из info_provider.call() шлёт UDP-датаграмму с
## proto3 JSON LanAnnounce (без Envelope) на broadcast_address:port (255.255.255.255:8081).
## info_provider() → Array словарей {code, host_name, address, port, game_version,
## pilots_count}; пустые host_name/address/game_version подставляются сами (имя пользователя
## ОС, первый локальный IPv4, версия игры). announce_now() — объявить немедленно (зона
## открылась). stop_announcing() — перестать.
##
## Слушатель (экран «Сетевая игра»): start_listening() / stop_listening(); zones — зоны рядом,
## сигнал zones_changed() — список изменился (появилась/пропала зона, поменялись поля).
## Зона пропадает через EXPIRE_S (3 с) без объявлений. Элемент zones:
##   {code, host_name, address, port, game_version, pilots_count, same_version, last_seen_s}
##   address — IP отправителя датаграммы (он достижим); поле address из объявления — только
##   если IP отправителя неизвестен. Подключаться: "%s:%d" % [address, port].
##   same_version — game_version совпадает со своей (иначе войти нельзя, пометить в списке).
##   last_seen_s — монотонное время последнего объявления, секунды (Time.get_ticks_msec()/1000).
## Своя зона (если игра и объявляет, и слушает) в списке тоже видна — это безвредно.
## На одной машине порт слушать может только один процесс: второй start_listening() вернёт
## false (в лог — предупреждение). Объявлять могут сколько угодно.
##
## Для тестов port, broadcast_address ("127.0.0.1" вместо broadcast) и game_version можно
## задать до start_*; класс создаётся и без автозагрузки (preload(...).new()).

signal zones_changed

## UDP-порт объявлений (WebSocket — NetClient.DEFAULT_PORT = 8080).
const PORT := 8081
## Период объявлений, с.
const ANNOUNCE_PERIOD_S := 1.0
## Зона пропадает из списка через столько секунд без объявлений.
const EXPIRE_S := 3.0

var port := PORT
var broadcast_address := "255.255.255.255"
## Своя версия игры (для same_version и подстановки в объявления).
var game_version: String = str(ProjectSettings.get_setting("application/config/version", ""))
## Зоны рядом (см. формат выше), по порядку появления.
var zones: Array = []

var _info_provider := Callable()
var _sender: PacketPeerUDP = null
var _listener: PacketPeerUDP = null
var _announce_left := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _exit_tree() -> void:
	stop_announcing()
	stop_listening()


# --- объявление ---


func start_announcing(info_provider: Callable) -> void:
	_info_provider = info_provider
	if _sender == null:
		_sender = PacketPeerUDP.new()
		_sender.set_broadcast_enabled(true)
		var err := _sender.bind(0)
		if err != OK:
			push_warning("LanDiscovery: не открыть UDP для объявлений (%s)" % error_string(err))
	_sender.set_dest_address(broadcast_address, port)
	announce_now()


func stop_announcing() -> void:
	_info_provider = Callable()
	if _sender != null:
		_sender.close()
		_sender = null


func is_announcing() -> bool:
	return _sender != null


## Разослать объявления всех зон сейчас (и отсчитать секунду заново).
func announce_now() -> void:
	_announce_left = ANNOUNCE_PERIOD_S
	if _sender == null or not _info_provider.is_valid():
		return
	var infos: Variant = _info_provider.call()
	if not infos is Array:
		return
	for info: Variant in infos:
		if info is Dictionary:
			var text := NetMessages.encode_bare("LanAnnounce", _announce_data(info))
			_sender.put_packet(text.to_utf8_buffer())


## Словарь info (snake_case) → поля LanAnnounce (lowerCamelCase) с подстановкой пустых.
func _announce_data(info: Dictionary) -> Dictionary:
	var host: String = str(info.get("host_name", ""))
	if host == "":
		host = default_host_name()
	var addr: String = str(info.get("address", ""))
	if addr == "":
		addr = local_ipv4()
	var ver: String = str(info.get("game_version", ""))
	if ver == "":
		ver = game_version
	return {
		"code": str(info.get("code", "")),
		"hostName": host,
		"address": addr,
		"port": int(info.get("port", 0)),
		"gameVersion": ver,
		"pilotsCount": int(info.get("pilots_count", 0)),
	}


## Имя пользователя ОС (USER / USERNAME), иначе "?".
static func default_host_name() -> String:
	for key in ["USER", "USERNAME"]:
		var v := OS.get_environment(key)
		if v != "":
			return v
	return "?"


## Первый локальный IPv4 не из 127.* (предпочтительно частный: 192.168.*, 10.*, 172.*), иначе "".
static func local_ipv4() -> String:
	var fallback := ""
	for a: String in IP.get_local_addresses():
		if a.contains(":") or a.begins_with("127.") or a.begins_with("169.254."):
			continue
		if a.begins_with("192.168.") or a.begins_with("10.") or a.begins_with("172."):
			return a
		if fallback == "":
			fallback = a
	return fallback


# --- слушатель ---


## Начать слушать порт. false — порт занят (другой процесс на этой машине уже слушает).
func start_listening() -> bool:
	if _listener != null:
		return true
	var l := PacketPeerUDP.new()
	var err := l.bind(port, "0.0.0.0")
	if err != OK:
		push_warning("LanDiscovery: не слушать UDP %d (%s)" % [port, error_string(err)])
		return false
	_listener = l
	return true


func stop_listening() -> void:
	if _listener != null:
		_listener.close()
		_listener = null
	if not zones.is_empty():
		zones.clear()
		zones_changed.emit()


func is_listening() -> bool:
	return _listener != null


func _process(delta: float) -> void:
	if _sender != null:
		_announce_left -= delta
		if _announce_left <= 0.0:
			announce_now()
	if _listener != null:
		_poll()


func _poll() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var changed := false
	while _listener.get_available_packet_count() > 0:
		var bytes := _listener.get_packet()
		var src := _listener.get_packet_ip()
		var d := NetMessages.decode_bare("LanAnnounce", bytes.get_string_from_utf8())
		if d.is_empty() or d.code == "" or d.port <= 0:
			continue
		changed = _upsert(d, src, now) or changed
	for i in range(zones.size() - 1, -1, -1):
		if now - float(zones[i].last_seen_s) > EXPIRE_S:
			zones.remove_at(i)
			changed = true
	if changed:
		zones_changed.emit()


## Обновить/добавить зону; true — список для игрока изменился.
func _upsert(d: Dictionary, src: String, now: float) -> bool:
	var entry := {
		"code": d.code,
		"host_name": d.hostName,
		"address": src if src != "" else d.address,
		"port": d.port,
		"game_version": d.gameVersion,
		"pilots_count": d.pilotsCount,
		"same_version": d.gameVersion == game_version,
		"last_seen_s": now,
	}
	for i in zones.size():
		var z: Dictionary = zones[i]
		if z.code == entry.code and z.address == entry.address and z.port == entry.port:
			var same := true
			for k in ["host_name", "game_version", "pilots_count"]:
				same = same and z[k] == entry[k]
			zones[i] = entry
			return not same
	zones.append(entry)
	return true
