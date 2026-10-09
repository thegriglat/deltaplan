class_name AirPlace
extends RefCounted
## Вход решения масштаба 1 для места игры (AM-03): рельеф слоя detail → сетка области, погода
## игры на час → фон θ̄(z) и верх слоя перемешивания z_i, поверхность и солнце → поток тепла H по
## долям классов клетки (SurfaceHeat, SH3). Перенос эталона AM-01: tools/research/air3d/real.py
## (grid_domain, case), weather.py (Day); H — не по air.py solar_flux (эталон старый, источник
## истины — SurfaceHeat, C2 v8). Погода — те же WeatherModel.diurnal_state / SunClock, что у игры.
##
##   var sf := AirPlace.surface_of(terrain, detail, water_img)   # главный поток, один раз на место
##   var c := AirPlace.domain_case(detail, water_img, loc_cfg, 400.0, 12.0, 3.0, 150.0, NAN, "clear",
##   		true, 1.0, sf)
##   var job := AirPicardJob.new(); job.case = c; job.start() …

const DOMAIN_L := 38400.0  # сторона области, м (38,4 км = 96·400 = 192·200)
const TOP_ABOVE := 3000.0  # потолок над максимумом рельефа, м
const GAMMA_D := 9.8  # К/км


## Область места (квадрат DOMAIN_L вокруг центра) с клеткой dx на час hour: ветер u10 (на 10 м,
## м/с) откуда wdir (°); t_max — дневной максимум (NAN — обычный для даты), sky — облачность;
## heat = false — без нагрева (H = 0). detail — слой рельефа 25 м, water — маска воды (или null),
## loc — configs/locations/<место>.json (center_lat, center_lon, utc_offset_h).
## u10 — ветер меню (на 10 м над стартом, C2 v6); inflow_k — множитель притока: α, класс
## устойчивости и max_profile — по u10 меню, приток на краю области AirCase.u10 = inflow_k·u10
## (AirRuntime подбирает k так, чтобы над стартом на 10 м было u10 меню).
## surface — снимок поверхности места (surface_of); null — без карты (класс NONE, вода — маска рек).
static func domain_case(
	detail: HeightLayer,
	water: Image,
	loc: Dictionary,
	dx: float,
	hour: float,
	u10: float,
	wdir: float,
	t_max := NAN,
	sky := "clear",
	heat := true,
	inflow_k := 1.0,
	surface: Surface = null
) -> AirCase:
	var n := roundi(DOMAIN_L / dx)
	var x0 := -DOMAIN_L / 2.0
	var y0 := -DOMAIN_L / 2.0
	var hc := block_mean(detail, x0, y0, dx, n, n)
	if hc.is_empty():
		return null
	var dz := 105.0 if dx >= 200.0 else dx / 2.0
	var lo := INF
	var hi := -INF
	for v in hc:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	var zb := floorf(lo / dz) * dz - dz
	var nz := ceili((hi + TOP_ABOVE - zb) / dz)
	nz += nz % 2
	var c := AirCase.new()
	c.set_grid(dx, n, n, dz, zb, nz, x0, y0)
	c.hc = hc
	c.wdir = wdir
	var cfg := WeatherModel.config()
	var ctx := context(detail, loc, cfg)
	if is_nan(t_max):
		t_max = WeatherModel.typical_max_c(int(ctx.month), int(ctx.day), cfg)
	var d := day(ctx, hour, t_max, sky, cfg)
	c.z_i = d.z_i
	c.set_inflow(u10, inflow_k, ctx, hour, float(d.cover))
	c.gam.resize(nz + 2)
	for k in nz + 2:
		c.gam[k] = gamma(d, c.zc(k))
	if heat:
		var cells := cell_surface(surface, water, detail, x0, y0, dx, n, n)
		c.heat = surface_flux(hc, dx, n, n, d, ctx, cfg, cells, u10, t_max)
	c.label = (
		"%s %sм %sч U%s%s %s°%s"
		% [
			String(loc.get("id", "")),
			dx,
			hour,
			u10,
			"" if inflow_k == 1.0 else " k%.3f" % inflow_k,
			wdir,
			"" if heat else " без нагрева"
		]
	)
	return c


