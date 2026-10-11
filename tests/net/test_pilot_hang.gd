extends TestCase
## PD-К4. Режим управления и положение пилота в PilotState: build_state (pilot_rel — только в
## «Маятнике», 1 см; control_mode — в полном пакете), RemotePilotState (последний режим,
## линейная интерполяция pilot_rel, старый клиент без полей).


func _data(t: float, rel: Variant, mode: String = "") -> Dictionary:
	var d := {
		"pilotId": "7",
		"t": t,
		"pos": {"x": t * 10.0, "y": 1000.0},
		"rot": {"w": 1.0},
		"vel": {"x": 10.0},
		"phase": "PILOT_PHASE_FLY",
		"wing": "wings/sport",
	}
	if mode != "":
		d["controlMode"] = mode
	if rel != null:
		d["pilotRel"] = NetMessages.vec3(rel)
	return d


func test_build_state() -> void:
	var st := {
		"pos": Vector3.ZERO,
		"rot": Quaternion.IDENTITY,
		"vel": Vector3.ZERO,
		"phase": "FLY",
		"wing": "wings/sport",
		"control_mode": "PENDULUM",
		"pilot_rel": Vector3(0.0512, -1.1834, -0.1201),
	}
	var full := NetPilots.build_state("7", false, 1.0, st, true, true, "Я")
	check(full.get("controlMode") == "CONTROL_MODE_PENDULUM", "полный пакет: controlMode")
	check(
		NetMessages.to_vector3(full.pilotRel).is_equal_approx(Vector3(0.05, -1.18, -0.12)),
		"pilotRel округлён до 1 см: %s" % [full.pilotRel]
	)
	var reg := NetPilots.build_state("7", false, 1.1, st, false, false)
	check(not reg.has("controlMode"), "обычный пакет: без controlMode")
	check(reg.has("pilotRel"), "обычный пакет: pilotRel есть")
	for cm: String in ["RATE", "WEIGHT_SHIFT", ""]:
		var s2 := st.duplicate()
		s2.control_mode = cm
		var d := NetPilots.build_state("7", false, 1.0, s2, true, true, "Я")
		check(not d.has("pilotRel"), "режим '%s': pilotRel не шлётся" % cm)
		check(d.has("controlMode") == (cm != ""), "режим '%s': controlMode" % cm)


func test_remote_state_sticky_mode_and_interp() -> void:
	var r := RemotePilotState.new("7")
	check(r.push(_data(1.0, Vector3(0.0, -1.2, 0.0), "CONTROL_MODE_PENDULUM"), 1.0), "t=1")
	check(r.push(_data(1.1, Vector3(0.1, -1.0, 0.0)), 1.1), "t=1,1 без controlMode")
	check(r.control_mode == "PENDULUM", "режим держится")
	var s := r.sample(1.05)
	check(s.control_mode == "PENDULUM", "sample: control_mode")
	check(s.has("pilot_rel"), "sample: pilot_rel")
	check((s.pilot_rel as Vector3).is_equal_approx(Vector3(0.05, -1.1, 0.0)), "линейно: %s" % [s.pilot_rel])
	# смена режима
	r.push(_data(1.2, null, "CONTROL_MODE_RATE"), 1.2)
	check(r.control_mode == "RATE", "режим сменился")


func test_old_client() -> void:
	var r := RemotePilotState.new("8")
	r.push(_data(1.0, null), 1.0)
	r.push(_data(1.1, null), 1.1)
	var s := r.sample(1.05)
	check(s.control_mode == "", "старый клиент: режима нет")
	check(not s.has("pilot_rel"), "старый клиент: pilot_rel нет")
