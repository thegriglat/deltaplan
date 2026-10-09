extends TestCase
## Инварианты ядра SurfaceHeat (контракт SH2).

const SKY := {"cover": 0.0, "sky_heat": 1.0}


func _cfg() -> Dictionary:
	return SurfaceHeat.config()


func _ctx() -> Dictionary:
	var c := WeatherModel.reference_context()
	c["utc_offset_h"] = 7.0
	return c


func test_shortwave_monotone_and_night() -> void:
	var cfg := _cfg()
	var prev := -1.0
	for i in 11:
		var k := SurfaceHeat.shortwave(i / 10.0, 0.8, 0.0, 1.0, cfg)
		check(k >= prev, "K↓ не убывает по cos_inc")
		prev = k
	check(SurfaceHeat.shortwave(1.0, 0.0, 0.0, 1.0, cfg) == 0.0, "sin_el = 0 → 0")
	check(SurfaceHeat.shortwave(0.5, -0.2, 0.0, 1.0, cfg) == 0.0, "солнце под горизонтом → 0")
	check(SurfaceHeat.shortwave(-0.5, 0.8, 0.0, 1.0, cfg) > 0.0, "тень склона: рассеянная остаётся")
	approx(SurfaceHeat.shortwave(1.0, 1.0, 0.0, 1.0, cfg), 1096.0, 0.01, "зенит, ясно: 1370·0,8")


func test_bowen() -> void:
	var cfg := _cfg()
	var mo: Dictionary = cfg.moisture
	for c in SurfaceLayer.CLASS_COUNT:
		var k: Dictionary = cfg.classes[SurfaceLayer.CLASS_NAMES[c]]
		approx(SurfaceHeat.bowen(c, mo.m_norm, cfg), k.bowen, 1e-9, "β(m_norm)")
		approx(SurfaceHeat.bowen(c, mo.m_dry, cfg), k.bowen_max, 1e-9, "β(m_dry)")
		approx(SurfaceHeat.bowen(c, 0.0, cfg), k.bowen_max, 1e-9, "β(0)")
		approx(SurfaceHeat.bowen(c, mo.m_wet, cfg), k.bowen_min, 1e-9, "β(m_wet)")
		approx(SurfaceHeat.bowen(c, 1.0, cfg), k.bowen_min, 1e-9, "β(1)")
		var prev := INF
		for i in 21:
			var b := SurfaceHeat.bowen(c, i / 20.0, cfg)
			check(b >= k.bowen_min - 1e-9 and b <= k.bowen_max + 1e-9, "β в границах")
			check(b <= prev + 1e-12, "β не растёт по m")
			prev = b


func test_land_flux() -> void:
	var cfg := _cfg()
	for c in SurfaceLayer.CLASS_COUNT:
		if c == SurfaceHeat.WATER_CLASS:
			continue
		var prev := INF
		for i in 11:
			var h := SurfaceHeat.land_flux(c, 800.0, 0.0, i / 10.0, cfg)
			check(h <= prev + 1e-9, "H не растёт по m (Rn − G > 0), класс %d" % c)
			prev = h
		check(SurfaceHeat.land_flux(c, 0.0, 0.0, 0.5, cfg) < 0.0, "ночью H < 0, класс %d" % c)
		check(
			SurfaceHeat.land_flux(c, 900.0, 0.0, 0.5, cfg) > SurfaceHeat.land_flux(c, 300.0, 0.0, 0.5, cfg),
			"H растёт с K↓"
		)
		check(
			SurfaceHeat.land_flux(c, 0.0, 1.0, 0.5, cfg) > SurfaceHeat.land_flux(c, 0.0, 0.0, 0.5, cfg),
			"облака ослабляют ночное выхолаживание"
		)


func test_href_consistent() -> void:
	var cfg := _cfg()
	var k := SurfaceHeat.shortwave(1.0, 1.0, 0.0, 1.0, cfg)
	var h := SurfaceHeat.land_flux(SurfaceLayer.BARE, k, 0.0, cfg.moisture.m_norm, cfg)
	approx(h, cfg.thermal.h_ref_wm2, 0.5, "h_ref_wm2 = H скалы в зените")


func test_water() -> void:
	var cfg := _cfg()
	check(SurfaceHeat.water_flux(10.0, 15.0, 3.0, cfg) < 0.0, "вода холоднее воздуха → H < 0")
	check(SurfaceHeat.water_flux(15.0, 10.0, 3.0, cfg) > 0.0, "вода теплее → H > 0")
	check(SurfaceHeat.water_flux(10.0, 10.0, 3.0, cfg) == 0.0, "равны → 0")
	approx(SurfaceHeat.water_flux(0.0, 5.0, 0.0, cfg), -1231.0 * 1.3e-3 * 1.0 * 5.0, 1e-6, "u_min")
	var ctx := _ctx()
	var wc: Dictionary = cfg.water
	var tw := SurfaceHeat.water_temp_c(7, 15, ctx.valley_msl_m, ctx, wc)
	check(tw >= 0.0, "T_w ≥ 0")
	var tmax := WeatherModel.typical_max_c(7, 15)
	var tmean_air := SurfaceHeat.air_temp_c(14.0, tmax, ctx.valley_msl_m, ctx, wc)
	check(tw < tmean_air and tw > 5.0, "летом вода теплее 5 °C и холоднее дневного воздуха: %.1f" % tw)
	check(SurfaceHeat.water_temp_c(1, 15, ctx.valley_msl_m, ctx, wc) == 0.0, "январь: лёд (0)")
	var hi := SurfaceHeat.water_temp_c(7, 15, ctx.valley_msl_m + 1000.0, ctx, wc)
	approx(tw - hi, 6.5, 1e-6, "поправка на высоту 6,5 К/км")
	approx(
		SurfaceHeat.air_temp_c(14.0, 25.0, ctx.valley_msl_m + 1000.0, ctx, wc),
		SurfaceHeat.air_temp_c(14.0, 25.0, ctx.valley_msl_m, ctx, wc) - 6.5,
		1e-9,
		"air_temp_c: высота"
	)