## Контекст места для погоды: дата (reference_context), широта/долгота/пояс, долина и среднее.
static func context(detail: HeightLayer, loc: Dictionary, cfg: Dictionary) -> Dictionary:
	var rc := WeatherModel.reference_context(cfg)
	var lat := float(loc.get("center_lat", rc.get("lat", 52.0)))
	var lon := float(loc.get("center_lon", rc.get("lon", 0.0)))
	var ctx := {
		month = int(rc.get("month", 7)),
		day = int(rc.get("day", 15)),
		lat = lat,
		lon = lon,
		utc_offset_h = float(loc.get("utc_offset_h", roundf(lon / 15.0))),
	}
	ctx.merge(WeatherModel.ground_context(detail.sample, 10000.0, 15, 0.1))
	return ctx


const NODE_STEP := 25.0  # шаг решётки мира, на которую берётся слой (C2 v7), м


## Узлы решётки мира 25 м вдоль одной оси: x = a0 + 25·m, m = 0 … cnt − 1 → дробный индекс слоя
## (sign = +1: ось x; −1: ось y на север, строки слоя растут на юг, z = −y; o — начало слоя по оси).
## Возвращает {} при выходе узла за слой (без экстраполяции), иначе {i0: PackedInt32Array,
## t: PackedFloat64Array (вес правого узла), f: PackedFloat64Array (дробный индекс)}.
static func _axis_nodes(a0: float, cnt: int, sign: float, o: float, s: float, n_layer: int) -> Dictionary:
	var i0 := PackedInt32Array()
	var t := PackedFloat64Array()
	var fr := PackedFloat64Array()
	i0.resize(cnt)
	t.resize(cnt)
	fr.resize(cnt)
	var hi := float(n_layer - 1)
	for m in cnt:
		var v := (sign * (a0 + NODE_STEP * m) - o) / s
		if v < -1.0e-9 or v > hi + 1.0e-9:
			return {}
		v = clampf(v, 0.0, hi)
		var i := mini(int(v), n_layer - 2)
		i0[m] = i
		t[m] = v - i
		fr[m] = v
	return {i0 = i0, t = t, f = fr}


## Проверка кратности: dx, x0, y0 кратны 25 м (иначе решётка мира не ложится на клетки).
static func _grid_ok(x0: float, y0: float, dx: float) -> bool:
	for v in [x0, y0, dx]:
		if absf(v / NODE_STEP - roundf(v / NODE_STEP)) > 1.0e-9:
			push_error("AirPlace: dx, x0, y0 должны быть кратны 25 м")
			return false
	return true


