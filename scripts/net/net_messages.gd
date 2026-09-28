class_name NetMessages
extends RefCounted
## Кодирование и разбор сообщений сетевой игры: Envelope ↔ (тип, данные).
##
## Источник правды — server/proto/deltaplan/v1/net.proto (описание: docs/net_protocol.md).
## Таблицы MESSAGES/ENUMS/ENVELOPE ниже — ручное зеркало net.proto: новое поле или сообщение
## в .proto нужно добавить и сюда (тест tests/net/test_messages.gd проверяет все примеры
## из docs/net_protocol.md).
##
## Формат на проводе — proto3 JSON (как Go protojson). Все его особенности — только здесь:
##   - ключи lowerCamelCase — и в данных GDScript те же ключи ("pilotId", "joinOrder");
##   - decode() подставляет умолчания для всех отсутствующих полей: 0 / 0.0 / false / "" /
##     [] / имя нулевого значения перечисления; вложенное сообщение — словарь с умолчаниями.
##     Игровому коду не нужен has(). Исключения (есть смысл «не задано»):
##       * optional double (Zone.pickLat/pickLon) — NAN, если не задано;
##       * PilotState.colors — null, если нет (родная текстура крыла) — см. NULLABLE;
##   - целые поля (int32/uint32/int64/uint64) в данных — int; 64-битные на проводе строками;
##   - float/double — float; перечисления — строки-имена ("PILOT_PHASE_FLY"), числа на входе
##     переводятся в имена, незнакомые значения — в умолчание;
##   - encode() опускает значения по умолчанию, как protojson; вложенное сообщение шлётся,
##     если ключ есть в данных (даже пустым {}); optional — если не NAN/null.
##     Вместо словаря Vec3/Quat можно передать Vector3/Quaternion;
##   - незнакомые ключи и незнакомые варианты Envelope пропускаются молча.
##
## Использование:
##   var text := NetMessages.encode("hello", {"gameVersion": "0.7.1", "name": "Пилот"})
##   var m := NetMessages.decode(text)
##   if not m.is_empty():  # {} — мусор или незнакомый (более новый) вариант
##       m.type     # "pilotState" — ключ варианта Envelope (lowerCamelCase)
##       m.data     # словарь полей с умолчаниями
##       m.from_id  # Envelope.fromId ("" если нет)

## Варианты Envelope: ключ JSON → имя сообщения в MESSAGES.
const ENVELOPE := {
	# клиент → сервер
	"hello": "Hello",
	"createZone": "CreateZone",
	"joinZone": "JoinZone",
	"leaveZone": "LeaveZone",
	"ping": "Ping",
	# сервер → клиент
	"welcome": "Welcome",
	"zoneCreated": "ZoneCreated",
	"zoneJoined": "ZoneJoined",
	"peerJoined": "PeerJoined",
	"peerLeft": "PeerLeft",
	"leaderChanged": "LeaderChanged",
	"error": "Error",
	"pong": "Pong",
	# пересылаемые внутри зоны
	"pilotState": "PilotState",
	"zoneState": "ZoneState",
}

