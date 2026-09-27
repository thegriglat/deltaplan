extends RefCounted
## Общие заготовки тестов заданий: телеметрия, «полёт» по точкам, перевод lat/lon.

const CENTER_LAT := 51.87
const CENTER_LON := 85.87


static func latlon_fn() -> Callable:
	return func(lat: float, lon: float) -> Vector2:
		return TerrainGeo.latlon_to_local(lat, lon, CENTER_LAT, CENTER_LON)


static func telem(pos: Vector3, time_s: float, phase: String = "flying") -> Telemetry:
	var t := Telemetry.new()
	t.position = pos
	t.altitude_msl = pos.y
	t.altitude_agl = pos.y
	t.time_s = time_s
	t.phase = phase
	t.on_ground = phase != "flying"
	return t


## Пролететь по прямой от a до b за duration_s с шагом dt (время от t0). Возвращает время конца.
static func fly(
	tr: TaskTracker, a: Vector3, b: Vector3, t0: float, duration_s: float, dt: float = 1.0
) -> float:
	var n := maxi(int(duration_s / dt), 1)
	for i in n + 1:
		var k := float(i) / float(n)
		tr.update(telem(a.lerp(b, k), t0 + duration_s * k))
	return t0 + duration_s


## Задание в метрах: пункты [[type, x, z, r], …].
static func make_task(pts: Array, gates: Array = [], type: String = "race") -> Task:
	var list := []
	for p: Array in pts:
		list.append(
			{
				"name": "P%d" % list.size(),
				"type": p[0],
				"x_m": p[1],
				"z_m": p[2],
				"radius_m": p[3],
				"direction": p[4] if p.size() > 4 else "enter"
			}
		)
	return Task.from_dict({"id": "t", "type": type, "start_gates_s": gates, "turnpoints": list})
