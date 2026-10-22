class_name MouseBar
extends RefCounted
## Мышь → штанга (BM-К1, docs/contracts/bar-mouse.md): ход в отсчётах мыши (InputEventMouseMotion.relative),
## размер окна и частота кадров в расчёт не входят. Чистые статические функции.

const DEFAULT_TRAVEL_PX := 2500.0
const DEFAULT_SENSITIVITY := 1.0


## Отсчётов мыши от нейтрали до упора в одну сторону: bar_travel_px / bar_sensitivity (множитель 0,05..20), не меньше 1.
static func travel_px(mouse: Dictionary) -> float:
	var travel := float(mouse.get("bar_travel_px", DEFAULT_TRAVEL_PX))
	var sens := clampf(float(mouse.get("bar_sensitivity", DEFAULT_SENSITIVITY)), 0.05, 20.0)
	return maxf(travel / sens, 1.0)


## Смещение штанги [-1, 1] по осям после движения мыши на rel отсчётов.
static func accumulate(offset: Vector2, rel: Vector2, mouse: Dictionary) -> Vector2:
	return (offset + rel / travel_px(mouse)).clamp(Vector2(-1, -1), Vector2(1, 1))


## Мёртвая зона вычитанием: непрерывна на пороге, ±1 → ±1.
static func apply_deadzone(x: float, dz: float) -> float:
	var d := clampf(dz, 0.0, 0.5)
	var a := absf(x)
	if a <= d:
		return 0.0
	return signf(x) * (a - d) / (1.0 - d)
