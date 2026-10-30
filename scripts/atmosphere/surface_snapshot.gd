class_name SurfaceSnapshot
extends RefCounted
## Снимок поверхности места (SH3): на решётке 25 м мира (узлы x = origin_x + 25·i,
## z = origin_z + 25·j, строки на юг), в пределах слоя detail. Входы берутся один раз на главном
## потоке (SurfaceSnapshot.start / of, после полей рельефа и полян у стартов), счёт — задачей
## пула (FL-9); готовый снимок только читается — рабочие потоки Terrain не трогают. Поля
## cls/moist читать после wait() (или is_ready()); cls — класс узла как Terrain._surface_class (карта поверхности,
## маска 10 м: вода G ≥ 0,5, лес R ≥ 0,5; круче rock_slope_deg → BARE) ∪ маска рек (WATER);
## moist — влажность рельефа в узле (TerrainRelief, билинейно), пусто — поля нет (m_norm).

const NODE_STEP := 25.0  # шаг решётки мира, на которую берётся слой, м

## Счёт задачей пула (FL-9); false — сразу, в вызывающем потоке (тесты).
static var parallel := true

var origin_x := 0.0
var origin_z := 0.0
var width := 0
var height := 0
var cls := PackedByteArray()
var moist := PackedFloat32Array()
## Время снимка, мс (отчёт).
var build_ms := 0.0
## Задача пула, что считает снимок (−1 — готов или ещё не запущен); под _wait_mx.
var _task := -1
var _wait_mx := Mutex.new()


## Снимок посчитан (не ждёт; главный поток опрашивает по кадрам).
func is_ready() -> bool:
	if not _wait_mx.try_lock():
		return false  # кто-то ждёт задачу — значит, ещё считается
	var ok := _task < 0 or WorkerThreadPool.is_task_completed(_task)
	_wait_mx.unlock()
	return ok


## Дождаться снимка (любой поток; задача ожидается ровно один раз).
func wait() -> void:
	_wait_mx.lock()
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	_wait_mx.unlock()


## Снимок поверхности (главный поток, готовый): terrain — Terrain (surfaces, reliefs, wait_relief),
## detail — слой 25 м места, water — маска рек слоя (или null). Ждёт поля рельефа (детерминизм:
## влажность не «гонится» с потоком). Нет карт поверхности и полей рельефа — null (поведение без
## снимка).
static func of(
	terrain: Object, detail: HeightLayer, water: Image
) -> SurfaceSnapshot:
	var sf := start(terrain, detail, water)
	if sf != null:
		sf.wait()
	return sf


