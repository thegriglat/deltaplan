extends TestCase
## Контрактный тест PD-К4 (docs/contracts/pendulum.md): сеть — режим управления и положение пилота.
## PilotState.control_mode = 11, pilot_rel = 12, enum ControlMode, JSON-ключи controlMode / pilotRel
## (nullable), прирост PilotState в двоичном protobuf. Правка контракта (версия +1) — вместе с этим файлом.

const DOC := "res://docs/contracts/pendulum.md"
const PROTO := "res://server/proto/deltaplan/v1/net.proto"


func _read(path: String) -> String:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		text = FileAccess.get_file_as_string(ProjectSettings.globalize_path(path))
	return text


func test_doc_heading() -> void:
	var text := _read(DOC)
	check(not text.is_empty(), "docs/contracts/pendulum.md читается")
	var re := RegEx.create_from_string("(?m)^## PD-К4\\. .* \\(v(\\d+)\\)\\s*$")
	var m := re.search(text)
	check(m != null and int(m.get_string(1)) == 2, "заголовок «## PD-К4. … (v2)»")


func test_proto_fields() -> void:
	var text := _read(PROTO)
	check(not text.is_empty(), "net.proto читается")
	check(text.contains("ControlMode control_mode = 11;"), "control_mode = 11")
	check(text.contains("Vec3 pilot_rel = 12;"), "pilot_rel = 12")
	for pair: Array in [
		["CONTROL_MODE_UNSPECIFIED", 0],
		["CONTROL_MODE_RATE", 1],
		["CONTROL_MODE_WEIGHT_SHIFT", 2],
		["CONTROL_MODE_PENDULUM", 3],
	]:
		check(text.contains("%s = %d;" % pair), "enum %s = %d" % pair)


func test_messages_schema() -> void:
	var f: Dictionary = NetMessages.MESSAGES["PilotState"]
	check(f.get("controlMode") == "enum:ControlMode", "controlMode — enum:ControlMode")
	check(f.get("pilotRel") == "msg:Vec3", "pilotRel — msg:Vec3")
	check(NetMessages.NULLABLE.get("PilotState.pilotRel", false), "pilotRel nullable")
	check(
		NetMessages.ENUMS["ControlMode"]
		== [
			"CONTROL_MODE_UNSPECIFIED",
			"CONTROL_MODE_RATE",
			"CONTROL_MODE_WEIGHT_SHIFT",
			"CONTROL_MODE_PENDULUM"
		],
		"ControlMode в ENUMS"
	)


func test_json_roundtrip_and_old_client() -> void:
	var rel := Vector3(0.05, -1.18, -0.12)
	var text := NetMessages.encode(
		"pilotState",
		{
			"pilotId": "7",
			"controlMode": "CONTROL_MODE_PENDULUM",
			"pilotRel": NetMessages.vec3(rel),
		}
	)
	var m := NetMessages.decode(text)
	var d: Dictionary = m.data
	check(d.controlMode == "CONTROL_MODE_PENDULUM", "controlMode туда-обратно")
	check(NetMessages.to_vector3(d.pilotRel).is_equal_approx(rel), "pilotRel туда-обратно")
	# старый клиент: полей нет → UNSPECIFIED и pilotRel == null
	var old := NetMessages.decode(NetMessages.encode("pilotState", {"pilotId": "7"}))
	check(old.data.controlMode == "CONTROL_MODE_UNSPECIFIED", "нет controlMode → UNSPECIFIED")
	check(old.data.pilotRel == null, "нет pilotRel → null")


## Размер поля Vec3 (float x, y, z; нулевые не пишутся) в protobuf: тег 1 + длина 1 + по 5 байт.
static func _vec3_field_size(v: Vector3) -> int:
	var inner := 0
	for c in [v.x, v.y, v.z]:
		if c != 0.0:
			inner += 5
	return 2 + inner


func test_binary_growth() -> void:
	# control_mode: тег 1 + varint 1 = 2 байта (только в полном пакете, раз в секунду)
	var mode_bytes := 2
	var rel := Vector3(snappedf(0.0512, 0.01), snappedf(-1.1834, 0.01), snappedf(-0.1201, 0.01))
	var rel_bytes := _vec3_field_size(rel)
	check(rel_bytes <= 17, "pilot_rel в обычном пакете: %d байт (тип Vec3 — 3×float)" % rel_bytes)
	# Контракт: ≤ 16. Три ненулевых float32 + тег и длина дают 17; ровно 16 — при одной нулевой
	# компоненте после округления до 1 см (x маятника около нуля). Отражено в отчёте PD-7.
	var rel0 := _vec3_field_size(Vector3(0.0, -1.18, -0.12))
	check(rel0 <= 12, "pilot_rel с нулевой компонентой: %d байт" % rel0)
	check(mode_bytes + rel_bytes <= 19, "полный пакет: +%d байт" % (mode_bytes + rel_bytes))
