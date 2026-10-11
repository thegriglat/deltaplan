extends TestCase
## Поток движения MR-К2 v3 («Поток»): режимы live/hold/neutral, плавный вход на всех переходах, множитель
## ускорений на земле, повтор пакета при зависании основного потока. MotionOutput с синтетическим входом (без сокета,
## пакеты — через packet_hook), порог скачка за пакет при rate_hz = 60, ramp_s = 2.5 в первые 2 с после перехода:
## ускорения srs ≤ 0.5 м/с², pitch/roll ≤ 1°, yaw ≤ 2.5° за пакет.

const DT := 1.0 / 120.0
const G := Units.G
const MAX_ACC := 0.5
const MAX_ANG := 1.0
const MAX_YAW := 2.5


## Стенд: выход + журнал пакетов (итоговые поля, режим, множитель).
class Rig:
	var o := MotionOutput.new()
	var frames: Array[Dictionary] = []
	var modes: Array[int] = []
	var scales: Array[float] = []

	func _init(fmt: String = "srs") -> void:
		o.enabled = true
		o.format = fmt
		o.every_n = 2
		o.rate_hz = 60
		o.ramp_s = 2.5
		o.ground_accel_scale = 0.3
		o.ground_blend_s = 0.4
		o.use_transport = false
		o.packet_hook = _on_packet
		o.reset()

	func _on_packet(_pkt: PackedByteArray, f: Dictionary, mode: int) -> void:
		frames.append(f)
		modes.append(mode)
		scales.append(o.ground_scale_now)

	## secs секунд физики; tel == null — без живых шагов.
	func run(secs: float, tel: Telemetry = null, mutate: Callable = Callable()) -> void:
		for i in int(round(secs / DT)):
			if tel != null:
				if mutate.is_valid():
					mutate.call(tel, i)
				o.step(tel, DT)
			o.tick(DT)


static func tel(vel: Vector3 = Vector3.ZERO, pitch_deg: float = 2.0, heading_deg: float = 151.0, bank_deg: float = 0.0,
		ground: bool = true) -> Telemetry:
	var t := Telemetry.new()
	t.pilot_velocity = vel
	t.air_velocity = vel
	t.pilot_basis = Basis.from_euler(Vector3(deg_to_rad(pitch_deg), -deg_to_rad(heading_deg), -deg_to_rad(bank_deg)))
	t.on_ground = ground
	return t


## Наибольший скачок поля за пакет на пакетах [from, to).
static func max_jump(frames: Array[Dictionary], key: String, from: int = 1, to: int = -1) -> float:
	var hi := frames.size() if to < 0 else mini(to, frames.size())
	var m := 0.0
	for i in range(maxi(1, from), hi):
		var d := float(frames[i][key]) - float(frames[i - 1][key])
		if key == "yaw" or key == "roll":
			d = wrapf(d, -180.0, 180.0)
		m = maxf(m, absf(d))
	return m


func _within(frames: Array[Dictionary], from: int, to: int, msg: String) -> void:
	for k in ["surge", "sway", "heave"]:
		check(max_jump(frames, k, from, to) <= MAX_ACC, "%s: скачок %s %.3f м/с² > %.1f" % [msg, k, max_jump(frames, k, from, to), MAX_ACC])
	for k in ["pitch", "roll"]:
		check(max_jump(frames, k, from, to) <= MAX_ANG, "%s: скачок %s %.2f° > %.1f" % [msg, k, max_jump(frames, k, from, to), MAX_ANG])
	check(max_jump(frames, "yaw", from, to) <= MAX_YAW, "%s: скачок yaw %.2f° > %.1f" % [msg, max_jump(frames, "yaw", from, to), MAX_YAW])


func test_menu_neutral_packets_flow() -> void:
	var r := Rig.new()
	r.run(2.0)  # без сцены полёта
	check(r.frames.size() == 120, "меню: 2 с при 60 Гц = 120 пакетов, а не %d" % r.frames.size())
	for i in r.frames.size():
		var f := r.frames[i]
		check(r.modes[i] == MotionOutput.Mode.NEUTRAL and f.surge == 0.0 and f.sway == 0.0 and f.heave == 0.0, "нейтраль: ускорения 0")
		check(f.pitch == 0.0 and f.roll == 0.0 and f.airspeed == 0.0, "нейтраль: углы и скорость 0")
	for f in r.frames:
		if f.surge != 0.0 or f.heave != 0.0:
			check(false, "в меню все пакеты нейтральные")
			break


