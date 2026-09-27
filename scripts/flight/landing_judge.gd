class_name LandingJudge
extends RefCounted
## Оценка посадки (FR-10): мягкая / жёсткая / авария по скорости относительно склона и крену.


## velocity — скорость в момент касания, normal — нормаль к земле, cfg — flight.json → landing.
## Возвращает {grade: "soft"|"hard"|"crash", vertical_speed_ms, horizontal_speed_ms, bank_deg}.
static func evaluate(
	velocity: Vector3, normal: Vector3, bank_deg: float, cfg: Dictionary
) -> Dictionary:
	var vn := -velocity.dot(normal)  # скорость в землю
	var vt := (velocity + normal * vn).length()  # вдоль поверхности
	var b := absf(bank_deg)
	var grade := "soft"
	if (
		vn > float(cfg.hard_vertical_ms)
		or vt > float(cfg.hard_horizontal_ms)
		or b > float(cfg.crash_bank_deg)
	):
		grade = "crash"
	elif (
		vn > float(cfg.soft_vertical_ms)
		or vt > float(cfg.soft_horizontal_ms)
		or b > float(cfg.soft_bank_deg)
	):
		grade = "hard"
	return {
		"grade": grade,
		"vertical_speed_ms": vn,
		"horizontal_speed_ms": vt,
		"bank_deg": bank_deg,
	}


## Нормаль к земле по конечным разностям ground_fn(x, z) с шагом d.
static func ground_normal(ground_fn: Callable, x: float, z: float, d: float) -> Vector3:
	if not ground_fn.is_valid():
		return Vector3.UP
	var hx := float(ground_fn.call(x + d, z)) - float(ground_fn.call(x - d, z))
	var hz := float(ground_fn.call(x, z + d)) - float(ground_fn.call(x, z - d))
	return Vector3(-hx, 2.0 * d, -hz).normalized()
