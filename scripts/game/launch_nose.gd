class_name LaunchNose
extends RefCounted
## Нос крыла бота на разбеге по ветру (F01, G06) — техника BotAgent (игрок ведёт нос сам).
## Техника (docs/flight.md → «Старт в сильный ветер»): стоя, пилот чувствует ветер в лицо;
## в сильный ветер (≥ strong_wind_ms) разбегается с носом ниже — держит угол атаки киля около
## target_alpha_deg (нейтраль носа ~23° — у самого срыва 24°). Крыло «обмякло» (срыв) — нос вниз.

## Ветер в лицо стоя (воздушная скорость), с которого нос держится по углу атаки, м/с.
var strong_wind_ms: float = 3.5
## Угол атаки киля на разбеге в сильный ветер, °.
var target_alpha_deg: float = 18.0
## Мёртвая зона по углу атаки, °.
var alpha_tol_deg: float = 1.0

## Ветер в лицо, замеренный стоя (максимум воздушной скорости в фазе standing), м/с.
var wind_ms: float = 0.0


## Параметры из словаря (configs/bots.json → launch.auto_nose); отсутствующие — как есть.
func configure(cfg: Dictionary) -> void:
	strong_wind_ms = float(cfg.get("strong_wind_ms", strong_wind_ms))
	target_alpha_deg = float(cfg.get("target_alpha_deg", target_alpha_deg))
	alpha_tol_deg = float(cfg.get("alpha_tol_deg", alpha_tol_deg))


func reset() -> void:
	wind_ms = 0.0


## Каждый шаг на земле: стоя — замер ветра в лицо.
func observe(t: Telemetry) -> void:
	if t.phase == "standing":
		wind_ms = maxf(wind_ms, t.airspeed)


## Сильный ветер: нос держится по углу атаки, а не на нейтрали.
func is_strong() -> bool:
	return wind_ms >= strong_wind_ms


## Куда подстроить нос: −1 — опустить, +1 — поднять (не выше нейтрали — это решает вызывающий),
## 0 — держать.
func direction(t: Telemetry) -> int:
	if t.stalled:
		return -1
	if not is_strong() or t.airspeed < 1.0:
		return 0
	var a := alpha_deg(t)
	if a > target_alpha_deg + alpha_tol_deg:
		return -1
	if a < target_alpha_deg - alpha_tol_deg:
		return 1
	return 0


## Угол атаки киля: тангаж минус угол набегающего потока, °.
static func alpha_deg(t: Telemetry) -> float:
	if t.airspeed < 1e-3:
		return t.pitch_deg
	var flow := rad_to_deg(asin(clampf(t.air_velocity.y / t.airspeed, -1.0, 1.0)))
	return t.pitch_deg - flow
