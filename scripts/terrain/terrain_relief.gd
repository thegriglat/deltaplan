class_name TerrainRelief
extends RefCounted
## Поля рельефа одного слоя высот — считаются из DEM при загрузке ЛЮБОЙ локации (и рантайм,
## load_point), без привязки к местам. Для шейдера рельефа и термиков:
##   moisture — «влажность» 0..1: накопление стока (D8 по сетке) + вогнутость на двух масштабах;
##              ложбины/овраги/днища долин влажнее, гребни и выпуклости суше;
##   north    — «северность» склона −1..1, сглаженная (экспозиция: северные зеленее, южные степнее);
##   ao       — видимость неба 0..1 по горизонтам в ao_directions направлениях относительно
##              касательной плоскости (плоский склон и гребень — 1, ложбина — меньше);
##   horizon  — угол горизонта в сторону азимута солнца, градусы (самозатенение при низком солнце:
##              в шейдере тень = солнце ниже горизонта; высота солнца меняется бесплатно,
##              при смене азимута — recompute_horizon в рабочих потоках, ~0,1–0,3 с).
## Сетка — узлы слоя через stride (≤ grid_max по стороне). Параметры — world.json → surface.relief.
## Всё — в рабочих потоках (WorkerThreadPool, полосы строк).

const BANDS := 48
## Угол горизонта в R8 текстуре: 0..HORIZON_MAX_DEG.
const HORIZON_MAX_DEG := 60.0
## Шаг подсетки дальнего поля горизонта (по высотам outer), узлов своей сетки.
const OUTER_SUB := 4

var layer_id := ""
var width := 0
var height := 0
var cell_m := 1.0
var origin_x := 0.0
var origin_z := 0.0
## Высоты на сетке поля (узлы слоя через stride).
var h := PackedFloat32Array()
var moisture := PackedFloat32Array()
var north := PackedFloat32Array()
var ao := PackedFloat32Array()
var horizon_deg := PackedFloat32Array()
## Азимут солнца, для которого посчитан horizon_deg (0 — север, по часовой).
var horizon_azimuth_deg := NAN
## Поля более грубого слоя, накрывающего этот (детальный → фон): луч горизонта, вышедший за свою
## дальность или край своей сетки, идёт дальше по его высотам до его дальности (SL-26: без этого
## детальный слой не видел гор дальше horizon_range_m и за своим краем — тень гор была только на
## фоне, а вокруг пилота земля светилась). null — луч кончается своей сеткой.
var outer: TerrainRelief = null
## RGBA8: R — влажность, G — AO, B — северность·0,5 + 0,5, A — угол горизонта к солнцу /
## HORIZON_MAX_DEG (SL-К7 v1: бывшая отдельная R8 тени рельефа; смена азимута переписывает только A).
var texture: ImageTexture
## Время расчёта, с.
var compute_s := 0.0
## Время этапов расчёта, с (отладка).
var timings: Dictionary = {}

var _cfg: Dictionary = {}
var _t_last := 0
var _gx := PackedFloat32Array()
var _gz := PackedFloat32Array()
## Байты texture (RGBA8): A переписывается при смене азимута без пересборки RGB.
var _rgba := PackedByteArray()


## Посчитать поля слоя. cfg — world.json → surface.relief, sun_azimuth_deg — азимут солнца,
## layer_index — номер слоя (0 — детальный): сторона сетки grid_max[layer_index]
## (последний элемент — для остальных слоёв).
## make_textures = false — без текстур (расчёт в не-главном потоке; потом make_textures()).
static func compute(
	layer: HeightLayer,
	cfg: Dictionary,
	sun_azimuth_deg: float,
	layer_index: int = 0,
	textures: bool = true,
	outer_relief: TerrainRelief = null
) -> TerrainRelief:
	var t0 := Time.get_ticks_usec()
	var r := TerrainRelief.new()
	r._cfg = cfg
	r.layer_id = layer.id
	var gm: Variant = cfg.get("grid_max", [801, 401])
	var grid_max := int(gm) if not gm is Array else int(gm[mini(layer_index, gm.size() - 1)])
	grid_max = maxi(grid_max, 8)
	var s := maxi(1, ceili((layer.width - 1) / float(grid_max - 1)))
	r.width = (layer.width - 1) / s + 1
	r.height = (layer.height - 1) / s + 1
	r.cell_m = layer.spacing * s
	r.origin_x = layer.origin_x
	r.origin_z = layer.origin_z
	r.outer = outer_relief
	r._resample(layer, s)
	r._lap("resample")
	r._terrain_pass()
	r._compute_ao()
	r._lap("ao")
	r.recompute_horizon(sun_azimuth_deg)
	r._lap("horizon")
	if textures:
		r.make_textures()
	r._lap("textures")
	r.compute_s = (Time.get_ticks_usec() - t0) / 1e6
	return r


