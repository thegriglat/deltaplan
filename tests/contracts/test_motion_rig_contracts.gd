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
		check(found.get(id, 0) == 1, "%s (v1) в заголовках: %s" % [id, found])


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
	check(MotionPacket.pack_generic(s, 0).decode_u32(4) == 1, "generic version 1")
	check(MotionPacket.pack_generic(s, 0).slice(0, 4).get_string_from_ascii() == "DPMR", "magic DPMR")


func test_k3_config_defaults() -> void:
	var c: Dictionary = Config.get_config("motion_rig")
	check(c.get("enabled") == false, "enabled = false")
	check(c.get("host") == "127.0.0.1", "host")
	check(int(c.get("port", 0)) == 33001, "port")
	check(int(c.get("rate_hz", 0)) == 60, "rate_hz")
	check(c.get("format") == "srs", "format")
	check(UserSettings.is_local_key("motion_rig.enabled"), "ключи — машинные (LOCAL_KEYS)")
	var cloud: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://steam/partner/auto_cloud.json"))
	check("motion_rig" in cloud.get("local_keys", []), "auto_cloud.json local_keys")