## Поля сообщений: ключ JSON → тип. Типы:
##   "string" "bool" "float" "double" "int32" "uint32" "int64" "uint64"
##   "enum:<Имя>"   — перечисление из ENUMS
##   "msg:<Имя>"    — вложенное сообщение
##   "opt:<скаляр>" — proto3 optional (не задано → NAN для float/double, иначе null)
##   "[]<тип>"      — repeated
const MESSAGES := {
	"Vec3": {"x": "float", "y": "float", "z": "float"},
	"Quat": {"x": "float", "y": "float", "z": "float", "w": "float"},
	"Forecast":
	{
		"temperatureC": "float",
		"windSpeedKmh": "float",
		"windIntoLaunch": "bool",
		"windFromDeg": "float",
		"sky": "string",
	},
	"Zone":
	{
		"locationId": "string",
		"siteId": "string",
		"pickLat": "opt:double",
		"pickLon": "opt:double",
		"month": "int32",
		"day": "int32",
		"startHour": "double",
		"forecast": "msg:Forecast",
		"seed": "uint32",
		"botsCount": "int32",
		"worldKey": "string",
		"worldHash": "string",
	},
	"Peer": {"id": "string", "name": "string", "joinOrder": "uint32"},
	"WingColors": {"hueDeg": "float", "sat": "float", "value": "float"},
	"Hello": {"gameVersion": "string", "name": "string"},
	"CreateZone": {"zone": "msg:Zone"},
	"JoinZone": {"code": "string"},
	"LeaveZone": {},
	"Ping": {"clientTime": "double"},
	"Welcome": {"yourId": "string", "serverVersion": "string"},
	"ZoneCreated": {"code": "string"},
	"ZoneJoined":
	{
		"code": "string",
		"zone": "msg:Zone",
		"peers": "[]msg:Peer",
		"leaderId": "string",
	},
	"PeerJoined": {"peer": "msg:Peer"},
	"PeerLeft": {"id": "string"},
	"LeaderChanged": {"leaderId": "string"},
	"Error": {"code": "enum:ErrorCode", "text": "string"},
	"Pong": {"clientTime": "double", "serverTime": "double"},
	"PilotState":
	{
		"pilotId": "string",
		"isBot": "bool",
		"name": "string",
		"t": "double",
		"pos": "msg:Vec3",
		"rot": "msg:Quat",
		"vel": "msg:Vec3",
		"phase": "enum:PilotPhase",
		"wing": "string",
		"colors": "msg:WingColors",
	},
	"ZoneState": {"clock": "double", "queue": "[]string"},
	# не вариант Envelope: UDP-объявление зоны в локальной сети (LanDiscovery), без конверта
	"LanAnnounce":
	{
		"code": "string",
		"hostName": "string",
		"address": "string",
		"port": "uint32",
		"gameVersion": "string",
		"pilotsCount": "uint32",
	},
}

## Вложенные сообщения, у которых «нет» — отдельный смысл: при разборе null вместо умолчаний.
## Ключ — "<Сообщение>.<поле>".
const NULLABLE := {"PilotState.colors": true}

## Перечисления: имена по порядку номеров (индекс = номер в .proto).
const ENUMS := {
	"ErrorCode":
	[
		"ERROR_CODE_UNSPECIFIED",
		"ERROR_CODE_ZONE_NOT_FOUND",
		"ERROR_CODE_VERSION_MISMATCH",
		"ERROR_CODE_ZONE_FULL",
		"ERROR_CODE_BAD_MESSAGE",
	],
	"PilotPhase":
	[
		"PILOT_PHASE_UNSPECIFIED",
		"PILOT_PHASE_STAND",
		"PILOT_PHASE_WALK",
		"PILOT_PHASE_RUN",
		"PILOT_PHASE_FLY",
		"PILOT_PHASE_LANDED",
		"PILOT_PHASE_CRASHED",
		"PILOT_PHASE_TOW",
	],
}


## Envelope с вариантом type (ключ ENVELOPE) → текст кадра. from_id шлёт только сервер —
## параметр для тестов и заглушек. "" и ошибка в лог, если тип незнакомый.
static func encode(type: String, data: Dictionary = {}, from_id: String = "") -> String:
	if not ENVELOPE.has(type):
		push_error("NetMessages.encode: незнакомый тип сообщения '%s'" % type)
		return ""
	var env := {type: encode_message(ENVELOPE[type], data)}
	if from_id != "":
		env["fromId"] = from_id
	return JSON.stringify(env)


## Текст кадра → {"type", "data", "from_id"}; {} — не JSON, не объект, нет известного варианта.
static func decode(text: String) -> Dictionary:
	var json := JSON.new()
	if json.parse(text) != OK:
		return {}
	var env: Variant = json.data
	if not env is Dictionary:
		return {}
	for key: Variant in env:
		if key is String and ENVELOPE.has(key):
			var body: Variant = env[key]
			if not body is Dictionary:
				return {}
			var from_id: Variant = env.get("fromId", "")
			return {
				"type": key,
				"data": decode_message(ENVELOPE[key], body),
				"from_id": str(from_id) if from_id != null else "",
			}
	return {}