## Текстура полей с горизонтом в A (главный поток).
func make_textures() -> void:
	_rgba = _fields_bytes()
	texture = ImageTexture.create_from_image(
		Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, _rgba)
	)


## Байты RGBA8 текстуры полей (тесты SL-К7: каналы = исходные поля).
func texture_bytes() -> PackedByteArray:
	return _rgba


## Пересчитать горизонт к солнцу для нового азимута (можно из не-главного потока;
## канал A texture обновится — вызывать update_shadow_texture в главном).
## Луч — по своей сетке до _horizon_range_m() (или до края сетки), дальше — по высотам outer
## (_outer_horizon): дальние гребни видны и детальному слою (SL-26).
func recompute_horizon(sun_azimuth_deg: float) -> void:
	var az := deg_to_rad(sun_azimuth_deg)
	var dx := sin(az)
	var dz := -cos(az)
	var range_m := _horizon_range_m()
	var ratio := maxf(float(_cfg.get("horizon_step_ratio", 1.25)), 1.01)
	var offs := _ray_offsets(dx, dz, range_m, ratio)
	var di: PackedInt32Array = offs[0]
	var dj: PackedInt32Array = offs[1]
	var inv: PackedFloat32Array = offs[2]
	var far := _outer_horizon(dx, dz, offs, range_m)
	var fa: PackedFloat32Array = far[0]
	var fb: PackedFloat32Array = far[1]
	var fw := int(far[2])
	var fh := int(far[3])
	var w := width
	var hh := height
	var hs := h
	var job := func(j0: int, j1: int) -> PackedFloat32Array:
		var out := PackedFloat32Array()
		out.resize((j1 - j0) * w)
		var n := di.size()
		for j in range(j0, j1):
			var row := j * w
			var fz := float(j) / OUTER_SUB
			var jz := mini(int(fz), maxi(fh - 2, 0))
			var tz := clampf(fz - jz, 0.0, 1.0)
			for i in w:
				var h0 := hs[row + i]
				var best := 0.0
				for k in n:
					var ii := i + di[k]
					var jj := j + dj[k]
					if ii < 0 or jj < 0 or ii >= w or jj >= hh:
						break
					var t := (hs[jj * w + ii] - h0) * inv[k]
					if t > best:
						best = t
				if fw > 1 and fh > 1:
					# дальнее поле: tan = a − h0·b, a и b билинейно с подсетки
					var fx := float(i) / OUTER_SUB
					var ix := mini(int(fx), fw - 2)
					var tx := clampf(fx - ix, 0.0, 1.0)
					var q := jz * fw + ix
					var a := lerpf(lerpf(fa[q], fa[q + 1], tx), lerpf(fa[q + fw], fa[q + fw + 1], tx), tz)
					var b := lerpf(lerpf(fb[q], fb[q + 1], tx), lerpf(fb[q + fw], fb[q + fw + 1], tx), tz)
					best = maxf(best, a - h0 * b)
				out[(j - j0) * w + i] = rad_to_deg(atan(best))
		return out
	horizon_deg = _concat_f(_par(height, job))
	horizon_azimuth_deg = sun_azimuth_deg


