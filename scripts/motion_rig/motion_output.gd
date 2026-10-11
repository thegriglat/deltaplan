class_name MotionOutput
extends RefCounted
## Отправка движения пилота по UDP (MR-К2 v3 «Поток», MR-К3 v3). Выключено → сокета и потока нет, на тик — одна проверка.
## Владелец — автозагрузка MotionRig: step() зовёт Game в шаг физики своего пилота, tick() — MotionRig каждый тик
## физики после Game. Пакеты идут всегда, пока вывод включён (live / hold / neutral), на любом переходе — плавный
## вход ramp_s в пространстве итоговых полей пакета, множитель ускорений на земле (srs), повтор пакета потоком
## отправки, если основной поток завис.

enum Mode { LIVE, HOLD, NEUTRAL }

var enabled: bool = false
var host: String = "127.0.0.1"
var port: int = 33001
var format: String = "srs"
var every_n: int = 2
var rate_hz: int = 60
## Название места старта (поле location формата srs).
var place: String = ""
var signs: Dictionary = {}  ## MR-К3 v2: величина → "direct" | "inverse"
var ramp_s: float = 2.5
var ground_accel_scale: float = 0.3
var ground_blend_s: float = 0.4

## Пакетов ушло (основной поток + повторы), из них повторов потоком отправки.
var packets_sent: int = 0
var repeats_sent: int = 0
var resolve_count: int = 0
## Тесты: false — пакеты не уходят в сокет (только packet_hook); поток повторов не запускается.
var use_transport: bool = true
var use_thread: bool = true
## Тесты: вызывается на каждый пакет основного потока: (pkt: PackedByteArray, frame: Dictionary, mode: int).
var packet_hook: Callable = Callable()
var last_mode: int = Mode.NEUTRAL
var last_frame: Dictionary = {}  ## итоговые поля последнего отправленного пакета
var ground_scale_now: float = 1.0  ## множитель ускорений на земле в последнем пакете

var _source := MotionSource.new()
var _attached: bool = false
var _stepped: bool = false  ## в этом окне пакета был живой шаг
var _held: MotionSample = null  ## последний живой сэмпл (для hold)
var _neutral_yaw: float = 0.0  ## курс последнего живого сэмпла (нейтраль курс не крутит)
var _counter: int = 0
var _acc_dt: float = 0.0
var _seq: int = 0
var _prev_mode: int = -1
var _breaks_seen: int = 0
var _req_ramp: bool = false
var _snap_scale: bool = true  ## множитель встаёт в цель сразу (после reset()/нейтрали)
var _gscale: float = 1.0
var _ramping: bool = false
var _tau: float = 0.0
var _p0: Dictionary = {}
var _winding_down: bool = false  ## вывод выключен: плавно в нейтраль, затем закрыть сокет
var _settings_key: Array = []
var _failed: bool = false  ## адрес не определился: не пытаться снова до configure()

# Общее с потоком повторов — только под _mutex.
var _mutex := Mutex.new()
var _thread: Thread = null
var _stop: bool = false
var _udp: PacketPeerUDP = null
var _last_pkt: PackedByteArray = PackedByteArray()
var _last_main_usec: int = 0
var _last_repeat_usec: int = 0


## Прочитать configs/motion_rig.json (и применить сразу, без перезапуска полёта).
func configure() -> void:
	var was := enabled
	enabled = bool(Config.value("motion_rig", "enabled", false))
	var new_host := String(Config.value("motion_rig", "host", "127.0.0.1")).strip_edges()
	var new_port := int(Config.value("motion_rig", "port", 33001))
	var new_format := String(Config.value("motion_rig", "format", "srs"))
	var sg: Variant = Config.value("motion_rig", "signs", {})
	signs = (sg as Dictionary).duplicate() if sg is Dictionary else {}
	rate_hz = clampi(int(Config.value("motion_rig", "rate_hz", 60)), 1, 100000)
	every_n = maxi(1, roundi(float(Engine.physics_ticks_per_second) / float(rate_hz)))
	ramp_s = clampf(float(Config.value("motion_rig", "ramp_s", 2.5)), 0.0, 10.0)
	ground_accel_scale = clampf(float(Config.value("motion_rig", "ground_accel_scale", 0.3)), 0.0, 1.0)
	ground_blend_s = clampf(float(Config.value("motion_rig", "ground_blend_s", 0.4)), 0.05, 2.0)
	var addr_changed := new_host != host or new_port != port
	host = new_host
	port = new_port
	format = new_format
	if addr_changed or _failed:
		_close_socket()
	var key: Array = [format, ground_accel_scale, ramp_s, signs, every_n]
	if enabled and not was:
		_enable()
	elif not enabled and was:
		_begin_wind_down()
	elif enabled and (key != _settings_key or addr_changed):
		_req_ramp = true  # смена настроек (в т. ч. знаков и множителя) — плавно, без скачка пакета
	_settings_key = key


