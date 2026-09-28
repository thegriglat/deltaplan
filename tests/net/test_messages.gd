extends TestCase
## NET-30. Кодирование/разбор сообщений (NetMessages) против примеров docs/net_protocol.md:
## каждый блок ```json разбирается, кодируется обратно и сверяется с исходным JSON (как
## словари); каждый вариант Envelope из NetMessages.ENVELOPE должен быть среди примеров.
## Плюс подстановка умолчаний proto3, мусор и незнакомые варианты.

const DOC_PATH := "res://docs/net_protocol.md"


func test_doc_examples_round_trip() -> void:
	var examples := _doc_examples()
	check(examples.size() >= 15, "примеров JSON в документе: %d" % examples.size())
	var seen := {}
	for ex: Dictionary in examples:
		var text: String = ex.json
		var m := NetMessages.decode(text)
		check(not m.is_empty(), "%s: разобран" % ex.header)
		if m.is_empty():
			continue
		seen[m.type] = true
		# заголовок "#### PilotState (бот)" → "pilotState"
		var expect_type: String = ex.header.split(" ")[0]
		expect_type = expect_type.left(1).to_lower() + expect_type.substr(1)
		check(m.type == expect_type, "%s: тип %s" % [ex.header, m.type])
		var again := NetMessages.encode(m.type, m.data, m.from_id)
		var orig: Variant = JSON.parse_string(text)
		var back: Variant = JSON.parse_string(again)
		check(_same(orig, back), "%s: туда-обратно\n  было:  %s\n  стало: %s" % [ex.header, text, again])
	for type: String in NetMessages.ENVELOPE:
		check(seen.has(type), "в docs/net_protocol.md есть пример %s" % type)


func test_defaults_filled() -> void:
	var m := NetMessages.decode('{"fromId": "3", "pilotState": {}}')
	check(m.type == "pilotState" and m.from_id == "3", "тип и fromId")
	var d: Dictionary = m.data
	check(d.pilotId == "" and d.isBot == false and d.name == "" and d.wing == "", "строки/bool")
	check(d.t is float and d.t == 0.0, "t = 0.0")
	check(d.pos == {"x": 0.0, "y": 0.0, "z": 0.0}, "pos по умолчанию")
	check(d.rot == {"x": 0.0, "y": 0.0, "z": 0.0, "w": 0.0}, "rot по умолчанию")
	check(d.phase == "PILOT_PHASE_UNSPECIFIED", "фаза по умолчанию")
	check(d.colors == null, "нет colors — null (родная текстура)")
	check(NetMessages.to_quaternion(d.rot) == Quaternion.IDENTITY, "нулевой кватернион → единичный")

	var zj: Dictionary = NetMessages.decode('{"zoneJoined": {"zone": {"month": 7}}}').data
	check(zj.code == "" and zj.leaderId == "" and zj.peers == [], "ZoneJoined умолчания")
	check(is_nan(zj.zone.pickLat) and is_nan(zj.zone.pickLon), "pickLat/pickLon не заданы → NAN")
	check(zj.zone.month is int and zj.zone.month == 7, "month — int")
	check(zj.zone.seed is int and zj.zone.seed == 0, "seed — int 0")
	check(zj.zone.forecast.sky == "" and zj.zone.forecast.windIntoLaunch == false, "forecast")

	var zs: Dictionary = NetMessages.decode('{"zoneState": {"clock": 1.5}}').data
	check(zs.queue == [] and zs.clock == 1.5, "ZoneState: пустая очередь")
	var err: Dictionary = NetMessages.decode('{"error": {"text": "x"}}').data
	check(err.code == "ERROR_CODE_UNSPECIFIED", "код ошибки по умолчанию")
	check(NetMessages.decode('{"leaveZone": {}}').data == {}, "пустое сообщение")
	check(NetMessages.defaults("ping") == {"clientTime": 0.0}, "defaults(ping)")


func test_garbage_and_unknown() -> void:
	check(NetMessages.decode("").is_empty(), "пустая строка")
	check(NetMessages.decode("not json").is_empty(), "не JSON")
	check(NetMessages.decode("[1, 2]").is_empty(), "не объект")
	check(NetMessages.decode('{"fromId": "1"}').is_empty(), "без варианта")
	check(NetMessages.decode('{"futureMessage": {"a": 1}}').is_empty(), "незнакомый вариант")
	check(NetMessages.decode('{"pong": 5}').is_empty(), "тело не объект")
	# незнакомые ключи внутри пропускаются, незнакомое значение перечисления → умолчание
	var m := NetMessages.decode(
		'{"pilotState": {"pilotId": "7", "newField": 1, "phase": "PILOT_PHASE_JETPACK"}}'
	)
	check(m.data.pilotId == "7" and not m.data.has("newField"), "незнакомый ключ пропущен")
	check(m.data.phase == "PILOT_PHASE_UNSPECIFIED", "незнакомая фаза → умолчание")
	# перечисление числом (сервер принимает оба вида) → имя
	var by_num: Dictionary = NetMessages.decode('{"pilotState": {"phase": 4}}').data
	check(by_num.phase == "PILOT_PHASE_FLY", "фаза числом")
	# исходные имена полей proto (pilot_id) клиент не понимает — это не lowerCamelCase
	var snake: Dictionary = NetMessages.decode('{"pilotState": {"pilot_id": "7"}}').data
	check(snake.pilotId == "", "snake_case не читаем")