## Сообщение msg_name без Envelope (LanAnnounce) → текст JSON.
static func encode_bare(msg_name: String, data: Dictionary) -> String:
	return JSON.stringify(encode_message(msg_name, data))


## Текст JSON сообщения msg_name без Envelope → словарь полей с умолчаниями; {} — не JSON-объект.
static func decode_bare(msg_name: String, text: String) -> Dictionary:
	var json := JSON.new()
	if json.parse(text) != OK or not json.data is Dictionary:
		return {}
	return decode_message(msg_name, json.data)


## Данные сообщения со всеми полями по умолчанию (удобно как заготовка для encode).
static func defaults(type: String) -> Dictionary:
	return decode_message(ENVELOPE[type], {}) if ENVELOPE.has(type) else {}


## JSON-объект сообщения msg_name → словарь со всеми полями (умолчания подставлены).
static func decode_message(msg_name: String, src: Dictionary) -> Dictionary:
	var out := {}
	var fields: Dictionary = MESSAGES[msg_name]
	for key: String in fields:
		var spec: String = fields[key]
		if not src.has(key) or src[key] == null:
			if NULLABLE.has(msg_name + "." + key):
				out[key] = null
			else:
				out[key] = default_value(spec)
		else:
			out[key] = decode_value(spec, src[key])
	return out


## Словарь полей → JSON-объект сообщения (умолчания опущены, незнакомые ключи пропущены).
static func encode_message(msg_name: String, data: Dictionary) -> Dictionary:
	var out := {}
	var fields: Dictionary = MESSAGES[msg_name]
	for key: String in fields:
		if not data.has(key):
			continue
		var spec: String = fields[key]
		var v: Variant = encode_value(spec, data[key])
		if v != null:
			out[key] = v
	return out


## Умолчание proto3 для типа поля.
static func default_value(spec: String) -> Variant:
	if spec.begins_with("[]"):
		return []
	if spec.begins_with("opt:"):
		return NAN if spec in ["opt:float", "opt:double"] else null
	if spec.begins_with("msg:"):
		return decode_message(spec.substr(4), {})
	if spec.begins_with("enum:"):
		return ENUMS[spec.substr(5)][0]
	match spec:
		"string":
			return ""
		"bool":
			return false
		"float", "double":
			return 0.0
		_:
			return 0


## Значение из JSON → значение GDScript по типу поля. Неподходящее значение → умолчание.
static func decode_value(spec: String, v: Variant) -> Variant:
	if spec.begins_with("[]"):
		var out := []
		if v is Array:
			var item_spec := spec.substr(2)
			for item: Variant in v:
				out.append(decode_value(item_spec, item))
		return out
	if spec.begins_with("opt:"):
		return decode_value(spec.substr(4), v)
	if spec.begins_with("msg:"):
		return decode_message(spec.substr(4), v if v is Dictionary else {})
	if spec.begins_with("enum:"):
		var names: Array = ENUMS[spec.substr(5)]
		if v is String and names.has(v):
			return v
		if v is float or v is int:
			var i := int(v)
			if i >= 0 and i < names.size():
				return names[i]
		return names[0]
	match spec:
		"string":
			return v if v is String else ""
		"bool":
			return v if v is bool else false
		"float", "double":
			return _to_float(v)
		_:
			return _to_int(v)