## Дальнее поле горизонта по высотам outer: на подсетке (каждый OUTER_SUB-й узел) луч от конца
## своего (дальность сетки или выход за её край) идёт по высотам outer (билинейно, шаг
## horizon_outer_step_ratio) до outer._horizon_range_m(). Для узла — главный заслон: tan угла
## = a − h0·b, a = H/s, b = 1/s (H, s — высота и дальность заслона); линейно по h0 — подсетку можно
## интерполировать на узлы со своими высотами. Возвращает [a, b, ширина, высота подсетки];
## без outer — пустые (ширина 0).
func _outer_horizon(dx: float, dz: float, offs: Array, range_m: float) -> Array:
	if outer == null or outer.h.is_empty():
		return [PackedFloat32Array(), PackedFloat32Array(), 0, 0]
	var di: PackedInt32Array = offs[0]
	var dj: PackedInt32Array = offs[1]
	var inv: PackedFloat32Array = offs[2]
	var oh := outer.h
	var ow := outer.width
	var ohh := outer.height
	var oc := outer.cell_m
	var oox := outer.origin_x
	var ooz := outer.origin_z
	var orange := outer._horizon_range_m()
	var oratio := maxf(float(_cfg.get("horizon_outer_step_ratio", 1.08)), 1.01)
	var os := PackedFloat32Array()
	var r := 1.0
	while r * oc <= orange:
		if r * oc > cell_m:
			os.append(r * oc)
		r = r + 1.0 if r * (oratio - 1.0) < 1.0 else r * oratio
	var m0 := os.size()
	for m in os.size():
		if os[m] > range_m:
			m0 = m
			break
	var fw := ceili((width - 1) / float(OUTER_SUB)) + 1
	var fh := ceili((height - 1) / float(OUTER_SUB)) + 1
	var w := width
	var hh := height
	var hs := h
	var c := cell_m
	var ox := origin_x
	var oz := origin_z
	var job := func(j0: int, j1: int) -> PackedFloat32Array:
		var out := PackedFloat32Array()
		out.resize((j1 - j0) * fw * 2)
		var n := di.size()
		var no := os.size()
		for sj in range(j0, j1):
			var j := mini(sj * OUTER_SUB, hh - 1)
			for si in fw:
				var i := mini(si * OUTER_SUB, w - 1)
				var h0 := hs[j * w + i]
				# где кончается свой луч: край сетки раньше своей дальности — дальше outer
				var m := m0
				for k in n:
					var ii := i + di[k]
					var jj := j + dj[k]
					if ii < 0 or jj < 0 or ii >= w or jj >= hh:
						var cut := 1.0 / inv[k]
						m = 0
						while m < no and os[m] < cut:
							m += 1
						break
				var x := ox + i * c
				var z := oz + j * c
				var best := -1e9
				var ba := 0.0
				var bb := 0.0
				while m < no:
					var sm := os[m]
					m += 1
					var fx := (x + dx * sm - oox) / oc
					var fz := (z + dz * sm - ooz) / oc
					if fx < 0.0 or fz < 0.0 or fx > ow - 1 or fz > ohh - 1:
						break
					var ix := mini(int(fx), ow - 2)
					var iz := mini(int(fz), ohh - 2)
					var tx := fx - ix
					var tz := fz - iz
					var q := iz * ow + ix
					var hv := lerpf(lerpf(oh[q], oh[q + 1], tx), lerpf(oh[q + ow], oh[q + ow + 1], tx), tz)
					var t := (hv - h0) / sm
					if t > best:
						best = t
						ba = hv / sm
						bb = 1.0 / sm
				if best < -1e8:
					ba = -1.0   # заслона нет: tan = −1 (ниже любого своего)
					bb = 0.0
				var o := ((sj - j0) * fw + si) * 2
				out[o] = ba
				out[o + 1] = bb
		return out
	var ab := _concat_f(_par(fh, job))
	var fa := PackedFloat32Array()
	var fb := PackedFloat32Array()
	fa.resize(fw * fh)
	fb.resize(fw * fh)
	for k in fw * fh:
		fa[k] = ab[k * 2]
		fb[k] = ab[k * 2 + 1]
	return [fa, fb, fw, fh]


