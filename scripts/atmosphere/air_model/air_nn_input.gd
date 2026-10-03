class_name AirNnInput
extends RefCounted
## Вход сети области из состояния игры и страж области применимости (O4, docs/contracts/air-onnx.md).
## Строка — словарь в форме строки набора пилота (O3): U10, wdir, t_max, hour, sky, profile{alpha,
## max_profile, stab, sun_el, sun_az}, day{z_i_msl, z_lcl_msl, heat, cap_agl, brk, t} + hc, heat
## (PackedFloat64Array ny·nx). Эталон — tools/research/air_nn_pilot/airlite_gen.py:solve_case
## (real.case → cond.alpha, max_profile, stab_class, sun_elev, sun[0]; cond.day.summary(); d400_hc,
## d400_H); фикстура — tools/air_onnx/make_input_fixture.py.
##
##   var cond := AirNnInput.cond_for(detail, loc, hour, t_max, sky)
##   var row := AirNnInput.row_from_case(case, cond)
##   var g := AirNnInput.guard(row, AirNnInput.default_domain())   # → {row, clamped}

const STAB := "ABCDEF"
## Условия набора пилота (airlite_gen.plan_rows): U10 0–8 м/с, час 9–20, t_max 18–34 °C.
const DEFAULT_DOMAIN := {"U10": [0.0, 8.0], "hour": [9.0, 20.0], "t_max": [18.0, 34.0]}


## Область применимости: конфиг air_model.nn_domain (если есть), иначе условия набора.
## Метаданные модели (deltaplan.domain) важнее — подставляет вызывающий (O5).
static func default_domain() -> Dictionary:
	var cfg: Dictionary = Config.get_config("atmosphere").get("air_model", {})
	var d: Dictionary = DEFAULT_DOMAIN.duplicate(true)
	var over: Dictionary = cfg.get("nn_domain", {})
	for k: String in over:
		d[k] = over[k]
	return d


## Условия часа для row_from_case: {hour, t_max, sky, ctx, cfg}. t_max NAN — обычный для даты.
static func cond_for(
	detail: HeightLayer, loc: Dictionary, hour: float, t_max := NAN, sky := "clear"
) -> Dictionary:
	var cfg := WeatherModel.config()
	var ctx := AirPlace.context(detail, loc, cfg)
	if is_nan(t_max):
		t_max = WeatherModel.typical_max_c(int(ctx.month), int(ctx.day), cfg)
	return {hour = hour, t_max = t_max, sky = sky, ctx = ctx, cfg = cfg}


## Строка входа сети из случая области С НАГРЕВОМ (AirPlace.domain_case) и условий часа cond
## ({hour, t_max, sky, ctx, cfg?}, см. cond_for). U10 — приток случая (k·меню), α/max_profile/класс —
## из случая (по ветру меню, C2 v6); heat — с гашением у края, как берёт решение (d400_H набора).
static func row_from_case(case: AirCase, cond: Dictionary) -> Dictionary:
	var cfg: Dictionary = cond.get("cfg", {})
	if cfg.is_empty():
		cfg = WeatherModel.config()
	var ctx: Dictionary = cond.ctx
	var hour := float(cond.hour)
	var t_max := float(cond.t_max)
	var sky := String(cond.get("sky", "clear"))
	var month := int(ctx.month)
	var dday := int(ctx.day)
	var cover := float(WeatherModel.sky_params(sky, cfg).get("cover", 0.0))
	var sky_heat := float(WeatherModel.sky_params(sky, cfg).get("heat", 1.0))
	# --- день (weather.Day.summary)
	var st := WeatherModel.diurnal_state(t_max, hour, ctx, cfg)
	var t := float(st.temperature_c)
	var h_v := float(ctx.valley_msl_m) / 1000.0
	var td := WeatherModel.monthly(cfg.dew_point_c, month, dday)
	td += float(cfg.get("td_follow_heat", 0.0)) * maxf(
		t_max - WeatherModel.typical_max_c(month, dday, cfg), 0.0
	)
	td = minf(td, t)
	var z_lcl := (h_v + float(cfg.lcl_m_per_k) / 1000.0 * (t - td)) * 1000.0
	var day := {
		t = _r(t, 2),
		heat = _r(float(st.heat) * sky_heat, 3),
		brk = _r(float(st["break"]), 2),
		z_lcl_msl = _r(z_lcl, 0),
	}
	if is_finite(case.z_i):
		day.z_i_msl = _r(case.z_i, 0)
	var cap := float(st.cap_agl_m)
	if is_finite(cap):
		day.cap_agl = cap
	# --- профиль притока: α, max_profile — из случая; класс и высота солнца — как их считает игра
	var sun_el := WindProfile.sun_elevation(ctx, hour)
	var u_menu: float = case.u10_menu if case.u10_menu > 0.0 else case.u10
	var cls := WindProfile.stability_class(u_menu, sun_el, cover)
	var lag := float(cfg.get("heating", {}).get("lag_h", {}).get("none", 0.3))
	var doy := SunClock.day_of_year(month, dday)
	var sun_az := SunClock.solar_position(
		float(ctx.lat), float(ctx.lon), doy, hour - lag, float(ctx.utc_offset_h)
	).x
	return {
		U10 = case.u10,
		wdir = case.wdir,
		t_max = t_max,
		hour = hour,
		sky = sky,
		profile =
		{
			alpha = float(case.p.alpha),
			max_profile = case.max_profile_used(),
			stab = STAB[cls],
			sun_el = sun_el,
			sun_az = sun_az,
		},
		day = day,
		hc = case.hc,
		heat = tapered_heat(case),
	}


## Поток тепла случая с гашением у края области (как AirCase.prepare / air.py), Вт/м², ny·nx;
## нет нагрева — нули.
static func tapered_heat(case: AirCase) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(case.nx * case.ny)
	if case.heat.is_empty():
		return out
	var tm := float(case.p.heat_taper_m)
	var lx := case.nx * case.dx
	var ly := case.ny * case.dx
	for j in case.ny:
		var ye := (j + 0.5) * case.dx
		var eyy := clampf(minf(ye, ly - ye) / tm, 0.0, 1.0)
		for i in case.nx:
			var v: float = case.heat[j * case.nx + i]
			if case.taper:
				var xe := (i + 0.5) * case.dx
				var exx := clampf(minf(xe, lx - xe) / tm, 0.0, 1.0)
				var f := sin(0.5 * PI * eyy) * sin(0.5 * PI * exx)
				v *= f * f
			out[j * case.nx + i] = v
	return out


## Страж: величины строки вне domain ({U10: [lo, hi], hour: […], t_max: […]}) зажимаются к краю —
## только для входа сети (числа FiLM); to_physical берёт настоящий U10 (выход нормирован на
## max(U10, 1) — у вызывающего). → {row: строка с зажатыми числами, clamped: ["U10 12.0→8.0", …]}.
static func guard(row: Dictionary, domain: Dictionary) -> Dictionary:
	var out := row.duplicate()
	var clamped: Array[String] = []
	for key: String in ["U10", "hour", "t_max"]:
		if not domain.has(key) or not row.has(key):
			continue
		var lim: Array = domain[key]
		var v := float(row[key])
		var c := clampf(v, float(lim[0]), float(lim[1]))
		if c != v:
			clamped.append("%s %.1f→%.1f" % [key, v, c])
			out[key] = c
	return {row = out, clamped = clamped}


## round() Python (до n знаков) — набор пилота видел округлённые числа summary().
static func _r(v: float, n: int) -> float:
	var s := pow(10.0, n)
	return roundf(v * s) / s