func test_encode_omits_defaults() -> void:
	var text := NetMessages.encode(
		"pilotState",
		{
			"pilotId": "7",
			"isBot": false,
			"t": 0.0,
			"pos": Vector3(1.5, 0, 0),
			"rot": Quaternion.IDENTITY,
			"vel": Vector3.ZERO,
			"phase": "PILOT_PHASE_UNSPECIFIED",
			"colors": null,
			"unknownKey": 5,
		}
	)
	var j: Dictionary = JSON.parse_string(text)
	var ps: Dictionary = j.pilotState
	check(not j.has("fromId"), "клиент не шлёт fromId")
	check(ps.keys().size() == 4, "только pilotId/pos/rot/vel: %s" % text)
	check(ps.pos == {"x": 1.5}, "pos без нулей")
	check(ps.rot == {"w": 1.0}, "единичный кватернион — {w: 1}")
	check(ps.vel == {}, "нулевая скорость — пустой объект")
	# фаза числом → имя
	var t2 := NetMessages.encode("pilotState", {"phase": 4})
	check(JSON.parse_string(t2).pilotState.phase == "PILOT_PHASE_FLY", "фаза: int → имя")
	check(NetMessages.encode("leaveZone") == '{"leaveZone":{}}', "LeaveZone — пустой объект")
	# optional: 0 — настоящий ноль (шлётся), NAN — не задано (не шлётся)
	var z0 := NetMessages.encode("createZone", {"zone": {"pickLat": 0.0, "pickLon": NAN, "month": 7}})
	var zone: Dictionary = JSON.parse_string(z0).createZone.zone
	check(zone.has("pickLat") and zone.pickLat == 0.0, "pickLat = 0 шлётся")
	check(not zone.has("pickLon"), "pickLon NAN не шлётся")
	check(str(zone.month) in ["7", "7.0"], "month")
	check(z0.contains('"month":7'), "целое без дробной части: %s" % z0)
	# очередь — PackedStringArray тоже годится
	var queue := PackedStringArray(["7", "bot-1"])
	var zs := NetMessages.encode("zoneState", {"clock": 2.0, "queue": queue})
	check(JSON.parse_string(zs).zoneState.queue == ["7", "bot-1"], "queue")


func test_int64_and_special_floats() -> void:
	# 64-битных полей в контракте пока нет — проверяем сам кодек
	check(NetMessages.decode_value("int64", "9007199254740993") == 9007199254740993, "int64 из строки")
	check(NetMessages.decode_value("uint64", 12.0) == 12, "uint64 из числа")
	check(NetMessages.encode_value("int64", 123) == "123", "int64 → строка")
	check(NetMessages.encode_value("int64", 0) == null, "int64 0 опущен")
	check(is_nan(NetMessages.decode_value("double", "NaN")), "NaN строкой")
	check(NetMessages.decode_value("float", "Infinity") == INF, "Infinity строкой")
	check(NetMessages.decode_value("int32", "42") == 42, "int32 строкой")
	check(NetMessages.short_enum("ERROR_CODE_ZONE_FULL") == "ZONE_FULL", "short_enum ошибки")
	check(NetMessages.short_enum("PILOT_PHASE_TOW") == "TOW", "short_enum фазы")


func test_vec_quat_helpers() -> void:
	var v := Vector3(1, -2, 3.5)
	check(NetMessages.to_vector3(NetMessages.vec3(v)) == v, "Vector3 туда-обратно")
	var q := Quaternion(Vector3.UP, 0.7)
	check(NetMessages.to_quaternion(NetMessages.quat(q)).is_equal_approx(q), "Quaternion туда-обратно")
	var wire := NetMessages.encode("pilotState", {"pos": v, "rot": q})
	var back: Dictionary = NetMessages.decode(wire).data
	check(NetMessages.to_vector3(back.pos).is_equal_approx(v), "pos через провод")
	check(NetMessages.to_quaternion(back.rot).is_equal_approx(q), "rot через провод")


## Блоки ```json из docs/net_protocol.md с заголовком #### над ними.
func _doc_examples() -> Array:
	var f := FileAccess.open(DOC_PATH, FileAccess.READ)
	check(f != null, "открыт %s" % DOC_PATH)
	if f == null:
		return []
	var out := []
	var header := ""
	var in_json := false
	var buf := ""
	for line in f.get_as_text().split("\n"):
		if in_json:
			if line.strip_edges() == "```":
				out.append({"header": header, "json": buf.strip_edges()})
				in_json = false
			else:
				buf += line + "\n"
		elif line.begins_with("#### "):
			header = line.substr(5).strip_edges()
		elif line.strip_edges() == "```json":
			in_json = true
			buf = ""
	return out


## Семантическое равенство JSON (числа — с допуском на печать float).
func _same(a: Variant, b: Variant) -> bool:
	var ok := false
	if a is Dictionary and b is Dictionary:
		ok = a.size() == b.size()
		for k: Variant in a:
			ok = ok and b.has(k) and _same(a[k], b[k])
	elif a is Array and b is Array:
		ok = a.size() == b.size()
		for i in mini(a.size(), b.size()):
			ok = ok and _same(a[i], b[i])
	elif (a is float or a is int) and (b is float or b is int):
		ok = absf(float(a) - float(b)) <= 1e-9 * maxf(1.0, absf(float(a)))
	else:
		ok = typeof(a) == typeof(b) and a == b
	return ok