## Дальность луча горизонта по своей сетке, м: horizon_range_m при клетке 50 м, у грубых — больше.
func _horizon_range_m() -> float:
	return float(_cfg.get("horizon_range_m", 8000.0)) * maxf(1.0, cell_m / 50.0)


## Горизонт из horizon_deg → канал A текстуры полей (главный поток); RGB не меняются.
func update_shadow_texture() -> void:
	if texture == null or _rgba.size() != width * height * 4:
		make_textures()
		return
	var hz := horizon_deg
	var w := width
	var src := _rgba
	var kq := 255.0 / HORIZON_MAX_DEG
	var job := func(j0: int, j1: int) -> PackedByteArray:
		var out := src.slice(j0 * w * 4, j1 * w * 4)
		var base := j0 * w
		for k in range(j0 * w, j1 * w):
			out[(k - base) * 4 + 3] = mini(int(hz[k] * kq + 0.5), 255)
		return out
	var data := PackedByteArray()
	for b: PackedByteArray in _par(height, job):
		data.append_array(b)
	_rgba = data
	texture.update(Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, _rgba))


## Влажность 0..1 в точке мира (билинейно).
func moisture_at(x: float, z: float) -> float:
	return _sample(moisture, x, z)


## Видимость неба (AO) 0..1 в точке мира (билинейно).
func ao_at(x: float, z: float) -> float:
	return _sample(ao, x, z)


## Сглаженная северность −1..1 в точке мира.
func north_at(x: float, z: float) -> float:
	return _sample(north, x, z)


## Угол горизонта к солнцу, градусы.
func horizon_at(x: float, z: float) -> float:
	return _sample(horizon_deg, x, z)


func contains(x: float, z: float) -> bool:
	return (
		x >= origin_x
		and z >= origin_z
		and x <= origin_x + (width - 1) * cell_m
		and z <= origin_z + (height - 1) * cell_m
	)


# ---------------- расчёт ----------------


func _lap(stage: String) -> void:
	var t := Time.get_ticks_usec()
	if _t_last != 0:
		timings[stage] = (t - _t_last) / 1e6
	_t_last = t


func _resample(layer: HeightLayer, s: int) -> void:
	_lap("")
	var w := width
	var lw := layer.width
	var src := layer.heights
	var job := func(j0: int, j1: int) -> PackedFloat32Array:
		var out := PackedFloat32Array()
		out.resize((j1 - j0) * w)
		for j in range(j0, j1):
			var row := j * s * lw
			for i in w:
				out[(j - j0) * w + i] = src[row + i * s]
		return out
	h = _concat_f(_par(height, job))


