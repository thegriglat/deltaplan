class_name TerrainGeo
extends RefCounted
## Перевод географических координат в координаты мира и обратно.
## Локальная равнопромежуточная проекция вокруг центра локации
## (та же, что в tools/terrain/fetch_dem.py):
##   x = (lon − lon0)·cos(lat0)·R·π/180 (восток),  z = −(lat − lat0)·R·π/180 (−Z — север).
## На 160 км ошибка масштаба < 1 % — для игры достаточно.

## Средний радиус Земли, м (геодезическая константа, не параметр игры).
const EARTH_RADIUS_M := 6371008.8


static func meters_per_deg_lat() -> float:
	return EARTH_RADIUS_M * PI / 180.0


static func meters_per_deg_lon(center_lat: float) -> float:
	return meters_per_deg_lat() * cos(deg_to_rad(center_lat))


## (lat, lon) → Vector2(x, z) в метрах относительно центра.
static func latlon_to_local(
	lat: float, lon: float, center_lat: float, center_lon: float
) -> Vector2:
	return Vector2(
		(lon - center_lon) * meters_per_deg_lon(center_lat),
		-(lat - center_lat) * meters_per_deg_lat()
	)


## (x, z) → Vector2(lat, lon).
static func local_to_latlon(x: float, z: float, center_lat: float, center_lon: float) -> Vector2:
	return Vector2(
		center_lat - z / meters_per_deg_lat(), center_lon + x / meters_per_deg_lon(center_lat)
	)


## Единичный вектор НА солнце по азимуту (0 — север, по часовой) и высоте над горизонтом.
static func sun_direction(azimuth_deg: float, elevation_deg: float) -> Vector3:
	var az := deg_to_rad(azimuth_deg)
	var el := deg_to_rad(elevation_deg)
	# север = −Z, восток = +X
	return Vector3(sin(az) * cos(el), sin(el), -cos(az) * cos(el)).normalized()


## Горизонтальный единичный вектор курса (0 — север, по часовой).
static func heading_vector(heading_deg: float) -> Vector3:
	var h := deg_to_rad(heading_deg)
	return Vector3(sin(h), 0.0, -cos(h))