func test_spawn_smooth_entry() -> void:
	var r := Rig.new()
	r.run(1.0)  # меню
	var n0 := r.frames.size()
	r.o.attach()
	r.o.reset()
	# склон, курс 151°, ускорения сразу «живые» (разбег начинается): поза + подтолкнуть
	var t := tel(Vector3.ZERO, 2.3, 151.0)
	r.run(3.0, t, func(tt: Telemetry, i: int) -> void:
		tt.pilot_velocity = Vector3(0, 0, -minf(3.0, 0.0 + i * DT * 1.5))
		tt.air_velocity = tt.pilot_velocity)
	var from := n0
	var to := n0 + 121  # первые 2 с после появления
	_within(r.frames, from, to, "появление")
	print("MR6 spawn: скачок за пакет в первые 2 с: surge %.3f sway %.3f vertical %.3f м/с², pitch %.2f roll %.2f yaw %.2f град" % [
		max_jump(r.frames, "surge", from, to), max_jump(r.frames, "sway", from, to), max_jump(r.frames, "heave", from, to),
		max_jump(r.frames, "pitch", from, to), max_jump(r.frames, "roll", from, to), max_jump(r.frames, "yaw", from, to)])
	check(r.modes[n0 + 5] == MotionOutput.Mode.LIVE, "после появления — live")
	check(bool(r.frames[n0 + 5].ramp), "идёт плавный вход (ramp)")
	check(not bool(r.frames[r.frames.size() - 1].ramp), "через 2.5 с плавный вход закончен")


func test_spawn_generic_flags_and_continuity() -> void:
	var r := Rig.new("generic")
	r.run(0.5)
	var f0 := r.frames[r.frames.size() - 1]
	check(bool(f0.synthetic) and not bool(f0.valid), "нейтраль generic: synthetic, valid = false")
	check(absf(f0.heave - G) < 1e-4, "нейтраль generic: heave = G")
	r.o.attach()
	var t := tel(Vector3(0, 0, -9.0), 6.0, 90.0, 0.0, false)
	r.run(1.0, t)
	var n := r.frames.size()
	check(bool(r.frames[n - 1].ramp) and not bool(r.frames[n - 1].synthetic), "generic live: ramp без synthetic")


func test_pause_hold_and_resume() -> void:
	var r := Rig.new()
	r.o.attach()
	var t := tel(Vector3(0, 0, -10.0), 6.0, 200.0, 20.0, false)
	r.run(4.0, t, func(tt: Telemetry, i: int) -> void:
		tt.pilot_velocity = Vector3(0, 0, -10.0 - 0.3 * i * DT)
		tt.air_velocity = tt.pilot_velocity)
	var live_last := r.frames[r.frames.size() - 1]
	var n0 := r.frames.size()
	r.run(2.0)  # пауза: живых шагов нет, сцена присоединена → hold
	check(r.frames.size() - n0 == 120, "пауза: пакеты идут (%d)" % (r.frames.size() - n0))
	for i in range(n0, r.frames.size()):
		check(r.modes[i] == MotionOutput.Mode.HOLD, "пауза: hold")
		if r.modes[i] != MotionOutput.Mode.HOLD:
			break
	var h := r.frames[r.frames.size() - 1]
	check(absf(h.roll - live_last.roll) < 0.5 and absf(h.pitch - live_last.pitch) < 0.5, "hold держит позу (roll %.2f→%.2f)" % [live_last.roll, h.roll])
	check(h.roll_rate == 0.0 and h.yaw_rate == 0.0 and bool(h.synthetic), "hold: угловые скорости 0, synthetic")
	_within(r.frames, n0 - 1, n0 + 120, "вход в паузу")
	# снятие паузы: Game делает reset() и снова шагает
	var n1 := r.frames.size()
	r.o.reset()
	r.run(3.0, t)
	_within(r.frames, n1 - 1, n1 + 121, "снятие паузы")


func test_menu_exit_and_reenter() -> void:
	var r := Rig.new()
	r.o.attach()
	var t := tel(Vector3(0, 0, -10.0), 6.0, 45.0, -15.0, false)
	r.run(3.0, t)
	var n0 := r.frames.size()
	r.o.detach()  # выход в меню
	r.run(3.0)
	check(r.frames.size() - n0 == 180, "меню после полёта: пакеты идут")
	check(r.modes[r.frames.size() - 1] == MotionOutput.Mode.NEUTRAL, "меню: нейтраль")
	_within(r.frames, n0 - 1, n0 + 121, "уход в меню")
	var last := r.frames[r.frames.size() - 1]
	check(absf(last.roll) < 1e-3 and absf(last.pitch) < 1e-3 and absf(last.heave) < 1e-3, "нейтраль достигнута")
	check(absf(wrapf(last.yaw - 45.0, -180.0, 180.0)) < 1e-3, "нейтраль держит последний курс")


