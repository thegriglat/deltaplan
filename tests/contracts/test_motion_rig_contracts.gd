extends TestCase
## Контрактные тесты motion-rig (docs/contracts/motion-rig.md): MR-К1 точка пилота и величины,
## MR-К2 пакеты, MR-К3 настройки. Правка контракта (версия +1) — вместе с этим файлом.

const DOC := "res://docs/contracts/motion-rig.md"


func _prop_names(o: Object) -> PackedStringArray:
	var out := PackedStringArray()
	for p: Dictionary in o.get_property_list():
		out.append(String(p.name))
	return out


func test_doc_headings() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	if text.is_empty():
		text = FileAccess.get_file_as_string(ProjectSettings.globalize_path(DOC))
	check(not text.is_empty(), "docs/contracts/motion-rig.md читается")
	var re := RegEx.create_from_string("(?m)^## (MR-К\\d)\\. .* \\(v(\\d+)\\)\\s*$")
	var found := {}
	for m in re.search_all(text):
		found[m.get_string(1)] = int(m.get_string(2))
	for id in ["MR-К1", "MR-К2", "MR-К3"]:
		check(found.get(id, 0) == 3, "%s (v3) в заголовках: %s" % [id, found])


## MR-К2 v2: ускорения srs в м/с² (vertical = heave − G); generic — version 2 (v3: биты 2 synthetic, 3 ramp).
func test_k2_srs_units_ms2() -> void:
	var s := MotionSample.new()
	s.sway = 0.7
	s.heave = Units.G + 1.3
	s.surge = -0.4
	var b := MotionPacket.pack_srs(s)
	check(absf(b.decode_float(192) - 0.7) < 1e-5, "lateral_acceleration = sway, м/с²")
	check(absf(b.decode_float(196) - 1.3) < 1e-5, "vertical_acceleration = heave − G, м/с²")
	check(absf(b.decode_float(200) + 0.4) < 1e-5, "longitudinal_acceleration = surge, м/с²")
	var g := MotionPacket.pack_generic(s, 0)
	check(absf(g.decode_float(28) - (Units.G + 1.3)) < 1e-4, "generic heave — как раньше, м/с²")


func test_k1_telemetry_and_classes() -> void:
	var t := Telemetry.new()
	var props := _prop_names(t)
	for f in ["pilot_position", "pilot_velocity", "pilot_basis"]:
		check(f in props, "Telemetry.%s" % f)
	check(t.pilot_position is Vector3 and t.pilot_velocity is Vector3 and t.pilot_basis is Basis, "типы")
	var s := MotionSample.new()
	props = _prop_names(s)
	for f in ["surge", "sway", "heave", "roll", "pitch", "yaw", "roll_rate", "pitch_rate", "yaw_rate",
			"airspeed", "air_lateral", "valid"]:
		check(f in props, "MotionSample.%s" % f)
	check(not s.valid, "MotionSample.valid по умолчанию false")
	var src := MotionSource.new()
	for m in ["push", "sample", "reset"]:
		check(src.has_method(m), "MotionSource.%s()" % m)
	check(src.sample() is MotionSample, "sample() -> MotionSample")


func test_k1_filled_by_flight_model() -> void:
	var Sim: GDScript = load("res://tests/flight/flight_sim.gd")
	var m: FlightModel = Sim.make("sport")
	m.reset_in_air(Vector3(10, 500, 20), 30.0)
	Sim.run_for(m, 1.0, Sim.input())
	var t := m.telemetry
	check(t.pilot_position.is_equal_approx(m.position), "pilot_position = position")
	check(t.pilot_velocity.is_equal_approx(m.velocity), "pilot_velocity = velocity")
	check(t.pilot_basis.is_equal_approx(t.basis), "pilot_basis = basis")


func test_k2_packet_sizes_and_constants() -> void:
	var s := MotionSample.new()
	check(MotionPacket.pack_srs(s).size() == 236 and MotionPacket.SRS_SIZE == 236, "srs 236 байт")
	check(MotionPacket.pack_generic(s, 0).size() == 64 and MotionPacket.GENERIC_SIZE == 64, "generic 64 байта")
	check(MotionPacket.pack_srs(s).decode_u32(4) == 102, "srs version 102")
	check(MotionPacket.pack_generic(s, 0).decode_u32(4) == 2, "generic version 2")
	check(MotionPacket.pack_generic(s, 0).slice(0, 4).get_string_from_ascii() == "DPMR", "magic DPMR")


func test_k3_config_defaults() -> void:
	var c: Dictionary = Config.get_config("motion_rig")
	check(c.get("enabled") == false, "enabled = false")
	check(c.get("host") == "127.0.0.1", "host")
	check(int(c.get("port", 0)) == 33001, "port")
	check(int(c.get("rate_hz", 0)) == 60, "rate_hz")
	check(c.get("format") == "srs", "format")
	check(absf(float(c.get("ramp_s", -1.0)) - 2.5) < 1e-6, "ramp_s = 2.5 (MR-К3 v3)")
	check(absf(float(c.get("ground_accel_scale", -1.0)) - 0.3) < 1e-6, "ground_accel_scale = 0.3")
	check(absf(float(c.get("ground_blend_s", -1.0)) - 0.4) < 1e-6, "ground_blend_s = 0.4")
	check(UserSettings.is_local_key("motion_rig.enabled"), "ключи — машинные (LOCAL_KEYS)")
	var cloud: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://steam/partner/auto_cloud.json"))
	check("motion_rig" in cloud.get("local_keys", []), "auto_cloud.json local_keys")
	var signs: Dictionary = c.get("signs", {})
	var keys: Array = signs.keys()
	keys.sort()
	var want: Array = ["pitch", "pitch_rate", "roll", "roll_rate", "surge", "sway", "heave", "yaw", "yaw_rate"]
	want.sort()
	check(keys == want, "signs: ключи %s" % [keys])
	for k: String in signs:
		check(signs[k] == "direct", "signs.%s = direct по умолчанию" % k)


## MR-К1 v3 «Кто зовёт»: автозагрузка MotionRig с интерфейсом для Game; Game не держит MotionOutput.
func test_k1_v3_motion_rig_autoload() -> void:
	var rig: Node = Engine.get_main_loop().root.get_node_or_null("MotionRig")
	check(rig != null, "автозагрузка MotionRig")
	if rig == null:
		return
	for m in ["attach", "detach", "step", "reset"]:
		check(rig.has_method(m), "MotionRig.%s()" % m)
	check("place" in _prop_names(rig), "MotionRig.place")
	check(rig.process_mode == Node.PROCESS_MODE_ALWAYS, "PROCESS_MODE_ALWAYS")
	check(rig.process_physics_priority > 0, "тикает после сцены полёта")
	var g := Game.new()
	check("motion" not in _prop_names(g), "Game больше не держит MotionOutput")
	g.free()


## MR-К2 v3: биты флагов generic — 2 synthetic, 3 ramp.
func test_k2_v3_generic_flag_bits() -> void:
	var f := MotionPacket.make_frame(MotionSample.new(), "generic")
	f["synthetic"] = true
	f["ramp"] = true
	var fl := MotionPacket.pack_frame(f).decode_u32(12)
	check((fl & 4) != 0 and (fl & 8) != 0, "биты synthetic и ramp: %d" % fl)
