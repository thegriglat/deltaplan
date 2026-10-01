class_name TreePlacer
extends RefCounted
## Расстановка деревьев-моделей вокруг точки (без нод, тестируется headless).
## Дерево стоит в клетке сетки spacing_m там, где доля леса по маске 10 м ≥ 0,5 и доля воды
## (канал G, реки/озёра OSM, T03) меньше water_max (set_forest_mask, V02; без маски — на классе
## «лес» карты поверхности 25 м, VR-0, VR-4): WorldCover часто зовёт лесом прибрежные кроны
## над руслом, а рельеф там рисует воду — вода для деревьев та же кромка, что луг; у кромки
## леса — гуще и раскидистее (опушка — стена деревьев), утоплено меньше (edge_sink_fraction);
## порода выбирается по высоте над морем и экспозиции (веса — configs/world.json → trees.species,
## локация может переопределить), всё детерминировано хешем клетки: при пересчёте вокруг новой
## точки дерево остаётся тем же (и тот же вариант модели — хеш клетки). Результат — буферы MultiMesh
## (порода × вариант × LOD). У границы LOD (полоса lod_fade_m + запас на сдвиг камеры до пересчёта
## rebuild_step_m) экземпляр стоит в обоих соседних LOD с кодом растворения в альфе цвета
## (FADE_*): tree_model.gdshader по живому расстоянию до камеры проявляет один и растворяет другой.

## Породы в порядке индексов (ключи trees.species и trees.models).
const SPECIES: PackedStringArray = ["pine", "cedar", "larch", "birch", "spruce"]
## Чисел на экземпляр в буфере MultiMesh (TRANSFORM_3D + цвет).
const STRIDE := 16
## Коды растворения на границе LOD (альфа цвета экземпляра, tree_model.gdshader): 1 — без растворения;
## 0,1/0,2 — уходит/проявляется на границе LOD0↔LOD1; 0,3/0,4 — на границе LOD1↔LOD2.
const FADE_NONE := 1.0
const FADE_OUT0 := 0.1
const FADE_IN0 := 0.2
const FADE_OUT1 := 0.3
const FADE_IN1 := 0.4
## Кольца поиска кромки, доли edge_band_m.
const EDGE_RINGS_K: PackedFloat32Array = [0.25, 0.5, 0.75, 1.0, 1.4]
## 8 направлений колец (через 45°).
const RING8: PackedVector2Array = [
	Vector2(1, 0),
	Vector2(0.7071, 0.7071),
	Vector2(0, 1),
	Vector2(-0.7071, 0.7071),
	Vector2(-1, 0),
	Vector2(-0.7071, -0.7071),
	Vector2(0, -1),
	Vector2(0.7071, -0.7071),
]

