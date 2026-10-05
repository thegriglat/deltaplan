class_name AirPlace
extends RefCounted
## Вход решения масштаба 1 для места игры (AM-03): рельеф слоя detail → сетка области, погода
## игры на час → фон θ̄(z) и верх слоя перемешивания z_i, солнце → поток тепла по склонам.
## Перенос эталона AM-01: tools/research/air3d/real.py (grid_domain, case), weather.py (Day),
## air.py (solar_flux). Погода — те же WeatherModel.diurnal_state / SunClock, что у игры.
##
##   var c := AirPlace.domain_case(detail, water_img, loc_cfg, 400.0, 12.0, 3.0, 150.0)
##   var job := AirPicardJob.new(); job.case = c; job.start() …

const DOMAIN_L := 38400.0  # сторона области, м (38,4 км = 96·400 = 192·200)
const TOP_ABOVE := 3000.0  # потолок над максимумом рельефа, м
const GAMMA_D := 9.8  # К/км
const H0_WM2 := 330.0  # явный поток при нормальном падении солнца, Вт/м²
const DIFFUSE := 0.10
const H_LW_WM2 := 40.0
const LW_CLOUD_K := 0.7


## Область места (квадрат DOMAIN_L вокруг центра) с клеткой dx на час hour: ветер u10 (на 10 м,
## м/с) откуда wdir (°); t_max — дневной максимум (NAN — обычный для даты), sky — облачность;
## heat = false — без нагрева (H = 0). detail — слой рельефа 25 м, water — маска воды (или null),
## loc — configs/locations/<место>.json (center_lat, center_lon, utc_offset_h).
## u10 — ветер меню (на 10 м над стартом, C2 v6); inflow_k — множитель притока: α, класс
## устойчивости и max_profile — по u10 меню, приток на краю области AirCase.u10 = inflow_k·u10
## (AirRuntime подбирает k так, чтобы над стартом на 10 м было u10 меню).
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
	inflow_k := 1.0
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
		c.heat = solar_flux(
			hc, dx, n, n, d, ctx, cfg, water_fraction(water, detail, x0, y0, dx, n, n)
		)
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


## Поток тепла (Вт/м² на горизонтальную площадь) по клеткам: солнце с запаздыванием прогрева
## луга, косинус угла к склону, рассеянная доля, выхолаживание; вода — 0 (air.solar_flux).
static func solar_flux(
	hc: PackedFloat64Array,
	dx: float,
	nx: int,
	ny: int,
	d: Dictionary,
	ctx: Dictionary,
	cfg: Dictionary,
	water: PackedFloat64Array
) -> PackedFloat64Array:
	var lag := float(cfg.get("heating", {}).get("lag_h", {}).get("none", 0.3))
	var doy := SunClock.day_of_year(int(ctx.month), int(ctx.day))
	var sp := SunClock.solar_position(
		float(ctx.lat), float(ctx.lon), doy, float(d.hour) - lag, float(ctx.utc_offset_h)
	)
	var az := deg_to_rad(sp.x)
	var el := deg_to_rad(sp.y)
	var sx := 0.0
	var sy := 0.0
	var sz := 0.0
	var up := sp.y > 0.0
	if up:
		sx = cos(el) * sin(az)
		sy = cos(el) * cos(az)
		sz = sin(el)
	var out := PackedFloat64Array()
	out.resize(nx * ny)
	var lw := H_LW_WM2 * (1.0 - LW_CLOUD_K * float(d.cover))
	for j in ny:
		for i in nx:
			var q := j * nx + i
			var cos_inc := 0.0
			if up:
				# np.gradient: центральные разности, на краях — односторонние
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
				cos_inc = -gx * sx - gy * sy + sz
			var h := (
				H0_WM2 * float(d.sky_heat) * (maxf(cos_inc, 0.0) + DIFFUSE * maxf(sz, 0.0)) - lw
			)
			if not water.is_empty():
				h *= 1.0 - water[q]
			out[q] = h
	return out
