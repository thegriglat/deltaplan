class_name OsmPilot
extends RefCounted
## Заглушка слоя OSM (вершины и перевалы с подписями, ЛЭП, мачты, канатки, аэродромы); наполняет OT-10. Сигнатура — контракт O9 (docs/contracts/osm-tiles.md):
## данные места (OsmData), конфиг WorldObjects, высота рельефа height_fn(x, z) -> float и индекс препятствий
## (OsmLayer передаёт свой). Возвращает Node3D для OsmLayer или null, если строить нечего.


static func build(
	_data: OsmData, _cfg: Dictionary, _height_fn: Callable, _obstacles: ObstacleIndex
) -> Node3D:
	return null