var layer: HeightLayer
var surface: SurfaceLayer
var spacing: float = 8.0
var radius: float = 500.0
## Границы LOD, м: [конец LOD0, конец LOD1]; дальше до radius — LOD2.
var lod_distances := PackedFloat32Array([60.0, 180.0])
## Ширина растворения на границе LOD, м (шейдер); в обоих LOD экземпляр стоит в полосе
## ±(lod_fade_m/2 + fade_margin_m): камера до пересчёта сдвигается до rebuild_step_m.
var lod_fade_m: float = 10.0
var fade_margin_m: float = 16.0
## Вариантов модели на породу (вариант — хеш клетки).
var variants: int = 8
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
## Маска леса 10 м (Terrain.get_forest_mask, V02): байты RG8/LA8 (R — доля леса 0..255), узел (0, 0)
## в мире mask_node0 (центр пикселя), шаг mask_cell. Пусто — лес по классу карты 25 м.
var mask_data := PackedByteArray()
var mask_w: int = 0
var mask_h: int = 0
var mask_bpp: int = 2
var mask_node0 := Vector2.ZERO
var mask_cell: float = 10.0
## Доля воды маски 10 м (G), с которой дерево уже не ставится (0,5 — кромка воды в шейдере рельефа;
## меньше — ствол не у самой воды, крона нависает над берегом).
var water_max: float = 0.35
## Опушка (V02): в полосе edge_band_m от кромки доля клеток с деревом растёт до edge_density,
## крона шире до ×(1 + edge_scale_k), в клетке появляется второе дерево с долей edge_extra.
var edge_band_m: float = 16.0
var edge_density: float = 1.0
var edge_scale_k: float = 0.15
var edge_extra: float = 0.5
var color_variation: float = 0.15
var band_blend_m: float = 200.0
## Высота модели породы и варианта, м (из меша) — для масштаба: model_height[вид * variants + вариант].
var model_height := PackedFloat32Array()
## Результат build(): buffers[(вид * variants + вариант) * 3 + lod] — PackedFloat32Array,
## counts — число экземпляров (в полосе растворения экземпляр в двух LOD — учтён в обоих).
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
	lod_fade_m = float(cfg.get("lod_fade_m", 10.0))
	fade_margin_m = float(cfg.get("rebuild_step_m", 16.0)) if lod_fade_m > 0.0 else 0.0
	variants = maxi(1, int(cfg.get("variants", 8)))
	model_height.resize(SPECIES.size() * variants)
	model_height.fill(20.0)
	density = float(cfg.get("density", 0.8))
	sink_fraction = float(cfg.get("sink_fraction", 0.5))
	edge_sink_fraction = float(cfg.get("edge_sink_fraction", sink_fraction))
	edge_probe_m = float(cfg.get("edge_probe_m", 30.0))
	edge_band_m = float(cfg.get("edge_band_m", 16.0))
	edge_density = float(cfg.get("edge_density", 1.0))
	edge_scale_k = float(cfg.get("edge_scale_k", 0.15))
	edge_extra = float(cfg.get("edge_extra", 0.5))
	color_variation = float(cfg.get("color_variation", 0.15))
	band_blend_m = maxf(1.0, float(cfg.get("band_blend_m", 200.0)))
	water_max = float(cfg.get("water_max", 0.35))
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


