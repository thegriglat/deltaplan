class_name TaskPoint
extends RefCounted
## Пункт задания: цилиндр (или линия гоула) в координатах мира.
## position.y — высота земли у пункта над уровнем моря, м (для требуемого качества).

enum Kind { TAKEOFF, SSS, TURNPOINT, ESS, GOAL }

const KIND_NAMES := {
	"takeoff": Kind.TAKEOFF,
	"sss": Kind.SSS,
	"turnpoint": Kind.TURNPOINT,
	"ess": Kind.ESS,
	"goal": Kind.GOAL,
}

var name: String = ""
var kind: Kind = Kind.TURNPOINT
var position: Vector3 = Vector3.ZERO
var radius_m: float = 400.0
## Направление пересечения: false — вход (обычно), true — выход (стартовый цилиндр «exit»).
var exit: bool = false
## Гоул-линия вместо цилиндра (только для GOAL).
var is_line: bool = false
var line_length_m: float = 400.0
## Исходные координаты (NAN, если пункт задан в метрах).
var lat: float = NAN
var lon: float = NAN


static func kind_from_string(s: String) -> Kind:
	return KIND_NAMES.get(s.to_lower(), Kind.TURNPOINT)


static func kind_to_string(k: Kind) -> String:
	for key: String in KIND_NAMES:
		if KIND_NAMES[key] == k:
			return key
	return "turnpoint"


func center_2d() -> Vector2:
	return Vector2(position.x, position.z)


## Горизонтальное расстояние от точки мира до центра, м.
func center_distance(p: Vector3) -> float:
	return Vector2(p.x - position.x, p.z - position.z).length()


## Расстояние до края цилиндра (0 внутри), м.
func edge_distance(p: Vector3) -> float:
	return maxf(center_distance(p) - radius_m, 0.0)


## Концы линии гоула: перпендикуляр к направлению прилёта leg_dir (единичный, XZ) через центр.
func line_ends(leg_dir: Vector2) -> PackedVector2Array:
	var n := Vector2(-leg_dir.y, leg_dir.x) * (line_length_m * 0.5)
	var c := center_2d()
	return PackedVector2Array([c - n, c + n])


func to_dict() -> Dictionary:
	return {
		"name": name,
		"type": kind_to_string(kind),
		"position": position,
		"radius_m": radius_m,
		"exit": exit,
		"goal_line": is_line,
	}