## Включение вывода: поток с нуля; первый пакет входит плавно из нейтрали.
func _enable() -> void:
	if _winding_down:
		_winding_down = false  # включили снова, не дожидаясь конца ухода: продолжаем с последнего пакета
		_req_ramp = true
		return
	_seq = 0
	last_frame = {}
	_source.reset()
	_breaks_seen = _source.breaks
	_counter = 0
	_acc_dt = 0.0
	_prev_mode = -1
	_snap_scale = true
	_req_ramp = true


func _begin_wind_down() -> void:
	if last_frame.is_empty():
		_close_socket()
		return
	_winding_down = true
	_req_ramp = true


## Сцена полёта присоединена / ушла (Game: set_flying). Пока присоединена и живых шагов нет — hold, иначе neutral.
func attach() -> void:
	_attached = true


func detach() -> void:
	_attached = false
	_held = null


func is_attached() -> bool:
	return _attached


## Разрыв потока (MR-К1): новый полёт, телепорт, постановка крыла, буксир, снятие паузы.
func reset() -> void:
	_source.reset()
	_breaks_seen = _source.breaks
	_snap_scale = true
	if enabled:
		_req_ramp = true  # плавный вход — отдельно от seq: номер пакета растёт через все разрывы


## Живой шаг физики своего пилота (внутри MotionSource.push).
func step(tel: Telemetry, dt: float) -> void:
	if not enabled:
		return
	_source.push(tel, dt)
	_stepped = true


## Тик физики (после Game): раз в every_n тиков — один пакет. true, если пакет ушёл на этом тике.
func tick(dt: float) -> bool:
	if (not enabled and not _winding_down) or (_failed and use_transport):
		_stepped = false  # выключено или адрес неверный (до configure()): пакет не собираем
		return false
	_acc_dt += dt
	_counter += 1
	if _counter < every_n:
		return false
	_counter = 0
	var pdt := _acc_dt
	_acc_dt = 0.0
	var pushed := _stepped
	_stepped = false
	var mode: int
	if _winding_down:
		mode = Mode.NEUTRAL
	elif pushed:
		mode = Mode.LIVE
	elif _attached and _held != null:
		mode = Mode.HOLD
	else:
		mode = Mode.NEUTRAL
	var s: MotionSample
	var trigger := _req_ramp or mode != _prev_mode
	match mode:
		Mode.LIVE:
			s = _source.sample()
			_held = s
			_neutral_yaw = s.yaw
			if _source.breaks != _breaks_seen:
				_breaks_seen = _source.breaks
				trigger = true  # защита от телепорта (50 g) — разрыв, как reset()
		Mode.HOLD:
			s = _hold_sample()
		_:
			s = _neutral_sample()
	_req_ramp = false
	var scale := _next_ground_scale(s, mode, pdt)
	var f := MotionPacket.make_frame(s, format, signs, scale, mode != Mode.LIVE)
	if trigger:
		_start_ramp(f)
	_prev_mode = mode
	if _ramping:
		var x := _tau / ramp_s if ramp_s > 0.0 else 1.0
		if x >= 1.0:
			_ramping = false
		else:
			f = MotionPacket.blend(_p0, f, x * x * (3.0 - 2.0 * x))
			f["ramp"] = true
		_tau += pdt
	last_mode = mode
	last_frame = f
	ground_scale_now = scale
	_emit(f, mode)
	if _winding_down and not _ramping:
		_winding_down = false
		_finish_stream()
	return true


## Сэмпл удержания: последний живой, угловые скорости = 0, остальное как было.
func _hold_sample() -> MotionSample:
	var h := MotionSample.new()
	var s := _held
	h.surge = s.surge
	h.sway = s.sway
	h.heave = s.heave
	h.roll = s.roll
	h.pitch = s.pitch
	h.yaw = s.yaw
	h.airspeed = s.airspeed
	h.air_lateral = s.air_lateral
	h.valid = s.valid
	h.t = s.t
	h.on_ground = s.on_ground
	return h


## Нейтраль: стоя на ровном неподвижно, курс — последний.
func _neutral_sample() -> MotionSample:
	var n := MotionSample.new()
	n.heave = Units.G
	n.yaw = _neutral_yaw
	n.on_ground = true
	n.valid = false
	return n