## Настройки деревьев с добавкой configs/vegetation.json → trees (группа «Растительность», V02):
## её ключи поверх cfg (world.json → trees + локация).
static func with_vegetation(cfg: Dictionary) -> Dictionary:
	var veg: Dictionary = Config.get_config("vegetation").get("trees", {})
	return Config._deep_merge(cfg, veg) if not veg.is_empty() else cfg


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
	var n_buf := SPECIES.size() * variants * 3
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
	var band := lod_fade_m * 0.5 + fade_margin_m if lod_fade_m > 0.0 else -1.0
	for dj in range(-nr, nr + 1):
		for di in range(-nr, nr + 1):
			var i := ci + di
			var j := cj + dj
			# 0 — основное дерево клетки, 1 — второе (только у опушки: если основное там)
			var cell_ek := 0.0
			for extra in 2:
				var k0 := 20 * extra
				var u := hash01(i, j, 1 + k0)
				if extra == 1 and u >= edge_extra * cell_ek:
					continue
				if extra == 0 and u >= maxf(density, edge_density):
					continue
				var x := (i + 0.5 + (hash01(i, j, 2 + k0) - 0.5) * 0.8) * spacing
				var z := (j + 0.5 + (hash01(i, j, 3 + k0) - 0.5) * 0.8) * spacing
				var dx := x - center.x
				var dz := z - center.y
				var d2 := dx * dx + dz * dz
				if d2 > r2 or not layer.contains(x, z):
					continue
				# переход к импостерам среднего плана: модели редеют к краю радиуса
				if fade_start_k > 0.0:
					var fk := smoothstep(radius * fade_start_k, radius, sqrt(d2))
					if hash01(i, j, 8 + k0) < fk:
						continue
				if not is_forest(x, z) or is_cleared(x, z):
					continue
				# сверх density дерево бывает только у опушки: в глубине леса сразу мимо
				if u >= density and _ring_forest(x, z, edge_band_m):
					continue
				var de := edge_distance(x, z)
				var ek := 1.0 - smoothstep(0.0, edge_band_m, de)
				if extra == 0:
					cell_ek = ek
				var dens := lerpf(density, edge_density, ek) if extra == 0 else edge_extra * ek
				if u >= dens:
					continue
				var h := layer.sample(x, z)
				var gx := (layer.sample(x + e, z) - h) / e
				var gz := (layer.sample(x, z + e) - h) / e
				var grad := sqrt(gx * gx + gz * gz)
				# «северность»: склон смотрит на −Z (север), т. е. высота растёт к +Z
				var north := (
					clampf(gz / grad, -1.0, 1.0) * clampf(grad / 0.25, 0.0, 1.0)
					if grad > 1e-4
					else 0.0
				)
				var sp := pick_species(h, north, hash01(i, j, 4 + k0))
				if sp < 0:
					continue
				var hh := lerpf(_h_min[sp], _h_max[sp], hash01(i, j, 5 + k0))
				var mv := sp * variants + int(hash01(i, j, 9 + k0) * 16777216.0) % variants
				var s := hh / maxf(model_height[mv], 0.1)
				# опушечное дерево раскидистее: крона шире (не выше — меньше нависает над лугом)
				var sw := s * (1.0 + edge_scale_k * ek)
				var a := hash01(i, j, 6 + k0) * TAU
				var c := cos(a) * sw
				var sn := sin(a) * sw
				var y := h - sink_for_edge(de) * hh
				var v := 1.0 + color_variation * (hash01(i, j, 7 + k0) - 0.5) * 2.0
				var d := sqrt(d2)
				var b := mv * 3
				# строки 3×4 матрицы: поворот вокруг Y с масштабом + сдвиг; затем цвет (альфа — код
				# растворения FADE_*)
				var row := PackedFloat32Array(
					[c, 0.0, sn, x, 0.0, s, 0.0, y, -sn, 0.0, c, z, v, v, v, FADE_NONE]
				)
				if absf(d - d0) < band:
					row[15] = FADE_OUT0
					lists[b].append_array(row)
					row[15] = FADE_IN0
					lists[b + 1].append_array(row)
				elif absf(d - d1) < band:
					row[15] = FADE_OUT1
					lists[b + 1].append_array(row)
					row[15] = FADE_IN1
					lists[b + 2].append_array(row)
				else:
					lists[b + (0 if d < d0 else (1 if d < d1 else 2))].append_array(row)
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


## Маска леса 10 м (Terrain.get_forest_mask): img — RG8 (R — доля леса), origin — мир (x, z) угла
## пикселя (0, 0), cell_m — размер пикселя. null — лес снова по классу карты 25 м.
func set_forest_mask(img: Image, origin: Vector2, cell_m: float) -> void:
	if img == null or img.is_empty():
		mask_data = PackedByteArray()
		mask_w = 0
		mask_h = 0
		return
	mask_data = img.get_data()
	mask_w = img.get_width()
	mask_h = img.get_height()
	mask_bpp = maxi(1, mask_data.size() / (mask_w * mask_h))
	mask_cell = cell_m
	mask_node0 = origin + Vector2(0.5, 0.5) * cell_m


## Доля леса 0..1: маска 10 м билинейно между центрами пикселей (как Terrain.forest_at до порога);
## без маски — 1 на классе «лес» карты 25 м, иначе 0.
func forest_r(x: float, z: float) -> float:
	if mask_w == 0:
		return 1.0 if surface.class_at(x, z) == SurfaceLayer.FOREST else 0.0
	return _mask_bilinear(x, z, 0)


