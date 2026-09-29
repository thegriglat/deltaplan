extends TestCase
## Термики из поля (AM-07, docs/air_model.md → «Масштаб 2: термики из поля»): источники над
## прогретым и в схождении, не в тени; потолок по инверсии и кромке; поток массы пузырей = потоку
## поля; сеть — маска ведущего даёт те же источники при поле с шумом; атмосфера с полем — термики
## поля в окне, аналитика вне его; без поля — как раньше.

const FIXTURE := "res://tests/atmosphere/fixtures/air_model/thermals/kayancha_w100_h12"
const N := 48
const NZ := 60
const DX := 100.0
const DZ := 50.0
const GROUND := 1000.0
const Z_BOT := 950.0


## Синтетическое поле: ровная земля GROUND, сетка N × N × NZ (−2,4…2,4 км), heat(x, z) Вт/м²,
## wconv(x, z, agl) м/с, ветер (ue, vn) м/с, θ′(agl) К; фон — нейтральный до z_i, выше gam_above.
static func _flat(
	heat_fn: Callable,
	wconv_fn: Callable,
	z_i: float = 2500.0,
	gam_above: float = 0.0058,
	wind := Vector2.ZERO,
	theta_fn := Callable()
) -> WindField:
	var m := {
		dx = DX,
		dz = DZ,
		x0 = -N * DX * 0.5,
		y0 = -N * DX * 0.5,
		z_bot = Z_BOT,
		nx = N,
		ny = N,
		nz = NZ,
		z0 = 0.1,
		z_i = z_i,
		u10 = wind.length() / 1.8,
	}
	var gam := []
	for k in NZ:
		gam.append(0.0 if Z_BOT + (k + 0.5) * DZ < z_i else gam_above)
	m["gam"] = gam
	var n := N * N * NZ
	var u := PackedFloat32Array()
	var v := PackedFloat32Array()
	var wm := PackedFloat32Array()
	var wc := PackedFloat32Array()
	var th := PackedFloat32Array()
	for a: PackedFloat32Array in [u, v, wm, wc, th]:
		a.resize(n)
	var hc := PackedFloat32Array()
	hc.resize(N * N)
	hc.fill(GROUND)
	var heat := PackedFloat32Array()
	heat.resize(N * N)
	for j in N:
		for i in N:
			var x: float = m.x0 + (i + 0.5) * DX
			var zw: float = -(m.y0 + (j + 0.5) * DX)
			heat[j * N + i] = float(heat_fn.call(x, zw))
			for k in NZ:
				var c := (k * N + j) * N + i
				var agl := Z_BOT + (k + 0.5) * DZ - GROUND
				u[c] = wind.x
				v[c] = wind.y
				wc[c] = float(wconv_fn.call(x, zw, agl)) if agl > 0.0 else 0.0
				th[c] = float(theta_fn.call(agl)) if theta_fn.is_valid() else 0.0
	m["heat"] = heat
	return WindField.from_arrays(m, u, v, wm, wc, th, hc)


static func _cfg(cb: float = 1.0e9) -> Dictionary:
	var c: Dictionary = Config.get_config("atmosphere").thermal.duplicate()
	var w: Dictionary = Config.get_config("weather/medium")
	c["radius_m"] = w.thermal_radius_m
	c["duty"] = float(w.thermal_duty)
	c["cloudbase_msl"] = cb
	return c


static func _sun_half(x: float, _z: float) -> float:
	return 300.0 if x < 0.0 else -30.0


## Полоса схождения (подъём по всему слою) на x = −1200 м, ширина σ = 250 м.
static func _conv_line(x: float, _z: float, agl: float) -> float:
	var zeta := clampf(agl / 1500.0, 0.0, 1.0)
	return 0.6 * exp(-pow((x + 1200.0) / 250.0, 2.0)) * sin(PI * zeta)


static func _zero3(_x: float, _z: float, _a: float) -> float:
	return 0.0


static func _heat300(_x: float, _z: float) -> float:
	return 300.0


# ---------------------------------------------------------------- источники