func test_restart_and_teleport_reset_live() -> void:
	var r := Rig.new()
	r.o.attach()
	var t := tel(Vector3(0, 0, -11.0), 6.0, 10.0, 25.0, false)
	r.run(3.0, t)
	var n0 := r.frames.size()
	# телепорт/постановка крыла: другая поза и скорость, reset() при живом потоке
	var t2 := tel(Vector3(5.0, -1.0, 0.0), 0.0, 280.0, -30.0, true)
	r.o.reset()
	r.run(3.0, t2)
	_within(r.frames, n0 - 1, n0 + 121, "телепорт с reset")


func test_tow_start_end() -> void:
	var r := Rig.new()
	r.o.attach()
	var t := tel(Vector3(0, 0, -11.0), 6.0, 10.0, 25.0, false)
	r.run(3.0, t)
	var n0 := r.frames.size()
	r.o.reset()  # начало буксира: reset(), затем шагов нет (hold)
	r.run(3.0)
	_within(r.frames, n0 - 1, n0 + 121, "начало буксира")
	var n1 := r.frames.size()
	r.o.reset()  # конец буксира
	r.run(3.0, tel(Vector3(0, 0, -9.0), 3.0, 95.0, 0.0, false))
	_within(r.frames, n1 - 1, n1 + 121, "конец буксира")


func test_crash_protection_50g() -> void:
	var r := Rig.new()
	r.o.attach()
	var t := tel(Vector3(0, 0, -15.0), 3.0, 0.0, 0.0, false)
	r.run(2.0, t)
	var n0 := r.frames.size()
	# авария: скорость падает до нуля за шаг (> 50 g) — разрыв внутри MotionSource
	t.pilot_velocity = Vector3.ZERO
	t.air_velocity = Vector3.ZERO
	t.on_ground = true
	r.run(3.0, t)
	check(r.o._source.breaks >= 1, "защита 50 g сработала (%d)" % r.o._source.breaks)
	_within(r.frames, n0 - 2, n0 + 121, "авария")


func test_settings_change_is_smooth() -> void:
	var r := Rig.new()
	r.o.attach()
	var t := tel(Vector3(0, 0, -10.0), 6.0, 130.0, 15.0, false)
	r.run(4.0, t)  # ramp закончен
	var saved: Dictionary = (Config.get_config("motion_rig") as Dictionary).duplicate(true)
	var cfg: Dictionary = Config.get_config("motion_rig")
	cfg["enabled"] = true
	cfg["format"] = "srs"
	r.o.configure()  # подхватил конфиг
	r.run(4.0, t)
	var n1 := r.frames.size()
	var sg: Dictionary = (cfg["signs"] as Dictionary).duplicate()
	sg["heave"] = "inverse"
	sg["roll"] = "inverse"
	cfg["signs"] = sg
	r.o.configure()  # знак поменяли на лету
	r.run(3.0, t)
	cfg.clear()
	cfg.merge(saved)
	r.o.configure()
	r.o.shutdown()
	_within(r.frames, n1 - 1, n1 + 121, "смена знаков")
	check(not bool(r.frames[n1 + 1].synthetic) and bool(r.frames[n1 + 1].ramp), "смена настроек: плавный вход")
	var f := r.frames[r.frames.size() - 1]
	check(f.roll < 0.0, "знак roll применился (крен 15° стал %.1f)" % f.roll)


func test_output_off_goes_neutral_then_silent() -> void:
	var r := Rig.new()
	r.o.attach()
	var t := tel(Vector3(0, 0, -10.0), 6.0, 130.0, 15.0, false)
	r.run(4.0, t)
	var cfg: Dictionary = Config.get_config("motion_rig")
	var saved: Dictionary = cfg.duplicate(true)
	cfg["enabled"] = true
	r.o.configure()
	r.run(0.5, t)
	cfg["enabled"] = false
	r.o.configure()  # выключили вывод
	check(not r.o.enabled, "enabled = false")
	var n1 := r.frames.size()
	r.run(3.5, t)
	var got := r.frames.size() - n1
	check(got >= 140 and got <= 160, "после выключения пакеты идут до конца ухода: %d" % got)
	var last := r.frames[r.frames.size() - 1]
	check(absf(last.roll) < 1e-3 and absf(last.heave) < 1e-3, "ушли в нейтраль")
	var n2 := r.frames.size()
	r.run(2.0, t)
	check(r.frames.size() == n2, "затем тишина")
	_within(r.frames, n1 - 1, n1 + 121, "уход в нейтраль при выключении")
	cfg.clear()
	cfg.merge(saved)
	r.o.shutdown()


