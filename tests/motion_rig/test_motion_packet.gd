extends TestCase
## Пакеты MR-К2: упаковка известного сэмпла и разбор по смещениям контракта; настройки; микрозамер.

const G := Units.G


static func known() -> MotionSample:
	var s := MotionSample.new()
	s.surge = 1.5
	s.sway = -2.0
	s.heave = 11.0
	s.roll = 12.5
	s.pitch = -3.25
	s.yaw = 270.0
	s.roll_rate = 4.0
	s.pitch_rate = -5.0
	s.yaw_rate = 6.0
	s.airspeed = 12.0
	s.air_lateral = 0.5
	s.valid = true
	s.on_ground = false
	s.t = 7.5
	return s


## Строка C из поля b[from:to] до первого нуля.
static func cstr(b: PackedByteArray, from: int, to: int) -> String:
	var raw := b.slice(from, to)
	var n := raw.find(0)
	return (raw.slice(0, n) if n >= 0 else raw).get_string_from_utf8()


func test_srs_layout() -> void:
	var b := MotionPacket.pack_srs(known(), "Altai")
	check(b.size() == 236, "размер srs %d" % b.size())
	check(b.slice(0, 3).get_string_from_ascii() == "api" and b[3] == 0, "api + выравнивание")
	check(b.decode_u32(4) == 102, "version")
	check(cstr(b, 8, 58) == "Deltaplan", "game")
	check(cstr(b, 58, 108) == "Hang glider", "vehicle")
	check(cstr(b, 108, 158) == "Altai", "location")
	approx(b.decode_float(160), 12.0 * 3.6, 1e-4, "speed км/ч")
	approx(b.decode_float(176), -3.25, 1e-5, "pitch")
	approx(b.decode_float(180), 12.5, 1e-5, "roll")
	approx(b.decode_float(184), -90.0, 1e-5, "yaw в (−180, 180]")
	approx(b.decode_float(188), 0.5, 1e-5, "lateral_velocity")
	approx(b.decode_float(192), -2.0 / G, 1e-5, "lateral_acceleration, g")
	approx(b.decode_float(196), 11.0 / G - 1.0, 1e-5, "vertical_acceleration, g")
	approx(b.decode_float(200), 1.5 / G, 1e-5, "longitudinal_acceleration, g")
	check(b.decode_s32(172) == 0, "gear")
	for off in [164, 168, 204, 208, 212, 216, 220, 224, 228, 232]:
		check(b.decode_u32(off) == 0, "нулевое поле @%d" % off)


func test_srs_location_truncation() -> void:
	var long := "Ж".repeat(40)  # 80 байт UTF-8
	var b := MotionPacket.pack_srs(known(), long)
	check(b[157] == 0 and b[158] == 0 and b[159] == 0, "терминатор и выравнивание")
	var txt := cstr(b, 108, 158)
	check(txt == "Ж".repeat(24), "обрезано по границе символа (48 байт): %s" % txt)
	b = MotionPacket.pack_srs(known(), "a" + "Ж".repeat(30))  # 'a' + 2-байтные: 49-й байт — середина символа
	check(cstr(b, 108, 158) == "a" + "Ж".repeat(24), "обрезка до 48 байт: сдвиг границы")
	check(b.size() == 236, "размер")


func test_generic_layout() -> void:
	var s := known()
	var b := MotionPacket.pack_generic(s, 42)
	check(b.size() == 64, "размер generic %d" % b.size())
	check(b.slice(0, 4).get_string_from_ascii() == "DPMR", "magic")
	check(b.decode_u32(4) == 1, "version")
	check(b.decode_u32(8) == 42, "seq")
	check(b.decode_u32(12) == 1, "flags: valid")
	s.valid = false
	s.on_ground = true
	check(MotionPacket.pack_generic(s, 0).decode_u32(12) == 2, "flags: на земле")
	var want := [7.5, 1.5, -2.0, 11.0, 12.5, -3.25, 270.0, 4.0, -5.0, 6.0, 12.0, 0.5]
	for i in want.size():
		approx(b.decode_float(16 + 4 * i), want[i], 1e-5, "generic float #%d @%d" % [i, 16 + 4 * i])