## Множитель ускорений на земле (srs): цель — ground_accel_scale на земле, 1 в воздухе; сдвиг не быстрее
## (1 − scale)/ground_blend_s в секунду. После reset() и в нейтрали — сразу в цель.
func _next_ground_scale(s: MotionSample, mode: int, pdt: float) -> float:
	var target := ground_accel_scale if s.on_ground else 1.0
	if _snap_scale or mode == Mode.NEUTRAL:
		_gscale = target
		_snap_scale = false
	else:
		_gscale = move_toward(_gscale, target, (1.0 - ground_accel_scale) / ground_blend_s * pdt)
	return _gscale


## Начало плавного входа: P0 — последний отправленный пакет (нет такого или другой формат — нейтраль с курсом цели).
func _start_ramp(target: Dictionary) -> void:
	if ramp_s <= 0.0:
		_ramping = false
		return
	if last_frame.is_empty() or last_frame.format != target.format:
		var neutral := MotionPacket.make_frame(_neutral_sample(), format, signs, 1.0, true)
		neutral["yaw"] = target.yaw
		_p0 = neutral
	else:
		_p0 = last_frame.duplicate()
	_ramping = true
	_tau = 0.0


func _emit(f: Dictionary, mode: int) -> void:
	var pkt := MotionPacket.pack_frame(f, place, 0)
	if packet_hook.is_valid():
		packet_hook.call(pkt, f, mode)
	if use_transport:
		_transmit(pkt)


## Основной поток: отправить пакет, запомнить для повтора. seq (generic) проставляется здесь, под замком.
func _transmit(pkt: PackedByteArray) -> void:
	if _failed:
		return
	_mutex.lock()
	if _udp == null and not _open_locked():
		_mutex.unlock()
		return
	if format == "generic":
		pkt.encode_u32(8, _seq & 0xFFFFFFFF)
		_seq += 1
	_last_pkt = pkt
	_last_main_usec = Time.get_ticks_usec()
	_last_repeat_usec = 0
	if _udp.put_packet(pkt) == OK:
		packets_sent += 1
	_mutex.unlock()


## Адрес определяется один раз на открытие сокета (IP — как есть, имя — IP.resolve_hostname); неудача
## запоминается до следующего configure(): вывод выключен, повторов в шаге физики нет. Под _mutex.
func _open_locked() -> bool:
	if host.is_empty() or port < 1 or port > 65535:
		_failed = true
		return false
	var ip := host if host.is_valid_ip_address() else _resolve(host)
	var u := PacketPeerUDP.new()
	if ip.is_empty() or u.set_dest_address(ip, port) != OK:
		_failed = true
		return false
	_udp = u
	if use_thread and _thread == null:
		_stop = false
		_thread = Thread.new()
		_thread.start(_repeat_loop)
	return true


## Поток отправки: если очередного пакета нет дольше 1.5 периода — повторяет последний (generic: свой seq и
## бит synthetic), по одному на период, пока основной поток не вернётся.
func _repeat_loop() -> void:
	while true:
		_mutex.lock()
		var stop := _stop
		var period := int(1000000.0 / float(maxi(1, rate_hz)))
		if not stop and _udp != null and not _last_pkt.is_empty():
			var now := Time.get_ticks_usec()
			if now - _last_main_usec > period * 3 / 2 and now - maxi(_last_main_usec, _last_repeat_usec) >= period:
				var pkt := _last_pkt.duplicate()
				if pkt.size() == MotionPacket.GENERIC_SIZE:
					pkt.encode_u32(8, _seq & 0xFFFFFFFF)
					pkt.encode_u32(12, pkt.decode_u32(12) | MotionPacket.FLAG_SYNTHETIC)
					_seq += 1
				_last_repeat_usec = now
				if _udp.put_packet(pkt) == OK:
					packets_sent += 1
					repeats_sent += 1
		_mutex.unlock()
		if stop:
			return
		OS.delay_usec(maxi(1000, period / 4))


## Конец потока (вывод выключен после ухода в нейтраль): сокет закрыть.
func _finish_stream() -> void:
	_close_socket()
	last_frame = {}
	_prev_mode = -1


## Остановить поток повторов и закрыть сокет. Зовёт MotionRig._exit_tree (выход из игры — без плавного ухода).
func shutdown() -> void:
	_close_socket()


func _close_socket() -> void:
	_mutex.lock()
	_stop = true
	var t := _thread
	_mutex.unlock()
	if t != null:
		t.wait_to_finish()
	_mutex.lock()
	_thread = null
	_stop = false
	if _udp != null:
		_udp.close()
		_udp = null
	_last_pkt = PackedByteArray()
	_failed = false
	_mutex.unlock()


func _resolve(name: String) -> String:
	resolve_count += 1
	return IP.resolve_hostname(name)
