class_name GoalSpec
extends RefCounted
## Формат цели полёта (GL-К1, docs/contracts/goals.md): словарь
## {kind, level, value, task}. Единицы value — по виду цели (см. контракт). Статика, без состояния.

const KINDS := ["height", "duration", "distance", "return", "triangle", "route", "speed", "landing"]
const LEVELS := ["easy", "medium", "hard", "custom"]
## Виды, к которым привязан предел времени `speed`.
const SPEED_COMPANIONS := ["route", "triangle", "return"]


static func make(kind: String, level: String, value: float, task: String = "") -> Dictionary:
	return {"kind": kind, "level": level, "value": value, "task": task}


## Ошибки списка целей (пусто — годно).
static func validate(goals: Array) -> PackedStringArray:
	var errs := PackedStringArray()
	var seen := {}
	for i in goals.size():
		var g: Variant = goals[i]
		if not g is Dictionary:
			errs.append("цель %d: не словарь" % i)
			continue
		var kind := String(g.get("kind", ""))
		if kind not in KINDS:
			errs.append("цель %d: неизвестный вид '%s'" % [i, kind])
			continue
		if seen.has(kind):
			errs.append("цель %d: вид '%s' повторяется" % [i, kind])
		seen[kind] = true
		var level := String(g.get("level", ""))
		if level not in LEVELS:
			errs.append("цель %d (%s): неизвестный уровень '%s'" % [i, kind, level])
		var value := float(g.get("value", 0.0))
		if kind == "route":
			if String(g.get("task", "")).is_empty():
				errs.append("цель %d (route): не задано задание" % i)
		elif not (value > 0.0 and is_finite(value)):
			errs.append("цель %d (%s): значение должно быть больше нуля" % [i, kind])
	if seen.has("speed"):
		var ok := false
		for k: String in SPEED_COMPANIONS:
			ok = ok or seen.has(k)
		if not ok:
			errs.append("speed: нужен маршрут (route, triangle или return)")
	return errs