func test_signs_default_is_direct() -> void:
	var s := known()
	check(MotionPacket.pack_srs(s, "x") == MotionPacket.pack_srs(s, "x", {}), "srs: пусто = direct")
	var all_direct := {}
	for k in MotionPacket.SIGN_KEYS:
		all_direct[k] = "direct"
	check(MotionPacket.pack_generic(s, 1) == MotionPacket.pack_generic(s, 1, all_direct), "generic: direct")
	check(MotionPacket.pack_generic(s, 1) == MotionPacket.pack_generic(s, 1, {"surge": "bogus", "x": "inverse"}),
		"неизвестное значение/ключ — direct")


func test_signs_inverse_generic() -> void:
	var base := MotionPacket.pack_generic(known(), 3)
	# смещение float в generic по ключу
	var at := {"surge": 20, "sway": 24, "heave": 28, "roll": 32, "pitch": 36, "yaw": 40,
		"roll_rate": 44, "pitch_rate": 48, "yaw_rate": 52}
	for k: String in at:
		var b := MotionPacket.pack_generic(known(), 3, {k: "inverse"})
		for other: String in at:
			var want := base.decode_float(at[other])
			if other == k:
				want = fposmod(-want, 360.0) if k == "yaw" else -want
			approx(b.decode_float(at[other]), want, 1e-4, "generic inverse %s → поле %s" % [k, other])
	check(MotionPacket.pack_generic(known(), 3, {"yaw": "inverse"}).decode_float(40) == 90.0, "yaw 270 → 90")


func test_signs_inverse_srs() -> void:
	var base := MotionPacket.pack_srs(known(), "x")
	var at := {"pitch": 176, "roll": 180, "yaw": 184, "sway": 192, "heave": 196, "surge": 200}
	for k: String in at:
		var b := MotionPacket.pack_srs(known(), "x", {k: "inverse"})
		for other: String in at:
			var want := base.decode_float(at[other])
			if other == k:
				want = -want
			approx(b.decode_float(at[other]), want, 1e-4, "srs inverse %s → поле %s" % [k, other])
	# vertical: −(heave/G − 1)
	approx(MotionPacket.pack_srs(known(), "", {"heave": "inverse"}).decode_float(196), -(11.0 / G - 1.0), 1e-5, "vertical")
	# yaw: обёртка в (−180, 180]
	var s := known()
	s.yaw = 180.0
	approx(MotionPacket.pack_srs(s, "", {"yaw": "inverse"}).decode_float(184), 180.0, 1e-5, "yaw 180 → 180")
	s.yaw = 10.0
	approx(MotionPacket.pack_srs(s, "", {"yaw": "inverse"}).decode_float(184), -10.0, 1e-5, "yaw 10 → −10")
	s.yaw = 350.0
	approx(MotionPacket.pack_srs(s, "", {"yaw": "inverse"}).decode_float(184), 10.0, 1e-4, "yaw 350 → 10")
	# поля без знака не меняются
	check(MotionPacket.pack_srs(known(), "x", {"roll_rate": "inverse"}) == base, "rate-знаки в srs не влияют")


## Фикстуры пакетов известного сэмпла (tests/motion_rig/fixtures/known_*.bin) = то, что пакует игра;
## их разбирает tools/motion_rig/check_layout.py через motion_formats.py. Перезаписать:
## MR_WRITE_FIXTURES=1 godot … --filter=test_motion_packet
func test_fixtures_match_packer() -> void:
	var dir := ProjectSettings.globalize_path("res://tests/motion_rig/fixtures")
	var packs := {
		"known_srs.bin": MotionPacket.pack_srs(known(), "Altai"),
		"known_generic.bin": MotionPacket.pack_generic(known(), 42),
	}
	for name: String in packs:
		var path := dir.path_join(name)
		if OS.get_environment("MR_WRITE_FIXTURES") != "":
			var f := FileAccess.open(path, FileAccess.WRITE)
			f.store_buffer(packs[name])
			f.close()
		check(FileAccess.get_file_as_bytes(path) == packs[name], "%s совпадает с упаковкой игры" % name)