## Доля воды 0..1 (канал G маски 10 м, как в шейдере рельефа), билинейно; без маски или без
## канала — 0 (класс «вода» карты 25 м и так не «лес»).
func water_g(x: float, z: float) -> float:
	if mask_w == 0 or mask_bpp < 2:
		return 0.0
	return _mask_bilinear(x, z, 1)


func _mask_bilinear(x: float, z: float, ch: int) -> float:
	var fx := clampf((x - mask_node0.x) / mask_cell, 0.0, mask_w - 1.001)
	var fz := clampf((z - mask_node0.y) / mask_cell, 0.0, mask_h - 1.001)
	var i := int(fx)
	var j := int(fz)
	var tx := fx - i
	var tz := fz - j
	var k := (j * mask_w + i) * mask_bpp + ch
	var row := mask_w * mask_bpp
	var a := lerpf(mask_data[k], mask_data[k + mask_bpp], tx)
	var b := lerpf(mask_data[k + row], mask_data[k + row + mask_bpp], tx)
	return lerpf(a, b, tz) / 255.0


## Лес ли в точке: доля леса ≥ 0,5 (та же кромка, что у полога и Terrain.forest_at) и не вода
## (доля воды < water_max).
func is_forest(x: float, z: float) -> bool:
	return forest_r(x, z) >= 0.5 and water_g(x, z) < water_max


## Расстояние до кромки леса, м (грубо: кольца по 8 направлений), не больше edge_probe_m:
## сначала кольцо edge_probe_m — если там всюду лес, точка в глубине; иначе ближайшее кольцо
## из EDGE_RINGS_K·edge_band_m, где есть не-лес.
func edge_distance(x: float, z: float) -> float:
	var far := maxf(edge_probe_m, edge_band_m)
	if _ring_forest(x, z, far):
		return far
	for k in EDGE_RINGS_K:
		var r := k * edge_band_m
		if r < far and not _ring_forest(x, z, r):
			return r
	return far


## Доля высоты дерева ниже поверхности DEM по расстоянию до кромки: в глубине леса —
## sink_fraction (кроны уже в DSM), у опушки — edge_sink_fraction, чтобы стволы читались.
func sink_for_edge(dist_m: float) -> float:
	return lerpf(
		edge_sink_fraction, sink_fraction, clampf(dist_m / maxf(edge_probe_m, 1.0), 0.0, 1.0)
	)


## То же для точки (x, z).
func sink_at(x: float, z: float) -> float:
	return sink_for_edge(edge_distance(x, z))


func _ring_forest(x: float, z: float, r: float) -> bool:
	if mask_w == 0:
		for k in 8:
			if surface.class_at(x + RING8[k].x * r, z + RING8[k].y * r) != SurfaceLayer.FOREST:
				return false
		return true
	var inv := 1.0 / mask_cell
	var ox := (x - mask_node0.x) * inv
	var oz := (z - mask_node0.y) * inv
	var rr := r * inv
	# вода — тоже кромка (берег реки в лесу — опушка: деревья гуще, стволы видны)
	var wmax := water_max * 255.0 if mask_bpp >= 2 else 256.0
	for k in 8:
		var i := clampi(roundi(ox + RING8[k].x * rr), 0, mask_w - 1)
		var j := clampi(roundi(oz + RING8[k].y * rr), 0, mask_h - 1)
		var o := (j * mask_w + i) * mask_bpp
		if mask_data[o] < 128 or (mask_bpp >= 2 and mask_data[o + 1] >= wmax):
			return false
	return true


## Детерминированное псевдослучайное 0..1 для клетки (i, j) и номера признака k.
static func hash01(i: int, j: int, k: int) -> float:
	var hsh := (i * 374761393 + j * 668265263 + k * 1442695041) & 0xFFFFFFFF
	hsh = ((hsh ^ (hsh >> 13)) * 1274126177) & 0xFFFFFFFF
	hsh = hsh ^ (hsh >> 16)
	return float(hsh & 0xFFFFFF) / 16777216.0
