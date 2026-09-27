class_name Units
## Перевод единиц. Внутри симуляции всё в СИ: м, м/с, кг, с, радианы.
## В конфигах — удобные пилоту единицы, суффикс ключа обязателен: _kmh, _ms, _kg, _deg, _m, _s.

const KMH_TO_MS := 1.0 / 3.6
const MS_TO_KMH := 3.6
const G := 9.80665


static func kmh(v: float) -> float:
	return v * KMH_TO_MS


static func to_kmh(v: float) -> float:
	return v * MS_TO_KMH


static func deg(a: float) -> float:
	return deg_to_rad(a)
