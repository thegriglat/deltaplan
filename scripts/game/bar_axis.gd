class_name BarAxis
extends RefCounted
## Ход ручки трапеции → управление (CB-К2 v1, docs/contracts/control-bar.md).
## Сырое значение оси → калибровка [min, center, max] → инверсия → мёртвая зона/экспонента/чувствительность.

const IDENTITY: Array = [-1.0, 0.0, 1.0]
const MIN_SPAN := 1e-3


## Кусочно-линейная нормализация по калибровке; итог в [-1, 1], всегда конечный.
static func normalize(raw: float, cal: Array) -> float:
	if not is_finite(raw):
		return 0.0
	var c := _fix(cal)
	var lo := float(c[0])
	var mid := float(c[1])
	var hi := float(c[2])
	var d := raw - mid
	var span := (hi - mid) if d >= 0.0 else (mid - lo)
	if span < MIN_SPAN:
		return 0.0
	return clampf(d / span, -1.0, 1.0)


## Мёртвая зона, экспонента, чувствительность (бывший input_controller._stick).
static func shape(x: float, gp: Dictionary) -> float:
	var dz := float(gp.deadzone)
	if absf(x) < dz:
		return 0.0
	var v := (absf(x) - dz) / (1.0 - dz)
	var e := float(gp.expo)
	v = (1.0 - e) * v + e * v * v * v
	return signf(x) * clampf(v * float(gp.sensitivity), 0.0, 1.0)


static func axis_value(raw: float, cal: Array, invert: bool, gp: Dictionary) -> float:
	return shape(normalize(raw, cal) * (-1.0 if invert else 1.0), gp)


## "" — первое подключённое; иначе первое с таким GUID; нет — -1.
static func find_device(guid: String) -> int:
	return pick_device(guid, devices())


## Подключённые устройства: [{id, guid, name}].
static func devices() -> Array:
	var out: Array = []
	for id: int in Input.get_connected_joypads():
		out.append({"id": id, "guid": Input.get_joy_guid(id), "name": Input.get_joy_name(id)})
	return out


## Выбор из списка устройств (чистая функция для тестов).
static func pick_device(guid: String, devs: Array) -> int:
	if devs.is_empty():
		return -1
	if guid == "":
		return int(devs[0].id)
	for d: Dictionary in devs:
		if String(d.guid) == guid:
			return int(d.id)
	return -1


## Калибровка оси из gamepad.calibration (roll / pitch); нет или неверна — без калибровки.
static func cal_of(gp: Dictionary, axis: String) -> Array:
	var all: Variant = gp.get("calibration", {})
	if all is Dictionary:
		var c: Variant = (all as Dictionary).get(axis)
		if c is Array:
			return c
	return IDENTITY


static func _fix(cal: Array) -> Array:
	if cal.size() != 3:
		return IDENTITY
	for v: Variant in cal:
		if not (v is float or v is int) or not is_finite(float(v)):
			return IDENTITY
	return cal
