class_name WorldCoverLoader
extends RefCounted
## Имена файлов ESA WorldCover (сборка карты покрова места — SurfaceStage, OA-3).


## Имя файла WorldCover по юго-западному углу 3°×3°: N51E084, S12W077.
static func tile_name(lat_i: int, lon_i: int) -> String:
	return (
		"%s%02d%s%03d"
		% ["N" if lat_i >= 0 else "S", absi(lat_i), "E" if lon_i >= 0 else "W", absi(lon_i)]
	)
