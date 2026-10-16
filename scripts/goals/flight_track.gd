class_name FlightTrack
extends RefCounted
## Трек полёта (GL-К5): точки lat/lon/высота/время. Время — секунды от первой точки, не убывает.

var lat := PackedFloat64Array()      ## градусы
var lon := PackedFloat64Array()
var alt_m := PackedFloat32Array()    ## м над уровнем моря
var t_s := PackedFloat32Array()      ## с от первой точки
var name := ""
var source := ""                     ## "last" | путь файла


func size() -> int:
	return lat.size()


func append(lat_deg: float, lon_deg: float, alt: float, t: float) -> void:
	lat.append(lat_deg)
	lon.append(lon_deg)
	alt_m.append(alt)
	t_s.append(t)


## Вертикальная скорость в точке i, м/с: (alt(t+w/2) − alt(t−w/2)) / w по точкам окна;
## у краёв окно укорочено до реальных точек. Одна точка в окне — 0.
func vertical_speed_ms(i: int, window_s: float) -> float:
	if i < 0 or i >= size() or window_s <= 0.0:
		return 0.0
	var half := window_s * 0.5
	var lo := i
	while lo > 0 and t_s[lo - 1] >= t_s[i] - half:
		lo -= 1
	var hi := i
	while hi < size() - 1 and t_s[hi + 1] <= t_s[i] + half:
		hi += 1
	var dt := t_s[hi] - t_s[lo]
	if dt <= 0.0:
		return 0.0
	return (alt_m[hi] - alt_m[lo]) / dt


## Доля точек внутри bounds (плоскость XZ мира). latlon_fn: Callable(lat, lon) -> Vector2(x, z).
func inside_fraction(bounds: Rect2, latlon_fn: Callable) -> float:
	if size() == 0:
		return 0.0
	var n := 0
	for i in size():
		var p: Vector2 = latlon_fn.call(lat[i], lon[i])
		if bounds.has_point(p):
			n += 1
	return float(n) / float(size())