## Высота клетки — блочное среднее значений слоя, взятых билинейно (как HeightLayer.sample, без
## выхода за край) в узлах решётки мира 25 м: x = x0 + 25·m, y = y0 + 25·m′, m, m′ = 0 … dx/25 − 1
## (C2 v7; как П6 terrain_cut.grid_h + block_mean_400 и air3d/terrain.block_mean). Билинейка
## сепарабельна, среднее линейно — считаем суммы по узлам клетки по столбцам для каждой строки слоя
## (float64; от П6 с float32-узлами отличается ≤ 1e-3 м). (ny·nx), j — на север. Узел вне слоя —
## пусто + push_error.
static func block_mean(
	layer: HeightLayer, x0: float, y0: float, dx: float, nx: int, ny: int
) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	if not _grid_ok(x0, y0, dx):
		return out
	var f := roundi(dx / NODE_STEP)
	var s := layer.spacing
	var ax := _axis_nodes(x0, f * nx, 1.0, layer.origin_x, s, layer.width)
	var ay := _axis_nodes(y0, f * ny, -1.0, layer.origin_z, s, layer.height)
	if ax.is_empty() or ay.is_empty():
		push_error("AirPlace: область вне слоя рельефа")
		return out
	var xi: PackedInt32Array = ax.i0
	var xt: PackedFloat64Array = ax.t
	var yi: PackedInt32Array = ay.i0
	var yt: PackedFloat64Array = ay.t
	var w := layer.width
	var h := layer.heights
	# разреженные веса столбцов клетки: Σ узлов клетки (1 − t)·H[c] + t·H[c + 1] → Σ_q cw·H[c0 + q]
	var cstart := PackedInt32Array()
	var wlen := PackedInt32Array()
	var woff := PackedInt32Array()
	var cw := PackedFloat64Array()
	for i in nx:
		var c0 := xi[i * f]
		var c1 := c0
		for q in f:
			c0 = mini(c0, xi[i * f + q])
			c1 = maxi(c1, xi[i * f + q] + 1)
		var wts := PackedFloat64Array()
		wts.resize(c1 - c0 + 1)
		for q in f:
			var c := i * f + q
			wts[xi[c] - c0] += 1.0 - xt[c]
			wts[xi[c] + 1 - c0] += xt[c]
		cstart.append(c0)
		wlen.append(wts.size())
		woff.append(cw.size())
		cw.append_array(wts)
	var inv_n := 1.0 / (f * f)
	out.resize(nx * ny)
	var cache := {}  # номер строки слоя → суммы по узлам клетки (nx)
	var acc := PackedFloat64Array()
	acc.resize(nx)
	for j in ny:
		acc.fill(0.0)
		for m in f:
			var node := j * f + m
			var r0 := yi[node]
			var tz := yt[node]
			for rr in 2:
				var r := r0 + rr
				var wr := tz if rr == 1 else 1.0 - tz
				if wr == 0.0:
					continue
				var rs: PackedFloat64Array
				if cache.has(r):
					rs = cache[r]
				else:
					rs = PackedFloat64Array()
					rs.resize(nx)
					var base := r * w
					for i in nx:
						var sum := 0.0
						var k := base + cstart[i]
						var wo := woff[i]
						for q in wlen[i]:
							sum += cw[wo + q] * h[k + q]
						rs[i] = sum
					cache[r] = rs
				for i in nx:
					acc[i] += wr * rs[i]
		for i in nx:
			out[j * nx + i] = acc[i] * inv_n
		# строки слоя убывают к северу: у следующей клетки максимальна первая строка узлов
		if j + 1 < ny:
			var keep := yi[(j + 1) * f] + 1
			for r in cache.keys():
				if r > keep:
					cache.erase(r)
	return out


## Доля воды по клеткам: по тем же узлам решётки 25 м, что и block_mean; маска — ближайший к
## узлу пиксель слоя (светлое — вода; как terrain.py), доля узлов клетки. Пусто — нет маски.
static func water_fraction(
	img: Image, layer: HeightLayer, x0: float, y0: float, dx: float, nx: int, ny: int
) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	if img == null or not _grid_ok(x0, y0, dx):
		return out
	if img.is_compressed() or img.get_format() != Image.FORMAT_L8:
		img = img.duplicate()
		if img.is_compressed():
			img.decompress()
		img.convert(Image.FORMAT_L8)
	var px_data := img.get_data()
	var s := layer.spacing
	var f := roundi(dx / NODE_STEP)
	var ax := _axis_nodes(x0, f * nx, 1.0, layer.origin_x, s, layer.width)
	var ay := _axis_nodes(y0, f * ny, -1.0, layer.origin_z, s, layer.height)
	if ax.is_empty() or ay.is_empty():
		return out
	var iw := img.get_width()
	var ih := img.get_height()
	var cols := PackedInt32Array()
	cols.resize(f * nx)
	for c in f * nx:
		cols[c] = int(roundi(ax.f[c]) * iw / layer.width)
	var rows := PackedInt32Array()
	rows.resize(f * ny)
	for r in f * ny:
		# строка маски: ближайший к узлу пиксель слоя (слой перевёрнут на север)
		rows[r] = (ih - 1 - int((layer.height - 1 - roundi(ay.f[r])) * ih / layer.height)) * iw
	out.resize(nx * ny)
	for j in ny:
		for i in nx:
			var cnt := 0
			for m in f:
				var rb := rows[j * f + m]
				for q in f:
					if px_data[rb + cols[i * f + q]] > 127:
						cnt += 1
			out[j * nx + i] = float(cnt) / (f * f)
	return out


