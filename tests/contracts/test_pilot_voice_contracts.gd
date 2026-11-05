extends TestCase
## Контрактные тесты pilot-voice (docs/contracts/pilot-voice.md): PV-К1 ситуации и реплики, PV-К2 конфиг,
## PV-К3 путь файла, PV-К4 форма классов. Правка контракта (версия +1) — вместе с этим файлом.

const DOC := "res://docs/contracts/pilot-voice.md"


func _doc() -> String:
	var text := FileAccess.get_file_as_string(DOC)
	if text.is_empty():
		text = FileAccess.get_file_as_string(ProjectSettings.globalize_path(DOC))
	return text


## Строки таблицы PV-К1: id -> {priority, ru_count}.
func _table() -> Dictionary:
	var out := {}
	var re := RegEx.create_from_string("(?m)^\\| `(\\w+)` \\|(.*)$")
	for m in re.search_all(_doc()):
		var cells := (m.get_string(1) + " |" + m.get_string(2)).split("|")
		if m.get_string(1).begins_with("egg_"):  # id, пасхалка, max_dist_m, chance, RU, EN, тон: приоритет 1
			var ru_e := String(cells[4]).strip_edges().split(" · ")
			var en_e := String(cells[5]).strip_edges().split(" · ")
			out[m.get_string(1)] = {"priority": 1, "ru": ru_e.size(), "en": en_e.size(), "max_dist": float(String(cells[2]).strip_edges())}
			continue
		# id, условие, пр., пауза, chance, RU, EN, тон
		var ru := String(cells[5]).strip_edges().split(" · ")
		var en := String(cells[6]).strip_edges().split(" · ")
		out[m.get_string(1)] = {"priority": int(String(cells[2]).strip_edges()), "ru": ru.size(), "en": en.size()}
	return out


func _prop_names(o: Object) -> PackedStringArray:
	var out := PackedStringArray()
	for p: Dictionary in o.get_property_list():
		out.append(String(p.name))
	return out


func test_doc_headings() -> void:
	var text := _doc()
	check(not text.is_empty(), "docs/contracts/pilot-voice.md читается")
	var re := RegEx.create_from_string("(?m)^## (PV-К\\d)\\. .* \\(v(\\d+)\\)\\s*$")
	var found := {}
	for m in re.search_all(text):
		found[m.get_string(1)] = int(m.get_string(2))
	for id in ["PV-К1", "PV-К2", "PV-К3", "PV-К4"]:
		check(found.get(id, 0) == (1 if id == "PV-К3" else 2), "%s (v2) в заголовках: %s" % [id, found])


## PV-К1/К2: ключи situations — ровно id таблицы, число реплик и приоритеты совпадают.
func test_k2_situations_match_table() -> void:
	var table := _table()
	check(table.size() == 30, "в таблицах PV-К1 30 ситуаций (17 + 13 пасхалок) (%d)" % table.size())
	var cfg: Dictionary = Config.get_config("pilot_voice")
	var sit: Dictionary = cfg.get("situations", {})
	var keys: Array = sit.keys()
	keys.sort()
	var want: Array = table.keys()
	want.sort()
	check(keys == want, "situations: ключи %s, ожидалось %s" % [keys, want])
	for id: String in table:
		if not sit.has(id):
			continue
		var s: Dictionary = sit[id]
		var lines: Array = s.get("lines", [])
		check(lines.size() == int(table[id].ru), "%s: реплик %d, в таблице %d" % [id, lines.size(), table[id].ru])
		check(table[id].ru == table[id].en, "%s: RU и EN одинаковое число вариантов" % id)
		check(int(s.get("priority", 0)) == int(table[id].priority), "%s: приоритет" % id)
		if id.begins_with("egg_"):
			var pp: Dictionary = s.get("params", {})
			check(absf(float(pp.get("max_dist_m", -1.0)) - float(table[id].max_dist)) < 1e-6, "%s: max_dist_m" % id)
			check(float(pp.get("cone_deg", 0.0)) == 30.0 and float(pp.get("hold_s", 0.0)) == 1.5, "%s: cone_deg/hold_s" % id)
			check(float(s.get("cooldown_s", 0.0)) == 300.0, "%s: пауза 300" % id)
		var pr := int(s.get("priority", 0))
		check(pr >= 1 and pr <= 3, "%s: priority 1..3" % id)
		check(float(s.get("cooldown_s", -1.0)) >= 0.0, "%s: cooldown_s >= 0" % id)
		var ch := float(s.get("chance", -1.0))
		check(ch >= 0.0 and ch <= 1.0, "%s: chance 0..1" % id)
		check(s.get("params") is Dictionary, "%s: params — словарь" % id)
		for v: Variant in (s.get("params", {}) as Dictionary).values():
			check(v is float or v is int, "%s: params — числа" % id)
		for l: Dictionary in lines:
			for k in ["ru", "en", "tone"]:
				check(l.get(k) is String and not String(l.get(k)).is_empty(), "%s: непустое поле %s" % [id, k])


