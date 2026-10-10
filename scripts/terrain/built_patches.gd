class_name BuiltPatches
extends RefCounted
## Пятна застройки места (NO-1, контракт N2, docs/contracts/no-osm.md): связные группы клеток 10 м с долей
## застройки WorldCover (деревни, хутора, города) — built_patches.json и detail_built10.webp, которые пишет
## SurfaceStage. Один на место, только чтение. Потребители: дома (NO-2), пасхалки (NO-3).

const META_KEY := "built_patches"

## "worldcover10" или "none" (нет места или нет файлов).
var source: String = "none"

var _patches: Array[Dictionary] = []
var _dir: String = ""
var _built_file: String = ""
var _x0: float = 0.0
var _z0: float = 0.0
var _cell: float = 10.0
var _w: int = 0
var _h: int = 0
var _img_tried: bool = false
var _data: PackedByteArray = PackedByteArray()


## Пятна загруженного места (кеш на Terrain, читается лениво); null или нет файлов — пустой.
static func for_terrain(t: Terrain) -> BuiltPatches:
	if t == null:
		return BuiltPatches.new()
	var dir := String(t.location.get("data_dir", "res://data/terrain/" + t.location_id))
	if t.has_meta(META_KEY):
		var cached: BuiltPatches = t.get_meta(META_KEY)
		if cached._dir == dir:
			return cached
	var bp := _load(dir)
	t.set_meta(META_KEY, bp)
	return bp


static func _load(dir: String) -> BuiltPatches:
	var bp := BuiltPatches.new()
	bp._dir = dir
	var surf: Variant = _json(dir.path_join("surface.json"))
	if not surf is Dictionary:
		return bp
	var det: Dictionary = {}
	for l: Dictionary in surf.get("layers", []):
		if String(l.get("id", "")) == "detail":
			det = l
	var b10: Dictionary = det.get("built10", {})
	var d10: Dictionary = det.get("detail10", {})
	if b10.is_empty() or d10.is_empty():
		return bp
	var pj: Variant = _json(dir.path_join(String(b10.get("patches_file", "built_patches.json"))))
	if not pj is Dictionary or int(pj.get("version", 0)) != 1:
		return bp
	for p: Dictionary in pj.get("patches", []):
		var bb: Array = p.bbox
		bp._patches.append(
			{
				"id": int(p.id),
				"x": float(p.x),
				"z": float(p.z),
				"area_m2": float(p.area_m2),
				"share": float(p.share),
				"bbox": Rect2(float(bb[0]), float(bb[1]), float(bb[2]) - float(bb[0]), float(bb[3]) - float(bb[1])),
			}
		)
	bp.source = String(pj.get("source", "worldcover10"))
	bp._built_file = String(b10.get("file", "detail_built10.webp"))
	bp._x0 = float(d10.get("origin_x_m", 0.0))
	bp._z0 = float(d10.get("origin_z_m", 0.0))
	bp._cell = float(d10.get("spacing_m", 10.0))
	bp._w = int(d10.get("width", 0))
	bp._h = int(d10.get("height", 0))
	return bp


static func _json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))


## Копия списка пятен: {id, x, z, area_m2, share, bbox: Rect2 (x0, z0, w, h)}.
func patches() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for p in _patches:
		out.append(p.duplicate())
	return out


## Ближайшее пятно по центру + dist_m; {} — пятен нет.
func nearest(x: float, z: float) -> Dictionary:
	var best := -1
	var best_d := INF
	for i in _patches.size():
		var d := Vector2(_patches[i].x - x, _patches[i].z - z).length_squared()
		if d < best_d:
			best_d = d
			best = i
	if best < 0:
		return {}
	var out: Dictionary = _patches[best].duplicate()
	out["dist_m"] = sqrt(best_d)
	return out


## Доля застройки 0..1 в клетке 10 м (без интерполяции); 0 — вне сетки или нет файла.
## Растр читается при первом вызове (не в for_terrain).
func share_at(x: float, z: float) -> float:
	if source == "none":
		return 0.0
	if not _img_tried:
		_img_tried = true
		var img := Image.new()
		var bytes := FileAccess.get_file_as_bytes(_dir.path_join(_built_file))
		if bytes.is_empty() or img.load_webp_from_buffer(bytes) != OK:
			img = null
		if img != null and img.get_width() == _w and img.get_height() == _h:
			if img.get_format() != Image.FORMAT_L8:
				img.convert(Image.FORMAT_L8)
			_data = img.get_data()
	if _data.is_empty():
		return 0.0
	var i := roundi((x - _x0) / _cell)
	var j := roundi((z - _z0) / _cell)
	if i < 0 or j < 0 or i >= _w or j >= _h:
		return 0.0
	return _data[j * _w + i] / 255.0