## Касание: удар ≈ 3 g на 0,1 с в момент on_ground false → true — пик vertical в пакете ≥ 0.75 пика без множителя.
func _touchdown_peak(gas: float) -> float:
	var r := Rig.new()
	r.o.ramp_s = 0.0
	r.o.ground_accel_scale = gas
	r.o.attach()
	var t := tel(Vector3(0, -2.94, -9.0), 0.0, 0.0, 0.0, false)
	r.run(1.0, t)
	var n0 := r.frames.size()
	r.run(1.0, t, func(tt: Telemetry, i: int) -> void:
		tt.on_ground = true  # касание
		var dur := 12
		tt.pilot_velocity.y = -2.94 * maxf(0.0, 1.0 - float(i + 1) / dur)
		tt.air_velocity = tt.pilot_velocity)
	var peak := 0.0
	for i in range(n0, r.frames.size()):
		peak = maxf(peak, absf(r.frames[i].heave))
	return peak


func test_touchdown_impact_survives_multiplier() -> void:
	var with_scale := _touchdown_peak(0.3)
	var without := _touchdown_peak(1.0)
	check(without > 20.0, "синтетический удар виден: %.1f м/с²" % without)
	check(with_scale >= 0.75 * without, "удар посадки идёт с множителем ≳ 0.8: %.1f против %.1f" % [with_scale, without])
	print("MR6 touchdown: пик vertical %.2f м/с² (×0.3) против %.2f (×1), отношение %.3f" % [with_scale, without, with_scale / without])


## На земле (через ≥ ground_blend_s) ускорения ровно ×ground_accel_scale; отрыв — без ступеньки.
func test_ground_multiplier_and_liftoff() -> void:
	var gas := 0.3
	var run := func(scale: float) -> Rig:
		var r := Rig.new()
		r.o.ramp_s = 0.0
		r.o.ground_accel_scale = scale
		r.o.attach()
		var t := tel(Vector3.ZERO, 2.0, 0.0, 0.0, true)
		r.run(2.0, t, func(tt: Telemetry, i: int) -> void:
			tt.pilot_velocity = Vector3(0, 0, -4.0 * i * DT)  # разбег a = 4 м/с²
			tt.air_velocity = tt.pilot_velocity)
		# отрыв: on_ground false, ускорение остаётся
		t.on_ground = false
		var v0 := t.pilot_velocity
		r.run(2.0, t, func(tt: Telemetry, i: int) -> void:
			tt.pilot_velocity = v0 + Vector3(0, 0, -4.0 * i * DT)
			tt.air_velocity = tt.pilot_velocity)
		return r
	var a: Rig = run.call(gas)
	var b: Rig = run.call(1.0)
	var i_g := 100  # 1.67 с на земле, > ground_blend_s
	check(absf(b.frames[i_g].surge) > 3.0, "разбег виден: %.2f" % b.frames[i_g].surge)
	approx(a.frames[i_g].surge, gas * b.frames[i_g].surge, 1e-3, "на земле ровно ×scale")
	approx(a.frames[i_g].heave, gas * b.frames[i_g].heave, 1e-3, "vertical на земле ×scale")
	approx(a.frames[i_g].pitch, b.frames[i_g].pitch, 1e-6, "углы не умножаются")
	var step_max := 0.0
	for i in range(1, a.scales.size()):
		step_max = maxf(step_max, absf(a.scales[i] - a.scales[i - 1]))
	var lim := (1.0 - gas) / (0.4 * 60.0) + 0.005
	check(step_max <= lim, "скачок множителя за пакет %.4f ≤ %.4f" % [step_max, lim])
	check(absf(a.scales[a.scales.size() - 1] - 1.0) < 1e-6, "в воздухе множитель 1")
	print("MR6 ground: surge ×%.3f на земле, скачок множителя за пакет %.4f (предел %.4f)" % [a.frames[i_g].surge / b.frames[i_g].surge, step_max, lim])
	# generic множитель не применяет
	var g := Rig.new("generic")
	g.o.ramp_s = 0.0
	g.o.attach()
	var t := tel(Vector3.ZERO, 2.0, 0.0, 0.0, true)
	g.run(1.0, t, func(tt: Telemetry, i: int) -> void: tt.pilot_velocity = Vector3(0, 0, -4.0 * i * DT))
	approx(g.frames[g.frames.size() - 1].surge, 4.0 + G * sin(deg_to_rad(2.0)), 0.1, "generic: честные величины на земле (a + g·sin)")