## То же, что surface_of, но счёт — задачей пула (parallel; иначе сразу): на главном потоке — только
## поиск карты и поля рельефа и копии входов (маска леса, маска рек). Снимок — после wait()/is_ready().
static func start(
	terrain: Object, detail: HeightLayer, water: Image
) -> SurfaceSnapshot:
	if terrain == null or detail == null:
		return null
	var t0 := Time.get_ticks_usec()
	if terrain.has_method("wait_relief"):
		terrain.call("wait_relief")
	var cx := detail.origin_x + 0.5 * detail.size_x()
	var cz := detail.origin_z + 0.5 * detail.size_z()
	# карта и поле — покрывающие центр слоя (как Terrain._surface_layer_at/_relief_at: самая детальная)
	var sl: SurfaceLayer = null
	for s: Variant in terrain.get("surfaces"):
		if s != null and (s as SurfaceLayer).contains(cx, cz):
			sl = s
			break
	var rel: TerrainRelief = null
	var rv: Variant = terrain.get("reliefs")
	if rv is Array:
		for r: Variant in rv:
			if r != null and (r as TerrainRelief).contains(cx, cz):
				rel = r
				break
	if rel != null and rel.moisture.is_empty():
		rel = null
	if sl == null and rel == null:
		return null
	var sf := SurfaceSnapshot.new()
	sf.origin_x = ceilf(detail.origin_x / NODE_STEP - 1.0e-9) * NODE_STEP
	sf.origin_z = ceilf(detail.origin_z / NODE_STEP - 1.0e-9) * NODE_STEP
	sf.width = floori((detail.origin_x + detail.size_x() - sf.origin_x) / NODE_STEP + 1.0e-9) + 1
	sf.height = floori((detail.origin_z + detail.size_z() - sf.origin_z) / NODE_STEP + 1.0e-9) + 1
	var ax := _snap_axis(sf.origin_x, sf.width, sl, rel, detail, water, true)
	var az := _snap_axis(sf.origin_z, sf.height, sl, rel, detail, water, false)
	var rock_cos := cos(deg_to_rad(float(Config.value("world", "terrain_look.rock_slope_deg", 90.0))))
	var riv := PackedByteArray()
	var riw := 0
	if water != null:
		var img := water
		if img.is_compressed() or img.get_format() != Image.FORMAT_L8:
			img = img.duplicate()
			if img.is_compressed():
				img.decompress()
			img.convert(Image.FORMAT_L8)
		riv = img.get_data()
		riw = img.get_width()
	var cls_src := sl.classes if sl != null else PackedByteArray()
	var cls_w := sl.width if sl != null else 0
	var cls_h := sl.height if sl != null else 0
	var mask := PackedByteArray()
	var mw := 0
	if sl != null and sl.has_forest_mask():
		mask = sl.forest_mask_image().get_data()  # копия: поляны у стартов уже вырезаны
		mw = sl.mask_width
	var inp := {
		ax = ax, az = az, rock_cos = rock_cos, riv = riv, riw = riw, cls_src = cls_src, cls_w = cls_w,
		cls_h = cls_h, mask = mask, mw = mw, mo = rel.moisture if rel != null else PackedFloat32Array(),
		rw = rel.width if rel != null else 0, hs = detail.heights, d_ox = detail.origin_x,
		d_oz = detail.origin_z, d_sp = detail.spacing, d_w = detail.width, d_h = detail.height,
		t0 = t0,
	}
	if parallel:
		sf._task = WorkerThreadPool.add_task(_surface_fill.bind(sf, inp), true, "SurfaceSnapshot")
	else:
		_surface_fill(sf, inp)
	return sf