## Градиент, северность, вогнутость, приёмник стока D8, накопление, влажность.
func _terrain_pass() -> void:
	var w := width
	var hh := height
	var c := cell_m
	var hs := h
	var s1 := maxi(1, roundi(float(_cfg.get("concavity_scales_m", [100.0, 300.0])[0]) / c))
	var s2 := maxi(1, roundi(float(_cfg.get("concavity_scales_m", [100.0, 300.0])[1]) / c))
	var conc_k := maxf(float(_cfg.get("concavity_k", 0.08)), 1e-4)
	# соседи D8: смещение индекса и 1/расстояние
	var nb_di := PackedInt32Array([1, -1, 0, 0, 1, 1, -1, -1])
	var nb_dj := PackedInt32Array([0, 0, 1, -1, 1, -1, 1, -1])
	var nb_inv := PackedFloat32Array([1.0, 1.0, 1.0, 1.0, 0.7071, 0.7071, 0.7071, 0.7071])
	var job := func(j0: int, j1: int) -> Array:
		var n := (j1 - j0) * w
		var gx := PackedFloat32Array()
		var gz := PackedFloat32Array()
		var nor := PackedFloat32Array()
		var conc := PackedFloat32Array()
		var rcv := PackedInt32Array()
		gx.resize(n)
		gz.resize(n)
		nor.resize(n)
		conc.resize(n)
		rcv.resize(n)
		for j in range(j0, j1):
			var jm := maxi(j - 1, 0)
			var jp := mini(j + 1, hh - 1)
			var jm1 := maxi(j - s1, 0) * w
			var jp1 := mini(j + s1, hh - 1) * w
			var jm2 := maxi(j - s2, 0) * w
			var jp2 := mini(j + s2, hh - 1) * w
			for i in w:
				var k := j * w + i
				var h0 := hs[k]
				var im := maxi(i - 1, 0)
				var ip := mini(i + 1, w - 1)
				var a := (hs[j * w + ip] - hs[j * w + im]) / ((ip - im) * c)
				var b := (hs[jp * w + i] - hs[jm * w + i]) / ((jp - jm) * c)
				var o := k - j0 * w
				gx[o] = a
				gz[o] = b
				var g := sqrt(a * a + b * b)
				# northness: нормаль (−a, 1, −b) смотрит на север (−Z), когда высота растёт к югу
				var sd := rad_to_deg(atan(g))
				nor[o] = (b / g) * smoothstep(3.0, 15.0, sd) if g > 1e-5 else 0.0
				# вогнутость (+ — ложбина): лапласиан на двух масштабах, м/м
				var l1 := (
					(
						hs[j * w + mini(i + s1, w - 1)]
						+ hs[j * w + maxi(i - s1, 0)]
						+ hs[jp1 + i]
						+ hs[jm1 + i]
						- 4.0 * h0
					)
					/ (4.0 * s1 * c)
				)
				var l2 := (
					(
						hs[j * w + mini(i + s2, w - 1)]
						+ hs[j * w + maxi(i - s2, 0)]
						+ hs[jp2 + i]
						+ hs[jm2 + i]
						- 4.0 * h0
					)
					/ (4.0 * s2 * c)
				)
				conc[o] = clampf(0.5 * (l1 + l2) / conc_k, -1.0, 1.0)
				# приёмник стока — самый крутой спуск среди 8 соседей
				var best := 0.0
				var r := -1
				for q in 8:
					var ii := i + nb_di[q]
					var jj := j + nb_dj[q]
					if ii < 0 or jj < 0 or ii >= w or jj >= hh:
						continue
					var kk := jj * w + ii
					var drop := (h0 - hs[kk]) * nb_inv[q]
					if drop > best:
						best = drop
						r = kk
				rcv[o] = r
		return [gx, gz, nor, conc, rcv]
	var bands := _par(height, job)
	var nor_all := PackedFloat32Array()
	var conc_all := PackedFloat32Array()
	var rcv_all := PackedInt32Array()
	for b: Array in bands:
		_gx.append_array(b[0])
		_gz.append_array(b[1])
		nor_all.append_array(b[2])
		conc_all.append_array(b[3])
		rcv_all.append_array(b[4])
	_lap("terrain_pass")
	var acc := _flow_accumulation(rcv_all)
	_lap("flow")
	# влажность: сток (лог площади водосбора) + вогнутость
	var area_lo := log(maxf(float(_cfg.get("flow_area_m2", [2e4, 3e6])[0]), 1.0)) / log(10.0)
	var area_hi := log(maxf(float(_cfg.get("flow_area_m2", [2e4, 3e6])[1]), 10.0)) / log(10.0)
	var base := float(_cfg.get("base", 0.45))
	var flow_w := float(_cfg.get("flow_weight", 0.4))
	var conc_w := float(_cfg.get("concavity_weight", 0.3))
	var cell_area := c * c
	var mjob := func(j0: int, j1: int) -> PackedFloat32Array:
		var out := PackedFloat32Array()
		out.resize((j1 - j0) * w)
		for k in range(j0 * w, j1 * w):
			var la := log(acc[k] * cell_area) / log(10.0)
			var fl := smoothstep(area_lo, area_hi, la)
			out[k - j0 * w] = clampf(base + flow_w * fl + conc_w * conc_all[k], 0.0, 1.0)
		return out
	var m := _concat_f(_par(height, mjob))
	_lap("moisture")
	var blur_m := float(_cfg.get("blur_m", 75.0))
	moisture = _blur(m, blur_m)
	north = _blur(nor_all, float(_cfg.get("north_blur_m", 150.0)))