func test_no_duplicate_packets_per_tick() -> void:
	var o := MotionOutput.new()
	o.enabled = true
	o.use_transport = false
	o.every_n = 2
	o.rate_hz = 60
	var cnt := [0]
	o.packet_hook = func(_p: PackedByteArray, _f: Dictionary, _m: int) -> void: cnt[0] += 1
	var sent_ticks := 0
	for i in 240:
		if o.tick(DT):
			sent_ticks += 1
	check(cnt[0] == 120 and sent_ticks == 120, "один пакет на 2 тика: %d" % cnt[0])


## Зависание основного потока 1 с: поток отправки повторяет последний пакет — в приёмнике ≥ 0.8·rate_hz.
func test_main_thread_stall_keepalive() -> void:
	var rx := PacketPeerUDP.new()
	check(rx.bind(0, "127.0.0.1") == OK, "bind")
	var o := MotionOutput.new()
	o.enabled = true
	o.host = "127.0.0.1"
	o.port = rx.get_local_port()
	o.format = "generic"
	o.every_n = 2
	o.rate_hz = 60
	var t := tel(Vector3(0, 0, -10.0), 6.0, 130.0, 0.0, false)
	o.attach()
	var t0 := Time.get_ticks_usec()
	for i in 120:  # ~1 с нормального потока
		o.step(t, DT)
		o.tick(DT)
		var due := t0 + int((i + 1) * DT * 1e6)
		var now := Time.get_ticks_usec()
		if due > now:
			OS.delay_usec(due - now)
	while rx.get_available_packet_count() > 0:
		rx.get_packet()
	OS.delay_msec(1000)  # зависание основного потока
	var got := 0
	var syn := 0
	var seqs: Array[int] = []
	while rx.get_available_packet_count() > 0:
		var p := rx.get_packet()
		got += 1
		if (p.decode_u32(12) & 4) != 0:
			syn += 1
		seqs.append(p.decode_u32(8))
	check(got >= 48, "за секунду зависания пришло %d пакетов (нужно ≥ 48)" % got)
	check(syn == got, "повторы помечены synthetic: %d из %d" % [syn, got])
	for i in range(1, seqs.size()):
		check(seqs[i] == seqs[i - 1] + 1, "seq подряд")
		if seqs[i] != seqs[i - 1] + 1:
			break
	print("MR6 keepalive: за 1 с зависания %d пакетов, повторов потоком %d" % [got, o.repeats_sent])
	o.shutdown()
	rx.close()


## Автозагрузка MotionRig без сцены полёта: пакеты идут с частотой rate_hz, все нейтральные (меню).
func test_autoload_menu_stream() -> void:
	var rig: Node = Engine.get_main_loop().root.get_node_or_null("MotionRig")
	if rig == null:
		check(false, "автозагрузка MotionRig")
		return
	var rx := PacketPeerUDP.new()
	check(rx.bind(0, "127.0.0.1") == OK, "bind")
	var cfg: Dictionary = Config.get_config("motion_rig")
	var saved: Dictionary = cfg.duplicate(true)
	cfg["enabled"] = true
	cfg["format"] = "generic"
	cfg["host"] = "127.0.0.1"
	cfg["port"] = rx.get_local_port()
	cfg["ramp_s"] = 0.0
	rig.output.configure()
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 1500:
		await Engine.get_main_loop().process_frame
	var got := 0
	var non_neutral := 0
	while rx.get_available_packet_count() > 0:
		var p := rx.get_packet()
		got += 1
		if (p.decode_u32(12) & 4) == 0 or (p.decode_u32(12) & 1) != 0:
			non_neutral += 1
	cfg.clear()
	cfg.merge(saved)
	rig.output.configure()
	rig.output.shutdown()
	rx.close()
	check(got >= int(0.8 * 60 * 1.5), "меню: пакетов %d за 1.5 с (нужно ≥ 72)" % got)
	check(non_neutral == 0, "меню: все пакеты нейтральные (не нейтральных %d)" % non_neutral)
	print("MR6 menu: %d пакетов за 1.5 с, не нейтральных %d" % [got, non_neutral])