## Погода дня в час для поля (weather.py → Day): z_i (м над морем) и профиль θ̄.
static func day(
	ctx: Dictionary, hour: float, t_max: float, sky: String, cfg: Dictionary
) -> Dictionary:
	var st := WeatherModel.diurnal_state(t_max, hour, ctx, cfg)
	var dd: Dictionary = cfg.get("diurnal", {})
	var m := int(ctx.month)
	var dday := int(ctx.day)
	var amp := WeatherModel.monthly(dd.get("range_k", [10.0]), m, dday)
	var t_res := t_max - float(dd.get("residual_cooling_k", 2.0))
	var ua: Dictionary = cfg.get("upper_air", {})
	var skyp := WeatherModel.sky_params(sky, cfg)
	var d := {
		hour = hour,
		t = float(st.temperature_c),
		cap = float(st.cap_agl_m),
		h_v = float(ctx.valley_msl_m) / 1000.0,
		t_u = WeatherModel.monthly(ua.get("temp_c", [0.0]), m, dday),
		z_u = float(ua.get("z_msl_m", 3000.0)) / 1000.0,
		gam = float(ua.get("lapse_k_per_km", 4.0)),
		t_min = t_max - amp,
		t_res = t_res,
		t_full = t_res - float(dd.get("break_window_k", 3.0)),
		dep = float(dd.get("inversion_depth_m", 500.0)) / 1000.0,
		sky_heat = float(skyp.get("heat", 1.0)),
		cover = float(skyp.get("cover", 0.0)),
		heat = float(st.heat) * float(skyp.get("heat", 1.0)),
	}
	d.theta_s = d.t + float(cfg.get("parcel_excess_k", 1.0)) + GAMMA_D * d.h_v
	# z_i — где профиль над слоем впервые теплее частицы (сетка как в эталоне)
	var h_v: float = d.h_v
	var nstep := 23000
	var step := (12.0 - h_v) / nstep
	var zi := 12.0
	for k in nstep + 1:
		var z := h_v + k * step if k < nstep else 12.0
		if _theta_upper(d, z) > d.theta_s:
			zi = z
			break
	d.z_i = zi * 1000.0
	return d


static func _theta_upper(d: Dictionary, zk: float) -> float:
	var fa: float = d.t_u + d.gam * (d.z_u - zk) + GAMMA_D * zk
	if is_inf(d.cap):
		return fa
	var th_min: float = d.t_min + GAMMA_D * d.h_v
	var th_res: float = d.t_res + GAMMA_D * d.h_v
	var slope: float = (d.t_full - d.t_min) / d.dep
	var night := minf(th_min + slope * maxf(zk - d.h_v, 0.0), th_res)
	return maxf(night, fa)


## θ̄(z) над морем (м), К.
static func theta(d: Dictionary, z_m: float) -> float:
	return maxf(_theta_upper(d, z_m / 1000.0), d.theta_s)


## dθ̄/dz, К/м (разностью ±5 м, как эталон).
static func gamma(d: Dictionary, z_m: float) -> float:
	return (theta(d, z_m + 5.0) - theta(d, z_m - 5.0)) / 10.0




# ---------------- поверхность и поток тепла (SH3, docs/contracts/surface-heat.md) ----------------