## Накопление стока D8: сортировка узлов по высоте (нативно, ключ int64), от верхних к нижним.
func _flow_accumulation(rcv: PackedInt32Array) -> PackedFloat32Array:
	var n := width * height
	var hmin := INF
	for v in h:
		hmin = minf(hmin, v)
	var hs := h
	var w := width
	var kjob := func(j0: int, j1: int) -> PackedInt64Array:
		var out := PackedInt64Array()
		out.resize((j1 - j0) * w)
		for k in range(j0 * w, j1 * w):
			out[k - j0 * w] = (int((hs[k] - hmin) * 1000.0) << 22) | k
		return out
	var keys := PackedInt64Array()
	for b: PackedInt64Array in _par(height, kjob):
		keys.append_array(b)
	keys.sort()
	var acc := PackedFloat32Array()
	acc.resize(n)
	acc.fill(1.0)
	var mask := (1 << 22) - 1
	for t in range(n - 1, -1, -1):
		var k := keys[t] & mask
		var r := rcv[k]
		if r >= 0:
			acc[r] += acc[k]
	return acc


## AO: видимость неба по горизонтам относительно касательной плоскости. Считается на прореженной
## сетке (ao_stride) и растягивается билинейно — AO гладкое (масштаб ложбин ≥ 100 м).
func _compute_ao() -> void:
	var dirs := maxi(int(_cfg.get("ao_directions", 8)), 4)
	var range_m := float(_cfg.get("ao_range_m", 1200.0)) * maxf(1.0, cell_m / 50.0)
	var ratio := maxf(float(_cfg.get("ao_step_ratio", 1.4)), 1.01)
	var gain := float(_cfg.get("ao_gain", 1.1))
	var st := maxi(int(_cfg.get("ao_stride", 2)), 1)
	# лучи одним массивом: смещения, 1/расстояние; начало луча и направление
	var oi := PackedInt32Array()
	var oj := PackedInt32Array()
	var oinv := PackedFloat32Array()
	var start := PackedInt32Array()
	var dcx := PackedFloat32Array()
	var dcz := PackedFloat32Array()
	for d in dirs:
		var a := TAU * d / dirs
		var ray := _ray_offsets(cos(a), sin(a), range_m, ratio)
		start.append(oi.size())
		oi.append_array(ray[0])
		oj.append_array(ray[1])
		oinv.append_array(ray[2])
		dcx.append(cos(a))
		dcz.append(sin(a))
	start.append(oi.size())
	var w := width
	var hh := height
	var aw := (w - 1) / st + 1
	var ah := (hh - 1) / st + 1
	var hs := h
	var gxs := _gx
	var gzs := _gz
	var job := func(j0: int, j1: int) -> PackedFloat32Array:
		var out := PackedFloat32Array()
		out.resize((j1 - j0) * aw)
		for sj in range(j0, j1):
			var j := sj * st
			for si in aw:
				var i := si * st
				var k := j * w + i
				var h0 := hs[k]
				var ax := gxs[k]
				var az := gzs[k]
				var occ := 0.0
				for d in dirs:
					# подъём касательной плоскости вдоль луча, м/м
					var tan0 := ax * dcx[d] + az * dcz[d]
					var best := tan0
					for q in range(start[d], start[d + 1]):
						var ii := i + oi[q]
						var jj := j + oj[q]
						if ii < 0 or jj < 0 or ii >= w or jj >= hh:
							break
						var t := (hs[jj * w + ii] - h0) * oinv[q]
						if t > best:
							best = t
					var rel := best - tan0
					occ += rel / sqrt(1.0 + rel * rel)
				out[(sj - j0) * aw + si] = clampf(1.0 - gain * occ / dirs, 0.0, 1.0)
		return out
	var sub := _concat_f(_par(ah, job))
	if st > 1:
		var img := Image.create_from_data(aw, ah, false, Image.FORMAT_RF, sub.to_byte_array())
		img.resize(w, hh, Image.INTERPOLATE_BILINEAR)
		sub = img.get_data().to_float32_array()
	ao = _blur(sub, float(_cfg.get("ao_blur_m", 0.0)))