func test_output_disabled_has_no_socket() -> void:
	var o := MotionOutput.new()
	check(not o.enabled, "по умолчанию выключено")
	o.step(Telemetry.new(), 1.0 / 120.0)
	check(o._udp == null and o.packets_sent == 0, "сокет не создан")


func test_output_sends_every_n() -> void:
	var rx := PacketPeerUDP.new()
	check(rx.bind(0, "127.0.0.1") == OK, "bind приёмника")
	var o := MotionOutput.new()
	o.enabled = true
	o.host = "127.0.0.1"
	o.port = rx.get_local_port()
	o.format = "generic"
	o.every_n = 4
	var t := Telemetry.new()
	t.pilot_velocity = Vector3(0, 0, -10)
	for i in 40:
		o.step(t, 1.0 / 120.0)
	check(o.packets_sent == 10, "пакетов %d (ожидалось 10)" % o.packets_sent)
	OS.delay_msec(50)
	var got := 0
	var last_seq := -1
	while rx.get_available_packet_count() > 0:
		var p := rx.get_packet()
		check(p.size() == 64, "размер принятого")
		last_seq = p.decode_u32(8)
		got += 1
	check(got == 10 and last_seq == 9, "принято %d, последний seq %d" % [got, last_seq])
	rx.close()


func test_output_bad_address_is_silent() -> void:
	var o := MotionOutput.new()
	o.enabled = true
	o.host = ""
	o.every_n = 1
	var t := Telemetry.new()
	for i in 5:
		o.step(t, 1.0 / 120.0)
	check(o.packets_sent == 0, "адрес неверный — ничего не уходит, без ошибок")


func test_output_bad_host_resolves_once() -> void:
	var o := MotionOutput.new()
	o.enabled = true
	o.host = "no-such-host.invalid"
	o.every_n = 1
	var t := Telemetry.new()
	for i in 20:
		o.step(t, 1.0 / 120.0)
	check(o.resolve_count == 1, "имя разрешалось %d раз (ожидалось 1)" % o.resolve_count)
	check(o._udp == null and o.packets_sent == 0, "сокета нет")
	o.configure()
	o.host = "no-such-host.invalid"
	for i in 3:
		o.step(t, 1.0 / 120.0)
	check(o.resolve_count <= 2, "после configure — не больше одной новой попытки")


func test_parse_address() -> void:
	var a := SettingsPanel.parse_motion_address(" 192.168.1.5:33001 ")
	check(a.get("host") == "192.168.1.5" and a.get("port") == 33001, "host:port")
	for bad in ["", "localhost", ":33001", "h:", "h:abc", "h:0", "h:70000"]:
		check(SettingsPanel.parse_motion_address(bad).is_empty(), "неверный адрес '%s'" % bad)


func test_microbench() -> void:
	var src := MotionSource.new()
	var t := Telemetry.new()
	t.pilot_velocity = Vector3(0, -1, -10)
	t.air_velocity = Vector3(0, -1, -10)
	var t0 := Time.get_ticks_usec()
	var bytes := 0
	for i in 1000:
		t.pilot_velocity.z = -10.0 - 0.001 * i
		t.pilot_basis = Basis.from_euler(Vector3(0.1, -0.001 * i, -0.2))
		src.push(t, 1.0 / 120.0)
		bytes += MotionPacket.pack_srs(src.sample(), "Altai").size()
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	print("MR2 microbench: 1000 x (push+sample+pack srs) = %.2f мс" % ms)
	check(bytes == 236000, "размер")
	check(ms <= 50.0, "1000 пакетов за %.2f мс (≤ 50)" % ms)