## Снимок поверхности места для решателя (SH3): на решётке 25 м мира (узлы x = origin_x + 25·i,
## z = origin_z + 25·j, строки на юг), в пределах слоя detail. Делается один раз на главном потоке
## (AirPlace.surface_of, после полей рельефа и полян у стартов) и дальше только читается — рабочие
## потоки решателя Terrain не трогают. cls — класс узла как Terrain._surface_class (карта поверхности,
## маска 10 м: вода G ≥ 0,5, лес R ≥ 0,5; круче rock_slope_deg → BARE) ∪ маска рек (WATER);
## moist — влажность рельефа в узле (TerrainRelief, билинейно), пусто — поля нет (m_norm).
class Surface:
	extends RefCounted
	var origin_x := 0.0
	var origin_z := 0.0
	var width := 0
	var height := 0
	var cls := PackedByteArray()
	var moist := PackedFloat32Array()
	## Время снимка, мс (отчёт).
	var build_ms := 0.0
	var _cells := {}
	var _mutex := Mutex.new()

	## Доли классов и влажность клеток сетки (кэш для крупных сеток — область считается часто).
	func cells(x0: float, y0: float, dx: float, nx: int, ny: int) -> Dictionary:
		var key := "%s|%s|%s|%d|%d" % [x0, y0, dx, nx, ny]
		var big := dx >= 200.0
		if big:
			_mutex.lock()
			var hit: Variant = _cells.get(key)
			_mutex.unlock()
			if hit != null:
				return hit
		var out := AirPlace._cells_from_surface(self, x0, y0, dx, nx, ny)
		if big:
			_store(key, out)
		return out

	## Заранее (главный поток, полосами в пуле) — клетки области с шагом dx: рабочему потоку
	## решателя остаётся чтение кэша.
	func precompute(x0: float, y0: float, dx: float, nx: int, ny: int) -> void:
		var key := "%s|%s|%s|%d|%d" % [x0, y0, dx, nx, ny]
		_store(key, AirPlace._cells_from_surface(self, x0, y0, dx, nx, ny, true))

	func _store(key: String, out: Dictionary) -> void:
		_mutex.lock()
		_cells[key] = out
		_mutex.unlock()


## Снимок поверхности (главный поток): terrain — Terrain (surfaces, reliefs, wait_relief), detail —
## слой 25 м места, water — маска рек слоя (или null). Ждёт поля рельефа (детерминизм: влажность не
## «гонится» с потоком). Нет карт поверхности и полей рельефа — null (поведение без снимка).
## domain_dx — шаги сеток области (domain_case), доли клеток которых посчитать сразу (в пуле).
static func surface_of(
	terrain: Object, detail: HeightLayer, water: Image, domain_dx := PackedFloat64Array()
) -> Surface:
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
	var sf := Surface.new()
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
	var mo := rel.moisture if rel != null else PackedFloat32Array()
	var rw := rel.width if rel != null else 0
	var w := sf.width
	var h := sf.height
	# 1) высоты узлов: билинейно по слою, как HeightLayer.sample (у встроенных слоёв 25 м — значения
	# узлов); оси разделимы, без вызовов методов в цикле
	var hx := _sample_axis(sf.origin_x, w, detail.origin_x, detail.spacing, detail.width)
	var hz := _sample_axis(sf.origin_z, h, detail.origin_z, detail.spacing, detail.height)
	var hs := detail.heights
	var lw := detail.width
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
	for ddx in domain_dx:
		var n := roundi(DOMAIN_L / ddx)
		if _grid_ok(-DOMAIN_L / 2.0, -DOMAIN_L / 2.0, ddx):
			sf.precompute(-DOMAIN_L / 2.0, -DOMAIN_L / 2.0, ddx, n, n)
	sf.build_ms = (Time.get_ticks_usec() - t0) / 1000.0
	return sf


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