## Смещения узлов вдоль луча (dx, dz) с геометрическим шагом: [di, dj, 1/расстояние].
func _ray_offsets(dx: float, dz: float, range_m: float, ratio: float) -> Array:
	var di := PackedInt32Array()
	var dj := PackedInt32Array()
	var inv := PackedFloat32Array()
	var r := 1.0
	var last := Vector2i.ZERO
	while r * cell_m <= range_m:
		var p := Vector2i(roundi(dx * r), roundi(dz * r))
		if p != last and p != Vector2i.ZERO:
			di.append(p.x)
			dj.append(p.y)
			inv.append(1.0 / (Vector2(p).length() * cell_m))
			last = p
		r = maxf(r * ratio, r + 1.0) if r < 4.0 else r * ratio
	return [di, dj, inv]


func _fields_bytes() -> PackedByteArray:
	var m := moisture
	var o := ao
	var nr := north
	var hz := horizon_deg
	var kq := 255.0 / HORIZON_MAX_DEG
	var w := width
	var job := func(j0: int, j1: int) -> PackedByteArray:
		var out := PackedByteArray()
		out.resize((j1 - j0) * w * 4)
		for k in range(j0 * w, j1 * w):
			var q := (k - j0 * w) * 4
			out[q] = int(clampf(m[k], 0.0, 1.0) * 255.0 + 0.5)
			out[q + 1] = int(clampf(o[k], 0.0, 1.0) * 255.0 + 0.5)
			out[q + 2] = int(clampf(nr[k] * 0.5 + 0.5, 0.0, 1.0) * 255.0 + 0.5)
			out[q + 3] = mini(int(hz[k] * kq + 0.5), 255)
		return out
	var data := PackedByteArray()
	for b: PackedByteArray in _par(height, job):
		data.append_array(b)
	return data


## Размытие поля (нативно: уменьшение и увеличение Image), радиус ~blur_m.
func _blur(a: PackedFloat32Array, blur_m: float) -> PackedFloat32Array:
	var f := blur_m / cell_m
	if f < 1.2:
		return a
	var img := Image.create_from_data(width, height, false, Image.FORMAT_RF, a.to_byte_array())
	img.resize(maxi(2, roundi(width / f)), maxi(2, roundi(height / f)), Image.INTERPOLATE_BILINEAR)
	img.resize(width, height, Image.INTERPOLATE_BILINEAR)
	return img.get_data().to_float32_array()


func _sample(a: PackedFloat32Array, x: float, z: float) -> float:
	if a.is_empty():
		return 0.0
	var fx := clampf((x - origin_x) / cell_m, 0.0, width - 1.001)
	var fz := clampf((z - origin_z) / cell_m, 0.0, height - 1.001)
	var i := int(fx)
	var j := int(fz)
	var tx := fx - i
	var tz := fz - j
	var k := j * width + i
	return lerpf(lerpf(a[k], a[k + 1], tx), lerpf(a[k + width], a[k + width + 1], tx), tz)


## Выполнить fn(j0, j1) по полосам строк в рабочих потоках; результаты — по порядку полос.
static func _par(rows: int, fn: Callable) -> Array:
	var nb := mini(rows, BANDS)
	var slots: Array[Array] = []
	for b in nb:
		slots.append([null])
	var job := func(b: int) -> void:
		var j0 := rows * b / nb
		var j1 := rows * (b + 1) / nb
		slots[b][0] = fn.call(j0, j1)
	var gid := WorkerThreadPool.add_group_task(job, nb, -1, true, "TerrainRelief")
	WorkerThreadPool.wait_for_group_task_completion(gid)
	var out := []
	for s in slots:
		out.append(s[0])
	return out


static func _concat_f(bands: Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for b: PackedFloat32Array in bands:
		out.append_array(b)
	return out