func test_sources_sunny_convergence_not_shade() -> void:
	var f := _flat(_sun_half, _conv_line)
	var s := AirThermals.new()
	check(s.build(f, _cfg()), "источники строятся")
	var n_shade := 0
	var n_line := 0
	var n_sun := 0
	var q_line := 0.0
	var q_sun := 0.0
	var near_line := false
	for k in s.count():
		var p := s.pos[k]
		if p.x >= 0.0:
			n_shade += 1
		elif absf(p.x + 1200.0) < 300.0:
			n_line += 1
			q_line += s.carried[k]
			near_line = near_line or absf(p.x + 1200.0) <= 150.0
		elif p.x < -300.0 and absf(p.x + 1200.0) > 600.0:
			n_sun += 1
			q_sun += s.carried[k]
	print(
		(
			"    источников %d: в тени %d, в схождении %d (ядра %.0f м³/с), на солнце %d (%.0f)"
			% [s.count(), n_shade, n_line, q_line / maxi(n_line, 1), n_sun, q_sun / maxi(n_sun, 1)]
		)
	)
	check(n_shade == 0, "в тени (H < 0) источников нет")
	check(n_sun > 0, "на прогретой равнине источники есть")
	check(near_line, "источник на оси схождения (±150 м)")
	check(q_line / n_line > 1.2 * q_sun / n_sun, "в схождении пузыри несут больше (сильнее)")
	# сила ≈ k·w* (Аллен): на равнине
	var ws := s.wstar[0]
	var k_min := INF
	var k_max := 0.0
	for k in s.count():
		if s.pos[k].x < -300.0 and absf(s.pos[k].x + 1200.0) > 600.0:
			k_min = minf(k_min, s.w0[k] / s.wstar[k])
			k_max = maxf(k_max, s.w0[k] / s.wstar[k])
	print(
		(
			"    w* %.2f м/с, w0/w* на равнине %.2f…%.2f (k Аллена %.2f)"
			% [ws, k_min, k_max, AirThermals.K_ALLEN]
		)
	)
	check(ws > 1.5 and ws < 3.0, "w* в разумных пределах (%.2f)" % ws)
	check(
		k_min > 0.5 and k_max <= AirThermals.K_MAX + 1e-3,
		"сила пузыря ~ w* (%.2f…%.2f)" % [k_min, k_max]
	)


func test_ceiling_inversion_and_cloudbase() -> void:
	# Инверсия 20 К/км над z_i = 2000 м: частица с избытком Холтслага–Бовилля останавливается у z_i.
	var f := _flat(_heat300, _zero3, 2000.0, 0.02)
	var s := AirThermals.new()
	s.build(f, _cfg())
	check(s.count() > 0, "источники есть")
	var t0 := s.top[0]
	print("    инверсия 20 К/км на 2000 м: потолок частицы %.0f м" % t0)
	check(t0 > 2000.0 and t0 < 2100.0, "потолок ≈ высоте инверсии (%.0f м)" % t0)
	# Слабая устойчивость выше (5,8 К/км): проскок выше — Δθ/Γ.
	var f2 := _flat(_heat300, _zero3, 2000.0, 0.0058)
	var s2 := AirThermals.new()
	s2.build(f2, _cfg())
	print("    свободная атмосфера 5,8 К/км над 2000 м: потолок %.0f м" % s2.top[0])
	check(s2.top[0] > t0 + 50.0, "без сильной инверсии — выше")
	# Тёплый слой θ′ поля (например опускание над долиной) — потолок ниже.
	var f3 := _flat(_heat300, _zero3, 2000.0, 0.0058, Vector2.ZERO, _warm_lid)
	var s3 := AirThermals.new()
	s3.build(f3, _cfg())
	print("    тёплый слой θ′ +2 К с 800 м: потолок %.0f м" % s3.top[0])
	check(s3.top[0] < GROUND + 900.0, "θ′ поля гасит частицу (инверсия «сама»)")
	# В атмосфере: потолок термика = min(частица, кромка); частица ниже кромки — сухой термик.
	var a := _atmo(f)
	a.set_cloudbase_msl(2600.0)
	a.set_air_field(f, 0.0)
	_run(a, 1200.0)
	var n := 0
	var ok := true
	var dry := true
	for id in a.field.thermals:
		var th: AtmoThermal = a.field.thermals[id]
		if th.cell.x >= 1 << 19:
			n += 1
			ok = ok and absf(th.top - s.top[0]) < 60.0
			dry = dry and not th.has_cloud
	check(n > 0 and ok, "термики поля — до инверсии, не до кромки 2600 (%d)" % n)
	check(dry, "не дошли до кромки — без облака")
	a.free()
	var b := _atmo(f2)
	b.set_cloudbase_msl(2100.0)
	b.set_air_field(f2, 0.0)
	_run(b, 1200.0)
	var tops := []
	for id in b.field.thermals:
		var th: AtmoThermal = b.field.thermals[id]
		if th.cell.x >= 1 << 19:
			tops.append(th.top)
	check(not tops.is_empty() and tops.max() <= 2100.0 + 1e-3, "частица выше кромки — до кромки")
	b.free()


