class_name OsmGrid
extends RefCounted
## Мировая сетка тайлов OSM 20 км (контракт O1, docs/contracts/osm-tiles.md). Все числа — double,
## операции ровно по контракту (золотая таблица tests/contracts/osm_tiles/grid_golden.json).

const R := 6371008.8
const DLAT := 0.18
const T := 20000.0
const J_MIN := -500
const J_MAX := 499

static var _m: float = PI * R / 180.0


## Метров на градус широты (= ky пояса).
static func m_per_deg() -> float:
	return _m


static func band_of(lat: float) -> int:
	var l := clampf(lat, -90.0, 90.0)
	return clampi(int(floor(l / DLAT)), J_MIN, J_MAX)


## Метров на градус долготы в поясе j (kx).
static func kx(j: int) -> float:
	var latc := (j + 0.5) * DLAT
	return _m * cos(latc * PI / 180.0)


## Число тайлов в поясе j.
static func n_of(j: int) -> int:
	return maxi(1, int(floor(360.0 * kx(j) / T)))


static func dlon(j: int) -> float:
	return 360.0 / float(n_of(j))


static func _wrap_lon(lon: float) -> float:
	var l := fposmod(lon + 180.0, 360.0) - 180.0
	return l


static func index_of(j: int, lon: float) -> int:
	var n := n_of(j)
	return clampi(int(floor((_wrap_lon(lon) + 180.0) / dlon(j))), 0, n - 1)


## Тайл точки: Vector2i(j, i).
static func tile_of(lat: float, lon: float) -> Vector2i:
	var j := band_of(lat)
	return Vector2i(j, index_of(j, lon))


## Юго-западный угол тайла: Vector2(lat0, lon0).
static func origin(j: int, i: int) -> Vector2:
	return Vector2(j * DLAT, -180.0 + i * dlon(j))


## Угол тайла в double: [lat0, lon0].
static func origin_d(j: int, i: int) -> PackedFloat64Array:
	return PackedFloat64Array([j * DLAT, -180.0 + i * dlon(j)])


## Координаты тайла (x восток, y север, м) точки.
static func to_tile(j: int, i: int, lat: float, lon: float) -> Vector2:
	var o := origin_d(j, i)
	return Vector2((_wrap_lon(lon) - o[1]) * kx(j), (lat - o[0]) * _m)


## Соседи 3x3 точки: массив Vector2i(j, i), снизу вверх, запад → восток, без повторов.
static func neighbors(lat: float, lon: float) -> Array[Vector2i]:
	var j0 := band_of(lat)
	var out: Array[Vector2i] = []
	for jj in [j0 - 1, j0, j0 + 1]:
		if jj < J_MIN or jj > J_MAX:
			continue
		var n := n_of(jj)
		var ic := index_of(jj, lon)
		var seen := {}
		for d in [-1, 0, 1]:
			var i := posmod(ic + d, n)
			if not seen.has(i):
				seen[i] = true
				out.append(Vector2i(jj, i))
	return out
