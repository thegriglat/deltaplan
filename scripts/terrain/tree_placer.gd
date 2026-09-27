class_name TreePlacer
extends RefCounted
## Расстановка деревьев-моделей вокруг точки (без нод, тестируется headless).
## Дерево стоит в клетке сетки spacing_m, только на классе «лес» карты поверхности (VR-0, VR-4);
## порода выбирается по высоте над морем и экспозиции (веса — configs/world.json → trees.species,
## локация может переопределить), всё детерминировано хешем клетки: при пересчёте вокруг новой
## точки дерево остаётся тем же. Результат — буферы MultiMesh (порода × LOD).

## Породы в порядке индексов (ключи trees.species и trees.models).
const SPECIES: PackedStringArray = ["pine", "cedar", "larch", "birch", "spruce"]
## Чисел на экземпляр в буфере MultiMesh (TRANSFORM_3D + цвет).
const STRIDE := 16

var layer: HeightLayer
var surface: SurfaceLayer
var spacing: float = 8.0
var radius: float = 500.0
## Границы LOD, м: [конец LOD0, конец LOD1]; дальше до radius — LOD2.
var lod_distances := PackedFloat32Array([60.0, 180.0])
var density: float = 0.8
var sink_fraction: float = 0.5
## У опушки DSM ещё не поднялся на высоту крон — дерево утоплено меньше.
var edge_sink_fraction: float = 0.05
var edge_probe_m: float = 30.0
## Просеки (дороги, ЛЭП, здания, посадки): L8, 255 — расчищено; null — нет.
var clear_image: Image
var clear_origin: Vector2 = Vector2.ZERO
var clear_cell: float = 10.0
## С этой доли радиуса модели редеют, уступая импостерам (0 — не редеют).
var fade_start_k: float = 0.0
var color_variation: float = 0.15
var band_blend_m: float = 200.0
## Высота модели каждой породы, м (из меша) — для масштаба.
var model_height := PackedFloat32Array([20.0, 22.0, 25.0, 14.0, 23.0])
## Результат build(): buffers[вид * 3 + lod] — PackedFloat32Array, counts — число экземпляров.
var buffers: Array[PackedFloat32Array] = []
var counts := PackedInt32Array()

var _weight := PackedFloat32Array()
var _min_m := PackedFloat32Array()
var _max_m := PackedFloat32Array()
var _aspect := PackedFloat32Array()
var _h_min := PackedFloat32Array()
var _h_max := PackedFloat32Array()


## cfg — configs/world.json → trees (с переопределениями локации).
func setup(height_layer: HeightLayer, surface_layer: SurfaceLayer, cfg: Dictionary) -> void:
	layer = height_layer
	surface = surface_layer
	spacing = float(cfg.get("spacing_m", 8.0))
	radius = float(cfg.get("radius_m", 500.0))
	lod_distances = PackedFloat32Array(cfg.get("lod_distances_m", [60.0, 180.0]))
	density = float(cfg.get("density", 0.8))
	sink_fraction = float(cfg.get("sink_fraction", 0.5))
	edge_sink_fraction = float(cfg.get("edge_sink_fraction", sink_fraction))
	edge_probe_m = float(cfg.get("edge_probe_m", 30.0))
	color_variation = float(cfg.get("color_variation", 0.15))
	band_blend_m = maxf(1.0, float(cfg.get("band_blend_m", 200.0)))
	var ic: Dictionary = cfg.get("impostors", {})
	fade_start_k = float(ic.get("fade_start_k", 0.0)) if bool(ic.get("enabled", false)) else 0.0
	var sp: Dictionary = cfg.get("species", {})
	for arr in [_weight, _min_m, _max_m, _aspect, _h_min, _h_max]:
		arr.resize(SPECIES.size())
	for k in SPECIES.size():
		var s: Dictionary = sp.get(SPECIES[k], {})
		_weight[k] = float(s.get("weight", 0.0))
		_min_m[k] = float(s.get("min_m", -1e4))
		_max_m[k] = float(s.get("max_m", 1e4))
		_aspect[k] = float(s.get("aspect", 0.0))
		var hr: Array = s.get("height_m", [15.0, 25.0])
		_h_min[k] = float(hr[0])
		_h_max[k] = float(hr[1])


## Порода для точки (−1 — ни одна не подходит): высота над морем h, «северность» north −1..1,
## u — случайное 0..1.
func pick_species(h: float, north: float, u: float) -> int:
	var w := PackedFloat32Array()
	w.resize(SPECIES.size())
	var total := 0.0
	for k in SPECIES.size():
		var band := (
			clampf((h - _min_m[k]) / band_blend_m + 0.5, 0.0, 1.0)
			* clampf((_max_m[k] - h) / band_blend_m + 0.5, 0.0, 1.0)
		)
		w[k] = _weight[k] * band * maxf(0.05, 1.0 + _aspect[k] * north)
		total += w[k]
	if total <= 0.0:
		return -1
	var t := u * total
	for k in SPECIES.size():
		t -= w[k]
		if t <= 0.0:
			return k
	return SPECIES.size() - 1