static func _warm_lid(agl: float) -> float:
	return 2.0 * smoothstep(750.0, 850.0, agl)


# ---------------------------------------------------------------- поток массы


func test_mass_flux_matches_field() -> void:
	var f := _flat(_heat300, _conv_line)
	var s := AirThermals.new()
	s.build(f, _cfg())
	var m_sum := 0.0
	for k in s.count():
		m_sum += s.flux[k]
	print(
		(
			"    поток: поля %.0f м³/с, водосборам %.0f, несут ядра %.0f, без хозяина %.0f; жизнь %.2f"
			% [s.total_flux, m_sum, s.carried_flux, s.lost_flux, s.life_mean]
		)
	)
	check(
		absf(m_sum + s.lost_flux - s.total_flux) < 1.0e-3 * s.total_flux, "поток распределён весь"
	)
	check(s.lost_flux < 0.05 * s.total_flux, "почти весь — водосборам источников")
	# Монте-Карло: средний поток ядер пузырей (w > 0) на ξ = 0,5 в середине окна за 40 мин
	# против Φ поля (F̄ + W̄⁺), штиль — без сноса за край.
	var a := _atmo(f)
	a.set_air_field(f, 0.0)
	var got := 0.0
	var want := 0.0
	var n := 0
	var tf := a.field
	for step in 48:
		_run(a, 50.0)
		var keep := tf.air_src
		for j in range(-12, 13):
			for i in range(-12, 13):
				var x := i * 80.0
				var z := j * 80.0
				var c := s.level
				var ci := int(floor((x - c.x0) / DX))
				var cj := int(floor((-z - c.y0) / DX))
				var col := cj * N + ci
				var owner := keep.owner[col]
				if owner < 0:
					continue
				var d := keep.depth[owner]
				var p := Vector3(x, GROUND + 0.5 * d, z)
				tf.air_src = null
				got += maxf(tf.sample(p).x, 0.0)
				tf.air_src = keep
				want += keep.expected_up(p)
				n += 1
	var r := got / maxf(want, 1.0e-9)
	print(
		(
			"    Монте-Карло (ξ = 0,5, %d точек): ядра %.3f м/с, ожидание поля %.3f — %.2f"
			% [n, got / n, want / n, r]
		)
	)
	check(r > 0.8 and r < 1.2, "поток ядер = потоку поля ±20 %% (%.2f)" % r)
	a.free()


# ---------------------------------------------------------------- сеть