## Доли классов и влажность клеток (SH3): по тем же узлам 25 м, что block_mean (f×f на клетку).
## surface — снимок (null — без карты: класс NONE, вода — по маске рек water, m = m_norm).
## {fr: PackedFloat32Array (ny·nx·CLASS_COUNT, доля узлов класса), m: PackedFloat32Array (ny·nx)}.
static func cell_surface(
	surface: Surface, water: Image, layer: HeightLayer, x0: float, y0: float, dx: float, nx: int,
	ny: int
) -> Dictionary:
	if not _grid_ok(x0, y0, dx):
		return {}
	if surface != null:
		return surface.cells(x0, y0, dx, nx, ny)
	var nc := SurfaceLayer.CLASS_COUNT
	var fr := PackedFloat32Array()
	fr.resize(nx * ny * nc)
	var m := PackedFloat32Array()
	m.resize(nx * ny)
	m.fill(float(SurfaceHeat.config().get("moisture", {}).get("m_norm", 0.5)))
	var wf := water_fraction(water, layer, x0, y0, dx, nx, ny)
	for q in nx * ny:
		var w := wf[q] if not wf.is_empty() else 0.0
		fr[q * nc + SurfaceLayer.WATER] = w
		fr[q * nc + SurfaceLayer.NONE] = 1.0 - w
	return {fr = fr, m = m}


## Доли и влажность клеток по снимку: в рабочем потоке — одной полосой, parallel — полосами строк
## клеток в пуле (главный поток, surface_of). Результат от разбиения не зависит (клетки независимы).
static func _cells_from_surface(
	sf: Surface, x0: float, y0: float, dx: float, nx: int, ny: int, parallel := false
) -> Dictionary:
	var fn := func(j0: int, j1: int) -> Array:
		return _cells_rows(sf, x0, y0, dx, nx, j0, j1)
	var bands: Array = TerrainRelief._par(ny, fn) if parallel else [fn.call(0, ny)]
	var fr := PackedFloat32Array()
	var m := PackedFloat32Array()
	for b: Array in bands:
		fr.append_array(b[0])
		m.append_array(b[1])
	return {fr = fr, m = m}


static func _cells_rows(
	sf: Surface, x0: float, y0: float, dx: float, nx: int, j0: int, j1: int
) -> Array:
	var nc := SurfaceLayer.CLASS_COUNT
	var f := roundi(dx / NODE_STEP)
	var rows := j1 - j0
	var fr := PackedFloat32Array()
	fr.resize(rows * nx * nc)
	var m := PackedFloat32Array()
	m.resize(rows * nx)
	var m_norm := float(SurfaceHeat.config().get("moisture", {}).get("m_norm", 0.5))
	var has_m := not sf.moist.is_empty()
	var cls := sf.cls
	var mo := sf.moist
	var sw := sf.width
	var i0 := roundi((x0 - sf.origin_x) / NODE_STEP)
	var r0 := roundi((-y0 - sf.origin_z) / NODE_STEP)  # узел y0 (север = −z) → строка снимка
	var inv := 1.0 / (f * f)
	var cnt := PackedInt32Array()
	cnt.resize(nc)
	for j in range(j0, j1):
		# строки узлов клетки: y растёт на север — строки снимка убывают
		var top := r0 - (j * f + f - 1)
		var bot := r0 - j * f
		for i in nx:
			cnt.fill(0)
			var msum := 0.0
			var c0 := i0 + i * f
			if top >= 0 and bot < sf.height and c0 >= 0 and c0 + f <= sw:
				for row in range(top, bot + 1):
					var k := row * sw + c0
					for qq in f:
						cnt[cls[k + qq]] += 1
						if has_m:
							msum += mo[k + qq]
				if not has_m:
					msum = m_norm * f * f
			else:  # узлы вне снимка — NONE, m_norm (block_mean такую область не пропускает)
				for mm in f:
					var row := r0 - (j * f + mm)
					for qq in f:
						var col := c0 + qq
						if row < 0 or row >= sf.height or col < 0 or col >= sw:
							cnt[SurfaceLayer.NONE] += 1
							msum += m_norm
						else:
							cnt[cls[row * sw + col]] += 1
							msum += mo[row * sw + col] if has_m else m_norm
			var q := (j - j0) * nx + i
			for c in nc:
				fr[q * nc + c] = cnt[c] * inv
			m[q] = msum * inv
	return [fr, m]


