extends Node
## Контракт TP-К9 (docs/contracts/trike-pilot.md): звук двигателя игрока (TowTrikeSound.setup_player/update_engine).

const ENGINE := {"gear_ratio": 3.47, "prop_blades": 2, "prop_rpm_idle": 576.0}
const DT := 0.02

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _add(n: Node) -> void:
	add_child(n)


func _make() -> TowTrikeSound:
	var cfg: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://configs/trike_pilot.json"))
	var s := TowTrikeSound.new()
	_add(s)
	s.setup_player(ENGINE, cfg.get("sound", {}))
	return s


func test_off_silent() -> void:
	var s := _make()
	check(not s.playing, "после setup_player не играет")
	s.update_engine("off", 0.0, 0.0)
	check(not s.playing, "off — не играет")
	s.update_engine("running", 576.0, 0.0)
	check(s.playing, "running — играет")
	s.update_engine("off", 0.0, 0.0)
	check(not s.playing, "снова off — тишина")


func test_pitch_monotone_and_tt_k5() -> void:
	var s := _make()
	var ref := TowTrikeSound.new()
	_add(ref)
	ref.setup(ENGINE)
	var last := 0.0
	for rpm: float in [100.0, 300.0, 576.0, 900.0, 1300.0, 1700.0]:
		s.update_engine("starting", rpm, 0.0)
		check(s.playing, "играет на %d об/мин" % rpm)
		check(s.pitch_scale > last, "pitch растёт с оборотами (%d)" % rpm)
		last = s.pitch_scale
		ref.update(rpm, 0.0)
		check(absf(s.pitch_scale / ref.pitch_scale - 1.0) <= 0.01, "pitch = TT-К5 на %d об/мин" % rpm)


func test_smooth() -> void:
	var s := _make()
	var e := TrikeEngine.new()
	var cfg: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://configs/trike_pilot.json"))
	var tug: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://configs/tow_tug.json"))
	e.setup(tug.engine, tug.thrust, cfg)
	e.reset()
	var prev_p := 0.0
	var prev_rpm := 0.0
	var prev_vol := -999.0
	var played := false
	var seq := [[true, 0.0, 4.0], [false, 1.0, 6.0], [false, -1.0, 6.0], [true, 0.0, 6.0]]
	for seg: Array in seq:
		var n := int(float(seg[2]) / DT)
		for i in n:
			e.step(DT, 0.0, float(seg[1]), seg[0] and i == 0)
			s.update_engine(e.state, e.prop_rpm, e.throttle)
			if s.playing:
				if played and prev_rpm > 0.05 * ENGINE.prop_rpm_idle:  # ниже 5 % холостых звук неслышим
					var rel_rpm := absf(e.prop_rpm - prev_rpm) / prev_rpm
					var rel_p := absf(s.pitch_scale - prev_p) / prev_p
					check(rel_p <= rel_rpm + 0.01, "pitch за кадр не быстрее оборотов (%s)" % e.state)
					# громкость: не более 3 дБ за кадр (без щелчков)
					check(absf(s.volume_db - prev_vol) < 3.0, "громкость без скачка (%s)" % e.state)
				played = true
				prev_p = s.pitch_scale
				prev_rpm = e.prop_rpm
				prev_vol = s.volume_db
			else:
				played = false
	check(not s.playing and e.state == "off", "после остановки — тишина")