func test_host_mask_same_sources_with_noise() -> void:
	var f := _flat(_sun_half, _conv_line)
	var g := _noisy(f, 1.0e-3 * 3.0)
	var a := AirThermals.new()
	a.build(f, _cfg())
	var b := AirThermals.new()
	b.build(g, _cfg())
	var same := a.count() == b.count()
	var diff := 0
	var set_a := {}
	for c in a.col:
		set_a[c] = true
	for c in b.col:
		if not set_a.has(c):
			diff += 1
	print("    без ведущего: источников %d / %d, других столбцов %d" % [a.count(), b.count(), diff])
	var c2 := AirThermals.new()
	c2.build(g, _cfg(), a.mask_bytes())
	check(c2.col == a.col, "с маской ведущего — те же столбцы")
	var dw := 0.0
	var dt := 0.0
	var dd := 0.0
	for k in a.count():
		dw = maxf(dw, absf(c2.w0[k] - a.w0[k]) / a.w0[k])
		dt = maxf(dt, absf(c2.top[k] - a.top[k]))
		dd = maxf(dd, (c2.drift[k] - a.drift[k]).length())
	print("    с маской: |Δw0| ≤ %.5f отн., |Δпотолок| ≤ %.3f м, |Δснос| ≤ %.5f м/с" % [dw, dt, dd])
	check(dw < 0.01 and dt < 5.0 and dd < 0.01, "параметры — в пределах шума поля")
	print("    (без ведущего одинаковы: %s)" % same)


## То же поле + шум амплитуды amp (м/с для скоростей, К·amp/3 для θ′).
static func _noisy(f: WindField, amp: float) -> WindField:
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var n := f.nx * f.ny * f.nz
	var u := PackedFloat32Array()
	var v := PackedFloat32Array()
	var wm := PackedFloat32Array()
	var wc := PackedFloat32Array()
	var th := PackedFloat32Array()
	for a: PackedFloat32Array in [u, v, wm, wc, th]:
		a.resize(n)
	for c in n:
		u[c] = f._vel[c * 3] + rng.randf_range(-amp, amp)
		v[c] = f._vel[c * 3 + 1] + rng.randf_range(-amp, amp)
		wm[c] = f._vel[c * 3 + 2] + rng.randf_range(-amp, amp)
		wc[c] = f._wconv[c] + rng.randf_range(-amp, amp)
		th[c] = f._theta[c] + rng.randf_range(-amp, amp) / 3.0
	return WindField.from_arrays(f.meta.duplicate(), u, v, wm, wc, th, f._hc)


func test_two_clients_same_thermals() -> void:
	var f := _flat(_sun_half, _conv_line)
	var g := _noisy(f, 3.0e-3)
	var host := _atmo(f)
	host.set_air_field(f, 0.0)
	_run(host, 1.0)
	var mask := host.field.air_sources_mask()
	var cl := _atmo(g)
	cl.set_air_field(g, 0.0)
	cl.field.set_air_forced(String(mask.sig), mask.mask)
	for a: Atmosphere in [host, cl]:
		a.start_at(3000.0)
	var ids_h: Array = host.field.thermals.keys()
	var ids_c: Array = cl.field.thermals.keys()
	ids_h.sort()
	ids_c.sort()
	check(ids_h == ids_c, "те же термики (%d / %d)" % [ids_h.size(), ids_c.size()])
	var dp := 0.0
	var ds := 0.0
	for id in ids_h:
		if not cl.field.thermals.has(id):
			continue
		var a: AtmoThermal = host.field.thermals[id]
		var b: AtmoThermal = cl.field.thermals[id]
		dp = maxf(dp, (a.axis_at(1500.0) - b.axis_at(1500.0)).length())
		ds = maxf(ds, absf(a.strength - b.strength))
	print(
		(
			"    два клиента (шум поля 3e-3): термиков %d, |Δось| ≤ %.2f м, |Δсила| ≤ %.3f м/с"
			% [ids_h.size(), dp, ds]
		)
	)
	check(dp < 20.0 and ds < 0.05, "позиции и сила совпадают в пределах шума")
	host.free()
	cl.free()


# ---------------------------------------------------------------- атмосфера