## Счёт снимка по входам surface_start (рабочий поток или вызывающий): только PackedArray-копии
## и снимок sf, ни Terrain, ни слоёв.
static func _surface_fill(sf: SurfaceSnapshot, inp: Dictionary) -> void:
	var t0 := int(inp.t0)
	var ax: Dictionary = inp.ax
	var az: Dictionary = inp.az
	var rock_cos := float(inp.rock_cos)
	var riv: PackedByteArray = inp.riv
	var riw := int(inp.riw)
	var cls_src: PackedByteArray = inp.cls_src
	var cls_w := int(inp.cls_w)
	var cls_h := int(inp.cls_h)
	var mask: PackedByteArray = inp.mask
	var mw := int(inp.mw)
	var mo: PackedFloat32Array = inp.mo
	var rw := int(inp.rw)
	var w := sf.width
	var h := sf.height
	# 1) высоты узлов: билинейно по слою, как HeightLayer.sample (у встроенных слоёв 25 м — значения
	# узлов); оси разделимы, без вызовов методов в цикле
	var hx := _sample_axis(sf.origin_x, w, float(inp.d_ox), float(inp.d_sp), int(inp.d_w))
	var hz := _sample_axis(sf.origin_z, h, float(inp.d_oz), float(inp.d_sp), int(inp.d_h))
	var hs: PackedFloat32Array = inp.hs
	var lw := int(inp.d_w)
	var hb := TerrainRelief._par(
		h,
		func(j0: int, j1: int) -> PackedFloat32Array:
			var a := PackedFloat32Array()
			a.resize((j1 - j0) * w)
			var xi: PackedInt32Array = hx.i
			var xt: PackedFloat64Array = hx.t
			var k := 0
			for j in range(j0, j1):
				var r0 := int(hz.i[j]) * lw
				var tz := float(hz.t[j])
				for i in w:
					var q := r0 + xi[i]
					var tx := xt[i]
					a[k] = lerpf(lerpf(hs[q], hs[q + 1], tx), lerpf(hs[q + lw], hs[q + lw + 1], tx), tz)
					k += 1
			return a
	)
	var hn := TerrainRelief._concat_f(hb)
	var e2 := 2.0 * NODE_STEP
	var rc2 := rock_cos * rock_cos
	# 2) класс и влажность узла (оси разделимы: индексы и веса — по столбцу и по строке)
	var bands := TerrainRelief._par(
		h,
		func(j0: int, j1: int) -> Array:
			var cb := PackedByteArray()
			cb.resize((j1 - j0) * w)
			var mb := PackedFloat32Array()
			if rw > 0:
				mb.resize((j1 - j0) * w)
			var ci: PackedInt32Array = ax.ci
			var mi: PackedInt32Array = ax.mi
			var mt: PackedFloat32Array = ax.mt
			var min_: PackedByteArray = ax.mn
			var ri: PackedInt32Array = ax.ri
			var rt: PackedFloat32Array = ax.rt
			var vi: PackedInt32Array = ax.vi
			var nc := SurfaceLayer.CLASS_COUNT
			var cnt := PackedInt32Array()
			cnt.resize(nc)
			var q := 0
			for j in range(j0, j1):
				var crow := int(az.ci[j]) * cls_w
				var mrow := int(az.mi[j]) * mw
				var tz := float(az.mt[j])
				var zin := int(az.mn[j]) == 1
				var rrow := int(az.ri[j]) * rw
				var rtz := float(az.rt[j])
				var vrow := int(az.vi[j]) * riw
				var jm := maxi(j - 1, 0) * w
				var jp := mini(j + 1, h - 1) * w
				var jc := j * w
				for i in w:
					var c := SurfaceLayer.NONE
					if cls_w > 0:
						c = cls_src[crow + ci[i]]
					if mw > 0 and zin and min_[i] == 1:
						# маска 10 м билинейно (как SurfaceLayer._mask_channel), RG8
						var k := (mrow + mi[i]) * 2
						var kr := k + mw * 2
						var tx := mt[i]
						var g0 := mask[k + 1]
						var g1 := mask[k + 3]
						var g2 := mask[kr + 1]
						var g3 := mask[kr + 3]
						var g := 0.0
						if g0 | g1 | g2 | g3 != 0:  # почти везде воды нет — без билинейки
							g = lerpf(lerpf(g0, g1, tx), lerpf(g2, g3, tx), tz)
						if g >= 127.5:
							c = SurfaceLayer.WATER
						else:
							var r0 := mask[k]
							var r1 := mask[k + 2]
							var r2 := mask[kr]
							var r3 := mask[kr + 2]
							var r := 0.0
							if r0 & r1 & r2 & r3 == 255:
								r = 255.0
							elif r0 | r1 | r2 | r3 != 0:
								r = lerpf(lerpf(r0, r1, tx), lerpf(r2, r3, tx), tz)
							if r >= 127.5:
								c = SurfaceLayer.FOREST
							elif c == SurfaceLayer.FOREST:
								# как SurfaceLayer.open_class_near: самый частый не-лесной класс 3×3 узлов
								cnt.fill(0)
								for dj in range(-1, 2):
									var rr := clampi(int(az.ci[j]) + dj, 0, cls_h - 1) * cls_w
									for di in range(-1, 2):
										var cc := cls_src[rr + clampi(ci[i] + di, 0, cls_w - 1)]
										if cc != SurfaceLayer.FOREST and cc != SurfaceLayer.NONE and cc < nc:
											cnt[cc] += 1
								c = SurfaceLayer.GRASS
								for kc in nc:
									if cnt[kc] > cnt[c]:
										c = kc
					if (
						c == SurfaceLayer.GRASS
						or c == SurfaceLayer.CROP
						or c == SurfaceLayer.SHRUB
						or c == SurfaceLayer.NONE
					):
						# n_y = 2e/√(gx² + gz² + 4e²) < cos(rock_slope) — как Terrain.normal_at
						var gx := hn[jc + mini(i + 1, w - 1)] - hn[jc + maxi(i - 1, 0)]
						var gz := hn[jp + i] - hn[jm + i]
						if e2 * e2 < rc2 * (gx * gx + gz * gz + e2 * e2):
							c = SurfaceLayer.BARE
					if riw > 0 and riv[vrow + vi[i]] > 127:
						c = SurfaceLayer.WATER
					cb[q] = c
					if rw > 0:
						var k2 := rrow + ri[i]
						var tx2 := rt[i]
						mb[q] = lerpf(
							lerpf(mo[k2], mo[k2 + 1], tx2), lerpf(mo[k2 + rw], mo[k2 + rw + 1], tx2), rtz
						)
					q += 1
			return [cb, mb]
	)
	for b: Array in bands:
		sf.cls.append_array(b[0])
		sf.moist.append_array(b[1])
	sf.build_ms = (Time.get_ticks_usec() - t0) / 1000.0


