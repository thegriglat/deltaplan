class_name MotionOutput
extends RefCounted
## Отправка движения пилота по UDP (MR-К2/К3). Выключено → сокета нет, на шаг физики — одна проверка флага.
## step() зовёт Game после glider.step(dt) для своего пилота в полёте; reset() — на разрыв.

var enabled: bool = false
var host: String = "127.0.0.1"
var port: int = 33001
var format: String = "srs"
var every_n: int = 2
## Название места старта (поле location формата srs).
var place: String = ""
var packets_sent: int = 0

var _source := MotionSource.new()
var _udp: PacketPeerUDP = null
var _counter: int = 0
var _seq: int = 0
var _active: bool = false  ## были шаги в полёте с прошлого reset()


## Прочитать configs/motion_rig.json (и применить сразу, без перезапуска полёта).
func configure() -> void:
	var was := enabled
	enabled = bool(Config.value("motion_rig", "enabled", false))
	host = String(Config.value("motion_rig", "host", "127.0.0.1")).strip_edges()
	port = int(Config.value("motion_rig", "port", 33001))
	format = String(Config.value("motion_rig", "format", "srs"))
	var hz := clampi(int(Config.value("motion_rig", "rate_hz", 60)), 1, 100000)
	every_n = maxi(1, roundi(float(Engine.physics_ticks_per_second) / float(hz)))
	_close()
	if enabled and not was:
		reset()


func reset() -> void:
	_source.reset()
	_counter = 0
	_seq = 0
	_active = false


## Вне полёта: пакетов нет; следующий полёт начнётся с reset().
func idle() -> void:
	if _active:
		reset()


func step(tel: Telemetry, dt: float) -> void:
	if not enabled:
		return
	_active = true
	_source.push(tel, dt)
	_counter += 1
	if _counter < every_n:
		return
	_counter = 0
	var pkt := build_packet(_source.sample())
	_send(pkt)


func build_packet(s: MotionSample) -> PackedByteArray:
	var pkt: PackedByteArray
	if format == "generic":
		pkt = MotionPacket.pack_generic(s, _seq)
	else:
		pkt = MotionPacket.pack_srs(s, place)
	_seq += 1
	return pkt


func _send(pkt: PackedByteArray) -> void:
	if _udp == null:
		if host.is_empty() or port < 1 or port > 65535:
			return
		var u := PacketPeerUDP.new()
		if u.set_dest_address(host, port) != OK:
			return  # неверный адрес: отправка выключена
		_udp = u
	if _udp.put_packet(pkt) == OK:
		packets_sent += 1


func _close() -> void:
	if _udp != null:
		_udp.close()
		_udp = null