## Значение GDScript → значение JSON; null — опустить (умолчание или «не задано»).
static func encode_value(spec: String, v: Variant) -> Variant:
	if v == null:
		return null
	if spec.begins_with("[]"):
		if not (v is Array or v is PackedStringArray) or v.is_empty():
			return null
		var out := []
		var item_spec := spec.substr(2)
		for item: Variant in v:
			var e: Variant = encode_value(item_spec, item)
			out.append(e if e != null else _zero_json(item_spec))
		return out
	if spec.begins_with("opt:"):
		if (v is float or v is int) and is_nan(float(v)):
			return null
		var inner := spec.substr(4)
		var e: Variant = encode_value(inner, v)
		return e if e != null else _zero_json(inner)
	if spec.begins_with("msg:"):
		var msg_name := spec.substr(4)
		if v is Vector3:
			v = vec3(v)
		elif v is Quaternion:
			v = quat(v)
		if not v is Dictionary:
			return null
		return encode_message(msg_name, v)
	if spec.begins_with("enum:"):
		var names: Array = ENUMS[spec.substr(5)]
		var name: String = ""
		if v is int and v >= 0 and v < names.size():
			name = names[v]
		elif v is String and names.has(v):
			name = v
		return name if name != "" and name != names[0] else null
	match spec:
		"string":
			var s := str(v)
			return s if s != "" else null
		"bool":
			return true if v is bool and v else null
		"float", "double":
			var f := float(v)
			if f == 0.0:
				return null
			if is_nan(f):
				return "NaN"
			if is_inf(f):
				return "Infinity" if f > 0.0 else "-Infinity"
			return f
		"int64", "uint64":
			var i := int(v)
			return str(i) if i != 0 else null
		_:
			var i := int(v)
			return i if i != 0 else null


## Vector3 → Vec3 (мир Godot: X — восток, Y — вверх, −Z — север).
static func vec3(v: Vector3) -> Dictionary:
	return {"x": v.x, "y": v.y, "z": v.z}


## Vec3 (разобранный decode) → Vector3.
static func to_vector3(d: Variant) -> Vector3:
	if not d is Dictionary:
		return Vector3.ZERO
	return Vector3(_to_float(d.get("x", 0.0)), _to_float(d.get("y", 0.0)), _to_float(d.get("z", 0.0)))


## Quaternion → Quat.
static func quat(q: Quaternion) -> Dictionary:
	return {"x": q.x, "y": q.y, "z": q.z, "w": q.w}


## Quat → Quaternion (нормализованный; нулевой — единичный поворот).
static func to_quaternion(d: Variant) -> Quaternion:
	if not d is Dictionary:
		return Quaternion.IDENTITY
	var q := Quaternion(
		_to_float(d.get("x", 0.0)),
		_to_float(d.get("y", 0.0)),
		_to_float(d.get("z", 0.0)),
		_to_float(d.get("w", 0.0))
	)
	if q.length_squared() < 1e-12:
		return Quaternion.IDENTITY
	return q.normalized()


## "ERROR_CODE_ZONE_NOT_FOUND" → "ZONE_NOT_FOUND" (имя без префикса перечисления).
static func short_enum(name: String) -> String:
	for enum_name: String in ENUMS:
		var first: String = ENUMS[enum_name][0]
		var prefix := first.trim_suffix("UNSPECIFIED")
		if name.begins_with(prefix):
			return name.substr(prefix.length())
	return name


static func _to_float(v: Variant) -> float:
	if v is float or v is int:
		return float(v)
	if v is String:
		match v:
			"NaN":
				return NAN
			"Infinity":
				return INF
			"-Infinity":
				return -INF
		return v.to_float() if v.is_valid_float() else 0.0
	return 0.0


static func _to_int(v: Variant) -> int:
	if v is int:
		return v
	if v is float:
		return int(v)
	if v is String and v.is_valid_int():
		return v.to_int()
	if v is String and v.is_valid_float():
		return int(v.to_float())
	return 0


## Нулевое значение на проводе (для элементов repeated и optional, где опускать нельзя).
static func _zero_json(spec: String) -> Variant:
	if spec.begins_with("msg:"):
		return {}
	if spec.begins_with("enum:"):
		return ENUMS[spec.substr(5)][0]
	match spec:
		"string":
			return ""
		"bool":
			return false
		"int64", "uint64":
			return "0"
		_:
			return 0