## Ось билинейки HeightLayer.sample: узлы o + 25·k → {i: ячейка, t: вес} (за краем — край).
static func _sample_axis(o: float, n: int, lo: float, sp: float, ln: int) -> Dictionary:
	var ii := PackedInt32Array()
	var tt := PackedFloat64Array()
	ii.resize(n)
	tt.resize(n)
	var inv := 1.0 / sp
	for k in n:
		var f := clampf((o + NODE_STEP * k - lo) * inv, 0.0, ln - 1.0)
		ii[k] = mini(int(f), ln - 2)
		tt[k] = f - ii[k]
	return {i = ii, t = tt}


## Индексы и веса одной оси снимка (n узлов от o с шагом 25 м; x — по столбцам, иначе по строкам):
## ci — ближайший узел карты классов (class_at); mi, mt, mn — маска 10 м (ячейка, вес, внутри ли);
## ri, rt — поле влажности (как TerrainRelief._sample); vi — пиксель маски рек (как water_fraction;
## для строк — номер строки изображения).
static func _snap_axis(
	o: float, n: int, sl: SurfaceLayer, rel: TerrainRelief, layer: HeightLayer, water: Image, is_x: bool
) -> Dictionary:
	var ci := PackedInt32Array()
	var mi := PackedInt32Array()
	var mt := PackedFloat32Array()
	var mn := PackedByteArray()
	var ri := PackedInt32Array()
	var rt := PackedFloat32Array()
	var vi := PackedInt32Array()
	ci.resize(n)
	mi.resize(n)
	mt.resize(n)
	mn.resize(n)
	ri.resize(n)
	rt.resize(n)
	vi.resize(n)
	for k in n:
		var p := o + NODE_STEP * k
		if sl != null:
			var so := sl.origin_x if is_x else sl.origin_z
			var sn := sl.width if is_x else sl.height
			ci[k] = clampi(roundi((p - so) / sl.spacing), 0, sn - 1)
			var mw := sl.mask_width if is_x else sl.mask_height
			if mw > 0:
				var mo := sl.mask_origin_x if is_x else sl.mask_origin_z
				mn[k] = 1 if p >= mo and p <= mo + (mw - 1) * sl.mask_spacing else 0
				var f := clampf((p - mo) / sl.mask_spacing, 0.0, mw - 1.0)
				mi[k] = mini(int(f), mw - 2)
				mt[k] = f - mi[k]
		if rel != null:
			var ro := rel.origin_x if is_x else rel.origin_z
			var rn := rel.width if is_x else rel.height
			var f := clampf((p - ro) / rel.cell_m, 0.0, rn - 1.001)
			ri[k] = int(f)
			rt[k] = f - ri[k]
		if water != null:
			var lo := layer.origin_x if is_x else layer.origin_z
			var ln := layer.width if is_x else layer.height
			var fi := clampi(roundi((p - lo) / layer.spacing), 0, ln - 1)
			if is_x:
				vi[k] = int(fi * water.get_width() / ln)
			else:
				var ih := water.get_height()
				vi[k] = ih - 1 - int((ln - 1 - fi) * ih / ln)
	return {ci = ci, mi = mi, mt = mt, mn = mn, ri = ri, rt = rt, vi = vi}