func _fr(c: int) -> PackedFloat32Array:
	var f := PackedFloat32Array()
	f.resize(SurfaceLayer.CLASS_COUNT * 2)
	f[SurfaceLayer.CLASS_COUNT + c] = 1.0
	return f


func _sun(el_deg: float) -> PackedVector3Array:
	var s := PackedVector3Array()
	s.resize(SurfaceLayer.CLASS_COUNT)
	var v := Vector3(0.0, sin(deg_to_rad(el_deg)), cos(deg_to_rad(el_deg)))
	for c in SurfaceLayer.CLASS_COUNT:
		s[c] = v if el_deg > 0.0 else Vector3.ZERO
	return s


func test_mix_flux() -> void:
	var cfg := _cfg()
	var up := Vector3.UP
	var sun := _sun(60.0)
	# Один класс = land_flux.
	var h1 := SurfaceHeat.mix_flux(_fr(SurfaceLayer.GRASS), SurfaceLayer.CLASS_COUNT, up, sun, 0.5, SKY, {}, cfg)
	var k := SurfaceHeat.shortwave(sin(deg_to_rad(60.0)), sin(deg_to_rad(60.0)), 0.0, 1.0, cfg)
	approx(h1, SurfaceHeat.land_flux(SurfaceLayer.GRASS, k, 0.0, 0.5, cfg), 1e-3, "один класс")
	# Смесь 50/50 и ненормированные веса.
	var f := PackedFloat32Array()
	f.resize(SurfaceLayer.CLASS_COUNT)
	f[SurfaceLayer.GRASS] = 2.0
	f[SurfaceLayer.BARE] = 2.0
	var hm := SurfaceHeat.mix_flux(f, 0, up, sun, 0.5, SKY, {}, cfg)
	var ha := SurfaceHeat.land_flux(SurfaceLayer.GRASS, k, 0.0, 0.5, cfg)
	var hb := SurfaceHeat.land_flux(SurfaceLayer.BARE, k, 0.0, 0.5, cfg)
	approx(hm, 0.5 * (ha + hb), 1e-3, "смесь")
	# Сумма 0 → NONE.
	var z := PackedFloat32Array()
	z.resize(SurfaceLayer.CLASS_COUNT)
	approx(
		SurfaceHeat.mix_flux(z, 0, up, sun, 0.5, SKY, {}, cfg),
		SurfaceHeat.land_flux(SurfaceLayer.NONE, k, 0.0, 0.5, cfg),
		1e-3,
		"сумма 0 → NONE"
	)
	# Ночь: H < 0.
	check(SurfaceHeat.mix_flux(_fr(SurfaceLayer.GRASS), SurfaceLayer.CLASS_COUNT, up, _sun(-10.0), 0.5, SKY, {}, cfg) < 0.0, "ночью H < 0")
	# Вода: тёплая — по water_flux, пустой контекст — 0, лёд — как снег.
	var fw := _fr(SurfaceLayer.WATER)
	var wd := {"t_water_c": 12.0, "t_air_c": 17.0, "u_ms": 3.0}
	approx(
		SurfaceHeat.mix_flux(fw, SurfaceLayer.CLASS_COUNT, up, sun, 0.5, SKY, wd, cfg),
		SurfaceHeat.water_flux(12.0, 17.0, 3.0, cfg),
		1e-3,
		"вода"
	)
	check(SurfaceHeat.mix_flux(fw, SurfaceLayer.CLASS_COUNT, up, sun, 0.5, SKY, {}, cfg) == 0.0, "нет контекста воды → 0")
	var ice := {"t_water_c": 0.0, "t_air_c": 5.0, "u_ms": 3.0}
	approx(
		SurfaceHeat.mix_flux(fw, SurfaceLayer.CLASS_COUNT, up, sun, 0.5, SKY, ice, cfg),
		SurfaceHeat.land_flux(SurfaceLayer.SNOW, k, 0.0, 0.5, cfg),
		1e-3,
		"лёд = снег"
	)
	# Наклон: к солнцу > ровно > от солнца.
	var toward := Vector3(0.0, 1.0, 0.5)
	var away := Vector3(0.0, 1.0, -0.5)
	var ht := SurfaceHeat.mix_flux(_fr(2), SurfaceLayer.CLASS_COUNT, toward, sun, 0.5, SKY, {}, cfg)
	var hp := SurfaceHeat.mix_flux(_fr(2), SurfaceLayer.CLASS_COUNT, up, sun, 0.5, SKY, {}, cfg)
	var hw := SurfaceHeat.mix_flux(_fr(2), SurfaceLayer.CLASS_COUNT, away, sun, 0.5, SKY, {}, cfg)
	check(ht > hp and hp > hw, "к солнцу > ровно > от солнца")


func test_deterministic() -> void:
	var cfg := _cfg()
	var a := SurfaceHeat.land_flux(2, SurfaceHeat.shortwave(0.7, 0.7, 0.3, 0.8, cfg), 0.3, 0.42, cfg)
	var b := SurfaceHeat.land_flux(2, SurfaceHeat.shortwave(0.7, 0.7, 0.3, 0.8, cfg), 0.3, 0.42, cfg)
	check(a == b, "побитно")