func test_k2_top_level_and_rules() -> void:
	var cfg: Dictionary = Config.get_config("pilot_voice")
	check(cfg.get("voice") == "male", "voice по умолчанию male")
	check(cfg.get("voices") == ["male", "female"], "voices")
	check(cfg.get("bus") == "Voice", "bus")
	check(cfg.get("dir") == "res://assets/sounds/voice", "dir")
	check(cfg.has("volume_db"), "volume_db")
	var r: Dictionary = cfg.get("rules", {})
	var gap: Dictionary = r.get("gap_s", {})
	check(float(gap.get("1", 0)) == 20.0 and float(gap.get("2", 0)) == 5.0 and float(gap.get("3", 0)) == 2.0, "gap_s")
	check(float(r.get("max_wait_s", 0)) == 3.0, "max_wait_s")
	check(float(r.get("quiet_after_takeoff_s", 0)) == 8.0, "quiet_after_takeoff_s")
	# голос — настройка игрока, не машинная (облако Steam)
	check(not UserSettings.is_local_key("pilot_voice.voice"), "voice — не машинный ключ")


func test_k2_params_names_and_defaults() -> void:
	var sit: Dictionary = Config.get_config("pilot_voice").get("situations", {})
	var want := {
		"takeoff": {"delay_s": 1.0},
		"thermal_found": {"v_ms": 1.0, "hold_s": 3.0, "v_quiet_ms": 0.5, "quiet_s": 20.0},
		"thermal_strong": {"v_ms": 3.0, "hold_s": 4.0},
		"thermal_lost": {"v_in_ms": 0.8, "in_s": 30.0, "v_out_ms": -1.0, "hold_s": 5.0},
		"sink": {"v_ms": -3.0, "hold_s": 3.0, "max_airspeed_ms": 15.0},
		"turbulence": {"min_agl_m": 10.0, "window_s": 8.0, "peaks": 3.0, "n_dev": 0.4},
		"stall": {"min_agl_m": 5.0, "hold_s": 0.5},
		"fast": {"airspeed_ms": 22.0, "hold_s": 3.0},
		"low": {"agl_m": 80.0, "rearm_agl": 200.0},
		"high": {"step_m": 300.0},
		"cloud": {"cloud": 0.6, "hold_s": 1.0},
		"view": {"min_agl_m": 150.0, "v_calm_ms": 1.0, "calm_s": 60.0},
		"egg_eagle": {"max_dist_m": 150.0, "cone_deg": 30.0, "hold_s": 1.5},
		"landing_soft": {"delay_s": 0.6},
		"landing_hard": {"delay_s": 0.6},
		"crash": {"delay_s": 0.8},
	}
	for id: String in want:
		var params: Dictionary = (sit.get(id, {}) as Dictionary).get("params", {})
		for k: String in want[id]:
			check(params.has(k) and absf(float(params[k]) - float(want[id][k])) < 1e-6, "%s.params.%s = %s" % [id, k, want[id][k]])


func test_k3_line_path() -> void:
	check(
		PilotVoice.line_path("female", "ru", "sink_2") == "res://assets/sounds/voice/female/ru/sink_2.ogg",
		"путь файла реплики"
	)
	check(
		PilotVoice.line_path("male", "en", "crash_1", "res://x") == "res://x/male/en/crash_1.ogg",
		"dir параметром"
	)


func test_k4_class_shape() -> void:
	var l := PilotVoiceLogic.new()
	for m in ["setup", "reset", "event", "update", "line_finished", "is_interrupting"]:
		check(l.has_method(m), "PilotVoiceLogic.%s()" % m)
	check(l is RefCounted, "PilotVoiceLogic — RefCounted, без нод")
	var v := PilotVoice.new()
	for m in ["set_voice", "on_event", "update", "watch_eggs"]:
		check(v.has_method(m), "PilotVoice.%s()" % m)
	check(v is Node, "PilotVoice — Node")
	v.free()
	check(PilotVoice.egg_in_view(Transform3D.IDENTITY, Vector3(0, 0, -10), 30.0, 100.0), "egg_in_view: статический метод")
	var egg := EasterEgg.new()
	check(egg.has_method("voice_anchor"), "EasterEgg.voice_anchor")
	egg.free()
	check(AudioBuses.index_or_master("Voice") >= 0, "index_or_master не падает")


func test_k4_voice_bus_in_layout() -> void:
	var text := FileAccess.get_file_as_string("res://scenes/audio/bus_layout.tres")
	check(text.contains('&"Voice"'), "шина Voice в bus_layout.tres")
	AudioBuses.ensure({})
	var i := AudioServer.get_bus_index("Voice")
	check(i >= 0 and AudioServer.get_bus_send(i) == &"Master", "AudioBuses.ensure создаёт Voice -> Master")