## Поток тепла клеток (Вт/м² на горизонтальную площадь, SH3): H = SurfaceHeat.mix_flux по долям
## классов клетки (cells — cell_surface), её влажности, нормали сетки (−∂h/∂x, 1, ∂h/∂y в осях игры:
## x — восток, y — вверх, z — юг = −y решателя; без нормировки — на горизонтальную площадь;
## градиент — np.gradient: центральные разности, на краях односторонние), солнцу классов
## (SurfaceHeating.directions(hour)), небу {cover, sky_heat} дня d; вода — {t_water_c (дата места,
## высота клетки), t_air_c (час, высота клетки), u_ms = u10, z_m = hc}.
static func surface_flux(
	hc: PackedFloat64Array,
	dx: float,
	nx: int,
	ny: int,
	d: Dictionary,
	ctx: Dictionary,
	cfg: Dictionary,
	cells: Dictionary,
	u10: float,
	t_max: float
) -> PackedFloat64Array:
	var scfg := SurfaceHeat.config()
	var wcfg: Dictionary = scfg.get("water", {})
	var hour := float(d.hour)
	var heating := SurfaceHeating.new()
	heating.setup(
		float(ctx.lat), float(ctx.lon), int(ctx.month), int(ctx.day), float(ctx.utc_offset_h), cfg
	)
	var sun := heating.directions(hour)
	if sun.is_empty():  # инерция прогрева выключена — всем классам текущее солнце
		sun.resize(SurfaceLayer.CLASS_COUNT)
		sun.fill(heating.sun_at(hour))
	var sky := {cover = float(d.cover), sky_heat = float(d.sky_heat)}
	var fr: PackedFloat32Array = cells.fr
	var mo: PackedFloat32Array = cells.m
	var nc := SurfaceLayer.CLASS_COUNT
	# T воды: water_temp_c = max(0, T̄ − lapse(z)); T̄ — один раз на высоте долины (lapse = 0), дальше
	# то же выражение, что в SurfaceHeat (побитно равно прямому вызову); T̄ ≤ 0 — прямой вызов по клетке.
	var zv := float(ctx.get("valley_msl_m", 0.0))
	var tw_v := SurfaceHeat.water_temp_c(int(ctx.month), int(ctx.day), zv, ctx, wcfg)
	var ta_v := SurfaceHeat.air_temp_c(hour, t_max, zv, ctx, wcfg)
	var out := PackedFloat64Array()
	out.resize(nx * ny)
	for j in ny:
		for i in nx:
			var q := j * nx + i
			var gx: float
			var gy: float
			if i == 0:
				gx = (hc[q + 1] - hc[q]) / dx
			elif i == nx - 1:
				gx = (hc[q] - hc[q - 1]) / dx
			else:
				gx = (hc[q + 1] - hc[q - 1]) / (2.0 * dx)
			if j == 0:
				gy = (hc[q + nx] - hc[q]) / dx
			elif j == ny - 1:
				gy = (hc[q] - hc[q - nx]) / dx
			else:
				gy = (hc[q + nx] - hc[q - nx]) / (2.0 * dx)
			var water := {}
			if fr[q * nc + SurfaceLayer.WATER] > 0.0:
				var z := hc[q]
				var lap := SurfaceHeat._lapse(z, ctx, wcfg)
				var tw := (
					maxf(0.0, tw_v - lap)
					if tw_v > 0.0
					else SurfaceHeat.water_temp_c(int(ctx.month), int(ctx.day), z, ctx, wcfg)
				)
				water = {t_water_c = tw, t_air_c = ta_v - lap, u_ms = u10, z_m = z}
			out[q] = SurfaceHeat.mix_flux(
				fr, q * nc, Vector3(-gx, 1.0, gy), sun, float(mo[q]), sky, water, scfg
			)
	return out