func test_atmosphere_field_region_and_off() -> void:
	var f := _flat(_heat300, _zero3)
	var a := _atmo(f)
	var ref := _atmo(f)
	a.set_air_field(f, 0.0)
	for x: Atmosphere in [a, ref]:
		x.start_at(2000.0)
	var n_air := 0
	var n_grid_in := 0
	var n_grid_out := 0
	for id in a.field.thermals:
		var th: AtmoThermal = a.field.thermals[id]
		var inside := f.edge_weight(Vector3(th.src.x, GROUND + 10.0, th.src.z)) >= 0.5
		if th.cell.x >= 1 << 19:
			n_air += 1
		elif inside:
			n_grid_in += 1
		else:
			n_grid_out += 1
	print(
		"    термики: поля %d, сетки в поле %d, сетки вне поля %d" % [n_air, n_grid_in, n_grid_out]
	)
	check(n_air > 0, "в поле — термики поля")
	check(n_grid_in == 0, "в поле — нет термиков сетки")
	check(n_grid_out > 0, "вне поля — аналитика")
	# Выключенное поле — как без поля (те же термики).
	a.set_air_mode("off")
	a.start_at(2000.0)
	var k1: Array = a.field.thermals.keys()
	var k2: Array = ref.field.thermals.keys()
	k1.sort()
	k2.sort()
	check(k1 == k2, "поле выключено — термики как без поля")
	# «Между» в поле: фоновое опускание не действует, вместо него w_conv − поток пузырей.
	a.set_air_mode("auto")
	a.start_at(2000.0)
	var p := Vector3(-300.0, GROUND + 600.0, 700.0)
	var th := a.field.sample(p)
	check(th.y > 0.99 or th.x != 0.0, "в поле маска фона ≈ 1 (%.3f)" % th.y)
	a.free()
	ref.free()


func test_real_kayancha_fixture() -> void:
	var f := WindField.load_file(FIXTURE)
	check(f != null, "фикстура читается")
	if f == null:
		return
	check(AirThermals.has_inputs(f), "в фикстуре есть H и z_i")
	var s := AirThermals.new()
	var cb := float(f.meta.z_lcl)
	check(s.build(f, _cfg(cb)), "источники строятся")
	var n := s.count()
	var kmin := INF
	var kmax := 0.0
	var agl := 0.0
	for k in n:
		kmin = minf(kmin, s.w0[k] / s.wstar[k])
		kmax = maxf(kmax, s.w0[k] / s.wstar[k])
		agl += minf(s.top[k], cb) - s.pos[k].y
	print(
		(
			"    Каянча 12:00 (32×32): ист. %d, w* %.2f, w0/w* %.2f…%.2f, столб %.0f, снос (%.2f, %.2f)"
			% [
				n,
				s.wstar[0] if n > 0 else 0.0,
				kmin,
				kmax,
				agl / maxi(n, 1),
				s.drift[0].x if n > 0 else 0.0,
				s.drift[0].y if n > 0 else 0.0
			]
		)
	)
	check(n > 0, "источники есть")
	check(kmin > 0.3 and kmax <= AirThermals.K_MAX + 1e-3, "сила ~ w*")
	print(
		(
			"    поток: поля %.0f, несут ядра %.0f (%.0f %%)"
			% [s.total_flux, s.carried_flux, 100.0 * s.carried_flux / s.total_flux]
		)
	)


# ---------------------------------------------------------------- помощники


static func _atmo(f: WindField) -> Atmosphere:
	var w: Dictionary = Config.get_config("weather/medium").duplicate(true)
	w.wind_speed_kmh = 0.0
	w.thermal_extreme_chance = 0.0
	var a := Atmosphere.new()
	a.visuals_enabled = false
	a.seed_value = 7
	a.configure(Config.get_config("atmosphere"), w)
	a.set_ground(f.ground_height, _sun_one)
	a.turbulence_enabled = false
	a.wave.enabled = false
	a.set_focus(Vector3(0.0, GROUND + 500.0, 0.0))
	a.step(0.01)
	return a


static func _sun_one(_x: float, _z: float) -> float:
	return 1.0


static func _run(a: Atmosphere, secs: float) -> void:
	var t := 0.0
	while t < secs:
		a.step(1.0)
		t += 1.0
