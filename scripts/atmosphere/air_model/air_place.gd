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


## Область места (квадрат DOMAIN_L вокруг центра) с клеткой dx на час hour: ветер U10 (на 10 м,
## м/с) откуда wdir (°); t_max — дневной максимум (NAN — обычный для даты), sky — облачность;
## heat = false — без нагрева (H = 0). detail — слой рельефа 25 м, water — маска воды (или null),
## loc — configs/locations/<место>.json (center_lat, center_lon, utc_offset_h).
static func domain_case(
	detail: HeightLayer, water: Image, loc: Dictionary, dx: float, hour: float, U10: float,
	wdir: float, t_max := NAN, sky := "clear", heat := true
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
	c.U10 = U10
	c.wdir = wdir
	var cfg := WeatherModel.config()
	var ctx := context(detail, loc, cfg)
	if is_nan(t_max):
		t_max = WeatherModel.typical_max_c(int(ctx.month), int(ctx.day), cfg)
	var d := day(ctx, hour, t_max, sky, cfg)
	c.z_i = d.z_i
	c.gam.resize(nz + 2)
	for k in nz + 2:
		c.gam[k] = gamma(d, c.zc(k))
	if heat:
		c.heat = solar_flux(hc, dx, n, n, d, ctx, cfg, water_fraction(water, detail, x0, y0, dx, n, n))
	c.label = "%s %sм %sч U%s %s°%s" % [
		String(loc.get("id", "")), dx, hour, U10, wdir, "" if heat else " без нагрева"
	]
	return c


## Контекст места для погоды: дата (reference_context), широта/долгота/пояс, долина и среднее.
static func context(detail: HeightLayer, loc: Dictionary, cfg: Dictionary) -> Dictionary:
	var rc := WeatherModel.reference_context(cfg)
	var lat := float(loc.get("center_lat", rc.get("lat", 52.0)))
	var lon := float(loc.get("center_lon", rc.get("lon", 0.0)))
	var ctx := {
		month = int(rc.get("month", 7)), day = int(rc.get("day", 15)), lat = lat, lon = lon,
		utc_offset_h = float(loc.get("utc_offset_h", roundf(lon / 15.0))),
	}
	ctx.merge(WeatherModel.ground_context(detail.sample, 10000.0, 15, 0.1))
	return ctx


## Блочное среднее слоя (узлы 25 м) по клеткам dx: (ny·nx), j — на север.
static func block_mean(
	layer: HeightLayer, x0: float, y0: float, dx: float, nx: int, ny: int
) -> PackedFloat64Array:
	var s := layer.spacing
	var f := roundi(dx / s)
	var yl := -(layer.origin_z + (layer.height - 1) * s)  # юг слоя в осях решателя
	var i0 := roundi((x0 - layer.origin_x) / s)
	var j0 := roundi((y0 - yl) / s)
	var out := PackedFloat64Array()
	if i0 < 0 or j0 < 0 or i0 + f * nx > layer.width or j0 + f * ny > layer.height:
		push_error("AirPlace: область вне слоя рельефа")
		return out
	out.resize(nx * ny)
	var w := layer.width
	var h := layer.heights
	var rows := PackedFloat64Array()
	rows.resize(nx)
	for j in ny:
		rows.fill(0.0)
		for jf in range(j0 + f * j, j0 + f * (j + 1)):
			var base := (layer.height - 1 - jf) * w + i0  # строка слоя растёт на юг
			for i in nx:
				var b := base + f * i
				var acc := 0.0
				for q in f:
					acc += h[b + q]
				rows[i] += acc
		for i in nx:
			out[j * nx + i] = rows[i] / (f * f)
	return out


## Доля воды по клеткам (маска слоя: светлое — вода; как terrain.py), null — нет маски.
static func water_fraction(
	img: Image, layer: HeightLayer, x0: float, y0: float, dx: float, nx: int, ny: int
) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	if img == null:
		return out
	if img.is_compressed() or img.get_format() != Image.FORMAT_L8:
		img = img.duplicate()
		if img.is_compressed():
			img.decompress()
		img.convert(Image.FORMAT_L8)
	var px_data := img.get_data()
	var s := layer.spacing
	var f := roundi(dx / s)
	var yl := -(layer.origin_z + (layer.height - 1) * s)
	var i0 := roundi((x0 - layer.origin_x) / s)
	var j0 := roundi((y0 - yl) / s)
	var iw := img.get_width()
	var ih := img.get_height()
	out.resize(nx * ny)
	for j in ny:
		for i in nx:
			var cnt := 0
			for jf in range(j0 + f * j, j0 + f * (j + 1)):
				# строка маски: ближайшая к узлу слоя (слой перевёрнут на север)
				var py := ih - 1 - int(jf * ih / layer.height)
				for q in f:
					var px := int((i0 + f * i + q) * iw / layer.width)
					if px_data[py * iw + px] > 127:
						cnt += 1
			out[j * nx + i] = float(cnt) / (f * f)
	return out


## Погода дня в час для поля (weather.py → Day): z_i (м над морем) и профиль θ̄.
static func day(ctx: Dictionary, hour: float, t_max: float, sky: String, cfg: Dictionary) -> Dictionary:
	var st := WeatherModel.diurnal_state(t_max, hour, ctx, cfg)
	var dd: Dictionary = cfg.get("diurnal", {})
	var m := int(ctx.month)
	var dday := int(ctx.day)
	var amp := WeatherModel.monthly(dd.get("range_k", [10.0]), m, dday)
	var t_res := t_max - float(dd.get("residual_cooling_k", 2.0))
	var ua: Dictionary = cfg.get("upper_air", {})
	var skyp := WeatherModel.sky_params(sky, cfg)
	var d := {
		hour = hour, t = float(st.temperature_c), cap = float(st.cap_agl_m), h_v = float(ctx.valley_msl_m) / 1000.0,
		t_u = WeatherModel.monthly(ua.get("temp_c", [0.0]), m, dday),
		z_u = float(ua.get("z_msl_m", 3000.0)) / 1000.0, gam = float(ua.get("lapse_k_per_km", 4.0)),
		t_min = t_max - amp, t_res = t_res, t_full = t_res - float(dd.get("break_window_k", 3.0)),
		dep = float(dd.get("inversion_depth_m", 500.0)) / 1000.0,
		sky_heat = float(skyp.get("heat", 1.0)), cover = float(skyp.get("cover", 0.0)),
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
	hc: PackedFloat64Array, dx: float, nx: int, ny: int, d: Dictionary, ctx: Dictionary,
	cfg: Dictionary, water: PackedFloat64Array
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
			var h := H0_WM2 * float(d.sky_heat) * (maxf(cos_inc, 0.0) + DIFFUSE * maxf(sz, 0.0)) - lw
			if not water.is_empty():
				h *= 1.0 - water[q]
			out[q] = h
	return out

