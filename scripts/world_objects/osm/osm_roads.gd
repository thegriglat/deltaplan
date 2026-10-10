class_name OsmRoads
extends RefCounted
## Заглушка слоя OSM (дороги, реки и каналы, железные дороги, просеки, палатки); наполняет OT-9. Сигнатура — контракт O9 (docs/contracts/osm-tiles.md):
## данные места (OsmData), конфиг WorldObjects, высота рельефа height_fn(x, z) -> float и индекс препятствий
## (OsmLayer передаёт свой). Возвращает Node3D для OsmLayer или null, если строить нечего.


static func build(
	_data: OsmData, _cfg: Dictionary, _height_fn: Callable, _obstacles: ObstacleIndex
) -> Node3D:
	return null