## Расставить деревья в круге radius вокруг center (X/Z мира). Заполняет buffers и counts.
func build(center: Vector2) -> void:
	var n_buf := SPECIES.size() * 3
	buffers.clear()
	buffers.resize(n_buf)
	counts = PackedInt32Array()
	counts.resize(n_buf)
	var lists: Array[PackedFloat32Array] = []
	lists.resize(n_buf)
	for b in n_buf:
		lists[b] = PackedFloat32Array()
	var ci := floori(center.x / spacing)
	var cj := floori(center.y / spacing)
	var nr := ceili(radius / spacing)
	var r2 := radius * radius
	var d0 := lod_distances[0] if lod_distances.size() > 0 else 60.0
	var d1 := lod_distances[1] if lod_distances.size() > 1 else 180.0
	var e := layer.spacing
	for dj in range(-nr, nr + 1):
		for di in range(-nr, nr + 1):
			var i := ci + di
			var j := cj + dj
			if hash01(i, j, 1) >= density:
				continue
			var x := (i + 0.5 + (hash01(i, j, 2) - 0.5) * 0.8) * spacing
			var z := (j + 0.5 + (hash01(i, j, 3) - 0.5) * 0.8) * spacing
			var dx := x - center.x
			var dz := z - center.y
			var d2 := dx * dx + dz * dz
			if d2 > r2 or not layer.contains(x, z):
				continue
			# переход к импостерам среднего плана: модели редеют к краю радиуса
			if fade_start_k > 0.0:
				var fk := smoothstep(radius * fade_start_k, radius, sqrt(d2))
				if hash01(i, j, 8) < fk:
					continue
			if surface.class_at(x, z) != SurfaceLayer.FOREST or is_cleared(x, z):
				continue
			var h := layer.sample(x, z)
			var gx := (layer.sample(x + e, z) - h) / e
			var gz := (layer.sample(x, z + e) - h) / e
			var grad := sqrt(gx * gx + gz * gz)
			# «северность»: склон смотрит на −Z (север), т. е. высота растёт к +Z
			var north := (
				clampf(gz / grad, -1.0, 1.0) * clampf(grad / 0.25, 0.0, 1.0) if grad > 1e-4 else 0.0
			)
			var sp := pick_species(h, north, hash01(i, j, 4))
			if sp < 0:
				continue
			var hh := lerpf(_h_min[sp], _h_max[sp], hash01(i, j, 5))
			var s := hh / maxf(model_height[sp], 0.1)
			var a := hash01(i, j, 6) * TAU
			var c := cos(a) * s
			var sn := sin(a) * s
			var y := h - sink_at(x, z) * hh
			var v := 1.0 + color_variation * (hash01(i, j, 7) - 0.5) * 2.0
			var lod := 0 if d2 < d0 * d0 else (1 if d2 < d1 * d1 else 2)
			var b := sp * 3 + lod
			# строки 3×4 матрицы: поворот вокруг Y с масштабом + сдвиг; затем цвет
			lists[b].append_array(
				PackedFloat32Array([c, 0.0, sn, x, 0.0, s, 0.0, y, -sn, 0.0, c, z, v, v, v, 1.0])
			)
	for b in n_buf:
		buffers[b] = lists[b]
		counts[b] = lists[b].size() / STRIDE


## Расчищено ли место (маска просек WorldClearings).
func is_cleared(x: float, z: float) -> bool:
	if clear_image == null:
		return false
	var i := floori((x - clear_origin.x) / clear_cell)
	var j := floori((z - clear_origin.y) / clear_cell)
	if i < 0 or j < 0 or i >= clear_image.get_width() or j >= clear_image.get_height():
		return false
	return clear_image.get_pixel(i, j).r > 0.5


## Доля высоты дерева ниже поверхности DEM: в глубине леса — sink_fraction (кроны уже в DSM),
## у опушки — меньше (до edge_sink_fraction), чтобы стволы читались.
func sink_at(x: float, z: float) -> float:
	var n := 0
	for k in 8:
		var a := TAU * k / 8.0
		if (
			surface.class_at(x + cos(a) * edge_probe_m, z + sin(a) * edge_probe_m)
			== SurfaceLayer.FOREST
		):
			n += 1
	return lerpf(edge_sink_fraction, sink_fraction, n / 8.0)


## Детерминированное псевдослучайное 0..1 для клетки (i, j) и номера признака k.
static func hash01(i: int, j: int, k: int) -> float:
	var hsh := (i * 374761393 + j * 668265263 + k * 1442695041) & 0xFFFFFFFF
	hsh = ((hsh ^ (hsh >> 13)) * 1274126177) & 0xFFFFFFFF
	hsh = hsh ^ (hsh >> 16)
	return float(hsh & 0xFFFFFF) / 16777216.0
